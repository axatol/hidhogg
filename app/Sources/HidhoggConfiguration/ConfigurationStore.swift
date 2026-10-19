import Darwin
import Foundation
import HidhoggDomain

public actor ConfigurationStore {
    private let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public func load() throws -> ConfigurationSnapshot {
        let data = try ConfigurationFileSystem.read(from: url)
        guard let data else {
            return ConfigurationSnapshot(configuration: .empty, revision: .missing)
        }

        return ConfigurationSnapshot(
            configuration: try ConfigurationCodec.decode(data),
            revision: FileRevision(contents: data)
        )
    }

    public func save(
        _ configuration: AppConfiguration,
        expecting expectedRevision: FileRevision
    ) throws -> ConfigurationSnapshot {
        let data = try ConfigurationCodec.encode(configuration)
        let revision = try ConfigurationFileSystem.replace(
            data,
            at: url,
            expecting: expectedRevision
        )
        return ConfigurationSnapshot(configuration: configuration, revision: revision)
    }
}

private enum ConfigurationFileSystem {
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

    static func replace(_ data: Data, at url: URL, expecting expectedRevision: FileRevision) throws -> FileRevision {
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

        guard Darwin.renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            url.lastPathComponent
        ) == 0 else {
            throw ConfigurationError.filesystemAccessFailed
        }
        temporaryNeedsRemoval = false
        Darwin.fsync(directoryDescriptor)

        return FileRevision(contents: data)
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
