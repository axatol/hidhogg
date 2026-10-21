import Foundation
import XCTest
@testable import HidhoggApp
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions

@MainActor
final class WheelAcceptanceTests: XCTestCase {
    func testQueuedApplyIsInvalidatedBySleepWithoutKeyboardPermission() async throws {
        try await assertQueuedApplyInvalidatedByLifecycleStop(sleep: true)
    }

    func testQueuedApplyIsInvalidatedByTerminationWithoutKeyboardPermission() async throws {
        try await assertQueuedApplyInvalidatedByLifecycleStop(sleep: false)
    }

    private func assertQueuedApplyInvalidatedByLifecycleStop(sleep: Bool) async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = WheelLifecycleSession()
        let sender = ShortcutSender(
            preflight: { false },
            request: { false },
            postPair: { _ in }
        )
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        var configuration = AppConfiguration.empty
        configuration.devices[0].wheelInverted = false
        model.updateDraft(configuration)
        await model.save()
        session.emitReady()

        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.refreshPermission(), .denied)
        XCTAssertTrue(model.canApplyWheelPreference)
        XCTAssertEqual(session.stopCount, 0)

        model.applySavedWheelPreference()
        XCTAssertTrue(model.isWheelApplyPending)

        if sleep {
            await model.stopForSleep()
        } else {
            await model.stopForTermination()
        }
        await drainMainActorTasks()

        XCTAssertEqual(session.appliedCount, 0)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertFalse(model.isWheelApplyPending)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func drainMainActorTasks() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WheelAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class WheelLifecycleSession: BindingSession, @unchecked Sendable {
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var applyCalls = 0
    private var stopCalls = 0

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var appliedCount: Int { locked { applyCalls } }
    var stopCount: Int { locked { stopCalls } }

    func discover() async {}
    func enable() async {}
    func disable() async { await stop() }

    func stop() async {
        let status = locked { () -> BoltStatus in
            stopCalls += 1
            return BoltStatus(
                phase: .idle,
                message: "Stopped.",
                availableControls: [],
                generation: 2,
                cleanupUncertain: false,
                wheel: BoltWheelStatus(support: .supported, observedInverted: false)
            )
        }
        continuation.yield(.status(status))
    }

    func stopForRestart() async -> Bool {
        await stop()
        return true
    }

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool { false }

    func applyWheelPreference(_ inverted: Bool?) async {
        locked { applyCalls += 1 }
    }

    func emitReady() {
        continuation.yield(.status(BoltStatus(
            phase: .ready,
            message: "Ready.",
            availableControls: Set(MouseControl.allCases),
            generation: 1,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(support: .supported, observedInverted: true)
        )))
    }

    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
