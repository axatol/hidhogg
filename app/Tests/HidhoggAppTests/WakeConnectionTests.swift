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

    func testSecondSleepDuringWakeBackoffRetainsReconnectOwnership() async {
        let delay = WakeDelayGate()
        let session = WakeBindingSession()
        let model = makeModel(session, delay: { duration in await delay.wait(duration) })
        model.connect()
        await drain()
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        XCTAssertTrue(model.connectionRequested)

        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        delay.resume()
        await drain()

        let discoveries = await session.discoverCount
        XCTAssertEqual(discoveries, 2)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertTrue(model.connectionRequested)
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

    func testWakeRetriesTransportFailuresUntilConnectionReturns() async {
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
        XCTAssertEqual(count, 6)
        XCTAssertEqual(codes.filter { $0 == .wakeReconnectAttempt }.count, 5)
        XCTAssertEqual(codes.last, .wakeReconnectSucceeded)
    }

    func testDiscoveryFailuresRetryUntilTheControllerReturnsReady() async {
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
            XCTAssertEqual(count, 3, failure.rawValue)
            XCTAssertEqual(model.boltStatus.phase, .ready, failure.rawValue)
            XCTAssertEqual(model.diagnosticEvent?.code, .wakeReconnectSucceeded, failure.rawValue)
        }
    }

    func testWakeRecoversAfterUncertainCleanup() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        await session.setCleanupResult(false)
        model.systemWillSleep()
        model.systemDidWake()
        await drain()
        let count = await session.discoverCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertFalse(model.boltStatus.cleanupUncertain)
        XCTAssertEqual(model.diagnosticEvent?.code, .wakeReconnectSucceeded)
    }

    func testExplicitConnectRetriesAfterUncertainSleepCleanup() async {
        let session = WakeBindingSession()
        let model = makeModel(session)
        model.connect()
        await drain()
        await session.setCleanupResult(false)
        model.systemWillSleep()
        await drain()
        model.connect()
        await drain()

        let count = await session.discoverCount
        XCTAssertEqual(count, 2)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertFalse(model.boltStatus.cleanupUncertain)
    }

    func testUnexpectedDisconnectRetainsConnectionIntentAndReappliesBindings() async {
        let delay = WakeDelayGate()
        let session = WakeBindingSession()
        let model = makeModel(session, permissionAllowed: true, delay: { duration in await delay.wait(duration) })
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 33))
        model.updateDraft(configuration)
        model.connect()
        await drain()
        XCTAssertTrue(model.isBindingsEnabled)

        await session.disconnectUnexpectedly(cleanupUncertain: true)
        await drain()
        XCTAssertEqual(model.boltStatus.phase, .failed)
        XCTAssertEqual(model.boltStatus.failure?.code, .disconnected)
        let attemptsBeforeRetry = await session.discoverCount
        XCTAssertEqual(attemptsBeforeRetry, 1)
        XCTAssertEqual(delay.waitedDurations, [.seconds(1)])

        delay.resumeNext()
        await drain()

        let attemptsAfterRetry = await session.discoverCount
        XCTAssertEqual(attemptsAfterRetry, 2)
        XCTAssertEqual(model.boltStatus.phase, .enabled)
        XCTAssertFalse(model.boltStatus.cleanupUncertain)
        XCTAssertTrue(model.isBindingsEnabled)
        let enablesAfterRetry = await session.enableCount
        XCTAssertEqual(enablesAfterRetry, 2)
    }

    func testRepeatedDiscoveryFailuresUseIncreasingCappedBackoffAndDisconnectCancelsLoop() async {
        let delay = WakeDelayGate()
        let session = WakeBindingSession()
        let model = makeModel(session, delay: { duration in await delay.wait(duration) })
        model.connect()
        await drain()
        await session.setFailures(Array(repeating: .transportFailed, count: 8))
        await session.disconnectUnexpectedly(cleanupUncertain: true)

        for expected in [Duration.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)] {
            await drain()
            XCTAssertEqual(delay.waitedDurations.last, expected)
            delay.resumeNext()
            await drain()
        }

        let attemptsBeforeDisconnect = await session.discoverCount
        XCTAssertEqual(attemptsBeforeDisconnect, 8)
        XCTAssertEqual(delay.waitedDurations, [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30), .seconds(30)])
        model.disconnect()
        await drain()
        delay.resume()
        await drain()
        let attemptsAfterDisconnect = await session.discoverCount
        XCTAssertEqual(attemptsAfterDisconnect, 8)
        XCTAssertEqual(model.boltStatus.phase, .idle)
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
        let firstGeneration = await session.deferredGeneration(at: 0)
        timeout.resume()
        await drain()
        XCTAssertEqual(model.boltStatus.phase, .discovering)
        XCTAssertTrue(model.connectionRequested)
        let attemptsAfterTimeout = await session.discoverCount
        XCTAssertEqual(attemptsAfterTimeout, 3)
        if let firstGeneration { await session.publishReady(generation: firstGeneration) }
        await drain()
        XCTAssertEqual(model.boltStatus.phase, .discovering)
        await session.completeDiscovery()
        await drain()
        XCTAssertFalse(model.isBindingsEnabled)
        let count = await session.discoverCount
        XCTAssertEqual(count, 3)
        XCTAssertEqual(model.boltStatus.phase, .ready)
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
    private var continuations: [(Duration?, CheckedContinuation<Void, Never>)] = []
    private(set) var waitedDurations: [Duration] = []

    func wait(_ duration: Duration? = nil) async {
        await withCheckedContinuation { continuation in
            if let duration { waitedDurations.append(duration) }
            continuations.append((duration, continuation))
        }
    }

    func resume() {
        let pending = continuations
        continuations = []
        for (_, continuation) in pending { continuation.resume() }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        let (_, continuation) = continuations.removeFirst()
        continuation.resume()
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
    private var deferredGenerations: [UInt64] = []

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    func discover() async {
        discoverCount += 1
        generation &+= 1
        publish(.discovering)
        guard !deferredDiscovery else { deferredGenerations.append(generation); return }
        if !failures.isEmpty { publish(.failed, failure: failures.removeFirst()) }
        else { publish(.ready) }
    }

    func setFailures(_ failures: [BoltFailureCode]) { self.failures = failures }
    func disconnectUnexpectedly(cleanupUncertain: Bool) {
        generation &+= 1
        publish(.failed, uncertain: cleanupUncertain, failure: .disconnected)
    }
    func setCleanupResult(_ result: Bool) { cleanupResult = result }
    func pauseCleanup() { cleanupPaused = true }
    func completeCleanup() { cleanupPaused = false; cleanupWait?.resume(); cleanupWait = nil }
    func deferDiscoveryStatus() { deferredDiscovery = true }
    func completeDiscovery() { deferredDiscovery = false; publish(.ready) }
    func deferredGeneration(at index: Int) -> UInt64? {
        guard deferredGenerations.indices.contains(index) else { return nil }
        return deferredGenerations[index]
    }
    func publishReady(generation: UInt64) { publish(.ready, generation: generation) }
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

    private func publish(
        _ phase: BoltPhase,
        uncertain: Bool = false,
        failure: BoltFailureCode? = nil,
        generation: UInt64? = nil
    ) {
        continuation.yield(.status(BoltStatus(
            phase: phase,
            message: "Synthetic wake test status",
            availableControls: Set(MouseControl.allCases),
            generation: generation ?? self.generation,
            cleanupUncertain: uncertain,
            failure: failure.map { BoltFailureContext(code: $0, sourceFileID: #fileID, sourceLine: #line) }
        )))
    }
}
