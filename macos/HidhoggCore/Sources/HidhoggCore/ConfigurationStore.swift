import CryptoKit
import Darwin
import Foundation

public struct ConfigurationStoreDigest: Sendable, Hashable, CustomStringConvertible {
    private let storage: [UInt8]

    init(source: Data) {
        storage = Array(SHA256.hash(data: source))
    }

    public var bytes: Data { Data(storage) }

    public var description: String {
        storage.map { String(format: "%02x", $0) }.joined()
    }
}

public enum ConfigurationStoreOutcome: String, Sendable {
    case unchanged
    case committed
    case uncertain
}

public enum ConfigurationStoreError: String, Error, Sendable, Equatable, CustomStringConvertible {
    case stale = "configuration-changed"
    case invalidDestination = "invalid-destination"
    case mutationFailed = "mutation-failed"
    case invalidConfiguration = "invalid-configuration"
    case diskFailure = "storage-failure"
    case uncertain = "commit-uncertain"

    public var description: String { rawValue }
}

public struct ConfigurationStoreResult: Sendable {
    public let outcome: ConfigurationStoreOutcome
    public let digest: ConfigurationStoreDigest
    public let bytes: Data
    public let error: ConfigurationStoreError?

    init(
        outcome: ConfigurationStoreOutcome,
        digest: ConfigurationStoreDigest,
        bytes: Data = Data(),
        error: ConfigurationStoreError? = nil
    ) {
        self.outcome = outcome
        self.digest = digest
        self.bytes = bytes
        self.error = error
    }
}

public enum ConfigurationStore {
    public static func digest(_ source: Data) -> ConfigurationStoreDigest {
        ConfigurationStoreDigest(source: source)
    }

    /// Applies a strictly validated source edit using an exact-byte digest.
    /// The caller must hold the shared mutation and reload admission gate for
    /// the full operation. An uncertain result means rename succeeded but the
    /// parent-directory sync did not; the returned bytes are already committed.
    /// The second digest check narrows, but cannot remove, the race with an
    /// external writer between that check and rename.
    public static func apply(
        at path: String,
        expectedDigest: ConfigurationStoreDigest,
        mutate: (Data) throws -> Data
    ) throws -> ConfigurationStoreResult {
        try apply(at: path, expectedDigest: expectedDigest, mutate: mutate, fileSystem: ConfigurationStoreFileSystem())
    }

    static func apply(
        at path: String,
        expectedDigest: ConfigurationStoreDigest,
        mutate: (Data) throws -> Data,
        fileSystem: ConfigurationStoreFileSystem
    ) throws -> ConfigurationStoreResult {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw ConfigurationStoreError.invalidDestination }
        let absolutePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let directory = URL(fileURLWithPath: absolutePath).deletingLastPathComponent().path

        let initial = try readDestination(absolutePath, fileSystem: fileSystem)
        guard digest(initial.bytes) == expectedDigest else { throw ConfigurationStoreError.stale }
        do {
            _ = try HidhoggConfigurationDecoder.decode(initial.bytes)
        } catch {
            throw ConfigurationStoreError.invalidConfiguration
        }

        let prospective: Data
        do {
            prospective = independentCopy(try mutate(independentCopy(initial.bytes)))
        } catch {
            throw ConfigurationStoreError.mutationFailed
        }
        do {
            _ = try HidhoggConfigurationDecoder.decode(prospective)
        } catch {
            throw ConfigurationStoreError.invalidConfiguration
        }

        if prospective == initial.bytes {
            let current = try readDestination(absolutePath, fileSystem: fileSystem)
            guard digest(current.bytes) == expectedDigest else { throw ConfigurationStoreError.stale }
            return ConfigurationStoreResult(outcome: .unchanged, digest: digest(initial.bytes))
        }

        let temporary = try createTemporary(in: directory, fileSystem: fileSystem)
        var temporaryIsOpen = true
        var renamed = false
        defer {
            if temporaryIsOpen { _ = fileSystem.close(temporary.descriptor) }
            if !renamed { _ = fileSystem.remove(temporary.path) }
        }

        try writeTemporary(prospective, to: temporary.descriptor, permissions: initial.permissions, fileSystem: fileSystem)
        guard fileSystem.sync(temporary.descriptor) else { throw ConfigurationStoreError.diskFailure }
        let closed = fileSystem.close(temporary.descriptor)
        temporaryIsOpen = false
        guard closed else { throw ConfigurationStoreError.diskFailure }

        let current = try readDestination(absolutePath, fileSystem: fileSystem)
        guard digest(current.bytes) == expectedDigest else { throw ConfigurationStoreError.stale }
        guard fileSystem.rename(temporary.path, absolutePath) else { throw ConfigurationStoreError.diskFailure }
        renamed = true

        let committedDigest = digest(prospective)
        let directorySynchronized = synchronizeDirectory(directory, fileSystem: fileSystem)
        guard directorySynchronized else {
            return ConfigurationStoreResult(
                outcome: .uncertain,
                digest: committedDigest,
                bytes: independentCopy(prospective),
                error: .uncertain
            )
        }
        return ConfigurationStoreResult(
            outcome: .committed,
            digest: committedDigest,
            bytes: independentCopy(prospective)
        )
    }
}

private struct DestinationSnapshot {
    let bytes: Data
    let permissions: mode_t
}

private func readDestination(
    _ path: String,
    fileSystem: ConfigurationStoreFileSystem
) throws -> DestinationSnapshot {
    guard let before = fileSystem.lstat(path) else { throw ConfigurationStoreError.diskFailure }
    guard before.isRegular else { throw ConfigurationStoreError.invalidDestination }
    guard let descriptor = fileSystem.openRead(path) else { throw ConfigurationStoreError.diskFailure }

    guard let opened = fileSystem.fstat(descriptor) else {
        _ = fileSystem.close(descriptor)
        throw ConfigurationStoreError.diskFailure
    }
    guard opened.isRegular else {
        _ = fileSystem.close(descriptor)
        throw ConfigurationStoreError.invalidDestination
    }
    guard opened.sameFile(as: before) else {
        _ = fileSystem.close(descriptor)
        throw ConfigurationStoreError.stale
    }

    var bytes = Data()
    var readFailed = false
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            fileSystem.read(descriptor, rawBuffer.baseAddress!, rawBuffer.count)
        }
        if count == 0 { break }
        if count < 0 {
            if errno == EINTR { continue }
            readFailed = true
            break
        }
        bytes.append(contentsOf: buffer.prefix(count))
    }
    let closed = fileSystem.close(descriptor)
    guard !readFailed, closed else { throw ConfigurationStoreError.diskFailure }

    guard let after = fileSystem.lstat(path) else { throw ConfigurationStoreError.diskFailure }
    guard after.isRegular else { throw ConfigurationStoreError.invalidDestination }
    guard after.sameFile(as: opened) else { throw ConfigurationStoreError.stale }
    return DestinationSnapshot(bytes: bytes, permissions: before.permissions)
}

private func createTemporary(
    in directory: String,
    fileSystem: ConfigurationStoreFileSystem
) throws -> (path: String, descriptor: Int32) {
    guard let temporary = fileSystem.createTemporary(directory) else { throw ConfigurationStoreError.diskFailure }
    return temporary
}

private func writeTemporary(
    _ source: Data,
    to descriptor: Int32,
    permissions: mode_t,
    fileSystem: ConfigurationStoreFileSystem
) throws {
    var offset = 0
    while offset < source.count {
        let count = source.withUnsafeBytes { rawBytes -> Int in
            guard let baseAddress = rawBytes.baseAddress else { return -1 }
            return fileSystem.write(descriptor, baseAddress.advanced(by: offset), source.count - offset)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw ConfigurationStoreError.diskFailure
        }
        guard count > 0 else { throw ConfigurationStoreError.diskFailure }
        offset += count
    }
    guard fileSystem.chmod(descriptor, permissions) else { throw ConfigurationStoreError.diskFailure }
}

private func synchronizeDirectory(_ directory: String, fileSystem: ConfigurationStoreFileSystem) -> Bool {
    guard let descriptor = fileSystem.openDirectory(directory) else { return false }
    let synchronized = fileSystem.sync(descriptor)
    let closed = fileSystem.close(descriptor)
    return synchronized && closed
}

private func independentCopy(_ source: Data) -> Data {
    Data(source.map { $0 })
}

struct ConfigurationStoreFileStatus {
    let device: UInt64
    let inode: UInt64
    let mode: mode_t

    var isRegular: Bool { mode & S_IFMT == S_IFREG }
    var permissions: mode_t { mode & 0o777 }

    func sameFile(as other: ConfigurationStoreFileStatus) -> Bool {
        device == other.device && inode == other.inode
    }
}

struct ConfigurationStoreFileSystem {
    var lstat: (String) -> ConfigurationStoreFileStatus? = systemLstat
    var openRead: (String) -> Int32? = systemOpenRead
    var fstat: (Int32) -> ConfigurationStoreFileStatus? = systemFstat
    var read: (Int32, UnsafeMutableRawPointer, Int) -> Int = systemRead
    var close: (Int32) -> Bool = systemClose
    var createTemporary: (String) -> (path: String, descriptor: Int32)? = systemCreateTemporary
    var write: (Int32, UnsafeRawPointer, Int) -> Int = systemWrite
    var chmod: (Int32, mode_t) -> Bool = systemChmod
    var sync: (Int32) -> Bool = systemSync
    var remove: (String) -> Bool = systemRemove
    var rename: (String, String) -> Bool = systemRename
    var openDirectory: (String) -> Int32? = systemOpenDirectory
}

private func systemLstat(_ path: String) -> ConfigurationStoreFileStatus? {
    var info = stat()
    guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
    return ConfigurationStoreFileStatus(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), mode: info.st_mode)
}

private func systemOpenRead(_ path: String) -> Int32? {
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    return descriptor < 0 ? nil : descriptor
}

private func systemFstat(_ descriptor: Int32) -> ConfigurationStoreFileStatus? {
    var info = stat()
    guard Darwin.fstat(descriptor, &info) == 0 else { return nil }
    return ConfigurationStoreFileStatus(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), mode: info.st_mode)
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Darwin.read(descriptor, buffer, count)
}

private func systemClose(_ descriptor: Int32) -> Bool {
    Darwin.close(descriptor) == 0
}

private func systemCreateTemporary(_ directory: String) -> (path: String, descriptor: Int32)? {
    var template = Array((directory + "/.hidhogg-config-XXXXXX").utf8CString)
    let descriptor = template.withUnsafeMutableBufferPointer { buffer in
        Darwin.mkstemp(buffer.baseAddress!)
    }
    guard descriptor >= 0 else { return nil }
    let pathBytes = template.dropLast().map { UInt8(bitPattern: $0) }
    let path = String(decoding: pathBytes, as: UTF8.self)
    guard Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        _ = Darwin.close(descriptor)
        _ = path.withCString { Darwin.unlink($0) }
        return nil
    }
    return (path, descriptor)
}

private func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    Darwin.write(descriptor, bytes, count)
}

private func systemChmod(_ descriptor: Int32, _ permissions: mode_t) -> Bool {
    Darwin.fchmod(descriptor, permissions) == 0
}

private func systemSync(_ descriptor: Int32) -> Bool {
    Darwin.fsync(descriptor) == 0
}

private func systemRemove(_ path: String) -> Bool {
    path.withCString { Darwin.unlink($0) } == 0
}

private func systemRename(_ oldPath: String, _ newPath: String) -> Bool {
    oldPath.withCString { oldPointer in
        newPath.withCString { newPointer in
            Darwin.rename(oldPointer, newPointer) == 0
        }
    }
}

private func systemOpenDirectory(_ path: String) -> Int32? {
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY) }
    return descriptor < 0 ? nil : descriptor
}
