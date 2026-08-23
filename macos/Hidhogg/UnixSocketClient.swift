import Foundation
import Darwin

public enum UnixSocketClientError: Error, Equatable, Sendable {
    case invalidRequest
    case connectTimedOut
    case writeTimedOut
    case readTimedOut
    case peerCredentialsUnavailable
    case peerOwnerMismatch
    case connectionClosed
    case frameTooLarge
    case malformedResponse
    case endpoint(PathSecurityError)
    case response(ResponseValidationError)
    case systemCall(String, Int32)
}

public protocol SocketTransport: Sendable {
    func exchange(request: Data, socketPath: String, timeoutNanoseconds: UInt64) throws -> Data
}

public protocol RuntimeHealthChecking: Sendable {
    func health(requestID: String) throws -> RuntimeResponse
}

public protocol RuntimeHealthClientCreating: Sendable {
    func make(socketPath: String, instanceID: String) throws -> any RuntimeHealthChecking
}

public struct DarwinSocketTransport: SocketTransport, Sendable {
    public let phaseTimeoutNanoseconds: UInt64

    public init(phaseTimeoutNanoseconds: UInt64 = 1_000_000_000) {
        self.phaseTimeoutNanoseconds = phaseTimeoutNanoseconds
    }

    public func exchange(request: Data, socketPath: String, timeoutNanoseconds: UInt64) throws -> Data {
        do {
            try PathSecurity.validateEncodedSocketPath(socketPath)
        } catch let error as PathSecurityError {
            throw UnixSocketClientError.endpoint(error)
        }
        guard !socketPath.utf8.contains(0) else {
            throw UnixSocketClientError.invalidRequest
        }
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw UnixSocketClientError.systemCall("socket", errno)
        }
        defer { _ = Darwin.close(fileDescriptor) }

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) {
            Darwin.setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        let currentFlags = Darwin.fcntl(fileDescriptor, F_GETFL, 0)
        guard currentFlags >= 0,
              Darwin.fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            throw UnixSocketClientError.systemCall("fcntl", errno)
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { _ in
            let pathBytes = Array(socketPath.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                for offset in 0..<rawBuffer.count {
                    rawBuffer[offset] = 0
                }
                for (offset, byte) in pathBytes.enumerated() where offset < rawBuffer.count - 1 {
                    rawBuffer[offset] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                throw UnixSocketClientError.systemCall("connect", errno)
            }
            try waitFor(fileDescriptor: fileDescriptor, events: Int16(POLLOUT), timeoutNanoseconds: timeoutNanoseconds, timeoutError: .connectTimedOut)
            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorLength
            ) == 0 else {
                throw UnixSocketClientError.systemCall("getsockopt", errno)
            }
            guard socketError == 0 else {
                throw UnixSocketClientError.systemCall("connect", socketError)
            }
        }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard Darwin.getpeereid(fileDescriptor, &peerUID, &peerGID) == 0 else {
            throw UnixSocketClientError.peerCredentialsUnavailable
        }
        guard peerUID == geteuid() else {
            throw UnixSocketClientError.peerOwnerMismatch
        }

        try sendAll(request, fileDescriptor: fileDescriptor, timeoutNanoseconds: timeoutNanoseconds)
        return try receiveFrame(fileDescriptor: fileDescriptor, timeoutNanoseconds: timeoutNanoseconds)
    }

    private func sendAll(_ data: Data, fileDescriptor: Int32, timeoutNanoseconds: UInt64) throws {
        var offset = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < rawBuffer.count {
                do {
                    let result = Darwin.send(
                        fileDescriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset,
                        0
                    )
                    if result > 0 {
                        offset += result
                        continue
                    }
                    if result == 0 {
                        throw UnixSocketClientError.connectionClosed
                    }
                    if errno == EINTR { continue }
                    if errno != EAGAIN && errno != EWOULDBLOCK {
                        throw UnixSocketClientError.systemCall("send", errno)
                    }
                }
                try waitUntil(fileDescriptor: fileDescriptor, events: Int16(POLLOUT), deadline: deadline, timeoutError: .writeTimedOut)
            }
        }
    }

    private func receiveFrame(fileDescriptor: Int32, timeoutNanoseconds: UInt64) throws -> Data {
        var frame = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while true {
            let result = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if result > 0 {
                frame.append(contentsOf: buffer.prefix(result))
                guard frame.count <= ProtocolV1.frameLimit else {
                    throw UnixSocketClientError.frameTooLarge
                }
                if frame.firstIndex(of: 0x0a) != nil {
                    return frame
                }
                continue
            }
            if result == 0 {
                throw UnixSocketClientError.connectionClosed
            }
            if errno == EINTR { continue }
            if errno != EAGAIN && errno != EWOULDBLOCK {
                throw UnixSocketClientError.systemCall("recv", errno)
            }
            try waitUntil(fileDescriptor: fileDescriptor, events: Int16(POLLIN), deadline: deadline, timeoutError: .readTimedOut)
        }
    }

    private func waitFor(
        fileDescriptor: Int32,
        events: Int16,
        timeoutNanoseconds: UInt64,
        timeoutError: UnixSocketClientError
    ) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        try waitUntil(fileDescriptor: fileDescriptor, events: events, deadline: deadline, timeoutError: timeoutError)
    }

    private func waitUntil(
        fileDescriptor: Int32,
        events: Int16,
        deadline: UInt64,
        timeoutError: UnixSocketClientError
    ) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw timeoutError }
            let remaining = deadline - now
            let milliseconds = Int32(max(1, min(remaining / 1_000_000, UInt64(Int32.max))))
            var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            if result > 0 {
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0,
                   descriptor.revents & events == 0 {
                    throw UnixSocketClientError.connectionClosed
                }
                return
            }
            if result == 0 { throw timeoutError }
            if errno != EINTR {
                throw UnixSocketClientError.systemCall("poll", errno)
            }
        }
    }
}

public final class UnixSocketClient: @unchecked Sendable, RuntimeHealthChecking {
    public let socketPath: String
    public let instanceID: String
    public let phaseTimeoutNanoseconds: UInt64
    private let transport: any SocketTransport

    public init(
        socketPath: String,
        instanceID: String,
        transport: any SocketTransport = DarwinSocketTransport(),
        phaseTimeoutNanoseconds: UInt64 = 1_000_000_000
    ) throws {
        guard UUIDValidation.isCanonical(instanceID) else {
            throw UnixSocketClientError.invalidRequest
        }
        try PathSecurity.validateEncodedSocketPath(socketPath)
        self.socketPath = socketPath
        self.instanceID = instanceID
        self.transport = transport
        self.phaseTimeoutNanoseconds = phaseTimeoutNanoseconds
    }

    public func request(
        method: RuntimeMethod,
        requestID: String
    ) throws -> RuntimeResponse {
        guard UUIDValidation.isCanonical(requestID) else {
            throw UnixSocketClientError.invalidRequest
        }
        let socketURL = URL(fileURLWithPath: socketPath)
        do {
            _ = try PathSecurity.validateGenerationDirectory(socketURL.deletingLastPathComponent())
            _ = try PathSecurity.validateSocket(socketURL)
        } catch let error as PathSecurityError {
            throw UnixSocketClientError.endpoint(error)
        }
        let request = ProtocolV1.request(method: method, requestID: requestID, instanceID: instanceID)
        let responseFrame = try transport.exchange(
            request: request,
            socketPath: socketPath,
            timeoutNanoseconds: phaseTimeoutNanoseconds
        )
        do {
            return try ResponseValidator.validate(
                frame: responseFrame,
                expectedRequestID: requestID,
                method: method,
                expectedInstanceID: instanceID
            )
        } catch let error as ResponseValidationError {
            if case .serverError(let runtimeError) = error {
                throw UnixSocketClientError.response(.serverError(runtimeError))
            }
            throw UnixSocketClientError.response(error)
        }
    }

    public func health(requestID: String) throws -> RuntimeResponse {
        try request(method: .health, requestID: requestID)
    }
}

public struct UnixSocketHealthClientFactory: RuntimeHealthClientCreating, Sendable {
    private let transportFactory: @Sendable () -> any SocketTransport

    public init(transportFactory: @escaping @Sendable () -> any SocketTransport = { DarwinSocketTransport() }) {
        self.transportFactory = transportFactory
    }

    public func make(socketPath: String, instanceID: String) throws -> any RuntimeHealthChecking {
        try UnixSocketClient(
            socketPath: socketPath,
            instanceID: instanceID,
            transport: transportFactory()
        )
    }
}
