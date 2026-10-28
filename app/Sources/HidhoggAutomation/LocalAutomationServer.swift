import Foundation
import Darwin

public enum LocalAutomationError: Error {
    case unsafePath, endpointExists, socketFailure, unavailable, unauthorized, timedOut, busy
}

public actor LocalAutomationServer {
    public typealias Handler = @Sendable (AutomationRequest) async -> AutomationResponse
    private var listener: AutomationSocket?
    private var acceptTask: Task<Void, Never>?
    private var clients: [UUID: (AutomationSocket, Task<Void, Never>)] = [:]
    private var endpoint: (url: URL, device: dev_t, inode: ino_t)?

    public init() {}

    public func start(socketURL: URL = AutomationEndpoint.defaultSocketURL(), handler: @escaping Handler) async throws {
        guard listener == nil, clients.isEmpty else { throw LocalAutomationError.busy }
        let path = socketURL.path
        guard socketURL.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0),
              socketURL.lastPathComponent != ".", socketURL.lastPathComponent != ".." else { throw LocalAutomationError.unsafePath }
        let directory = socketURL.deletingLastPathComponent().path
        if Darwin.mkdir(directory, 0o700) != 0, errno != EEXIST { throw LocalAutomationError.unsafePath }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw LocalAutomationError.unsafePath }
        guard lstat(path, &info) != 0, errno == ENOENT else { throw LocalAutomationError.endpointExists }
        let socket = try AutomationSocket.make()
        do {
            try socket.bind(path: path)
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                throw LocalAutomationError.unsafePath
            }
            endpoint = (socketURL, info.st_dev, info.st_ino)
            guard chmod(path, 0o600) == 0 else { throw LocalAutomationError.unsafePath }
            try socket.listen()
            listener = socket
            acceptTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    guard let client = socket.acceptClient() else {
                        if socket.isClosed { return }
                        continue
                    }
                    guard let self else { client.close(); return }
                    await self.admit(client, handler: handler)
                }
            }
        } catch {
            socket.close()
            removeOwnedEndpoint()
            throw error
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        listener?.close()
        listener = nil
        let accepting = acceptTask
        acceptTask = nil
        for (client, task) in clients.values { task.cancel(); client.close() }
        removeOwnedEndpoint()
        await accepting?.value
    }

    private func admit(_ socket: AutomationSocket, handler: @escaping Handler) {
        guard listener != nil, clients.count < 8, socket.isOwnedByCurrentUser() else { socket.close(); return }
        let id = UUID()
        let task = Task.detached { [weak self] in
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(5)); socket.close() } catch {}
            }
            defer { deadline.cancel(); socket.close() }
            do {
                let frame = try socket.readFrame()
                if let request = try? AutomationFrame.decodeRequest(frame) {
                    let response: AutomationResponse
                    do {
                        try request.validated()
                        response = await handler(request)
                    } catch {
                        response = .failure(
                            requestID: request.requestID,
                            code: "invalid_request",
                            message: "Invalid local automation request."
                        )
                    }
                    guard !Task.isCancelled else { throw CancellationError() }
                    let encoded: Data
                    do {
                        encoded = try AutomationFrame.encode(response)
                    } catch {
                        encoded = try AutomationFrame.encode(
                            AutomationResponse.failure(requestID: request.requestID, code: "response_too_large", message: "Response exceeds the local protocol limit.")
                        )
                    }
                    try socket.writeFrame(encoded)
                } else {
                    try socket.writeFrame(AutomationFrame.encode(
                        AutomationResponse.failure(requestID: "invalid-request", code: "invalid_request", message: "Invalid local automation request.")
                    ))
                }
            } catch {}
            await self?.finished(id)
        }
        clients[id] = (socket, task)
    }

    private func finished(_ id: UUID) { clients.removeValue(forKey: id) }

    private func removeOwnedEndpoint() {
        guard let endpoint else { return }
        var info = stat()
        if lstat(endpoint.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
           info.st_uid == getuid(), info.st_dev == endpoint.device, info.st_ino == endpoint.inode {
            _ = unlink(endpoint.url.path)
        }
        self.endpoint = nil
    }
}

public enum LocalAutomationClient {
    public static func send(_ request: AutomationRequest, socketURL: URL = AutomationEndpoint.defaultSocketURL()) throws -> AutomationResponse {
        try request.validated()
        let socket = try AutomationSocket.make()
        defer { socket.close() }
        try socket.connect(path: socketURL.path)
        guard socket.isOwnedByCurrentUser() else { throw LocalAutomationError.unauthorized }
        try socket.writeFrame(AutomationFrame.encode(request))
        let response = try AutomationFrame.decodeResponse(socket.readFrame())
        guard response.requestID == request.requestID else { throw AutomationProtocolError.invalidRequest }
        return response
    }
}

private final class AutomationSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    var isClosed: Bool { lock.withLock { descriptor < 0 } }

    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }

    static func make() throws -> AutomationSocket {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalAutomationError.socketFailure }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            _ = Darwin.close(descriptor)
            throw LocalAutomationError.socketFailure
        }
        return AutomationSocket(descriptor)
    }

    func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            _ = shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    func bind(path: String) throws {
        try withAddress(path) { address, size in
            try lock.withLock {
                guard Darwin.bind(descriptor, address, size) == 0 else { throw LocalAutomationError.socketFailure }
            }
        }
    }

    func listen() throws {
        try lock.withLock {
            guard Darwin.listen(descriptor, 8) == 0 else { throw LocalAutomationError.socketFailure }
        }
    }

    func connect(path: String) throws {
        try withAddress(path) { address, size in
            let result = lock.withLock { Darwin.connect(descriptor, address, size) }
            guard result == 0 || errno == EINPROGRESS else { throw LocalAutomationError.unavailable }
            if result != 0 {
                try ready(events: Int16(POLLOUT), deadline: .now.advanced(by: .seconds(1)))
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                let success = lock.withLock { getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0 }
                guard success else { throw LocalAutomationError.unavailable }
            }
        }
    }

    func acceptClient() -> AutomationSocket? {
        do { try ready(events: Int16(POLLIN), deadline: .now.advanced(by: .milliseconds(100))) } catch { return nil }
        let accepted = lock.withLock { descriptor >= 0 ? Darwin.accept(descriptor, nil, nil) : -1 }
        guard accepted >= 0 else { return nil }
        var enabled: Int32 = 1
        guard setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(accepted, F_SETFL, O_NONBLOCK) == 0, fcntl(accepted, F_SETFD, FD_CLOEXEC) == 0 else {
            _ = Darwin.close(accepted)
            return nil
        }
        return AutomationSocket(accepted)
    }

    func isOwnedByCurrentUser() -> Bool {
        lock.withLock {
            guard descriptor >= 0 else { return false }
            var uid: uid_t = 0
            var gid: gid_t = 0
            return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
        }
    }

    func readFrame() throws -> Data {
        var frame = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while frame.count < AutomationFrame.maximumBytes {
            try ready(events: Int16(POLLIN), deadline: deadline)
            var buffer = [UInt8](repeating: 0, count: min(4096, AutomationFrame.maximumBytes - frame.count))
            let count = lock.withLock { descriptor >= 0 ? Darwin.recv(descriptor, &buffer, buffer.count, 0) : -1 }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw LocalAutomationError.unavailable }
            frame.append(contentsOf: buffer.prefix(count))
            if frame.contains(10) {
                guard frame.last == 10, !frame.dropLast().contains(10) else { throw AutomationProtocolError.invalidFrame }
                return frame
            }
        }
        throw AutomationProtocolError.frameTooLarge
    }

    func writeFrame(_ frame: Data) throws {
        guard frame.count <= AutomationFrame.maximumBytes else { throw AutomationProtocolError.frameTooLarge }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var offset = 0
        while offset < frame.count {
            try ready(events: Int16(POLLOUT), deadline: deadline)
            let sent = frame.withUnsafeBytes { bytes in
                lock.withLock { descriptor >= 0 ? Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), frame.count - offset, 0) : -1 }
            }
            if sent < 0, errno == EAGAIN || errno == EINTR { continue }
            guard sent > 0 else { throw LocalAutomationError.unavailable }
            offset += sent
        }
    }

    private func ready(events: Int16, deadline: ContinuousClock.Instant) throws {
        while ContinuousClock.now < deadline {
            let result: Int32 = try lock.withLock {
                guard descriptor >= 0 else { throw LocalAutomationError.unavailable }
                var item = pollfd(fd: descriptor, events: events, revents: 0)
                let result = poll(&item, 1, 50)
                if result > 0, item.revents & events == 0 { throw LocalAutomationError.unavailable }
                return result
            }
            if result > 0 { return }
            if result < 0, errno != EINTR { throw LocalAutomationError.socketFailure }
        }
        throw LocalAutomationError.timedOut
    }

    private func withAddress<T>(_ path: String, body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalAutomationError.unsafePath
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes + [0]) }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
