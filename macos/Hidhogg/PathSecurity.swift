import Foundation
import Darwin

public struct FileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum PathSecurityError: Error, Equatable, Sendable {
    case invalidPath
    case pathTooLong
    case rootChanged
    case missing(String)
    case lstatFailed(String, Int32)
    case wrongType(String)
    case wrongOwner(String)
    case wrongMode(String, UInt16)
    case unexpectedEndpoint(String)
    case notEmpty(String)
}

public enum GenerationRootPolicy: Equatable, Sendable {
    case productionPrivateTemporary
    case injected
}

public enum PathSecurity {
    public static let unixPathBytes = 104
    public static let maximumEncodedPathBytes = unixPathBytes - 1

    public static func validateEncodedSocketPath(_ path: String) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw PathSecurityError.invalidPath
        }
        guard path.utf8.count + 1 <= unixPathBytes else {
            throw PathSecurityError.pathTooLong
        }
    }

    public static func lstat(_ path: String) throws -> (identity: FileIdentity, mode: UInt16, type: UInt16, owner: UInt32) {
        var information = Darwin.stat()
        let result = path.withCString { Darwin.lstat($0, &information) }
        guard result == 0 else {
            let error = errno
            if error == ENOENT {
                throw PathSecurityError.missing(path)
            }
            throw PathSecurityError.lstatFailed(path, error)
        }
        let mode = UInt16(information.st_mode & 0o7777)
        let type = UInt16(information.st_mode & S_IFMT)
        return (
            FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino)),
            mode,
            type,
            UInt32(information.st_uid)
        )
    }

    public static func validateGenerationDirectory(_ url: URL) throws -> FileIdentity {
        let path = url.path
        let result = try lstat(path)
        guard result.type == UInt16(S_IFDIR) else {
            throw PathSecurityError.wrongType(path)
        }
        guard result.owner == UInt32(geteuid()) else {
            throw PathSecurityError.wrongOwner(path)
        }
        guard result.mode == 0o700 else {
            throw PathSecurityError.wrongMode(path, result.mode)
        }
        return result.identity
    }

    public static func validateGenerationRoot(
        _ url: URL,
        policy: GenerationRootPolicy
    ) throws -> FileIdentity {
        let path = url.path
        let result = try lstat(path)
        guard result.type == UInt16(S_IFDIR) else {
            throw PathSecurityError.wrongType(path)
        }
        switch policy {
        case .productionPrivateTemporary:
            guard result.owner == 0 else {
                throw PathSecurityError.wrongOwner(path)
            }
            guard result.mode == 0o1777 else {
                throw PathSecurityError.wrongMode(path, result.mode)
            }
        case .injected:
            guard result.owner == UInt32(geteuid()) else {
                throw PathSecurityError.wrongOwner(path)
            }
        }
        return result.identity
    }

    public static func validateSocket(_ url: URL) throws -> FileIdentity {
        let path = url.path
        let result = try lstat(path)
        guard result.type == UInt16(S_IFSOCK) else {
            throw PathSecurityError.wrongType(path)
        }
        guard result.owner == UInt32(geteuid()) else {
            throw PathSecurityError.wrongOwner(path)
        }
        guard result.mode == 0o600 else {
            throw PathSecurityError.wrongMode(path, result.mode)
        }
        return result.identity
    }

    public static func createGenerationDirectory(root: URL, directoryName: String) throws -> (url: URL, identity: FileIdentity) {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        let path = directory.path
        guard path.utf8.count + 1 <= unixPathBytes else {
            throw PathSecurityError.pathTooLong
        }
        let result = path.withCString { Darwin.mkdir($0, 0o700) }
        guard result == 0 else {
            let error = errno
            if error == EEXIST {
                throw PathSecurityError.unexpectedEndpoint(path)
            }
            throw PathSecurityError.lstatFailed(path, error)
        }
        let createdIdentity = (try? lstat(path))?.identity
        do {
            let identity = try validateGenerationDirectory(directory)
            return (directory, identity)
        } catch {
            if let createdIdentity {
                try? removeMatchingGeneration(
                    directory: directory,
                    directoryIdentity: createdIdentity,
                    socket: directory.appendingPathComponent("runtime.sock"),
                    socketIdentity: nil
                )
            }
            throw error
        }
    }

    public static func removeMatchingGeneration(
        directory: URL,
        directoryIdentity: FileIdentity,
        socket: URL,
        socketIdentity: FileIdentity?
    ) throws {
        let currentDirectory: FileIdentity
        do {
            let result = try lstat(directory.path)
            guard result.type == UInt16(S_IFDIR),
                  result.owner == UInt32(geteuid()),
                  result.mode == 0o700,
                  result.identity == directoryIdentity else {
                return
            }
            currentDirectory = result.identity
        } catch PathSecurityError.missing(_) {
            return
        }

        if let socketIdentity {
            do {
                let result = try lstat(socket.path)
                guard result.type == UInt16(S_IFSOCK),
                      result.owner == UInt32(geteuid()),
                      result.mode == 0o600,
                      result.identity == socketIdentity else {
                    return
                }
                guard socket.path.withCString({ Darwin.unlink($0) }) == 0 || errno == ENOENT else {
                    return
                }
            } catch PathSecurityError.missing(_) {
            } catch {
                return
            }
        }

        guard let beforeRemoval = try? lstat(directory.path),
              beforeRemoval.identity == directoryIdentity,
              beforeRemoval.type == UInt16(S_IFDIR),
              beforeRemoval.owner == UInt32(geteuid()),
              beforeRemoval.mode == 0o700 else {
            return
        }
        guard isEmptyDirectory(directory.path) else { return }
        guard let finalDirectory = try? lstat(directory.path),
              finalDirectory.identity == currentDirectory,
              finalDirectory.type == UInt16(S_IFDIR),
              finalDirectory.owner == UInt32(geteuid()),
              finalDirectory.mode == 0o700 else {
            return
        }
        _ = directory.path.withCString { Darwin.rmdir($0) }
    }

    private static func isEmptyDirectory(_ path: String) -> Bool {
        guard let handle = FileManager.default.enumerator(atPath: path) else { return true }
        return handle.nextObject() == nil
    }
}
