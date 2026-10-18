import Foundation
import Darwin
import HidhoggCore

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

public protocol RuntimeProfileChecking: Sendable {
    func listProfiles(requestID: String) throws -> ProfileListResponse
    func activateProfile(profileID: String, requestID: String) throws -> ProfileActivationResponse
}

public protocol RuntimeProfileClientCreating: Sendable {
    func make(socketPath: String, instanceID: String) throws -> any RuntimeProfileChecking
}

public protocol RuntimeDisplayHostStateChecking: Sendable {
    func setDisplayHostState(
        displayAwake: Bool,
        requestID: String
    ) throws -> DisplayHostStateResponse
}

public protocol RuntimeDisplayHostStateClientCreating: Sendable {
    func make(socketPath: String, instanceID: String) throws -> any RuntimeDisplayHostStateChecking
}

public protocol RuntimeConfigEditorChecking: Sendable {
    func configEditorSnapshot(requestID: String) throws -> ConfigEditorSnapshotResponse
    func configEditorProfile(
        profileID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorProfileResponse
    func setConfigEditorProfileLabel(
        profileID: String,
        label: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse
    func createConfigEditorProfile(
        profileID: String,
        label: String,
        expectedDigest: String,
        sourceProfileID: String?,
        requestID: String
    ) throws -> ConfigEditorMutationResponse
    func deleteConfigEditorProfile(
        profileID: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse
    func configEditorPositions(
        profileID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorPositionsResponse
    func configEditorPosition(
        profileID: String,
        positionID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorPositionResponse
    func setConfigEditorPositionLabel(
        profileID: String,
        positionID: String,
        label: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse
    func patchConfigEditorPosition(
        profileID: String,
        positionID: String,
        patch: ConfigurationPositionPatch,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse
}

public extension RuntimeConfigEditorChecking {
    func configEditorPositions(
        profileID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorPositionsResponse {
        throw UnixSocketClientError.invalidRequest
    }

    func configEditorPosition(
        profileID: String,
        positionID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorPositionResponse {
        throw UnixSocketClientError.invalidRequest
    }

    func setConfigEditorPositionLabel(
        profileID: String,
        positionID: String,
        label: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        throw UnixSocketClientError.invalidRequest
    }

    func patchConfigEditorPosition(
        profileID: String,
        positionID: String,
        patch: ConfigurationPositionPatch,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        throw UnixSocketClientError.invalidRequest
    }
}

public protocol RuntimeConfigEditorClientCreating: Sendable {
    func make(socketPath: String, instanceID: String) throws -> any RuntimeConfigEditorChecking
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

public final class UnixSocketClient: @unchecked Sendable, RuntimeHealthChecking, RuntimeProfileChecking, RuntimeDisplayHostStateChecking, RuntimeConfigEditorChecking {
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
        guard method == .health || method == .status,
              UUIDValidation.isCanonical(requestID) else {
            throw UnixSocketClientError.invalidRequest
        }
        let request = ProtocolV1.request(method: method, requestID: requestID, instanceID: instanceID)
        let responseFrame = try exchange(request: request)
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

    public func listProfiles(requestID: String) throws -> ProfileListResponse {
        let responseFrame = try profileExchange(
            method: .profilesList,
            requestID: requestID,
            profileID: nil
        )
        do {
            return try ResponseValidator.validateProfilesList(
                frame: responseFrame,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID
            )
        } catch let error as ResponseValidationError {
            throw mapResponseError(error)
        }
    }

    public func activateProfile(profileID: String, requestID: String) throws -> ProfileActivationResponse {
        let responseFrame = try profileExchange(
            method: .profilesActivate,
            requestID: requestID,
            profileID: profileID
        )
        do {
            return try ResponseValidator.validateProfileActivation(
                frame: responseFrame,
                expectedRequestID: requestID,
                expectedProfileID: profileID
            )
        } catch let error as ResponseValidationError {
            throw mapResponseError(error)
        }
    }

    public func setDisplayHostState(
        displayAwake: Bool,
        requestID: String
    ) throws -> DisplayHostStateResponse {
        let request: Data
        do {
            request = try ProtocolV1.displayHostStateRequest(
                requestID: requestID,
                instanceID: instanceID,
                displayAwake: displayAwake
            )
        } catch {
            throw UnixSocketClientError.invalidRequest
        }
        let responseFrame = try exchange(request: request)
        do {
            return try ResponseValidator.validateDisplayHostState(
                frame: responseFrame,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID,
                expectedDisplayAwake: displayAwake
            )
        } catch let error as ResponseValidationError {
            throw mapResponseError(error)
        }
    }

    public func configEditorSnapshot(requestID: String) throws -> ConfigEditorSnapshotResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorSnapshot,
            requestID: requestID
        )
        do {
            return try ResponseValidator.validateConfigEditorSnapshot(
                frame: responseFrame,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID
            )
        } catch let error as ResponseValidationError {
            throw mapResponseError(error)
        }
    }

    public func configEditorProfile(
        profileID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorProfileResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorProfileGet,
            requestID: requestID,
            profileID: profileID,
            sourceDigest: sourceDigest
        )
        do {
            return try ResponseValidator.validateConfigEditorProfile(
                frame: responseFrame,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID,
                expectedSourceDigest: sourceDigest,
                expectedProfileID: profileID
            )
        } catch let error as ResponseValidationError {
            throw mapResponseError(error)
        }
    }

    public func configEditorPositions(
        profileID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorPositionsResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorPositionsList,
            requestID: requestID,
            profileID: profileID,
            sourceDigest: sourceDigest
        )
        do {
            return try ResponseValidator.validateConfigEditorPositions(
                frame: responseFrame,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID,
                expectedSourceDigest: sourceDigest,
                expectedProfileID: profileID
            )
        } catch let error as ResponseValidationError {
            throw mapResponseError(error)
        }
    }

    public func configEditorPosition(
        profileID: String,
        positionID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorPositionResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorPositionGet,
            requestID: requestID,
            profileID: profileID,
            positionID: positionID,
            sourceDigest: sourceDigest
        )
        do {
            return try ResponseValidator.validateConfigEditorPosition(
                frame: responseFrame,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID,
                expectedSourceDigest: sourceDigest,
                expectedProfileID: profileID,
                expectedPositionID: positionID
            )
        } catch let error as ResponseValidationError {
            throw mapResponseError(error)
        }
    }

    public func setConfigEditorProfileLabel(
        profileID: String,
        label: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorProfileLabelSet,
            requestID: requestID,
            profileID: profileID,
            expectedDigest: expectedDigest,
            label: label
        )
        return try validateConfigEditorMutation(responseFrame, method: .configEditorProfileLabelSet, requestID: requestID)
    }

    public func createConfigEditorProfile(
        profileID: String,
        label: String,
        expectedDigest: String,
        sourceProfileID: String? = nil,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorProfileCreate,
            requestID: requestID,
            profileID: profileID,
            expectedDigest: expectedDigest,
            label: label,
            sourceProfileID: sourceProfileID
        )
        return try validateConfigEditorMutation(responseFrame, method: .configEditorProfileCreate, requestID: requestID)
    }

    public func deleteConfigEditorProfile(
        profileID: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorProfileDelete,
            requestID: requestID,
            profileID: profileID,
            expectedDigest: expectedDigest
        )
        return try validateConfigEditorMutation(responseFrame, method: .configEditorProfileDelete, requestID: requestID)
    }

    public func setConfigEditorPositionLabel(
        profileID: String,
        positionID: String,
        label: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorPositionLabelSet,
            requestID: requestID,
            profileID: profileID,
            positionID: positionID,
            expectedDigest: expectedDigest,
            label: label
        )
        return try validateConfigEditorMutation(
            responseFrame,
            method: .configEditorPositionLabelSet,
            requestID: requestID
        )
    }

    public func patchConfigEditorPosition(
        profileID: String,
        positionID: String,
        patch: ConfigurationPositionPatch,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        let responseFrame = try configEditorExchange(
            method: .configEditorPositionPatch,
            requestID: requestID,
            profileID: profileID,
            positionID: positionID,
            expectedDigest: expectedDigest,
            positionPatch: patch
        )
        return try validateConfigEditorMutation(
            responseFrame,
            method: .configEditorPositionPatch,
            requestID: requestID
        )
    }

    private func validateConfigEditorMutation(
        _ responseFrame: Data,
        method: RuntimeMethod,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        do {
            return try ResponseValidator.validateConfigEditorMutation(
                frame: responseFrame,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID,
                method: method
            )
        } catch let error as ResponseValidationError {
            throw mapResponseError(error)
        }
    }

    private func configEditorExchange(
        method: RuntimeMethod,
        requestID: String,
        profileID: String? = nil,
        positionID: String? = nil,
        sourceDigest: String? = nil,
        expectedDigest: String? = nil,
        label: String? = nil,
        sourceProfileID: String? = nil,
        positionPatch: ConfigurationPositionPatch? = nil
    ) throws -> Data {
        guard UUIDValidation.isCanonical(requestID) else {
            throw UnixSocketClientError.invalidRequest
        }
        let request: Data
        do {
            request = try ProtocolV1.configEditorRequest(
                method: method,
                requestID: requestID,
                instanceID: instanceID,
                profileID: profileID,
                positionID: positionID,
                sourceDigest: sourceDigest,
                expectedDigest: expectedDigest,
                label: label,
                sourceProfileID: sourceProfileID,
                positionPatch: positionPatch
            )
        } catch let error as ProtocolRequestValidationError {
            if error == .frameTooLarge {
                throw UnixSocketClientError.frameTooLarge
            }
            throw UnixSocketClientError.invalidRequest
        } catch {
            throw UnixSocketClientError.invalidRequest
        }
        return try exchange(request: request)
    }

    private func profileExchange(
        method: RuntimeMethod,
        requestID: String,
        profileID: String?
    ) throws -> Data {
        guard method == .profilesList || method == .profilesActivate,
              UUIDValidation.isCanonical(requestID) else {
            throw UnixSocketClientError.invalidRequest
        }
        let request: Data
        do {
            request = try ProtocolV1.profileRequest(
                method: method,
                requestID: requestID,
                instanceID: instanceID,
                profileID: profileID
            )
        } catch {
            throw UnixSocketClientError.invalidRequest
        }
        return try exchange(request: request)
    }

    private func exchange(request: Data) throws -> Data {
        guard request.count <= ProtocolV1.frameLimit else {
            throw UnixSocketClientError.frameTooLarge
        }
        let socketURL = URL(fileURLWithPath: socketPath)
        do {
            _ = try PathSecurity.validateGenerationDirectory(socketURL.deletingLastPathComponent())
            _ = try PathSecurity.validateSocket(socketURL)
        } catch let error as PathSecurityError {
            throw UnixSocketClientError.endpoint(error)
        }
        return try transport.exchange(
            request: request,
            socketPath: socketPath,
            timeoutNanoseconds: phaseTimeoutNanoseconds
        )
    }

    private func mapResponseError(_ error: ResponseValidationError) -> UnixSocketClientError {
        if case .serverError(let runtimeError) = error {
            return .response(.serverError(runtimeError))
        }
        return .response(error)
    }

    public func health(requestID: String) throws -> RuntimeResponse {
        try request(method: .health, requestID: requestID)
    }
}

public struct UnixSocketProfileClientFactory: RuntimeProfileClientCreating, Sendable {
    private let transportFactory: @Sendable () -> any SocketTransport

    public init(transportFactory: @escaping @Sendable () -> any SocketTransport = { DarwinSocketTransport() }) {
        self.transportFactory = transportFactory
    }

    public func make(socketPath: String, instanceID: String) throws -> any RuntimeProfileChecking {
        try UnixSocketClient(
            socketPath: socketPath,
            instanceID: instanceID,
            transport: transportFactory()
        )
    }
}

public struct UnixSocketDisplayHostStateClientFactory: RuntimeDisplayHostStateClientCreating, Sendable {
    private let transportFactory: @Sendable () -> any SocketTransport

    public init(transportFactory: @escaping @Sendable () -> any SocketTransport = { DarwinSocketTransport() }) {
        self.transportFactory = transportFactory
    }

    public func make(socketPath: String, instanceID: String) throws -> any RuntimeDisplayHostStateChecking {
        try UnixSocketClient(
            socketPath: socketPath,
            instanceID: instanceID,
            transport: transportFactory()
        )
    }
}

public struct UnixSocketConfigEditorClientFactory: RuntimeConfigEditorClientCreating, Sendable {
    private let transportFactory: @Sendable () -> any SocketTransport

    public init(transportFactory: @escaping @Sendable () -> any SocketTransport = { DarwinSocketTransport() }) {
        self.transportFactory = transportFactory
    }

    public func make(socketPath: String, instanceID: String) throws -> any RuntimeConfigEditorChecking {
        try UnixSocketClient(
            socketPath: socketPath,
            instanceID: instanceID,
            transport: transportFactory()
        )
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
