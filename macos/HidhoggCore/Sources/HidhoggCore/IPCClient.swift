import Darwin
import Foundation

public struct IPCDeadlines: Sendable, Equatable {
    public let connect: Duration
    public let read: Duration
    public let write: Duration

    public init(connect: Duration = .seconds(1), read: Duration = .seconds(1), write: Duration = .seconds(1)) {
        self.connect = connect > .zero ? connect : .seconds(1)
        self.read = read > .zero ? read : .seconds(1)
        self.write = write > .zero ? write : .seconds(1)
    }
}

public enum IPCClientError: Error, Sendable, Equatable {
    case endpointChanged
    case transport
    case invalidResponse
}

public protocol IPCTransport: Sendable {
    func exchange(socketPath: String, request: Data, deadlines: IPCDeadlines) throws -> Data
}

public struct IPCUnixTransport: IPCTransport, Sendable {
    private let operations: IPCPOSIXOperations

    public init() {
        operations = .live
    }

    init(operations: IPCPOSIXOperations) {
        self.operations = operations
    }

    public func exchange(socketPath: String, request: Data, deadlines: IPCDeadlines = IPCDeadlines()) throws -> Data {
        let descriptor = try connect(socketPath, deadline: deadlines.connect)
        defer { _ = operations.close(descriptor) }
        try writeAll(request, descriptor: descriptor, deadline: deadlines.write)
        return try readFrame(descriptor: descriptor, deadline: deadlines.read)
    }

    private func connect(_ path: String, deadline: Duration) throws -> Int32 {
        let absoluteDeadline = operations.now().advanced(by: deadline)
        let pathBytes = Array(path.utf8)
        guard !pathBytes.isEmpty,
              !pathBytes.contains(0),
              pathBytes.count + 1 <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw IPCClientError.transport }
        let socket = operations.createSocket()
        let descriptor = socket.value
        guard descriptor >= 0, socket.error == 0 else { throw IPCClientError.transport }
        guard operations.setNonblocking(descriptor).value == 0,
              operations.setNoSIGPIPE(descriptor).value == 0 else {
            _ = operations.close(descriptor)
            throw IPCClientError.transport
        }
        let result = operations.connect(descriptor, path)
        if result.value != 0 {
            guard result.error == EINPROGRESS || result.error == EAGAIN,
                  wait(descriptor, event: Int16(POLLOUT), deadline: absoluteDeadline) else {
                _ = operations.close(descriptor)
                throw IPCClientError.transport
            }
            let socketError = operations.socketError(descriptor)
            guard socketError.error == 0, socketError.value == 0 else {
                _ = operations.close(descriptor)
                throw IPCClientError.transport
            }
        }
        guard operations.now() < absoluteDeadline else {
            _ = operations.close(descriptor)
            throw IPCClientError.transport
        }
        let peerUID = operations.peerUserID(descriptor)
        guard peerUID.error == 0, peerUID.value == operations.effectiveUserID() else {
            _ = operations.close(descriptor)
            throw IPCClientError.transport
        }
        return descriptor
    }

    func writeAll(_ data: Data, descriptor: Int32, deadline: Duration) throws {
        let absoluteDeadline = operations.now().advanced(by: deadline)
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw IPCClientError.transport }
            while offset < data.count {
                guard wait(descriptor, event: Int16(POLLOUT), deadline: absoluteDeadline) else { throw IPCClientError.transport }
                let result = operations.send(descriptor, base.advanced(by: offset), data.count - offset)
                if result.value > 0 {
                    guard operations.now() < absoluteDeadline else { throw IPCClientError.transport }
                    offset += result.value
                    continue
                }
                if result.value < 0, result.error == EINTR || result.error == EAGAIN || result.error == EWOULDBLOCK { continue }
                throw IPCClientError.transport
            }
        }
    }

    func readFrame(descriptor: Int32, deadline: Duration) throws -> Data {
        let absoluteDeadline = operations.now().advanced(by: deadline)
        var frame = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            guard wait(descriptor, event: Int16(POLLIN), deadline: absoluteDeadline) else { throw IPCClientError.transport }
            let result = buffer.withUnsafeMutableBytes { bytes in
                operations.receive(descriptor, bytes.baseAddress, bytes.count)
            }
            let count = result.value
            if count == 0 { throw IPCFrameError.incomplete }
            if count < 0 {
                if result.error == EINTR || result.error == EAGAIN || result.error == EWOULDBLOCK { continue }
                throw IPCClientError.transport
            }
            guard operations.now() < absoluteDeadline else { throw IPCClientError.transport }
            let chunk = buffer[0..<count]
            if let newline = chunk.firstIndex(of: 0x0a) {
                let frameCount = frame.count + newline + 1
                guard frameCount <= IPCProtocol.maximumFrameBytes else { throw IPCFrameError.tooLarge }
                frame.append(contentsOf: chunk[..<newline])
                frame.append(0x0a)
                return frame
            }
            guard frame.count + count <= IPCProtocol.maximumFrameBytes else { throw IPCFrameError.tooLarge }
            frame.append(contentsOf: chunk)
        }
    }

    private func wait(_ descriptor: Int32, event: Int16, deadline: ContinuousClock.Instant) -> Bool {
        while true {
            let remaining = operations.now().duration(to: deadline)
            guard remaining > .zero else { return false }
            let poll = operations.poll(descriptor, event, milliseconds(remaining))
            if poll.result > 0 {
                guard operations.now() < deadline else { return false }
                return poll.events & event != 0
            }
            if poll.result == 0 { return false }
            if poll.error != EINTR { return false }
        }
    }

    private func milliseconds(_ duration: Duration) -> Int32 {
        let components = duration.components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let milliseconds = attoseconds / 1_000_000_000_000_000
        let hasRemainder = attoseconds % 1_000_000_000_000_000 != 0
        let fractional = milliseconds + (hasRemainder ? 1 : 0)
        let total = seconds.multipliedReportingOverflow(by: 1_000).partialValue + fractional
        return Int32(min(Int64(Int32.max), max(1, total)))
    }

    func setNoSIGPIPE(_ descriptor: Int32) -> Bool {
        let result = operations.setNoSIGPIPE(descriptor)
        return result.value == 0 && result.error == 0
    }
}

public struct IPCClient: Sendable {
    private let runtime: IPCResolvedRuntime
    private let transport: any IPCTransport
    private let deadlines: IPCDeadlines
    private let revalidateEndpoint: @Sendable () throws -> Void

    public init(runtime: IPCResolvedRuntime, transport: any IPCTransport = IPCUnixTransport(), deadlines: IPCDeadlines = IPCDeadlines()) {
        self.init(runtime: runtime, transport: transport, deadlines: deadlines, revalidateEndpoint: { try runtime.revalidate() })
    }

    init(
        runtime: IPCResolvedRuntime,
        transport: any IPCTransport = IPCUnixTransport(),
        deadlines: IPCDeadlines = IPCDeadlines(),
        revalidateEndpoint: @escaping @Sendable () throws -> Void
    ) {
        self.runtime = runtime
        self.transport = transport
        self.deadlines = deadlines
        self.revalidateEndpoint = revalidateEndpoint
    }

    public func call(_ command: IPCCommand) async throws -> IPCWireResponse {
        let requestID = UUID().uuidString.lowercased()
        let request = try IPCProtocol.encodeRequest(requestID: requestID, command: command, instanceID: runtime.metadata.instanceID)
        let reply: Data
        do {
            reply = try await Task.detached {
                try transport.exchange(socketPath: runtime.paths.socketPath, request: request, deadlines: deadlines)
            }.value
        } catch {
            do { try revalidateEndpoint() }
            catch { throw IPCClientError.endpointChanged }
            throw error
        }
        let response: IPCWireResponse
        do {
            response = try IPCProtocol.decodeResponse(
                reply,
                expectedRequestID: requestID,
                expectedInstanceID: runtime.metadata.instanceID,
                method: command.method
            )
        } catch {
            do { try revalidateEndpoint() }
            catch { throw IPCClientError.endpointChanged }
            throw IPCClientError.invalidResponse
        }
        do { try revalidateEndpoint() }
        catch { throw IPCClientError.endpointChanged }
        return response
    }
}
