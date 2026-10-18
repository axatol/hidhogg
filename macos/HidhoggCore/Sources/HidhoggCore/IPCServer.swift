import Darwin
import Foundation

public enum IPCServerError: Error, Sendable, Equatable {
    case invalidRuntimeDirectory
    case insecureRuntimeDirectory
    case existingGenerationInvalid
    case listenerUnavailable
    case cleanupUncertain
}

public enum IPCServerStopOutcome: Sendable, Equatable {
    case closed
    case cleanupUncertain
}

public typealias IPCWireHandler = @Sendable (IPCWireRequest) async throws -> IPCWireResponse

private struct IPCServerIdentity: Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
    let userID: UInt32
    let fileType: UInt16
    let mode: UInt16

    init(_ value: stat) {
        device = UInt64(value.st_dev)
        inode = UInt64(value.st_ino)
        userID = UInt32(value.st_uid)
        fileType = UInt16(value.st_mode & mode_t(S_IFMT))
        mode = UInt16(value.st_mode & 0o7777)
    }

    var type: UInt16 { fileType }
}

private struct IPCServerResources {
    let paths: IPCRuntimePaths
    let directoryDescriptor: Int32
    let directoryIdentity: IPCServerIdentity
    let listenerDescriptor: Int32
    let socketIdentity: IPCServerIdentity
    let metadataIdentity: IPCServerIdentity
}

public final class IPCServer: @unchecked Sendable {
    private let resources: IPCServerResources
    private let instanceID: String
    private let deadlines: IPCDeadlines
    private let maximumConnections: Int
    private let handler: IPCWireHandler
    private let operations: IPCPOSIXOperations
    private let stateLock = NSLock()
    private let acceptFinished = DispatchGroup()
    private let connections = DispatchGroup()
    private let stopFinished = DispatchGroup()
    private var stopping = false
    private var stopStarted = false
    private var stoppedOutcome: IPCServerStopOutcome?
    private var activeConnections = 0

    private init(
        resources: IPCServerResources,
        instanceID: String,
        deadlines: IPCDeadlines,
        maximumConnections: Int,
        operations: IPCPOSIXOperations,
        handler: @escaping IPCWireHandler
    ) {
        self.resources = resources
        self.instanceID = instanceID
        self.deadlines = deadlines
        self.maximumConnections = maximumConnections
        self.operations = operations
        self.handler = handler
        stopFinished.enter()
    }

    public static func start(
        runtimeDirectory: String,
        instanceID: String = UUID().uuidString.lowercased(),
        deadlines: IPCDeadlines = IPCDeadlines(),
        maximumConnections: Int = 8,
        handler: @escaping IPCWireHandler
    ) throws -> IPCServer {
        try start(
            runtimeDirectory: runtimeDirectory,
            instanceID: instanceID,
            deadlines: deadlines,
            maximumConnections: maximumConnections,
            operations: .live,
            handler: handler
        )
    }

    static func start(
        runtimeDirectory: String,
        instanceID: String,
        deadlines: IPCDeadlines,
        maximumConnections: Int,
        operations: IPCPOSIXOperations,
        handler: @escaping IPCWireHandler
    ) throws -> IPCServer {
        guard isCanonicalUUID(instanceID), (1...8).contains(maximumConnections) else {
            throw IPCServerError.invalidRuntimeDirectory
        }
        let paths: IPCRuntimePaths
        do { paths = try IPCRuntimePaths(directory: runtimeDirectory) }
        catch { throw IPCServerError.invalidRuntimeDirectory }

        let resources = try openGeneration(paths: paths, instanceID: instanceID, operations: operations)
        let server = IPCServer(
            resources: resources,
            instanceID: instanceID,
            deadlines: deadlines,
            maximumConnections: maximumConnections,
            operations: operations,
            handler: handler
        )
        server.acceptFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async { server.acceptLoop() }
        return server
    }

    public var runtimeDirectory: String { resources.paths.directory }
    public var runtimeInstanceID: String { instanceID }

    public func stop() async -> IPCServerStopOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.stopSynchronously())
            }
        }
    }

    private func acceptLoop() {
        var shouldStop = false
        defer {
            acceptFinished.leave()
            if shouldStop {
                Task { _ = await stop() }
            }
        }
        let descriptor = resources.listenerDescriptor
        while !isStopping {
            let ready = operations.poll(descriptor, Int16(POLLIN), 100)
            if ready.result == 0 { continue }
            if ready.result < 0 {
                if ready.error == EINTR { continue }
                if isStopping { return }
                shouldStop = true
                return
            }
            guard ready.events & Int16(POLLIN) != 0 else {
                if isStopping { return }
                if ready.events & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    shouldStop = true
                    return
                }
                continue
            }
            let accepted = operations.accept(descriptor)
            let connection = accepted.value
            if connection < 0 || accepted.error != 0 {
                if accepted.error == EINTR || accepted.error == EAGAIN || accepted.error == EWOULDBLOCK { continue }
                if isStopping { return }
                shouldStop = true
                return
            }
            let nonblocking = operations.setNonblocking(connection)
            let noSIGPIPE = operations.setNoSIGPIPE(connection)
            guard nonblocking.value == 0, nonblocking.error == 0,
                  noSIGPIPE.value == 0, noSIGPIPE.error == 0,
                  reserveConnection() else {
                _ = operations.close(connection)
                continue
            }
            connections.enter()
            Task.detached { [self] in
                await serve(connection)
                finishConnection()
            }
        }
    }

    private func serve(_ descriptor: Int32) async {
        defer { _ = operations.close(descriptor) }
        let peerUID = operations.peerUserID(descriptor)
        guard peerUID.error == 0, peerUID.value == operations.effectiveUserID() else { return }

        let requestBytes: Data
        do { requestBytes = try IPCUnixTransport(operations: operations).readFrame(descriptor: descriptor, deadline: deadlines.read) }
        catch IPCFrameError.tooLarge {
            await send(IPCWireResponse(
                requestID: nil,
                failure: IPCProtocolFailure(code: "message_too_large", message: "request message is too large")
            ), to: descriptor)
            return
        } catch {
            return
        }

        let response: IPCWireResponse
        switch IPCProtocol.decodeRequest(requestBytes) {
        case let .failure(failure):
            response = IPCWireResponse(requestID: failure.requestID, failure: failure)
        case let .success(request):
            guard request.instanceID == instanceID else {
                response = IPCWireResponse(
                    requestID: request.requestID,
                    failure: IPCProtocolFailure(
                        code: "instance_mismatch",
                        message: "runtime instance does not match",
                        requestID: request.requestID
                    )
                )
                await send(response, to: descriptor)
                return
            }
            do { response = try await handler(request) }
            catch {
                response = IPCWireResponse(
                    requestID: request.requestID,
                    failure: IPCProtocolFailure(code: "internal", message: "internal server error", requestID: request.requestID)
                )
            }
            guard IPCProtocol.validate(response, for: request) else {
                await send(IPCWireResponse(
                    requestID: request.requestID,
                    failure: IPCProtocolFailure(code: "internal", message: "internal server error", requestID: request.requestID)
                ), to: descriptor)
                return
            }
        }
        await send(response, to: descriptor)
    }

    private func send(_ response: IPCWireResponse, to descriptor: Int32) async {
        guard let bytes = try? IPCProtocol.encodeResponse(response) else { return }
        do { try IPCUnixTransport(operations: operations).writeAll(bytes, descriptor: descriptor, deadline: deadlines.write) }
        catch { return }
    }

    private func reserveConnection() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopping, activeConnections < maximumConnections else { return false }
        activeConnections += 1
        return true
    }

    private func finishConnection() {
        stateLock.lock()
        activeConnections -= 1
        stateLock.unlock()
        connections.leave()
    }

    private var isStopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    private func stopSynchronously() -> IPCServerStopOutcome {
        stateLock.lock()
        if let stoppedOutcome {
            stateLock.unlock()
            return stoppedOutcome
        }
        let firstStop = !stopStarted
        stopStarted = true
        stopping = true
        stateLock.unlock()

        guard firstStop else {
            stopFinished.wait()
            stateLock.lock()
            let finalOutcome = stoppedOutcome ?? .cleanupUncertain
            stateLock.unlock()
            return finalOutcome
        }
        acceptFinished.wait()
        connections.wait()
        let outcome = closeGeneration(resources, operations: operations)

        stateLock.lock()
        if stoppedOutcome == nil { stoppedOutcome = outcome }
        let finalOutcome = stoppedOutcome!
        stateLock.unlock()
        stopFinished.leave()
        return finalOutcome
    }
}

private func openGeneration(paths: IPCRuntimePaths, instanceID: String, operations: IPCPOSIXOperations) throws -> IPCServerResources {
    let openedDirectory = operations.open(paths.directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW, 0)
    let directoryDescriptor = openedDirectory.value
    guard directoryDescriptor >= 0, openedDirectory.error == 0 else { throw IPCServerError.insecureRuntimeDirectory }
    let directoryStat = operations.fstat(directoryDescriptor)
    guard directoryStat.error == 0 else {
        _ = operations.close(directoryDescriptor)
        throw IPCServerError.insecureRuntimeDirectory
    }
    let directoryIdentity = IPCServerIdentity(directoryStat.value)
    guard directoryIdentity.type == UInt16(S_IFDIR), directoryIdentity.mode == 0o700,
          directoryIdentity.userID == operations.effectiveUserID(), sameIdentity(paths.directory, directoryIdentity, operations: operations) else {
        _ = operations.close(directoryDescriptor)
        throw IPCServerError.insecureRuntimeDirectory
    }

    do {
        try recoverStaleGeneration(paths: paths, directoryDescriptor: directoryDescriptor, directoryIdentity: directoryIdentity, operations: operations)
        let listener = try bindListener(paths: paths, operations: operations)
        do {
            let metadata = try IPCMetadata(schemaVersion: 1, instanceID: instanceID, socketName: "runtime.sock").encode()
            let metadataIdentity = try publishMetadata(metadata, paths: paths, directoryDescriptor: directoryDescriptor, operations: operations)
            return IPCServerResources(
                paths: paths,
                directoryDescriptor: directoryDescriptor,
                directoryIdentity: directoryIdentity,
                listenerDescriptor: listener.0,
                socketIdentity: listener.1,
                metadataIdentity: metadataIdentity
            )
        } catch {
            let listenerClose = operations.close(listener.0)
            guard listenerClose.value == 0, listenerClose.error == 0 else {
                throw IPCServerError.cleanupUncertain
            }
            do {
                try removeAtIfCurrent(
                    directoryDescriptor,
                    leaf: "runtime.sock",
                    path: paths.socketPath,
                    identity: listener.1,
                    operations: operations
                )
            } catch {
                throw IPCServerError.cleanupUncertain
            }
            throw error
        }
    } catch {
        _ = operations.close(directoryDescriptor)
        throw error
    }
}

private func recoverStaleGeneration(paths: IPCRuntimePaths, directoryDescriptor: Int32, directoryIdentity: IPCServerIdentity, operations: IPCPOSIXOperations) throws {
    let metadata = try inspectStaleMetadata(paths.metadataPath, operations: operations)
    let socket = try inspectStaleSocket(paths.socketPath, operations: operations)
    guard sameIdentity(paths.directory, directoryIdentity, operations: operations) else { throw IPCServerError.existingGenerationInvalid }
    if let metadata { try removeAtIfCurrent(directoryDescriptor, leaf: "runtime.json", path: paths.metadataPath, identity: metadata, operations: operations) }
    if let socket { try removeAtIfCurrent(directoryDescriptor, leaf: "runtime.sock", path: paths.socketPath, identity: socket, operations: operations) }
}

private func inspectStaleMetadata(_ path: String, operations: IPCPOSIXOperations) throws -> IPCServerIdentity? {
    let inspected = operations.lstat(path)
    if inspected.error != 0 {
        if inspected.error == ENOENT { return nil }
        throw IPCServerError.existingGenerationInvalid
    }
    let identity = IPCServerIdentity(inspected.value)
    guard identity.type == UInt16(S_IFREG), identity.mode == 0o600,
          identity.userID == operations.effectiveUserID() else { throw IPCServerError.existingGenerationInvalid }
    let opened = operations.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0)
    let descriptor = opened.value
    guard descriptor >= 0, opened.error == 0 else { throw IPCServerError.existingGenerationInvalid }
    defer { _ = operations.close(descriptor) }
    let openedStat = operations.fstat(descriptor)
    guard openedStat.error == 0, IPCServerIdentity(openedStat.value) == identity else {
        throw IPCServerError.existingGenerationInvalid
    }
    let bytes = try readBounded(descriptor, maximum: 1024, operations: operations)
    do { _ = try IPCMetadata.decode(bytes) }
    catch { throw IPCServerError.existingGenerationInvalid }
    guard sameIdentity(path, identity, operations: operations) else { throw IPCServerError.existingGenerationInvalid }
    return identity
}

private func inspectStaleSocket(_ path: String, operations: IPCPOSIXOperations) throws -> IPCServerIdentity? {
    let inspected = operations.lstat(path)
    if inspected.error != 0 {
        if inspected.error == ENOENT { return nil }
        throw IPCServerError.existingGenerationInvalid
    }
    let identity = IPCServerIdentity(inspected.value)
    guard identity.type == UInt16(S_IFSOCK), identity.mode == 0o600,
          identity.userID == operations.effectiveUserID() else { throw IPCServerError.existingGenerationInvalid }
    return identity
}

private func bindListener(paths: IPCRuntimePaths, operations: IPCPOSIXOperations) throws -> (Int32, IPCServerIdentity) {
    let socket = operations.createSocket()
    let descriptor = socket.value
    guard descriptor >= 0, socket.error == 0 else { throw IPCServerError.listenerUnavailable }
    let nonblocking = operations.setNonblocking(descriptor)
    let noSIGPIPE = operations.setNoSIGPIPE(descriptor)
    guard nonblocking.value == 0, nonblocking.error == 0,
          noSIGPIPE.value == 0, noSIGPIPE.error == 0 else {
        _ = operations.close(descriptor)
        throw IPCServerError.listenerUnavailable
    }
    let bound = operations.bind(descriptor, paths.socketPath)
    guard bound.value == 0, bound.error == 0 else {
        _ = operations.close(descriptor)
        throw IPCServerError.listenerUnavailable
    }
    let chmodResult = operations.chmod(paths.socketPath, mode_t(0o600))
    guard chmodResult.value == 0, chmodResult.error == 0 else {
        _ = operations.close(descriptor)
        throw IPCServerError.cleanupUncertain
    }
    let listening = operations.listen(descriptor, 8)
    guard listening.value == 0, listening.error == 0 else {
        _ = operations.close(descriptor)
        throw IPCServerError.cleanupUncertain
    }
    let inspected = operations.lstat(paths.socketPath)
    guard inspected.error == 0 else {
        _ = operations.close(descriptor)
        throw IPCServerError.cleanupUncertain
    }
    let identity = IPCServerIdentity(inspected.value)
    guard identity.type == UInt16(S_IFSOCK), identity.mode == 0o600,
          identity.userID == operations.effectiveUserID() else {
        _ = operations.close(descriptor)
        throw IPCServerError.cleanupUncertain
    }
    return (descriptor, identity)
}

private func publishMetadata(_ data: Data, paths: IPCRuntimePaths, directoryDescriptor: Int32, operations: IPCPOSIXOperations) throws -> IPCServerIdentity {
    let temporary = "runtime.json.\(UUID().uuidString.lowercased()).tmp"
    let opened = operations.openAt(directoryDescriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
    let descriptor = opened.value
    guard descriptor >= 0, opened.error == 0 else { throw IPCServerError.existingGenerationInvalid }
    var published = false
    var metadataIdentity: IPCServerIdentity?
    defer {
        _ = operations.close(descriptor)
        _ = operations.unlinkAt(directoryDescriptor, temporary)
        if !published, let metadataIdentity, sameIdentity(paths.metadataPath, metadataIdentity, operations: operations) {
            _ = operations.unlink(paths.metadataPath)
        }
    }
    let permissions = operations.fchmod(descriptor, mode_t(0o600))
    guard permissions.value == 0, permissions.error == 0 else { throw IPCServerError.existingGenerationInvalid }
    try writeFile(data, descriptor: descriptor, operations: operations)
    let fileSync = operations.fsync(descriptor)
    guard fileSync.value == 0, fileSync.error == 0 else { throw IPCServerError.existingGenerationInvalid }
    let temporaryStat = operations.fstat(descriptor)
    guard temporaryStat.error == 0 else { throw IPCServerError.existingGenerationInvalid }
    metadataIdentity = IPCServerIdentity(temporaryStat.value)
    let link = operations.linkAt(directoryDescriptor, temporary, directoryDescriptor, "runtime.json")
    guard link.value == 0, link.error == 0 else { throw IPCServerError.existingGenerationInvalid }
    let directorySync = operations.fsync(directoryDescriptor)
    guard directorySync.value == 0, directorySync.error == 0 else { throw IPCServerError.existingGenerationInvalid }
    let inspected = operations.lstat(paths.metadataPath)
    guard inspected.error == 0 else { throw IPCServerError.existingGenerationInvalid }
    let identity = IPCServerIdentity(inspected.value)
    guard identity.type == UInt16(S_IFREG), identity.mode == 0o600,
          identity.userID == operations.effectiveUserID(), identity == metadataIdentity else { throw IPCServerError.existingGenerationInvalid }
    published = true
    return identity
}

private func closeGeneration(_ resources: IPCServerResources, operations: IPCPOSIXOperations) -> IPCServerStopOutcome {
    var certain = true
    let listenerClose = operations.close(resources.listenerDescriptor)
    if listenerClose.value != 0 || listenerClose.error != 0 { certain = false }
    if !sameIdentity(resources.paths.directory, resources.directoryIdentity, operations: operations) { certain = false }
    if sameIdentity(resources.paths.metadataPath, resources.metadataIdentity, operations: operations) {
        let result = operations.unlink(resources.paths.metadataPath)
        if result.value != 0 || result.error != 0 { certain = false }
    } else {
        certain = false
    }
    if sameIdentity(resources.paths.socketPath, resources.socketIdentity, operations: operations) {
        let result = operations.unlink(resources.paths.socketPath)
        if result.value != 0 || result.error != 0 { certain = false }
    } else {
        certain = false
    }
    if !sameIdentity(resources.paths.directory, resources.directoryIdentity, operations: operations) { certain = false }
    let directoryClose = operations.close(resources.directoryDescriptor)
    if directoryClose.value != 0 || directoryClose.error != 0 { certain = false }
    return certain ? .closed : .cleanupUncertain
}

private func removeAtIfCurrent(_ directory: Int32, leaf: String, path: String, identity: IPCServerIdentity, operations: IPCPOSIXOperations) throws {
    guard sameIdentity(path, identity, operations: operations) else {
        throw IPCServerError.existingGenerationInvalid
    }
    let result = operations.unlinkAt(directory, leaf)
    guard result.value == 0, result.error == 0 else { throw IPCServerError.existingGenerationInvalid }
}

private func sameIdentity(_ path: String, _ identity: IPCServerIdentity, operations: IPCPOSIXOperations) -> Bool {
    let result = operations.lstat(path)
    return result.error == 0 && IPCServerIdentity(result.value) == identity
}

private func readBounded(_ descriptor: Int32, maximum: Int, operations: IPCPOSIXOperations) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: maximum + 1)
    let capacity = buffer.count
    var count = 0
    while count < capacity {
        let amount = buffer.withUnsafeMutableBytes { bytes in
            operations.read(descriptor, bytes.baseAddress!.advanced(by: count), capacity - count)
        }
        if amount.value > 0 { count += amount.value; continue }
        if amount.value == 0 { break }
        if amount.error == EINTR { continue }
        throw IPCServerError.existingGenerationInvalid
    }
    guard count <= maximum else { throw IPCServerError.existingGenerationInvalid }
    return Data(buffer[..<count])
}

private func writeFile(_ data: Data, descriptor: Int32, operations: IPCPOSIXOperations) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { throw IPCServerError.existingGenerationInvalid }
        var offset = 0
        while offset < data.count {
            let amount = operations.write(descriptor, base.advanced(by: offset), data.count - offset)
            if amount.value > 0 { offset += amount.value; continue }
            if amount.value < 0, amount.error == EINTR { continue }
            throw IPCServerError.existingGenerationInvalid
        }
    }
}

private func isCanonicalUUID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 36, bytes[8] == 0x2d, bytes[13] == 0x2d, bytes[18] == 0x2d, bytes[23] == 0x2d else { return false }
    return bytes.enumerated().allSatisfy { index, byte in
        [8, 13, 18, 23].contains(index) || (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
    }
}
