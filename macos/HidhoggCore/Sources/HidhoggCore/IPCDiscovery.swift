import Darwin
import Foundation

public enum IPCDiscoveryError: String, Error, Sendable, Equatable {
    case invalidRuntimeDirectory
    case insecureRuntimeDirectory
    case invalidMetadata
    case invalidSocket
    case identityChanged
}

public struct IPCRuntimePaths: Sendable, Equatable {
    public let directory: String
    public let socketPath: String
    public let metadataPath: String

    public init(directory: String) throws {
        guard !directory.isEmpty, directory.utf8.first == 0x2f, !directory.utf8.contains(0) else {
            throw IPCDiscoveryError.invalidRuntimeDirectory
        }
        let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path
        self.directory = normalized
        socketPath = URL(fileURLWithPath: normalized).appendingPathComponent("runtime.sock", isDirectory: false).path
        metadataPath = URL(fileURLWithPath: normalized).appendingPathComponent("runtime.json", isDirectory: false).path
        guard socketPath.utf8.count + 1 <= 104 else { throw IPCDiscoveryError.invalidRuntimeDirectory }
    }
}

public struct IPCMetadata: Sendable, Equatable {
    public let schemaVersion: Int
    public let instanceID: String
    public let socketName: String

    public static func decode(_ data: Data) throws -> IPCMetadata {
        guard !data.isEmpty, data.count <= 1024,
              let value = try? IPCJSONCodec.decode(data),
              let fields = value.objectFields,
              exactFields(fields, ["schema_version", "instance_id", "socket_name"]),
              value.value(for: "schema_version")?.integerValue == 1,
              let instanceID = value.value(for: "instance_id")?.stringValue,
              isCanonicalUUID(instanceID),
              let socketName = value.value(for: "socket_name")?.stringValue,
              socketName == "runtime.sock" else {
            throw IPCDiscoveryError.invalidMetadata
        }
        return IPCMetadata(schemaVersion: 1, instanceID: instanceID, socketName: socketName)
    }

    public func encode() throws -> Data {
        guard schemaVersion == 1, isCanonicalUUID(instanceID), socketName == "runtime.sock" else {
            throw IPCDiscoveryError.invalidMetadata
        }
        let value = IPCJSONValue.object([
            ("schema_version", .number(IPCJSONNumber(integer: Int64(schemaVersion)))),
            ("instance_id", .string(instanceID)),
            ("socket_name", .string(socketName)),
        ])
        return IPCJSONCodec.encode(value)
    }
}

public struct IPCFileIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let userID: UInt32

    fileprivate init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        userID = UInt32(value.st_uid)
    }
}

public struct IPCResolvedRuntime: Sendable, Equatable {
    public let paths: IPCRuntimePaths
    public let metadata: IPCMetadata
    public let directoryIdentity: IPCFileIdentity
    public let metadataIdentity: IPCFileIdentity
    public let socketIdentity: IPCFileIdentity

    public func revalidate() throws {
        try revalidate(operations: .live)
    }

    func revalidate(operations: IPCPOSIXOperations) throws {
        let current = try IPCRuntimeDiscovery.resolve(paths.directory, operations: operations)
        guard current.metadata == metadata,
              current.directoryIdentity == directoryIdentity,
              current.metadataIdentity == metadataIdentity,
              current.socketIdentity == socketIdentity else {
            throw IPCDiscoveryError.identityChanged
        }
    }
}

public enum IPCRuntimeDiscovery {
    public static func resolve(_ directory: String) throws -> IPCResolvedRuntime {
        try resolve(directory, operations: .live)
    }

    static func resolve(_ directory: String, operations: IPCPOSIXOperations) throws -> IPCResolvedRuntime {
        let paths = try IPCRuntimePaths(directory: directory)
        let directoryStat = try inspect(paths.directory, operations: operations)
        guard fileType(directoryStat.st_mode) == UInt16(S_IFDIR),
              permissions(directoryStat.st_mode) == 0o700,
              directoryStat.st_uid == operations.effectiveUserID() else {
            throw IPCDiscoveryError.insecureRuntimeDirectory
        }

        let directoryOpen = operations.open(paths.directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW, 0)
        let directoryFD = directoryOpen.value
        guard directoryFD >= 0, directoryOpen.error == 0 else { throw IPCDiscoveryError.insecureRuntimeDirectory }
        defer { _ = operations.close(directoryFD) }
        let openedDirectory = try descriptorStat(directoryFD, expectedType: UInt16(S_IFDIR), expectedMode: 0o700, operations: operations)
        guard openedDirectory == IPCFileIdentity(directoryStat) else { throw IPCDiscoveryError.identityChanged }

        let (metadata, metadataIdentity) = try readMetadata(paths.metadataPath, operations: operations)
        let socketIdentity = try inspectSocket(paths.socketPath, operations: operations)
        let currentDirectory = try inspect(paths.directory, operations: operations)
        guard IPCFileIdentity(currentDirectory) == openedDirectory else { throw IPCDiscoveryError.identityChanged }
        return IPCResolvedRuntime(
            paths: paths,
            metadata: metadata,
            directoryIdentity: openedDirectory,
            metadataIdentity: metadataIdentity,
            socketIdentity: socketIdentity
        )
    }
}

private func readMetadata(_ path: String, operations: IPCPOSIXOperations) throws -> (IPCMetadata, IPCFileIdentity) {
    let before = try inspectOwnedRegular(path, operations: operations)
    let openedFile = operations.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0)
    let descriptor = openedFile.value
    guard descriptor >= 0, openedFile.error == 0 else { throw IPCDiscoveryError.invalidMetadata }
    defer { _ = operations.close(descriptor) }
    let opened = try descriptorStat(descriptor, expectedType: UInt16(S_IFREG), expectedMode: 0o600, operations: operations)
    guard opened == before else { throw IPCDiscoveryError.identityChanged }

    var bytes = [UInt8](repeating: 0, count: 1025)
    let capacity = bytes.count
    var count = 0
    while count < capacity {
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            operations.read(descriptor, buffer.baseAddress!.advanced(by: count), capacity - count)
        }
        if readCount.value > 0 {
            count += readCount.value
            continue
        }
        if readCount.value == 0 { break }
        if readCount.error == EINTR { continue }
        throw IPCDiscoveryError.invalidMetadata
    }
    guard count <= 1024 else { throw IPCDiscoveryError.invalidMetadata }
    let metadata = try IPCMetadata.decode(Data(bytes[0..<count]))
    let after = try inspect(path, operations: operations)
    guard IPCFileIdentity(after) == opened else { throw IPCDiscoveryError.identityChanged }
    return (metadata, opened)
}

private func inspectOwnedRegular(_ path: String, operations: IPCPOSIXOperations) throws -> IPCFileIdentity {
    let value = try inspect(path, operations: operations)
    guard fileType(value.st_mode) == UInt16(S_IFREG),
          permissions(value.st_mode) == 0o600,
          value.st_uid == operations.effectiveUserID() else { throw IPCDiscoveryError.invalidMetadata }
    return IPCFileIdentity(value)
}

private func inspectSocket(_ path: String, operations: IPCPOSIXOperations) throws -> IPCFileIdentity {
    let value = try inspect(path, operations: operations)
    guard fileType(value.st_mode) == UInt16(S_IFSOCK),
          permissions(value.st_mode) == 0o600,
          value.st_uid == operations.effectiveUserID() else { throw IPCDiscoveryError.invalidSocket }
    return IPCFileIdentity(value)
}

private func inspect(_ path: String, operations: IPCPOSIXOperations) throws -> stat {
    let result = operations.lstat(path)
    guard result.error == 0 else { throw IPCDiscoveryError.invalidRuntimeDirectory }
    return result.value
}

private func descriptorStat(_ descriptor: Int32, expectedType: UInt16, expectedMode: UInt16, operations: IPCPOSIXOperations) throws -> IPCFileIdentity {
    let result = operations.fstat(descriptor)
    let value = result.value
    guard result.error == 0,
          fileType(value.st_mode) == expectedType,
          permissions(value.st_mode) == expectedMode,
          value.st_uid == operations.effectiveUserID() else { throw IPCDiscoveryError.identityChanged }
    return IPCFileIdentity(value)
}

private func fileType(_ mode: mode_t) -> UInt16 {
    UInt16(mode & mode_t(S_IFMT))
}

private func permissions(_ mode: mode_t) -> UInt16 {
    UInt16(mode & 0o7777)
}

private func isCanonicalUUID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 36, bytes[8] == 0x2d, bytes[13] == 0x2d, bytes[18] == 0x2d, bytes[23] == 0x2d else { return false }
    return bytes.enumerated().allSatisfy { index, byte in
        [8, 13, 18, 23].contains(index) || (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
    }
}

private func exactFields(_ fields: [IPCJSONField], _ names: [String]) -> Bool {
    fields.count == names.count && names.allSatisfy { name in
        fields.contains { $0.key.utf8.elementsEqual(name.utf8) }
    }
}
