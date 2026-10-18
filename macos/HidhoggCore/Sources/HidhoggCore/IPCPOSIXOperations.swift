import Darwin
import Foundation

struct IPCPOSIXResult<Value> {
    let value: Value
    let error: Int32
}

struct IPCPollResult {
    let result: Int32
    let events: Int16
    let error: Int32
}

struct IPCPOSIXOperations: Sendable {
    var now: @Sendable () -> ContinuousClock.Instant
    var effectiveUserID: @Sendable () -> UInt32
    var createSocket: @Sendable () -> IPCPOSIXResult<Int32>
    var connect: @Sendable (Int32, String) -> IPCPOSIXResult<Int32>
    var bind: @Sendable (Int32, String) -> IPCPOSIXResult<Int32>
    var listen: @Sendable (Int32, Int32) -> IPCPOSIXResult<Int32>
    var accept: @Sendable (Int32) -> IPCPOSIXResult<Int32>
    var poll: @Sendable (Int32, Int16, Int32) -> IPCPollResult
    var send: @Sendable (Int32, UnsafeRawPointer?, Int) -> IPCPOSIXResult<Int>
    var receive: @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> IPCPOSIXResult<Int>
    var peerUserID: @Sendable (Int32) -> IPCPOSIXResult<UInt32?>
    var socketError: @Sendable (Int32) -> IPCPOSIXResult<Int32>
    var setNonblocking: @Sendable (Int32) -> IPCPOSIXResult<Int32>
    var setNoSIGPIPE: @Sendable (Int32) -> IPCPOSIXResult<Int32>
    var lstat: @Sendable (String) -> IPCPOSIXResult<stat>
    var fstat: @Sendable (Int32) -> IPCPOSIXResult<stat>
    var open: @Sendable (String, Int32, mode_t) -> IPCPOSIXResult<Int32>
    var openAt: @Sendable (Int32, String, Int32, mode_t) -> IPCPOSIXResult<Int32>
    var read: @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> IPCPOSIXResult<Int>
    var write: @Sendable (Int32, UnsafeRawPointer?, Int) -> IPCPOSIXResult<Int>
    var close: @Sendable (Int32) -> IPCPOSIXResult<Int32>
    var chmod: @Sendable (String, mode_t) -> IPCPOSIXResult<Int32>
    var fchmod: @Sendable (Int32, mode_t) -> IPCPOSIXResult<Int32>
    var fsync: @Sendable (Int32) -> IPCPOSIXResult<Int32>
    var linkAt: @Sendable (Int32, String, Int32, String) -> IPCPOSIXResult<Int32>
    var unlink: @Sendable (String) -> IPCPOSIXResult<Int32>
    var unlinkAt: @Sendable (Int32, String) -> IPCPOSIXResult<Int32>

    static let live = IPCPOSIXOperations(
        now: { ContinuousClock().now },
        effectiveUserID: { UInt32(geteuid()) },
        createSocket: {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            return IPCPOSIXResult(value: descriptor, error: descriptor < 0 ? errno : 0)
        },
        connect: { descriptor, path in
            withUnixAddress(path) { address in
                let result = withUnsafePointer(to: address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
            }
        },
        bind: { descriptor, path in
            withUnixAddress(path) { address in
                let result = withUnsafePointer(to: address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
            }
        },
        listen: { descriptor, backlog in
            let result = Darwin.listen(descriptor, backlog)
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        accept: { descriptor in
            let result = Darwin.accept(descriptor, nil, nil)
            return IPCPOSIXResult(value: result, error: result < 0 ? errno : 0)
        },
        poll: { descriptor, event, timeout in
            var value = pollfd(fd: descriptor, events: event, revents: 0)
            let result = Darwin.poll(&value, 1, timeout)
            return IPCPollResult(result: Int32(result), events: value.revents, error: result < 0 ? errno : 0)
        },
        send: { descriptor, bytes, count in
            let result = Darwin.send(descriptor, bytes, count, 0)
            return IPCPOSIXResult(value: result, error: result < 0 ? errno : 0)
        },
        receive: { descriptor, bytes, count in
            let result = Darwin.recv(descriptor, bytes, count, 0)
            return IPCPOSIXResult(value: result, error: result < 0 ? errno : 0)
        },
        peerUserID: { descriptor in
            var userID = uid_t.max
            var groupID = gid_t.max
            let result = getpeereid(descriptor, &userID, &groupID)
            return IPCPOSIXResult(value: result == 0 ? UInt32(userID) : nil, error: result == 0 ? 0 : errno)
        },
        socketError: { descriptor in
            var value: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            let result = Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &value, &length)
            return IPCPOSIXResult(value: value, error: result == 0 ? 0 : errno)
        },
        setNonblocking: { descriptor in
            let flags = Darwin.fcntl(descriptor, F_GETFL)
            guard flags >= 0 else { return IPCPOSIXResult(value: -1, error: errno) }
            let result = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        setNoSIGPIPE: { descriptor in
            var enabled: Int32 = 1
            let result = Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        lstat: { path in
            var value = stat()
            let result = path.withCString { Darwin.lstat($0, &value) }
            return IPCPOSIXResult(value: value, error: result == 0 ? 0 : errno)
        },
        fstat: { descriptor in
            var value = stat()
            let result = Darwin.fstat(descriptor, &value)
            return IPCPOSIXResult(value: value, error: result == 0 ? 0 : errno)
        },
        open: { path, flags, mode in
            let descriptor = path.withCString { Darwin.open($0, flags, mode) }
            return IPCPOSIXResult(value: descriptor, error: descriptor < 0 ? errno : 0)
        },
        openAt: { directory, path, flags, mode in
            let descriptor = path.withCString { Darwin.openat(directory, $0, flags, mode) }
            return IPCPOSIXResult(value: descriptor, error: descriptor < 0 ? errno : 0)
        },
        read: { descriptor, bytes, count in
            let result = Darwin.read(descriptor, bytes, count)
            return IPCPOSIXResult(value: result, error: result < 0 ? errno : 0)
        },
        write: { descriptor, bytes, count in
            let result = Darwin.write(descriptor, bytes, count)
            return IPCPOSIXResult(value: result, error: result < 0 ? errno : 0)
        },
        close: { descriptor in
            let result = Darwin.close(descriptor)
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        chmod: { path, mode in
            let result = path.withCString { Darwin.chmod($0, mode) }
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        fchmod: { descriptor, mode in
            let result = Darwin.fchmod(descriptor, mode)
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        fsync: { descriptor in
            let result = Darwin.fsync(descriptor)
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        linkAt: { oldDirectory, oldPath, newDirectory, newPath in
            let result = oldPath.withCString { oldLeaf in
                newPath.withCString { newLeaf in
                    Darwin.linkat(oldDirectory, oldLeaf, newDirectory, newLeaf, 0)
                }
            }
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        unlink: { path in
            let result = path.withCString { Darwin.unlink($0) }
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        },
        unlinkAt: { directory, path in
            let result = path.withCString { Darwin.unlinkat(directory, $0, 0) }
            return IPCPOSIXResult(value: result, error: result == 0 ? 0 : errno)
        }
    )
}

private func withUnixAddress<Result>(_ path: String, _ body: (sockaddr_un) -> Result) -> Result {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: bytes)
    }
    return body(address)
}
