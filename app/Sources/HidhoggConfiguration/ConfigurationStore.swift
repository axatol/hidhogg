import Darwin
import Foundation
import HidhoggDomain

public actor ConfigurationStore {
    private let url: URL
    private let initialWorkspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
    private let beforeRegistryPublication: (@Sendable () throws -> Void)?
    private let beforePayloadCleanup: (@Sendable () throws -> Void)?

    public init(url: URL) {
        self.url = url.standardizedFileURL
        beforeRegistryPublication = nil
        beforePayloadCleanup = nil
    }

    init(url: URL, beforeRegistryPublication: @escaping @Sendable () throws -> Void) {
        self.url = url.standardizedFileURL
        self.beforeRegistryPublication = beforeRegistryPublication
        beforePayloadCleanup = nil
    }

    init(url: URL, beforePayloadCleanup: @escaping @Sendable () throws -> Void) {
        self.url = url.standardizedFileURL
        beforeRegistryPublication = nil
        self.beforePayloadCleanup = beforePayloadCleanup
    }

    public func load() throws -> ConfigurationSnapshot {
        let snapshot = try readSnapshot()
        guard let data = snapshot.root else { return snapshot.snapshot }
        let version = try RegistryCodec.version(data)
        if version == AppConfiguration.currentVersion {
            return try publish(snapshot.snapshot.workspace, expecting: snapshot.snapshot.revision, legacyBackup: data)
        }
        let manifest = try RegistryCodec.manifest(data)
        guard manifest.devices.contains(where: \.usesLegacyPath) else { return snapshot.snapshot }
        return try publish(snapshot.snapshot.workspace, expecting: snapshot.snapshot.revision)
    }

    public func save(
        _ configuration: AppConfiguration,
        expecting expectedRevision: FileRevision
    ) throws -> ConfigurationSnapshot {
        _ = try ConfigurationCodec.encode(configuration)
        try requireRevision(expectedRevision)
        let current = try readSnapshot()
        guard current.snapshot.revision == expectedRevision else { throw ConfigurationError.revisionConflict }
        return try publish(current.snapshot.workspace.applying(configuration), expecting: expectedRevision,
                           legacyBackup: current.root.flatMap { (try? RegistryCodec.version($0)) == 1 ? $0 : nil })
    }

    public func save(_ workspace: WorkspaceConfiguration, expecting expectedRevision: FileRevision) throws -> ConfigurationSnapshot {
        try publish(workspace, expecting: expectedRevision)
    }

    private func readSnapshot() throws -> (snapshot: ConfigurationSnapshot, root: Data?) {
        guard let data = try ConfigurationFileSystem.read(from: url) else {
            return (ConfigurationSnapshot(workspace: initialWorkspace, revision: .missing), nil)
        }
        let version = try RegistryCodec.version(data)
        if version == AppConfiguration.currentVersion {
            let configuration = try ConfigurationCodec.decode(data)
            return (ConfigurationSnapshot(configuration: configuration, revision: FileRevision(contents: data)), data)
        }
        let manifest = try RegistryCodec.manifest(data)
        var references: [String: Data] = [:]
        let devices = try manifest.devices.map { reference in
            guard let payload = try ConfigurationFileSystem.read(from: payloadURL(reference)) else {
                throw ConfigurationError.invalidDocument
            }
            references[reference.relativePath] = payload
            return try RegistryCodec.device(payload, reference: reference)
        }
        let workspace: WorkspaceConfiguration
        do { workspace = try WorkspaceConfiguration(connectOnLaunch: manifest.connectOnLaunch, devices: devices).validated() }
        catch { throw ConfigurationError.invalidConfiguration(error.localizedDescription) }
        return (ConfigurationSnapshot(workspace: workspace, revision: FileRevision(contents: data, references: references)), data)
    }

    private func publish(_ workspace: WorkspaceConfiguration, expecting expectedRevision: FileRevision,
                         legacyBackup: Data? = nil) throws -> ConfigurationSnapshot {
        let validated: WorkspaceConfiguration
        do { validated = try workspace.validated() }
        catch { throw ConfigurationError.invalidConfiguration(error.localizedDescription) }
        return try ConfigurationFileSystem.withExclusiveLock(at: url) {
            try requireRevision(expectedRevision)
            let current = try readSnapshot()
            guard current.snapshot.revision == expectedRevision else { throw ConfigurationError.revisionConflict }
            let backupData = legacyBackup ?? current.root.flatMap { (try? RegistryCodec.version($0)) == 1 ? $0 : nil }
            if let legacyBackup = backupData {
                let backup = url.appendingPathExtension("legacy-v1.backup")
                if let existing = try ConfigurationFileSystem.read(from: backup) {
                    guard existing == legacyBackup else { throw ConfigurationError.revisionConflict }
                } else {
                    try ConfigurationFileSystem.createImmutable(legacyBackup, at: backup)
                }
            }
            var payloads: [String: Data] = [:]
            let references = try validated.devices.map { device in
                let data = try RegistryCodec.encode(device: device)
                let reference = RegistryReference(device: device, contentHash: RegistryCodec.shortSHA256(data))
                try ConfigurationFileSystem.createImmutableOrVerify(data, at: payloadURL(reference))
                payloads[reference.relativePath] = data
                return reference
            }
            let data = try RegistryCodec.encode(RegistryManifest(connectOnLaunch: validated.connectOnLaunch, devices: references))
            try beforeRegistryPublication?()
            try requireRevision(expectedRevision)
            _ = try ConfigurationFileSystem.replace(data, at: url, expecting: FileRevision(contents: current.root)) {
                try self.requireRevision(expectedRevision)
            }
            cleanupObsoletePayloads(afterPublishing: data)
            return ConfigurationSnapshot(workspace: validated, revision: FileRevision(contents: data, references: payloads))
        }
    }

    private func cleanupObsoletePayloads(afterPublishing rootData: Data) {
        guard rootStillMatches(rootData), let manifest = try? RegistryCodec.manifest(rootData) else { return }
        let activePaths = Set(manifest.devices.map(\.relativePath))
        do {
            let candidates = try ConfigurationFileSystem.managedPayloadCandidates(near: url)
            let nestedDirectories = Set(candidates.compactMap(\.nestedDirectory))
            try beforePayloadCleanup?()
            for candidate in candidates {
                guard !activePaths.contains(candidate.relativePath),
                      let data = try? ConfigurationFileSystem.read(from: candidate.url),
                      RegistryCodec.recognizesManagedPayload(data, id: candidate.id, family: candidate.family),
                      candidate.contentHash.map({ $0 == RegistryCodec.shortSHA256(data) }) ?? true else {
                    continue
                }
                guard (try? ConfigurationFileSystem.removeRegularFile(
                    candidate.url,
                    ifContents: data,
                    registryIsCurrent: { self.rootStillMatches(rootData) }
                )) != false else {
                    return
                }
            }

            for directory in nestedDirectories {
                guard (try? ConfigurationFileSystem.removeEmptyDirectory(
                    directory,
                    registryIsCurrent: { self.rootStillMatches(rootData) }
                )) != false else {
                    return
                }
            }
        } catch {
            return
        }
    }

    private func rootStillMatches(_ expected: Data) -> Bool {
        do { return try ConfigurationFileSystem.read(from: url) == expected }
        catch { return false }
    }

    private func payloadURL(_ reference: RegistryReference) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(reference.relativePath)
    }

    private func requireRevision(_ expected: FileRevision) throws {
        guard try ConfigurationFileSystem.read(from: url) == expected.rootContents else {
            throw ConfigurationError.revisionConflict
        }
        for (path, data) in expected.referencedContents {
            guard try ConfigurationFileSystem.read(from: url.deletingLastPathComponent().appendingPathComponent(path)) == data else {
                throw ConfigurationError.revisionConflict
            }
        }
    }
}

private enum ConfigurationFileSystem {
    private struct ImmutablePathAlreadyExists: Error {}

    struct ManagedPayloadCandidate {
        let url: URL
        let relativePath: String
        let id: UUID
        let family: DeviceFamily?
        let contentHash: String?
        let nestedDirectory: URL?
    }

    static func read(from url: URL) throws -> Data? {
        try validate(url)
        let directoryURL = url.deletingLastPathComponent().standardizedFileURL
        try rejectSymbolicLinks(in: directoryURL)

        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw accessError(for: errno)
        }
        defer { Darwin.close(directoryDescriptor) }

        return try readFile(named: url.lastPathComponent, in: directoryDescriptor)
    }

    static func replace(_ data: Data, at url: URL, expecting expectedRevision: FileRevision,
                        validateRevision: () throws -> Void = {}) throws -> FileRevision {
        try validate(url)
        let directoryURL = url.deletingLastPathComponent().standardizedFileURL
        try rejectSymbolicLinks(in: directoryURL)

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ConfigurationError.filesystemAccessFailed
        }

        try rejectSymbolicLinks(in: directoryURL)
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw accessError(for: errno)
        }
        defer { Darwin.close(directoryDescriptor) }

        let currentData = try readFile(named: url.lastPathComponent, in: directoryDescriptor)
        guard FileRevision(contents: currentData) == expectedRevision else {
            throw ConfigurationError.revisionConflict
        }

        let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let temporaryDescriptor = Darwin.openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard temporaryDescriptor >= 0 else {
            throw ConfigurationError.filesystemAccessFailed
        }

        var temporaryIsOpen = true
        var temporaryNeedsRemoval = true
        defer {
            if temporaryIsOpen {
                Darwin.close(temporaryDescriptor)
            }
            if temporaryNeedsRemoval {
                Darwin.unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        try write(data, to: temporaryDescriptor)
        guard Darwin.fchmod(temporaryDescriptor, mode_t(0o600)) == 0,
              Darwin.fsync(temporaryDescriptor) == 0 else {
            throw ConfigurationError.filesystemAccessFailed
        }
        Darwin.close(temporaryDescriptor)
        temporaryIsOpen = false

        let latestData = try readFile(named: url.lastPathComponent, in: directoryDescriptor)
        guard FileRevision(contents: latestData) == expectedRevision else {
            throw ConfigurationError.revisionConflict
        }
        try validateRevision()

        guard Darwin.renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            url.lastPathComponent
        ) == 0 else {
            throw ConfigurationError.filesystemAccessFailed
        }
        temporaryNeedsRemoval = false
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw ConfigurationError.publicationDurabilityUncertain }

        return FileRevision(contents: data)
    }

    static func withExclusiveLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        try validate(url)
        try prepareDirectory(url.deletingLastPathComponent())
        let lockURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw accessError(for: errno) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              flock(descriptor, LOCK_EX) == 0 else { throw ConfigurationError.filesystemAccessFailed }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    static func createImmutable(_ data: Data, at url: URL, allowExistingRace: Bool = false) throws {
        try validate(url)
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == EEXIST, allowExistingRace { throw ImmutablePathAlreadyExists() }
            throw accessError(for: errno)
        }
        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed { Darwin.unlink(url.path) }
        }
        try write(data, to: descriptor)
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0, Darwin.fsync(descriptor) == 0 else {
            throw ConfigurationError.filesystemAccessFailed
        }
        try synchronizeDirectory(directory)
        completed = true
    }

    static func createImmutableOrVerify(_ data: Data, at url: URL) throws {
        if let existing = try read(from: url) {
            guard existing == data else { throw ConfigurationError.payloadHashCollision }
            try synchronizeExistingFileAndParent(at: url, ifContents: data)
            return
        }

        do {
            try createImmutable(data, at: url, allowExistingRace: true)
        } catch is ImmutablePathAlreadyExists {
            guard let existing = try read(from: url) else { throw ConfigurationError.filesystemAccessFailed }
            guard existing == data else { throw ConfigurationError.payloadHashCollision }
            try synchronizeExistingFileAndParent(at: url, ifContents: data)
        }
    }

    private static func synchronizeExistingFileAndParent(at url: URL, ifContents expectedData: Data) throws {
        try validate(url)
        let directoryURL = url.deletingLastPathComponent().standardizedFileURL
        try rejectSymbolicLinks(in: directoryURL)
        let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw accessError(for: errno) }
        defer { Darwin.close(directoryDescriptor) }

        let fileDescriptor = Darwin.openat(directoryDescriptor, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else { throw accessError(for: errno) }
        defer { Darwin.close(fileDescriptor) }
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ConfigurationError.filesystemAccessFailed
        }
        guard try readContents(from: fileDescriptor) == expectedData else { throw ConfigurationError.revisionConflict }
        guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0,
              Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0,
              Darwin.fsync(fileDescriptor) == 0,
              Darwin.fsync(directoryDescriptor) == 0 else {
            throw ConfigurationError.filesystemAccessFailed
        }
    }

    static func managedPayloadCandidates(near configurationURL: URL) throws -> [ManagedPayloadCandidate] {
        let devicesURL = configurationURL.deletingLastPathComponent().appendingPathComponent("devices", isDirectory: true)
        let entries = try directoryEntries(at: devicesURL)
        var candidates: [ManagedPayloadCandidate] = []

        for name in entries {
            if let flat = flatPayloadCandidate(name: name, devicesURL: devicesURL) {
                candidates.append(flat)
                continue
            }
            guard let id = canonicalUUID(name) else { continue }

            let directoryURL = devicesURL.appendingPathComponent(name, isDirectory: true)
            let nestedEntries: [String]
            do { nestedEntries = try directoryEntries(at: directoryURL) }
            catch { continue }
            for filename in nestedEntries {
                guard filename.hasSuffix(".toml"),
                      let revision = canonicalUUID(String(filename.dropLast(".toml".count))) else {
                    continue
                }
                let relativePath = "devices/\(name)/\(revision.uuidString).toml"
                candidates.append(ManagedPayloadCandidate(
                    url: directoryURL.appendingPathComponent(filename),
                    relativePath: relativePath,
                    id: id,
                    family: nil,
                    contentHash: nil,
                    nestedDirectory: directoryURL
                ))
            }
        }

        return candidates
    }

    static func removeRegularFile(_ url: URL, ifContents expectedData: Data,
                                  registryIsCurrent: () -> Bool) throws -> Bool {
        try validate(url)
        let directoryURL = url.deletingLastPathComponent().standardizedFileURL
        try rejectSymbolicLinks(in: directoryURL)
        let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw accessError(for: errno) }
        defer { Darwin.close(directoryDescriptor) }

        guard try readFile(named: url.lastPathComponent, in: directoryDescriptor) == expectedData else { return true }
        var status = stat()
        guard Darwin.fstatat(directoryDescriptor, url.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return true }
            throw accessError(for: errno)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return true }
        guard registryIsCurrent() else { return false }
        guard Darwin.unlinkat(directoryDescriptor, url.lastPathComponent, 0) == 0 else {
            if errno == ENOENT { return true }
            throw accessError(for: errno)
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else { throw ConfigurationError.filesystemAccessFailed }
        return true
    }

    static func removeEmptyDirectory(_ url: URL, registryIsCurrent: () -> Bool) throws -> Bool {
        try validate(url)
        let parentURL = url.deletingLastPathComponent().standardizedFileURL
        try rejectSymbolicLinks(in: parentURL)
        let parentDescriptor = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { throw accessError(for: errno) }
        defer { Darwin.close(parentDescriptor) }

        var status = stat()
        guard Darwin.fstatat(parentDescriptor, url.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return true }
            throw accessError(for: errno)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return true }
        guard registryIsCurrent() else { return false }
        guard Darwin.unlinkat(parentDescriptor, url.lastPathComponent, AT_REMOVEDIR) == 0 else {
            if errno == ENOENT || errno == ENOTEMPTY { return true }
            throw accessError(for: errno)
        }
        guard Darwin.fsync(parentDescriptor) == 0 else { throw ConfigurationError.filesystemAccessFailed }
        return true
    }

    private static func directoryEntries(at url: URL) throws -> [String] {
        try validate(url)
        try rejectSymbolicLinks(in: url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { return [] }
            throw accessError(for: errno)
        }
        guard let stream = Darwin.fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw ConfigurationError.filesystemAccessFailed
        }
        defer { Darwin.closedir(stream) }

        var result: [String] = []
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            result.append(name)
        }
        return result
    }

    private static func flatPayloadCandidate(name: String, devicesURL: URL) -> ManagedPayloadCandidate? {
        guard name.hasSuffix(".toml") else { return nil }
        for family in DeviceFamily.allCases {
            let prefix = family.rawValue + "."
            guard name.hasPrefix(prefix) else { continue }
            let stem = String(name.dropFirst(prefix.count).dropLast(".toml".count))
            let components = stem.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 2,
                  let id = canonicalUUID(String(components[0])),
                  RegistryPayloadRevision.isContentHash(String(components[1])) else {
                return nil
            }
            return ManagedPayloadCandidate(
                url: devicesURL.appendingPathComponent(name),
                relativePath: "devices/\(name)",
                id: id,
                family: family,
                contentHash: String(components[1]),
                nestedDirectory: nil
            )
        }
        return nil
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value), uuid.uuidString == value else { return nil }
        return uuid
    }

    private static func prepareDirectory(_ directory: URL) throws {
        try rejectSymbolicLinks(in: directory)
        var directoriesToSync = [directory]
        var ancestor = directory
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            ancestor = ancestor.deletingLastPathComponent()
            directoriesToSync.append(ancestor)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ConfigurationError.filesystemAccessFailed }
        try rejectSymbolicLinks(in: directory)
        for directory in directoriesToSync { try synchronizeDirectory(directory) }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw accessError(for: errno) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw ConfigurationError.filesystemAccessFailed }
    }

    private static func validate(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/", !url.lastPathComponent.isEmpty else {
            throw ConfigurationError.invalidLocation
        }
    }

    private static func rejectSymbolicLinks(in url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)

        for component in url.standardizedFileURL.pathComponents where component != "/" {
            current.appendPathComponent(component, isDirectory: true)
            var status = stat()
            guard Darwin.lstat(current.path, &status) == 0 else {
                if errno == ENOENT { return }
                throw ConfigurationError.filesystemAccessFailed
            }
            let isSymbolicLink = status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
            // macOS system aliases such as /tmp are root-owned symbolic links.
            guard !isSymbolicLink || status.st_uid == 0 else {
                throw ConfigurationError.symbolicLinkNotAllowed
            }
        }
    }

    private static func readFile(named name: String, in directoryDescriptor: Int32) throws -> Data? {
        var pathStatus = stat()
        if Darwin.fstatat(directoryDescriptor, name, &pathStatus, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw accessError(for: errno)
        }
        guard pathStatus.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
            throw ConfigurationError.symbolicLinkNotAllowed
        }
        guard pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ConfigurationError.filesystemAccessFailed
        }

        let descriptor = Darwin.openat(directoryDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw accessError(for: errno)
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ConfigurationError.filesystemAccessFailed
        }

        return try readContents(from: descriptor)
    }

    private static func readContents(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)

        while true {
            let remaining = ConfigurationCodec.maximumFileSize + 1 - result.count
            if remaining <= 0 {
                throw ConfigurationError.fileTooLarge
            }

            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ConfigurationError.filesystemAccessFailed
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            if result.count > ConfigurationCodec.maximumFileSize {
                throw ConfigurationError.fileTooLarge
            }
        }

        return result
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0

            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ConfigurationError.filesystemAccessFailed
                }
                guard count > 0 else {
                    throw ConfigurationError.filesystemAccessFailed
                }
                offset += count
            }
        }
    }

    private static func accessError(for code: Int32) -> ConfigurationError {
        code == ELOOP ? .symbolicLinkNotAllowed : .filesystemAccessFailed
    }
}
