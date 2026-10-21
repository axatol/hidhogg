import Darwin
import Foundation

protocol ApplicationInstanceOwnership: AnyObject {
    var isHeld: Bool { get }
    func acquire() throws -> Bool
    func release() throws
}

final class ApplicationInstanceLease: ApplicationInstanceOwnership {
    private let directoryDescriptor: Int32
    private let lockDescriptor: Int32
    private(set) var isHeld = false

    init(parentURL: URL, directoryName: String = "com.hidhogg.instance") throws {
        guard !directoryName.isEmpty, !directoryName.contains("/"), directoryName != ".", directoryName != ".." else {
            throw InstanceLeaseFailure.unsafeFilesystem
        }
        let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw InstanceLeaseFailure.system(errno) }
        defer { close(parent) }
        var parentStat = stat()
        guard fstat(parent, &parentStat) == 0 else { throw InstanceLeaseFailure.system(errno) }
        guard parentStat.st_uid == getuid(), parentStat.st_mode & S_IFMT == S_IFDIR,
              parentStat.st_mode & 0o022 == 0 else {
            throw InstanceLeaseFailure.unsafeFilesystem
        }

        if mkdirat(parent, directoryName, 0o700) != 0, errno != EEXIST {
            throw InstanceLeaseFailure.system(errno)
        }
        let directory = openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw InstanceLeaseFailure.system(errno) }
        do {
            try Self.verify(directory, type: S_IFDIR, mode: 0o700)
            let file = openat(directory, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw InstanceLeaseFailure.system(errno) }
            do {
                try Self.verify(file, type: S_IFREG, mode: 0o600, singleLink: true)
            } catch {
                close(file)
                throw error
            }
            directoryDescriptor = directory
            lockDescriptor = file
        } catch {
            close(directory)
            throw error
        }
    }

    deinit {
        close(lockDescriptor)
        close(directoryDescriptor)
    }

    func acquire() throws -> Bool {
        if isHeld { return true }
        try Self.verify(directoryDescriptor, type: S_IFDIR, mode: 0o700)
        try Self.verify(lockDescriptor, type: S_IFREG, mode: 0o600, singleLink: true)
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK { return false }
            throw InstanceLeaseFailure.system(code)
        }
        isHeld = true
        return true
    }

    func release() throws {
        guard isHeld else { throw InstanceLeaseFailure.notOwner }
        guard flock(lockDescriptor, LOCK_UN) == 0 else { throw InstanceLeaseFailure.system(errno) }
        isHeld = false
    }

    private static func verify(_ descriptor: Int32, type: mode_t, mode: mode_t, singleLink: Bool = false) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw InstanceLeaseFailure.system(errno) }
        guard value.st_uid == getuid(), value.st_mode & S_IFMT == type,
              value.st_mode & 0o7777 == mode, !singleLink || value.st_nlink == 1 else {
            throw InstanceLeaseFailure.unsafeFilesystem
        }
    }
}

enum InstanceLeaseFailure: LocalizedError {
    case unsafeFilesystem
    case notOwner
    case system(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeFilesystem: "Hidhogg could not verify its private application ownership lock."
        case .notOwner: "Hidhogg no longer owns the application runtime."
        case .system(let code): "Hidhogg application ownership failed (system error \(code))."
        }
    }
}
