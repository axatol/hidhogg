import Darwin
import Foundation
import XCTest
@testable import HidhoggCore

final class IPCUnixTransportTests: XCTestCase {
    func testConnectWritesAndReadsThroughInjectedProductionOperations() throws {
        let script = IPCTransportScript()
        script.connectResult = IPCPOSIXResult(value: -1, error: EINPROGRESS)
        script.pollSteps = [
            .ready(Int16(POLLOUT)),
            .ready(Int16(POLLOUT)),
            .ready(Int16(POLLIN)),
        ]
        script.sendSteps = [.written(5)]
        script.receiveSteps = [.bytes(Data("reply\n".utf8))]
        let transport = IPCUnixTransport(operations: script.operations())

        let reply = try transport.exchange(
            socketPath: "/tmp/hidhogg-synthetic.sock",
            request: Data("ping\n".utf8),
            deadlines: IPCDeadlines(connect: .seconds(2), read: .seconds(2), write: .seconds(2))
        )

        XCTAssertEqual(reply, Data("reply\n".utf8))
        XCTAssertEqual(script.sentBytes, Data("ping\n".utf8))
        XCTAssertEqual(script.connectedPath, "/tmp/hidhogg-synthetic.sock")
        XCTAssertEqual(script.closedDescriptors, [42])
    }

    func testPartialWritesAndTransientReadErrorsRetryUntilCompleteFrame() throws {
        let script = IPCTransportScript()
        script.pollSteps = Array(repeating: .ready(nil), count: 7)
        script.sendSteps = [.failed(EINTR), .written(2), .failed(EAGAIN), .written(4)]
        script.receiveSteps = [.failed(EAGAIN), .bytes(Data("partial".utf8)), .bytes(Data("\nignored\n".utf8))]
        let transport = IPCUnixTransport(operations: script.operations())

        try transport.writeAll(Data("abcdef".utf8), descriptor: 7, deadline: .seconds(2))
        let frame = try transport.readFrame(descriptor: 7, deadline: .seconds(2))

        XCTAssertEqual(script.sentBytes, Data("abcdef".utf8))
        XCTAssertEqual(frame, Data("partial\n".utf8))
    }

    func testFrameLimitIncludesFirstLFAndIgnoresBytesAfterIt() throws {
        let maximum = IPCProtocol.maximumFrameBytes
        let exactFrame = Data(repeating: 0x61, count: maximum - 1) + Data([0x0a]) + Data("ignored".utf8)
        let exactScript = IPCTransportScript()
        exactScript.pollSteps = Array(repeating: .ready(nil), count: 6)
        exactScript.receiveSteps = [.bytes(exactFrame)]
        let exact = try IPCUnixTransport(operations: exactScript.operations())
            .readFrame(descriptor: 8, deadline: .seconds(2))
        XCTAssertEqual(exact.count, maximum)
        XCTAssertEqual(exact.last, 0x0a)

        let oversizedScript = IPCTransportScript()
        oversizedScript.pollSteps = Array(repeating: .ready(nil), count: 5)
        oversizedScript.receiveSteps = [.bytes(Data(repeating: 0x62, count: maximum + 1))]
        XCTAssertThrowsError(try IPCUnixTransport(operations: oversizedScript.operations())
            .readFrame(descriptor: 9, deadline: .seconds(2))) { error in
                XCTAssertEqual(error as? IPCFrameError, .tooLarge)
            }
    }

    func testLateReadinessCannotCompleteConnectWriteOrRead() {
        let connectScript = IPCTransportScript()
        connectScript.connectResult = IPCPOSIXResult(value: -1, error: EINPROGRESS)
        connectScript.pollSteps = [.lateReady(Int16(POLLOUT), by: .seconds(1))]
        XCTAssertThrowsError(try IPCUnixTransport(operations: connectScript.operations()).exchange(
            socketPath: "/tmp/hidhogg-synthetic.sock",
            request: Data("x\n".utf8),
            deadlines: IPCDeadlines(connect: .seconds(1), read: .seconds(1), write: .seconds(1))
        ))
        XCTAssertTrue(connectScript.sentBytes.isEmpty)
        XCTAssertEqual(connectScript.closedDescriptors, [42])

        let writeScript = IPCTransportScript()
        writeScript.pollSteps = [.lateReady(Int16(POLLOUT), by: .seconds(1))]
        XCTAssertThrowsError(try IPCUnixTransport(operations: writeScript.operations())
            .writeAll(Data("x".utf8), descriptor: 10, deadline: .seconds(1)))
        XCTAssertTrue(writeScript.sentBytes.isEmpty)

        let readScript = IPCTransportScript()
        readScript.pollSteps = [.lateReady(Int16(POLLIN), by: .seconds(1))]
        XCTAssertThrowsError(try IPCUnixTransport(operations: readScript.operations())
            .readFrame(descriptor: 11, deadline: .seconds(1)))
    }

    func testConnectRejectsInvalidPathAndWrongPeerBeforeSending() {
        let invalidPathScript = IPCTransportScript()
        let tooLong = "/" + String(repeating: "x", count: MemoryLayout.size(ofValue: sockaddr_un().sun_path))
        XCTAssertThrowsError(try IPCUnixTransport(operations: invalidPathScript.operations()).exchange(
            socketPath: tooLong,
            request: Data("x\n".utf8),
            deadlines: IPCDeadlines()
        ))
        XCTAssertEqual(invalidPathScript.socketCreationCount, 0)

        let wrongPeerScript = IPCTransportScript()
        wrongPeerScript.peerUID = 99
        wrongPeerScript.connectResult = IPCPOSIXResult(value: 0, error: 0)
        XCTAssertThrowsError(try IPCUnixTransport(operations: wrongPeerScript.operations()).exchange(
            socketPath: "/tmp/hidhogg-synthetic.sock",
            request: Data("x\n".utf8),
            deadlines: IPCDeadlines()
        ))
        XCTAssertTrue(wrongPeerScript.sentBytes.isEmpty)
        XCTAssertEqual(wrongPeerScript.closedDescriptors, [42])
    }

    func testImmediateConnectAndConnectionSetupFailureCloseDescriptors() throws {
        let immediate = IPCTransportScript()
        immediate.pollSteps = [.ready(Int16(POLLOUT)), .ready(Int16(POLLIN))]
        immediate.sendSteps = [.written(2)]
        immediate.receiveSteps = [.bytes(Data("ok\n".utf8))]
        let reply = try IPCUnixTransport(operations: immediate.operations()).exchange(
            socketPath: "/tmp/hidhogg-synthetic.sock",
            request: Data("x\n".utf8),
            deadlines: IPCDeadlines()
        )
        XCTAssertEqual(reply, Data("ok\n".utf8))
        XCTAssertEqual(immediate.closedDescriptors, [42])

        let setupFailure = IPCTransportScript()
        setupFailure.nonblockingResult = IPCPOSIXResult(value: -1, error: EIO)
        XCTAssertThrowsError(try IPCUnixTransport(operations: setupFailure.operations()).exchange(
            socketPath: "/tmp/hidhogg-synthetic.sock",
            request: Data("x\n".utf8),
            deadlines: IPCDeadlines()
        ))
        XCTAssertEqual(setupFailure.closedDescriptors, [42])
        XCTAssertNil(setupFailure.connectedPath)
    }

    func testPendingConnectRejectsSocketErrorAndClosesDescriptor() {
        let script = IPCTransportScript()
        script.connectResult = IPCPOSIXResult(value: -1, error: EINPROGRESS)
        script.pollSteps = [.ready(Int16(POLLOUT))]
        script.socketErrorValue = ECONNREFUSED

        XCTAssertThrowsError(try IPCUnixTransport(operations: script.operations()).exchange(
            socketPath: "/tmp/hidhogg-synthetic.sock",
            request: Data("x\n".utf8),
            deadlines: IPCDeadlines()
        ))
        XCTAssertTrue(script.sentBytes.isEmpty)
        XCTAssertEqual(script.closedDescriptors, [42])
    }

    func testZeroAndFatalWritesAndEOFOrFatalReadsFail() {
        for step in [IPCTransportScript.SendStep.zero, .failed(EPIPE)] {
            let script = IPCTransportScript()
            script.pollSteps = [.ready(Int16(POLLOUT))]
            script.sendSteps = [step]
            XCTAssertThrowsError(try IPCUnixTransport(operations: script.operations())
                .writeAll(Data("x".utf8), descriptor: 12, deadline: .seconds(1)))
        }

        let eof = IPCTransportScript()
        eof.pollSteps = [.ready(Int16(POLLIN))]
        eof.receiveSteps = [.eof]
        XCTAssertThrowsError(try IPCUnixTransport(operations: eof.operations())
            .readFrame(descriptor: 13, deadline: .seconds(1))) { error in
                XCTAssertEqual(error as? IPCFrameError, .incomplete)
            }

        let fatalRead = IPCTransportScript()
        fatalRead.pollSteps = [.ready(Int16(POLLIN))]
        fatalRead.receiveSteps = [.failed(EIO)]
        XCTAssertThrowsError(try IPCUnixTransport(operations: fatalRead.operations())
            .readFrame(descriptor: 14, deadline: .seconds(1))) { error in
                XCTAssertEqual(error as? IPCClientError, .transport)
            }
    }

    func testPollRetriesEINTRAndRejectsFatalOrUnrequestedReadiness() throws {
        let retry = IPCTransportScript()
        retry.pollSteps = [.failed(EINTR), .ready(Int16(POLLOUT))]
        retry.sendSteps = [.written(1)]
        try IPCUnixTransport(operations: retry.operations()).writeAll(Data("x".utf8), descriptor: 15, deadline: .seconds(1))
        XCTAssertEqual(retry.sentBytes, Data("x".utf8))

        let fatal = IPCTransportScript()
        fatal.pollSteps = [.failed(EIO)]
        XCTAssertThrowsError(try IPCUnixTransport(operations: fatal.operations())
            .writeAll(Data("x".utf8), descriptor: 16, deadline: .seconds(1)))
        XCTAssertTrue(fatal.sentBytes.isEmpty)

        let unrelated = IPCTransportScript()
        unrelated.pollSteps = [.ready(Int16(POLLERR))]
        XCTAssertThrowsError(try IPCUnixTransport(operations: unrelated.operations())
            .writeAll(Data("x".utf8), descriptor: 17, deadline: .seconds(1)))
        XCTAssertTrue(unrelated.sentBytes.isEmpty)
    }
}

private final class IPCTransportScript: @unchecked Sendable {
    enum PollStep {
        case ready(Int16?)
        case empty
        case lateReady(Int16?, by: Duration)
        case failed(Int32)
    }

    enum SendStep {
        case written(Int)
        case failed(Int32)
        case zero
    }

    enum ReceiveStep {
        case bytes(Data)
        case failed(Int32)
        case eof
    }

    private let lock = NSLock()
    private let origin = ContinuousClock().now
    private var elapsed = Duration.zero
    private var polls = [PollStep]()
    private var sends = [SendStep]()
    private var receives = [ReceiveStep]()
    private var sent = Data()
    private var closed = [Int32]()
    private var socketCreations = 0
    private var path: String?
    var connectResult = IPCPOSIXResult<Int32>(value: 0, error: 0)
    var peerUID: UInt32 = 42
    var socketErrorValue: Int32 = 0
    var nonblockingResult = IPCPOSIXResult<Int32>(value: 0, error: 0)
    var noSIGPIPEResult = IPCPOSIXResult<Int32>(value: 0, error: 0)

    var pollSteps: [PollStep] {
        get { access { polls } }
        set { access { polls = newValue } }
    }

    var sendSteps: [SendStep] {
        get { access { sends } }
        set { access { sends = newValue } }
    }

    var receiveSteps: [ReceiveStep] {
        get { access { receives } }
        set { access { receives = newValue } }
    }

    var sentBytes: Data { access { sent } }
    var closedDescriptors: [Int32] { access { closed } }
    var socketCreationCount: Int { access { socketCreations } }
    var connectedPath: String? { access { path } }

    func operations() -> IPCPOSIXOperations {
        var result = IPCPOSIXOperations.live
        result.now = { [self] in access { origin.advanced(by: elapsed) } }
        result.effectiveUserID = { 42 }
        result.createSocket = { [self] in access { socketCreations += 1 }; return IPCPOSIXResult(value: 42, error: 0) }
        result.connect = { [self] _, value in access { path = value }; return connectResult }
        result.poll = { [self] _, event, _ in nextPoll(event) }
        result.send = { [self] _, bytes, count in send(bytes, count: count) }
        result.receive = { [self] _, bytes, count in receive(bytes, count: count) }
        result.peerUserID = { [self] _ in IPCPOSIXResult(value: access { peerUID }, error: 0) }
        result.socketError = { [self] _ in IPCPOSIXResult(value: access { socketErrorValue }, error: 0) }
        result.setNonblocking = { [self] _ in access { nonblockingResult } }
        result.setNoSIGPIPE = { [self] _ in access { noSIGPIPEResult } }
        result.close = { [self] descriptor in access { closed.append(descriptor) }; return IPCPOSIXResult(value: 0, error: 0) }
        return result
    }

    private func nextPoll(_ event: Int16) -> IPCPollResult {
        access {
            guard !polls.isEmpty else { return IPCPollResult(result: 0, events: 0, error: 0) }
            switch polls.removeFirst() {
            case let .ready(events):
                return IPCPollResult(result: 1, events: events ?? event, error: 0)
            case .empty:
                return IPCPollResult(result: 0, events: 0, error: 0)
            case let .lateReady(events, delay):
                elapsed = elapsed + delay
                return IPCPollResult(result: 1, events: events ?? event, error: 0)
            case let .failed(error):
                return IPCPollResult(result: -1, events: 0, error: error)
            }
        }
    }

    private func send(_ bytes: UnsafeRawPointer?, count: Int) -> IPCPOSIXResult<Int> {
        access {
            guard !sends.isEmpty else { return IPCPOSIXResult(value: -1, error: EIO) }
            switch sends.removeFirst() {
            case let .written(amount):
                let written = min(amount, count)
                if written > 0, let bytes { sent.append(Data(bytes: bytes, count: written)) }
                return IPCPOSIXResult(value: written, error: 0)
            case let .failed(error):
                return IPCPOSIXResult(value: -1, error: error)
            case .zero:
                return IPCPOSIXResult(value: 0, error: 0)
            }
        }
    }

    private func receive(_ bytes: UnsafeMutableRawPointer?, count: Int) -> IPCPOSIXResult<Int> {
        access {
            guard !receives.isEmpty else { return IPCPOSIXResult(value: -1, error: EIO) }
            switch receives.removeFirst() {
            case let .bytes(data):
                let amount = min(data.count, count)
                guard amount > 0, let bytes else { return IPCPOSIXResult(value: 0, error: 0) }
                data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: amount)
                if amount < data.count { receives.insert(.bytes(Data(data.dropFirst(amount))), at: 0) }
                return IPCPOSIXResult(value: amount, error: 0)
            case let .failed(error):
                return IPCPOSIXResult(value: -1, error: error)
            case .eof:
                return IPCPOSIXResult(value: 0, error: 0)
            }
        }
    }

    private func access<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
