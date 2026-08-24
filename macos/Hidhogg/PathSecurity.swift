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
    case removeFailed(String, Int32)
    case directoryReadFailed(String)
    case wrongType(String)
    case wrongOwner(String)
    case wrongMode(String, UInt16)
    case identityChanged(String)
    case unexpectedEndpoint(String)
    case notEmpty(String)
}

public enum GenerationCleanupResult: Equatable, Sendable {
    case removed
    case alreadyAbsent
    case refused(PathSecurityError)
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

    @discardableResult
    public static func removeMatchingGeneration(
        directory: URL,
        directoryIdentity: FileIdentity,
        socket: URL,
        socketIdentity: FileIdentity?
    ) throws -> GenerationCleanupResult {
        let currentDirectory: FileIdentity
        do {
            let result = try lstat(directory.path)
            guard result.type == UInt16(S_IFDIR) else {
                return .refused(.wrongType(directory.path))
            }
            guard result.owner == UInt32(geteuid()) else {
                return .refused(.wrongOwner(directory.path))
            }
            guard result.mode == 0o700 else {
                return .refused(.wrongMode(directory.path, result.mode))
            }
            guard result.identity == directoryIdentity else {
                return .refused(.identityChanged(directory.path))
            }
            currentDirectory = result.identity
        } catch PathSecurityError.missing(_) {
            return .alreadyAbsent
        }

        if let socketIdentity {
            do {
                let result = try lstat(socket.path)
                guard result.type == UInt16(S_IFSOCK) else {
                    return .refused(.wrongType(socket.path))
                }
                guard result.owner == UInt32(geteuid()) else {
                    return .refused(.wrongOwner(socket.path))
                }
                guard result.mode == 0o600 else {
                    return .refused(.wrongMode(socket.path, result.mode))
                }
                guard result.identity == socketIdentity else {
                    return .refused(.identityChanged(socket.path))
                }
                guard socket.path.withCString({ Darwin.unlink($0) }) == 0 || errno == ENOENT else {
                    throw PathSecurityError.removeFailed(socket.path, errno)
                }
            } catch PathSecurityError.missing(_) {
                // The recorded socket has already gone away; continue checking
                // the generation directory before removing it.
            }
        }

        let beforeRemoval: (identity: FileIdentity, mode: UInt16, type: UInt16, owner: UInt32)
        do {
            beforeRemoval = try lstat(directory.path)
        } catch PathSecurityError.missing(_) {
            return .alreadyAbsent
        }
        guard beforeRemoval.type == UInt16(S_IFDIR) else {
            return .refused(.wrongType(directory.path))
        }
        guard beforeRemoval.owner == UInt32(geteuid()) else {
            return .refused(.wrongOwner(directory.path))
        }
        guard beforeRemoval.mode == 0o700 else {
            return .refused(.wrongMode(directory.path, beforeRemoval.mode))
        }
        guard beforeRemoval.identity == directoryIdentity else {
            return .refused(.identityChanged(directory.path))
        }
        guard try isEmptyDirectory(directory.path) else {
            return .refused(.notEmpty(directory.path))
        }

        let finalDirectory: (identity: FileIdentity, mode: UInt16, type: UInt16, owner: UInt32)
        do {
            finalDirectory = try lstat(directory.path)
        } catch PathSecurityError.missing(_) {
            return .alreadyAbsent
        }
        guard finalDirectory.identity == currentDirectory else {
            return .refused(.identityChanged(directory.path))
        }
        guard finalDirectory.type == UInt16(S_IFDIR) else {
            return .refused(.wrongType(directory.path))
        }
        guard finalDirectory.owner == UInt32(geteuid()) else {
            return .refused(.wrongOwner(directory.path))
        }
        guard finalDirectory.mode == 0o700 else {
            return .refused(.wrongMode(directory.path, finalDirectory.mode))
        }
        let result = directory.path.withCString { Darwin.rmdir($0) }
        guard result == 0 else {
            let error = errno
            if error == ENOENT {
                return .alreadyAbsent
            }
            throw PathSecurityError.removeFailed(directory.path, error)
        }
        return .removed
    }

    private static func isEmptyDirectory(_ path: String) throws -> Bool {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path).isEmpty
        } catch {
            throw PathSecurityError.directoryReadFailed(path)
        }
    }
}
