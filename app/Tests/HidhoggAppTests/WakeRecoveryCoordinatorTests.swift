import Foundation
import XCTest
@testable import HidhoggApp

@MainActor
final class WakeRecoveryCoordinatorTests: XCTestCase {
    func testWakeWaitsForCleanupAndDuplicateNotificationsDoNotOverlapAttempts() async {
        let cleanup = WakeGate<Bool>()
        let delay = WakeGate<Void>()
        var codes: [DiagnosticCode] = []
        var attempts = 0
        var stops = 0
        let coordinator = WakeRecoveryCoordinator(delay: { _ in await delay.wait() }) { code, _ in codes.append(code) }
        coordinator.sleep(reconnect: true) { stops += 1; return await cleanup.wait() }
        coordinator.sleep(reconnect: false) { XCTFail("Duplicate sleep must retain the original cleanup and eligibility"); return false }
        coordinator.wake { attempts += 1; return .connected }
        coordinator.wake { XCTFail("Duplicate wake"); return .stop }
        await drain()
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(attempts, 0)
        cleanup.resume(true)
        await drain()
        XCTAssertEqual(attempts, 0)
        delay.resume(())
        await drain()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(codes, [.systemSleep, .systemWake, .wakeReconnectAttempt, .wakeReconnectSucceeded])
    }

    func testTransportRetriesAreBoundedAndHaveNoIdleWorkAfterExhaustion() async {
        var durations: [Duration] = []
        var attempts = 0
        var codes: [DiagnosticCode] = []
        let coordinator = WakeRecoveryCoordinator(delay: { durations.append($0) }) { code, _ in codes.append(code) }
        coordinator.sleep(reconnect: true) { true }
        coordinator.wake { attempts += 1; return .retry }
        await drain()
        XCTAssertEqual(durations, [.zero, .seconds(1), .seconds(2), .seconds(4)])
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(codes.last, .wakeReconnectExhausted)
        await drain()
        XCTAssertEqual(attempts, 4)
    }

    func testUncertainCleanupAndSafetyFailuresNeverRetry() async {
        for cleaned in [false, true] {
            var attempts = 0
            var codes: [DiagnosticCode] = []
            let coordinator = WakeRecoveryCoordinator(delay: { _ in }) { code, _ in codes.append(code) }
            coordinator.sleep(reconnect: true) { cleaned }
            coordinator.wake { attempts += 1; return .stop }
            await drain()
            XCTAssertEqual(attempts, cleaned ? 1 : 0)
            XCTAssertEqual(codes.last, .wakeReconnectCancelled)
            XCTAssertFalse(codes.contains(.wakeReconnectSucceeded))
        }
    }

    func testCancellationRejectsEvenAnUncooperativeDelay() async {
        let delay = WakeGate<Void>()
        var attempts = 0
        var codes: [DiagnosticCode] = []
        let coordinator = WakeRecoveryCoordinator(delay: { _ in await delay.wait() }) { code, _ in codes.append(code) }
        coordinator.sleep(reconnect: true) { true }
        coordinator.wake { attempts += 1; return .retry }
        await drain()
        coordinator.cancel()
        delay.resume(())
        await drain()
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(codes.last, .wakeReconnectCancelled)
    }

    func testSubsequentSleepCancelsPendingWakeAndSerializesCleanup() async {
        let cleanup = WakeGate<Bool>()
        var stops = 0
        var attempts = 0
        let coordinator = WakeRecoveryCoordinator(delay: { _ in }) { _, _ in }
        coordinator.sleep(reconnect: true) { stops += 1; return await cleanup.wait() }
        coordinator.wake { attempts += 1; return .connected }
        await drain()
        coordinator.sleep(reconnect: false) { stops += 1; return true }
        coordinator.wake { attempts += 1; return .connected }
        await drain()
        XCTAssertEqual(stops, 1)
        cleanup.resume(true)
        await drain()
        XCTAssertEqual(stops, 2)
        XCTAssertEqual(attempts, 0)
    }

    func testDisconnectedSleepNeverStartsRecovery() async {
        var attempts = 0
        let coordinator = WakeRecoveryCoordinator(delay: { _ in XCTFail("No delay while disconnected") }) { _, _ in }
        coordinator.sleep(reconnect: false) { true }
        coordinator.wake { attempts += 1; return .connected }
        await drain()
        XCTAssertEqual(attempts, 0)
    }

    private func drain() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

@MainActor
private final class WakeGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ value: Value) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}
