import Combine
import Foundation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class WakeConnectionTests: XCTestCase {
    func testEnabledSessionReconcilesConfiguredBindingAfterWakeExactlyOnce() async {
        let session = WakeBindingSession()
        let model = makeModel(session, permissionAllowed: true)
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 33))
        model.updateDraft(configuration)
        model.connect()
        await drain()
        XCTAssertTrue(model.isBindingsEnabled)
        model.systemWillSleep()
        XCTAssertFalse(model.isBindingsEnabled)
        model.systemDidWake()
        await drain()
        let enables = await session.enableCount
        let discoveries = await session.discoverCount
        XCTAssertEqual(enables, 2)
        XCTAssertEqual(discoveries, 2)
        XCTAssertTrue(model.isBindingsEnabled)
    }

    func testTransientDiscoveryFailureThenSuccessRestoresConnection() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        await session.setFailures([.endpointUnavailable])
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        let count = await session.discoverCount
        XCTAssertEqual(count, 3)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertEqual(model.diagnosticEvent?.code, .wakeReconnectSucceeded)
    }

    func testWakeBeforeCleanupWaitsAndDuplicateNotificationsReconnectOnlyOnceWithoutPermission() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        XCTAssertEqual(model.boltStatus.phase, .ready)
        await session.pauseCleanup()
        model.systemWillSleep()
        model.systemWillSleep()
        model.systemDidWake()
        model.systemDidWake()
        await drain()
        let before = await session.discoverCount
        XCTAssertEqual(before, 1)
        await session.completeCleanup()
        await drain()
        let after = await session.discoverCount
        XCTAssertEqual(after, 2)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertEqual(model.permission, .denied)
        XCTAssertFalse(model.isBindingsEnabled)
        XCTAssertEqual(model.diagnosticEvent?.code, .wakeReconnectSucceeded)
    }

    func testManualDisconnectBeforeSleepNeverReconnects() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        model.disconnect()
        await drain()
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        let count = await session.discoverCount
        XCTAssertEqual(count, 1)
    }

    func testDisconnectImmediatelyBeforeSleepCannotRestoreStaleReadyStatus() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        model.disconnect()
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        let count = await session.discoverCount
        XCTAssertEqual(count, 1)
    }

    func testOnlyDiscoveryTransportFailuresRetryAndExhaustAtFourAttempts() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        var codes: [DiagnosticCode] = []
        let observation = model.$diagnosticEvent.compactMap { $0?.code }.sink { codes.append($0) }
        defer { observation.cancel() }
        model.connect()
        await drain()
        await session.setFailures([.endpointUnavailable, .requestTimeout, .disconnected, .transportFailed])
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        let count = await session.discoverCount
        XCTAssertEqual(count, 5)
        XCTAssertEqual(codes.filter { $0 == .wakeReconnectAttempt }.count, 4)
        XCTAssertEqual(codes.last, .wakeReconnectExhausted)
        XCTAssertFalse(codes.contains(.wakeReconnectSucceeded))
    }

    func testSafetyAndUnknownDiscoveryFailuresStopWithoutRetry() async {
        for failure in [BoltFailureCode.endpointAmbiguous, .externalStateChanged, .replyMalformed, .controlsUnsupported, .operationCancelled, .eventsOverflowed, .requestIDsExhausted] {
            let session = WakeBindingSession()
            let model = makeModel(session)
            model.connect()
            await drain()
            await session.setFailures([failure])
            model.systemWillSleep()
            model.systemDidWake()
            await drain()
            let count = await session.discoverCount
            XCTAssertEqual(count, 2, failure.rawValue)
            XCTAssertEqual(model.diagnosticEvent?.code, .wakeReconnectCancelled)
        }
    }

    func testCleanupUncertaintyFailsClosed() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        await session.setCleanupResult(false)
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        let count = await session.discoverCount
        XCTAssertEqual(count, 1)
        XCTAssertTrue(model.boltStatus.cleanupUncertain)
        XCTAssertEqual(model.diagnosticEvent?.code, .wakeReconnectCancelled)
    }

    func testExplicitConnectDuringPausedSleepCleanupWaitsAndCancelsAutomaticRecovery() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        await session.pauseCleanup()
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        model.connect()
        await drain()
        let before = await session.discoverCount
        XCTAssertEqual(before, 1)
        await session.completeCleanup()
        await drain()
        let after = await session.discoverCount
        XCTAssertEqual(after, 2)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertNotEqual(model.diagnosticEvent?.code, .wakeReconnectSucceeded)
    }

    func testEveryNewLifecycleIntentCancelsPendingRetry() async {
        for action in ["disconnect", "connect", "sleep", "restart", "quit"] {
            let delay = WakeDelayGate()
            let session = WakeBindingSession()
            let model = makeModel(session, delay: { _ in await delay.wait() })
            model.connect()
            await drain()
            model.systemWillSleep()
            model.systemDidWake()
            await drain()
            switch action {
            case "disconnect": model.disconnect()
            case "connect": model.connect()
            case "sleep": model.systemWillSleep()
            case "restart": model.setRestarting(true)
            default: _ = await model.stopForTermination()
            }
            await drain()
            delay.resume()
            await drain()
            let count = await session.discoverCount
            XCTAssertEqual(count, action == "connect" ? 2 : 1, action)
            XCTAssertNotEqual(model.diagnosticEvent?.code, .wakeReconnectSucceeded, action)
        }
    }

    func testDiscoveryResultPublishedAfterDiscoverReturnsIsAwaited() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        await session.deferDiscoveryStatus()
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        XCTAssertEqual(model.boltStatus.phase, .discovering)
        XCTAssertNotEqual(model.diagnosticEvent?.code, .wakeReconnectSucceeded)
        await session.completeDiscovery()
        await drain()
        XCTAssertEqual(model.diagnosticEvent?.code, .wakeReconnectSucceeded)
    }

    func testMissingTerminalEventTimesOutAndLateReadyCannotActivate() async {
        let timeout = WakeDelayGate()
        let session = WakeBindingSession()
        let model = makeModel(session, timeout: { _ in await timeout.wait() })
        model.connect()
        await drain()
        await session.deferDiscoveryStatus()
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        timeout.resume()
        await drain()
        XCTAssertEqual(model.diagnosticEvent?.code, .wakeReconnectCancelled)
        await session.completeDiscovery()
        await drain()
        XCTAssertFalse(model.isBindingsEnabled)
        let count = await session.discoverCount
        XCTAssertEqual(count, 2)
    }

    private func makeModel(
        _ session: WakeBindingSession,
        permissionAllowed: Bool = false,
        delay: @escaping WakeRecoveryCoordinator.Delay = { _ in },
        timeout: @escaping WakeRecoveryCoordinator.Delay = { try await Task.sleep(for: $0) }
    ) -> AppModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HidhoggWake-\(UUID().uuidString)/config.toml")
        return AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: ShortcutSender(preflight: { permissionAllowed }, request: { permissionAllowed }, postPair: { _ in }),
            loadImmediately: false,
            observeSleep: false,
            wakeDelay: delay,
            wakeStatusTimeout: timeout
        )
    }

    private func drain() async {
        for _ in 0..<250 { await Task.yield() }
    }
}

@MainActor
private final class WakeDelayGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { continuations.append($0) } }
    func resume() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

private actor WakeBindingSession: BindingSession {
    nonisolated let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private var generation: UInt64 = 0
    private(set) var discoverCount = 0
    private(set) var enableCount = 0
    private var failures: [BoltFailureCode] = []
    private var cleanupResult = true
    private var cleanupPaused = false
    private var cleanupWait: CheckedContinuation<Void, Never>?
    private var deferredDiscovery = false

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    func discover() async {
        discoverCount += 1
        generation &+= 1
        publish(.discovering)
        guard !deferredDiscovery else { return }
        if !failures.isEmpty { publish(.failed, failure: failures.removeFirst()) }
        else { publish(.ready) }
    }

    func setFailures(_ failures: [BoltFailureCode]) { self.failures = failures }
    func setCleanupResult(_ result: Bool) { cleanupResult = result }
    func pauseCleanup() { cleanupPaused = true }
    func completeCleanup() { cleanupPaused = false; cleanupWait?.resume(); cleanupWait = nil }
    func deferDiscoveryStatus() { deferredDiscovery = true }
    func completeDiscovery() { deferredDiscovery = false; publish(.ready) }
    func enable() async { enableCount += 1; publish(.enabled) }
    func disable() async { publish(.ready) }
    func stop() async { _ = await stopForRestart() }
    func stopForRestart() async -> Bool {
        publish(.stopping)
        if cleanupPaused { await withCheckedContinuation { cleanupWait = $0 } }
        generation &+= 1
        publish(cleanupResult ? .idle : .failed, uncertain: !cleanupResult)
        return cleanupResult
    }
    nonisolated func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool { false }

    private func publish(_ phase: BoltPhase, uncertain: Bool = false, failure: BoltFailureCode? = nil) {
        continuation.yield(.status(BoltStatus(
            phase: phase,
            message: "Synthetic wake test status",
            availableControls: Set(MouseControl.allCases),
            generation: generation,
            cleanupUncertain: uncertain,
            failure: failure.map { BoltFailureContext(code: $0, sourceFileID: #fileID, sourceLine: #line) }
        )))
    }
}
