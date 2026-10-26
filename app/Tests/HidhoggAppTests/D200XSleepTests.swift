import Foundation
import XCTest
@testable import HidhoggApp
import HidhoggDomain
import LogitechBolt
import MacOSActions
import UlanziD200X

@MainActor
final class D200XSleepTests: XCTestCase {
    func testSleepRetainsConnectionAndWakeRestoresConfiguredBrightnessInOrder() async throws {
        let session = SleepTestD200XSession()
        let model = makeModel(session: session, brightness: 53)
        model.connect()

        let initialWriteCompleted = await eventually {
            let operations = await session.operations()
            return model.isConnected && operations == ["brightness:53"]
        }
        XCTAssertTrue(initialWriteCompleted)
        await session.clearOperations()

        model.sleep()
        let sleepApplied = await eventually {
            await session.operations() == ["keepawake:false", "brightness:0"]
        }
        XCTAssertTrue(sleepApplied)
        XCTAssertTrue(model.isConnected)
        var connections = await session.connectionCount()
        var disconnects = await session.disconnectCount()
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(disconnects, 0)

        model.wake()
        let wakeApplied = await eventually {
            await session.operations() == ["keepawake:false", "brightness:0", "keepawake:true", "brightness:53"]
        }
        XCTAssertTrue(wakeApplied)
        XCTAssertTrue(model.isConnected)
        connections = await session.connectionCount()
        disconnects = await session.disconnectCount()
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(disconnects, 0)
    }

    func testWakeRestoresBrightnessTo100WhenNoOverrideIsSaved() async throws {
        let session = SleepTestD200XSession()
        let model = makeModel(session: session, brightness: nil)
        model.connect()

        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)
        model.sleep()
        let sleepApplied = await eventually {
            await session.operations() == ["keepawake:false", "brightness:0"]
        }
        XCTAssertTrue(sleepApplied)

        model.wake()
        let wakeApplied = await eventually {
            await session.operations() == ["keepawake:false", "brightness:0", "keepawake:true", "brightness:100"]
        }
        XCTAssertTrue(wakeApplied)
        XCTAssertEqual(model.configuration?.brightnessPercent, nil)
    }

    func testSleepDuringConnectionPausesDeviceAfterConnectCompletes() async throws {
        let session = SleepTestD200XSession(holdConnection: true)
        let model = makeModel(session: session, brightness: 41)
        model.connect()
        let connectionStarted = await eventually { await session.connectionCount() == 1 }
        XCTAssertTrue(connectionStarted)
        XCTAssertTrue(model.isBusy)

        model.sleep()
        await session.releaseConnection()
        let sleepApplied = await eventually {
            let operations = await session.operations()
            return model.isConnected && operations == ["keepawake:false", "brightness:0"]
        }
        XCTAssertTrue(sleepApplied)
        let connections = await session.connectionCount()
        let disconnects = await session.disconnectCount()
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(disconnects, 0)
    }

    func testRapidWakeInvalidatesPendingSleepBrightnessWithoutDisconnecting() async throws {
        let session = SleepTestD200XSession(holdSleepPause: true)
        let model = makeModel(session: session, brightness: 47)
        model.connect()
        let initialWriteCompleted = await eventually {
            let operations = await session.operations()
            return model.isConnected && operations == ["brightness:47"]
        }
        XCTAssertTrue(initialWriteCompleted)
        await session.clearOperations()

        model.sleep()
        let pauseStarted = await eventually { await session.operations() == ["keepawake:false"] }
        XCTAssertTrue(pauseStarted)
        model.wake()
        await session.releaseSleepPause()

        let wakeApplied = await eventually {
            await session.operations() == ["keepawake:false", "keepawake:true", "brightness:47"]
        }
        XCTAssertTrue(wakeApplied)
        XCTAssertTrue(model.isConnected)
        let connections = await session.connectionCount()
        let disconnects = await session.disconnectCount()
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(disconnects, 0)
    }

    func testWakeReconnectsLostHandleThenRestoresSettings() async throws {
        let session = SleepTestD200XSession()
        let model = makeModel(session: session, brightness: 66)
        model.connect()
        let initialWriteCompleted = await eventually {
            let operations = await session.operations()
            return model.isConnected && operations == ["brightness:66"]
        }
        XCTAssertTrue(initialWriteCompleted)
        await session.clearOperations()

        model.sleep()
        let sleepApplied = await eventually {
            await session.operations() == ["keepawake:false", "brightness:0"]
        }
        XCTAssertTrue(sleepApplied)
        await session.emitStatus(.disconnected)
        let lostHandle = await eventually { !model.isConnected }
        XCTAssertTrue(lostHandle)

        model.wake()
        let wakeApplied = await eventually {
            await session.operations() == ["keepawake:false", "brightness:0", "keepawake:true", "brightness:66"]
        }
        XCTAssertTrue(wakeApplied)
        let connections = await session.connectionCount()
        let disconnects = await session.disconnectCount()
        XCTAssertEqual(connections, 2)
        XCTAssertEqual(disconnects, 0)
    }

    func testWakeReappliesLatestBrightnessIfConfigurationChangesDuringWrite() async throws {
        let session = SleepTestD200XSession(holdWakeBrightness: true)
        let model = makeModel(session: session, brightness: 40)
        model.connect()
        let initialWriteCompleted = await eventually {
            let operations = await session.operations()
            return model.isConnected && operations == ["brightness:40"]
        }
        XCTAssertTrue(initialWriteCompleted)
        await session.clearOperations()

        model.sleep()
        let sleepApplied = await eventually {
            await session.operations() == ["keepawake:false", "brightness:0"]
        }
        XCTAssertTrue(sleepApplied)
        model.wake()
        let previousRestoreStarted = await eventually {
            await session.operations() == ["keepawake:false", "brightness:0", "keepawake:true", "brightness:40"]
        }
        XCTAssertTrue(previousRestoreStarted)

        model.synchronize(D200XConfiguration(brightnessPercent: 66), canEdit: true)
        await session.releaseWakeBrightness()
        let latestRestoreApplied = await eventually {
            await session.operations() == [
                "keepawake:false", "brightness:0", "keepawake:true", "brightness:40", "brightness:66"
            ]
        }
        XCTAssertTrue(latestRestoreApplied)
        XCTAssertEqual(model.configuration?.brightnessPercent, 66)
    }

    func testDisconnectWaitsForPendingSleepTransitionThenClosesSession() async throws {
        let session = SleepTestD200XSession(holdSleepPause: true)
        let model = makeModel(session: session, brightness: 39)
        model.connect()
        let initialWriteCompleted = await eventually {
            let operations = await session.operations()
            return model.isConnected && operations == ["brightness:39"]
        }
        XCTAssertTrue(initialWriteCompleted)
        await session.clearOperations()

        model.sleep()
        let pauseStarted = await eventually { await session.operations() == ["keepawake:false"] }
        XCTAssertTrue(pauseStarted)
        model.disconnect()
        await session.releaseSleepPause()

        let disconnected = await eventually { await session.disconnectCount() == 1 }
        XCTAssertTrue(disconnected)
        let operations = await session.operations()
        XCTAssertEqual(operations, ["keepawake:false", "disconnect"])
    }

    private func makeModel(session: SleepTestD200XSession, brightness: Int?) -> D200XModel {
        let model = D200XModel(session: session, sender: makeSender())
        model.synchronize(D200XConfiguration(brightnessPercent: brightness), canEdit: true)
        return model
    }

    private func makeSender(postPair: @escaping (KeyboardShortcut) -> Void = { _ in }) -> ShortcutSender {
        ShortcutSender(preflight: { true }, request: { false }, postPair: postPair)
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor SleepTestD200XSession: D200XSessionProtocol {
    nonisolated let events: AsyncStream<D200XSessionEvent>
    private let continuation: AsyncStream<D200XSessionEvent>.Continuation
    private let connectionGate = SleepTestGate()
    private let sleepPauseGate = SleepTestGate()
    private let wakeBrightnessGate = SleepTestGate()
    private let holdConnection: Bool
    private let holdSleepPause: Bool
    private let holdWakeBrightness: Bool
    private var didHoldConnection = false
    private var didHoldSleepPause = false
    private var didHoldWakeBrightness = false
    private var shouldHoldWakeBrightness = false
    private var generation: UInt64 = 0
    private var connections = 0
    private var disconnects = 0
    private var recordedOperations = [String]()

    init(holdConnection: Bool = false, holdSleepPause: Bool = false, holdWakeBrightness: Bool = false) {
        let stream = AsyncStream<D200XSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        self.holdConnection = holdConnection
        self.holdSleepPause = holdSleepPause
        self.holdWakeBrightness = holdWakeBrightness
    }

    func connect() async throws {
        connections += 1
        generation &+= 1
        continuation.yield(.status(.connecting, generation: generation))
        if holdConnection && !didHoldConnection {
            didHoldConnection = true
            await connectionGate.wait()
        }
        continuation.yield(.status(.connected(try identity()), generation: generation))
    }

    func disconnect() async {
        disconnects += 1
        recordedOperations.append("disconnect")
        continuation.yield(.status(.disconnected, generation: generation))
    }

    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws {}

    func setBrightness(_ percent: Int) async throws {
        recordedOperations.append("brightness:\(percent)")
        if shouldHoldWakeBrightness && !didHoldWakeBrightness {
            didHoldWakeBrightness = true
            await wakeBrightnessGate.wait()
        }
    }

    func setKeepAwakeEnabled(_ enabled: Bool) async throws {
        recordedOperations.append("keepawake:\(enabled)")
        if enabled && holdWakeBrightness { shouldHoldWakeBrightness = true }
        if !enabled && holdSleepPause && !didHoldSleepPause {
            didHoldSleepPause = true
            await sleepPauseGate.wait()
        }
    }

    func emitStatus(_ status: D200XStatus) {
        continuation.yield(.status(status, generation: generation))
    }

    func releaseConnection() async { await connectionGate.open() }
    func releaseSleepPause() async { await sleepPauseGate.open() }
    func releaseWakeBrightness() async { await wakeBrightnessGate.open() }
    func operations() -> [String] { recordedOperations }
    func clearOperations() { recordedOperations.removeAll() }
    func connectionCount() -> Int { connections }
    func disconnectCount() -> Int { disconnects }

    private func identity() throws -> D200XIdentity {
        try D200XIdentity(payload: Data(
            #"{"SerialNumber":"02123A04512345678","Dversion":"1.0","HardwareVersion":"1.0"}"#.utf8
        ))
    }
}

private actor SleepTestGate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
