import Darwin
import Foundation
import XCTest
@testable import HidhoggCore

final class IPCServerTests: XCTestCase {
    func testStartPublishesMetadataAndStopRemovesOnlyItsGeneration() async throws {
        let fixture = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = try fixture.start { request in Self.healthResponse(for: request) }

        XCTAssertTrue(fixture.fake.socketIsBound)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), ["runtime.json"])
        XCTAssertEqual(
            try IPCMetadata.decode(Data(contentsOf: URL(fileURLWithPath: fixture.paths.metadataPath))).instanceID,
            fixture.instanceID
        )

        let outcome = await server.stop()

        XCTAssertEqual(outcome, .closed)
        XCTAssertFalse(fixture.fake.socketIsBound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.metadataPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [])
    }

    func testInvalidStaleMetadataFailsBeforeListenerCreation() throws {
        let invalid = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: invalid.directory) }
        try Data("{invalid".utf8).write(to: URL(fileURLWithPath: invalid.paths.metadataPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: invalid.paths.metadataPath)

        XCTAssertThrowsError(try invalid.start { request in Self.healthResponse(for: request) }) { error in
            XCTAssertEqual(error as? IPCServerError, .existingGenerationInvalid)
        }
        XCTAssertEqual(invalid.fake.listenerCreationCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.paths.metadataPath))
        XCTAssertFalse(invalid.fake.socketIsBound)
    }

    func testMetadataPublishFailureClosesListenerAndRemovesSocket() throws {
        let fixture = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.fake.failMetadataLink = true

        XCTAssertThrowsError(try fixture.start { request in Self.healthResponse(for: request) }) { error in
            XCTAssertEqual(error as? IPCServerError, .existingGenerationInvalid)
        }

        XCTAssertEqual(fixture.fake.listenerCreationCount, 1)
        XCTAssertTrue(fixture.fake.listenerCloseWasAttempted)
        XCTAssertFalse(fixture.fake.socketIsBound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.metadataPath))
    }

    func testMetadataPublishFailurePreservesReplacementSocketAndReportsUncertainty() throws {
        let fixture = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.fake.failMetadataLink = true
        fixture.fake.replaceSocketOnMetadataLinkFailure = true

        XCTAssertThrowsError(try fixture.start { request in Self.healthResponse(for: request) }) { error in
            XCTAssertEqual(error as? IPCServerError, .cleanupUncertain)
        }

        XCTAssertTrue(fixture.fake.listenerWasClosed)
        XCTAssertTrue(fixture.fake.socketIsBound)
        XCTAssertEqual(fixture.fake.socketInode, 881)
        XCTAssertEqual(fixture.fake.socketUnlinkCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.metadataPath))
    }

    func testPostBindLookupFailurePreservesUnknownSocketAndReportsUncertainty() throws {
        let fixture = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.fake.socketLookupError = EIO
        fixture.fake.replaceSocketOnLookupError = true

        XCTAssertThrowsError(try fixture.start { request in Self.healthResponse(for: request) }) { error in
            XCTAssertEqual(error as? IPCServerError, .cleanupUncertain)
        }

        XCTAssertEqual(fixture.fake.postBindSocketLookupCount, 1)
        XCTAssertTrue(fixture.fake.listenerWasClosed)
        XCTAssertTrue(fixture.fake.socketIsBound)
        XCTAssertEqual(fixture.fake.socketInode, 881)
        XCTAssertEqual(fixture.fake.socketUnlinkCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.metadataPath))
    }

    func testPostBindChmodAndListenFailuresPreserveSocketAndReportUncertainty() throws {
        for failure in ["chmod", "listen"] {
            let fixture = try IPCServerFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if failure == "chmod" {
                fixture.fake.chmodError = EIO
            } else {
                fixture.fake.listenError = EIO
            }

            XCTAssertThrowsError(try fixture.start { request in Self.healthResponse(for: request) }) { error in
                XCTAssertEqual(error as? IPCServerError, .cleanupUncertain, failure)
            }

            XCTAssertEqual(fixture.fake.listenCallCount, failure == "chmod" ? 0 : 1, failure)
            XCTAssertEqual(fixture.fake.postBindSocketLookupCount, 0, failure)
            XCTAssertTrue(fixture.fake.listenerWasClosed, failure)
            XCTAssertTrue(fixture.fake.socketIsBound, failure)
            XCTAssertEqual(fixture.fake.socketUnlinkCount, 0, failure)
        }
    }

    func testPeerAndInstanceMismatchesNeverReachHandler() async throws {
        let fixture = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let handler = IPCServerHandlerRecorder()
        let server = try fixture.start { request in
            handler.recordCall()
            return Self.healthResponse(for: request)
        }
        defer { Task { _ = await server.stop() } }

        let wrongPeer = fixture.fake.enqueue(
            try Self.healthRequest(instanceID: fixture.instanceID),
            peerUID: fixture.fake.userID &+ 1
        )
        try await fixture.fake.waitForClose(wrongPeer)
        XCTAssertTrue(fixture.fake.sentBytes(for: wrongPeer).isEmpty)

        let otherInstance = "33333333-3333-4333-8333-333333333333"
        let mismatched = fixture.fake.enqueue(try Self.healthRequest(instanceID: otherInstance))
        try await fixture.fake.waitForClose(mismatched)

        let response = try IPCProtocol.decodeResponse(
            fixture.fake.sentBytes(for: mismatched),
            expectedRequestID: "44444444-4444-4444-8444-444444444444",
            expectedInstanceID: fixture.instanceID,
            method: .health
        )
        XCTAssertEqual(response.failure?.code, "instance_mismatch")
        XCTAssertEqual(handler.callCount, 0)
        let stopOutcome = await server.stop()
        XCTAssertEqual(stopOutcome, .closed)
    }

    func testMalformedRequestAndHandlerFailureReturnSafeProtocolErrors() async throws {
        let fixture = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = try fixture.start { _ in throw IPCServerTestError.handler }
        defer { Task { _ = await server.stop() } }

        let malformed = fixture.fake.enqueue(Data("not-json\n".utf8))
        try await fixture.fake.waitForClose(malformed)
        let malformedResponse = try Self.decodeRawResponse(fixture.fake.sentBytes(for: malformed))
        XCTAssertEqual(malformedResponse.value(for: "error")?.value(for: "code")?.stringValue, "invalid_json")

        let requestID = "55555555-5555-4555-8555-555555555555"
        let valid = fixture.fake.enqueue(try Self.healthRequest(instanceID: fixture.instanceID, requestID: requestID))
        try await fixture.fake.waitForClose(valid)
        let failure = try IPCProtocol.decodeResponse(
            fixture.fake.sentBytes(for: valid),
            expectedRequestID: requestID,
            expectedInstanceID: fixture.instanceID,
            method: .health
        )
        XCTAssertEqual(failure.failure?.code, "internal")
        let stopOutcome = await server.stop()
        XCTAssertEqual(stopOutcome, .closed)
    }

    func testConnectionLimitRejectsExcessAndStopWaitsForActiveHandler() async throws {
        let fixture = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pause = IPCServerPause()
        let handler = IPCServerHandlerRecorder()
        let server = try fixture.start(maximumConnections: 1) { request in
            handler.recordCall()
            await pause.hold()
            return Self.healthResponse(for: request)
        }

        let first = fixture.fake.enqueue(try Self.healthRequest(instanceID: fixture.instanceID))
        await pause.waitUntilEntered()
        let excess = fixture.fake.enqueue(try Self.healthRequest(instanceID: fixture.instanceID))
        try await fixture.fake.waitForClose(excess)
        XCTAssertEqual(handler.callCount, 1)

        let stopping = Task { await server.stop() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(fixture.fake.listenerCloseWasAttempted)

        await pause.release()
        let stopOutcome = await stopping.value
        XCTAssertEqual(stopOutcome, .closed)
        try await fixture.fake.waitForClose(first)
        XCTAssertTrue(fixture.fake.listenerCloseWasAttempted)
        XCTAssertEqual(handler.callCount, 1)
    }

    func testListenerCloseFailureReturnsStableCleanupUncertainty() async throws {
        let fixture = try IPCServerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = try fixture.start { request in Self.healthResponse(for: request) }
        fixture.fake.listenerCloseError = EIO

        let firstOutcome = await server.stop()
        let secondOutcome = await server.stop()
        XCTAssertEqual(firstOutcome, .cleanupUncertain)
        XCTAssertEqual(secondOutcome, .cleanupUncertain)
        XCTAssertTrue(fixture.fake.listenerCloseWasAttempted)
        XCTAssertFalse(fixture.fake.socketIsBound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.metadataPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [])
    }

    private static func healthRequest(instanceID: String, requestID: String = "44444444-4444-4444-8444-444444444444") throws -> Data {
        try IPCProtocol.encodeRequest(requestID: requestID, command: .health, instanceID: instanceID)
    }

    private static func healthResponse(for request: IPCWireRequest) -> IPCWireResponse {
        IPCWireResponse(
            requestID: request.requestID,
            result: .object([
                IPCJSONField(key: "instance_id", value: .string(request.instanceID)),
                IPCJSONField(key: "state", value: .string("ready")),
            ])
        )
    }

    private static func decodeRawResponse(_ data: Data) throws -> IPCJSONValue {
        let frame = try IPCProtocol.firstFrame(in: data)
        return try IPCJSONCodec.decode(Data(frame.dropLast()))
    }
}

private enum IPCServerTestError: Error {
    case handler
}

private struct IPCServerFixture {
    let directory: URL
    let paths: IPCRuntimePaths
    let instanceID = "22222222-2222-4222-8222-222222222222"
    let fake: IPCServerFake

    init() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("hgsvr-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        paths = try IPCRuntimePaths(directory: directory.path)
        fake = IPCServerFake(paths: paths)
    }

    func start(
        maximumConnections: Int = 8,
        handler: @escaping IPCWireHandler
    ) throws -> IPCServer {
        try IPCServer.start(
            runtimeDirectory: directory.path,
            instanceID: instanceID,
            deadlines: IPCDeadlines(connect: .seconds(1), read: .seconds(1), write: .seconds(1)),
            maximumConnections: maximumConnections,
            operations: fake.operations(),
            handler: handler
        )
    }
}

private final class IPCServerFake: @unchecked Sendable {
    private struct Client {
        let request: Data
        let peerUID: UInt32
        var readOffset = 0
        var response = Data()
        var closed = false
    }

    private static let listenerDescriptor: Int32 = 880
    private static let firstClientDescriptor: Int32 = 881
    private let listenerDescriptor = IPCServerFake.listenerDescriptor
    private let lock = NSLock()
    private let listenerSignal = DispatchSemaphore(value: 0)
    private let live = IPCPOSIXOperations.live
    private let paths: IPCRuntimePaths
    private var bound = false
    private var nextDescriptor = IPCServerFake.firstClientDescriptor
    private var pending = [Int32]()
    private var clients = [Int32: Client]()
    private var closed = [Int32]()
    private var listenerCreations = 0
    private var listenerCloseAttempted = false
    private var socketNodeInode: UInt64 = 880
    private var postBindSocketLookups = 0
    private var socketUnlinks = 0
    private var listenCalls = 0
    private var configuredListenerCloseError: Int32?
    private var configuredChmodError: Int32?
    private var configuredListenError: Int32?
    private var configuredSocketLookupError: Int32?
    private var configuredReplaceSocketOnLookupError = false
    private var configuredMetadataLinkFailure = false
    private var configuredReplaceSocketOnMetadataLinkFailure = false
    let userID = UInt32(geteuid())

    init(paths: IPCRuntimePaths) {
        self.paths = paths
    }

    var socketIsBound: Bool { access { bound } }
    var socketInode: UInt64 { access { socketNodeInode } }
    var listenerCreationCount: Int { access { listenerCreations } }
    var listenerCloseWasAttempted: Bool { access { listenerCloseAttempted } }
    var listenerWasClosed: Bool { access { closed.contains(listenerDescriptor) } }
    var postBindSocketLookupCount: Int { access { postBindSocketLookups } }
    var socketUnlinkCount: Int { access { socketUnlinks } }
    var listenCallCount: Int { access { listenCalls } }

    var listenerCloseError: Int32? {
        get { access { configuredListenerCloseError } }
        set { access { configuredListenerCloseError = newValue } }
    }

    var chmodError: Int32? {
        get { access { configuredChmodError } }
        set { access { configuredChmodError = newValue } }
    }

    var listenError: Int32? {
        get { access { configuredListenError } }
        set { access { configuredListenError = newValue } }
    }

    var socketLookupError: Int32? {
        get { access { configuredSocketLookupError } }
        set { access { configuredSocketLookupError = newValue } }
    }

    var replaceSocketOnLookupError: Bool {
        get { access { configuredReplaceSocketOnLookupError } }
        set { access { configuredReplaceSocketOnLookupError = newValue } }
    }

    var failMetadataLink: Bool {
        get { access { configuredMetadataLinkFailure } }
        set { access { configuredMetadataLinkFailure = newValue } }
    }

    var replaceSocketOnMetadataLinkFailure: Bool {
        get { access { configuredReplaceSocketOnMetadataLinkFailure } }
        set { access { configuredReplaceSocketOnMetadataLinkFailure = newValue } }
    }

    func enqueue(_ request: Data, peerUID: UInt32? = nil) -> Int32 {
        let descriptor = access { () -> Int32 in
            let descriptor = nextDescriptor
            nextDescriptor += 1
            clients[descriptor] = Client(request: request, peerUID: peerUID ?? userID)
            pending.append(descriptor)
            return descriptor
        }
        listenerSignal.signal()
        return descriptor
    }

    func sentBytes(for descriptor: Int32) -> Data {
        access { clients[descriptor]?.response ?? Data() }
    }

    func wasClosed(_ descriptor: Int32) -> Bool {
        access { closed.contains(descriptor) }
    }

    func waitForClose(_ descriptor: Int32) async throws {
        for _ in 0..<400 {
            if wasClosed(descriptor) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("fake connection \(descriptor) did not close")
    }

    func operations() -> IPCPOSIXOperations {
        var operations = live
        operations.effectiveUserID = { [userID] in userID }
        operations.createSocket = { [self] in
            access { listenerCreations += 1 }
            return IPCPOSIXResult(value: listenerDescriptor, error: 0)
        }
        operations.bind = { [self] descriptor, path in
            guard descriptor == listenerDescriptor, path == paths.socketPath else {
                return IPCPOSIXResult(value: -1, error: EINVAL)
            }
            access { bound = true }
            return IPCPOSIXResult(value: 0, error: 0)
        }
        operations.chmod = { [self] path, mode in
            guard path == paths.socketPath, mode == 0o600 else { return live.chmod(path, mode) }
            if let error = chmodError { return IPCPOSIXResult(value: -1, error: error) }
            return IPCPOSIXResult(value: 0, error: 0)
        }
        operations.listen = { [self] descriptor, _ in
            guard descriptor == listenerDescriptor else { return IPCPOSIXResult(value: -1, error: EBADF) }
            return access {
                listenCalls += 1
                if let error = configuredListenError { return IPCPOSIXResult(value: -1, error: error) }
                return IPCPOSIXResult(value: 0, error: 0)
            }
        }
        operations.poll = { [self] descriptor, events, timeout in
            if descriptor == listenerDescriptor { return pollListener(events, timeout: timeout) }
            let known = access { clients[descriptor] != nil }
            return known
                ? IPCPollResult(result: 1, events: events, error: 0)
                : IPCPollResult(result: -1, events: 0, error: EBADF)
        }
        operations.accept = { [self] descriptor in
            guard descriptor == listenerDescriptor else { return IPCPOSIXResult(value: -1, error: EBADF) }
            return acceptClient()
        }
        operations.peerUserID = { [self] descriptor in
            guard let peer = access({ clients[descriptor]?.peerUID }) else {
                return IPCPOSIXResult(value: nil, error: EBADF)
            }
            return IPCPOSIXResult(value: peer, error: 0)
        }
        operations.setNonblocking = { [self] descriptor in
            isFakeDescriptor(descriptor)
                ? IPCPOSIXResult(value: 0, error: 0)
                : live.setNonblocking(descriptor)
        }
        operations.setNoSIGPIPE = { [self] descriptor in
            isFakeDescriptor(descriptor)
                ? IPCPOSIXResult(value: 0, error: 0)
                : live.setNoSIGPIPE(descriptor)
        }
        operations.receive = { [self] descriptor, bytes, count in receive(descriptor, into: bytes, count: count) }
        operations.send = { [self] descriptor, bytes, count in send(descriptor, bytes: bytes, count: count) }
        operations.close = { [self] descriptor in close(descriptor) }
        operations.lstat = { [self] path in
            guard path == paths.socketPath else { return live.lstat(path) }
            return socketStat()
        }
        operations.unlink = { [self] path in
            guard path == paths.socketPath else { return live.unlink(path) }
            return access { () -> IPCPOSIXResult<Int32> in
                guard bound else { return IPCPOSIXResult(value: -1, error: ENOENT) }
                bound = false
                return IPCPOSIXResult(value: 0, error: 0)
            }
        }
        operations.unlinkAt = { [self] descriptor, leaf in
            guard leaf == "runtime.sock" else { return live.unlinkAt(descriptor, leaf) }
            return access { () -> IPCPOSIXResult<Int32> in
                socketUnlinks += 1
                guard bound else { return IPCPOSIXResult(value: -1, error: ENOENT) }
                bound = false
                return IPCPOSIXResult(value: 0, error: 0)
            }
        }
        operations.linkAt = { [self] oldDirectory, oldPath, newDirectory, newPath in
            if newPath == "runtime.json", failMetadataLink {
                if replaceSocketOnMetadataLinkFailure {
                    access { socketNodeInode = 881 }
                }
                return IPCPOSIXResult(value: -1, error: EIO)
            }
            return live.linkAt(oldDirectory, oldPath, newDirectory, newPath)
        }
        return operations
    }

    private func pollListener(_ events: Int16, timeout: Int32) -> IPCPollResult {
        if access({ !pending.isEmpty }) { return IPCPollResult(result: 1, events: events, error: 0) }
        _ = listenerSignal.wait(timeout: .now() + .milliseconds(Int(min(max(timeout, 1), 20))))
        return access {
            pending.isEmpty
                ? IPCPollResult(result: 0, events: 0, error: 0)
                : IPCPollResult(result: 1, events: events, error: 0)
        }
    }

    private func acceptClient() -> IPCPOSIXResult<Int32> {
        access {
            guard !pending.isEmpty else { return IPCPOSIXResult(value: -1, error: EAGAIN) }
            return IPCPOSIXResult(value: pending.removeFirst(), error: 0)
        }
    }

    private func receive(_ descriptor: Int32, into destination: UnsafeMutableRawPointer?, count: Int) -> IPCPOSIXResult<Int> {
        access {
            guard var client = clients[descriptor], let destination else {
                return IPCPOSIXResult(value: -1, error: EBADF)
            }
            guard client.readOffset < client.request.count else { return IPCPOSIXResult(value: 0, error: 0) }
            let amount = min(count, client.request.count - client.readOffset)
            client.request.withUnsafeBytes { source in
                destination.copyMemory(from: source.baseAddress!.advanced(by: client.readOffset), byteCount: amount)
            }
            client.readOffset += amount
            clients[descriptor] = client
            return IPCPOSIXResult(value: amount, error: 0)
        }
    }

    private func send(_ descriptor: Int32, bytes: UnsafeRawPointer?, count: Int) -> IPCPOSIXResult<Int> {
        access {
            guard var client = clients[descriptor], let bytes else { return IPCPOSIXResult(value: -1, error: EBADF) }
            client.response.append(Data(bytes: bytes.assumingMemoryBound(to: UInt8.self), count: count))
            clients[descriptor] = client
            return IPCPOSIXResult(value: count, error: 0)
        }
    }

    private func close(_ descriptor: Int32) -> IPCPOSIXResult<Int32> {
        if descriptor == listenerDescriptor {
            return access {
                listenerCloseAttempted = true
                if let error = configuredListenerCloseError { return IPCPOSIXResult(value: -1, error: error) }
                closed.append(descriptor)
                return IPCPOSIXResult(value: 0, error: 0)
            }
        }
        let isClient = access { clients[descriptor] != nil }
        guard isClient else { return live.close(descriptor) }
        return access {
            clients[descriptor]?.closed = true
            closed.append(descriptor)
            return IPCPOSIXResult(value: 0, error: 0)
        }
    }

    private func socketStat() -> IPCPOSIXResult<stat> {
        access {
            guard bound else { return IPCPOSIXResult(value: stat(), error: ENOENT) }
            postBindSocketLookups += 1
            if let error = configuredSocketLookupError {
                if configuredReplaceSocketOnLookupError { socketNodeInode = 881 }
                return IPCPOSIXResult(value: stat(), error: error)
            }
            var value = stat()
            value.st_mode = mode_t(S_IFSOCK | 0o600)
            value.st_uid = uid_t(userID)
            value.st_dev = 0x535652
            value.st_ino = ino_t(socketNodeInode)
            return IPCPOSIXResult(value: value, error: 0)
        }
    }

    private func isFakeDescriptor(_ descriptor: Int32) -> Bool {
        descriptor == listenerDescriptor || access { clients[descriptor] != nil }
    }

    private func access<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class IPCServerHandlerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { access { calls } }

    func recordCall() { access { calls += 1 } }

    private func access<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor IPCServerPause {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
