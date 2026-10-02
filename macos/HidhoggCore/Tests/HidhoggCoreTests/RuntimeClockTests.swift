import Foundation
import XCTest
@testable import HidhoggCore

final class RuntimeClockTests: XCTestCase {
    func testAbsoluteDeadlineUsesTheClockOriginWithoutWaitingForElapsedDuration() async throws {
        let clock = ManualRuntimeMonotonicClock()
        let start = clock.now()
        let deadline = start.advanced(by: .seconds(50))
        let sleep = Task { try await clock.sleep(until: deadline) }

        guard await waitForSleepers(1, on: clock) else {
            sleep.cancel()
            XCTFail("absolute sleep was not registered")
            return
        }

        clock.advance(by: .seconds(49))
        XCTAssertEqual(clock.now(), start.advanced(by: .seconds(49)))
        XCTAssertEqual(clock.waitingDeadlines, [deadline])

        clock.advance(by: .seconds(1))
        try await sleep.value
        XCTAssertEqual(clock.waitingDeadlines, [])
    }

    func testDeadlineAtCurrentInstantCompletesImmediately() async throws {
        let clock = ManualRuntimeMonotonicClock()
        let deadline = clock.now()

        try await clock.sleep(until: deadline)

        XCTAssertEqual(clock.waitingDeadlines, [])
    }

    func testSystemClockIsNondecreasingAndElapsedDeadlineCompletesImmediately() async throws {
        let clock = SystemRuntimeMonotonicClock()
        let first = clock.now()
        let second = clock.now()

        XCTAssertGreaterThanOrEqual(first.durationFromOrigin, .zero)
        XCTAssertGreaterThanOrEqual(second, first)
        try await clock.sleep(until: first)
    }

    func testSystemClockSleepRespondsToCancellation() async throws {
        let clock = SystemRuntimeMonotonicClock()
        let deadline = clock.now().advanced(by: .seconds(60))
        let sleep = Task { try await clock.sleep(until: deadline) }
        sleep.cancel()

        do {
            try await sleep.value
            XCTFail("cancelled monotonic sleep completed successfully")
        } catch is CancellationError {
        }
    }

    func testInFlightAbsoluteSleepRespondsToCancellation() async throws {
        let clock = ManualRuntimeMonotonicClock()
        let sleep = Task { try await clock.sleep(until: clock.now().advanced(by: .seconds(50))) }

        guard await waitForSleepers(1, on: clock) else {
            sleep.cancel()
            XCTFail("absolute sleep was not suspended")
            return
        }

        sleep.cancel()
        do {
            try await sleep.value
            XCTFail("cancelled suspended sleep completed successfully")
        } catch is CancellationError {
        }
        XCTAssertEqual(clock.waitingDeadlines, [])
    }

    private func waitForSleepers(_ count: Int, on clock: ManualRuntimeMonotonicClock) async -> Bool {
        for _ in 0..<1_000 {
            if clock.waitingDeadlines.count == count { return true }
            await Task.yield()
        }
        return clock.waitingDeadlines.count == count
    }
}

private final class ManualRuntimeMonotonicClock: RuntimeMonotonicClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: RuntimeMonotonicInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var instant = RuntimeMonotonicInstant(durationFromOrigin: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    func now() -> RuntimeMonotonicInstant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    var waitingDeadlines: [RuntimeMonotonicInstant] {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.values.map(\.deadline).sorted()
    }

    func sleep(until deadline: RuntimeMonotonicInstant) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard deadline > instant else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[identifier] = Sleeper(deadline: deadline, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            cancel(identifier)
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        let ready = sleepers.filter { $0.value.deadline <= instant }
        for identifier in ready.keys {
            sleepers.removeValue(forKey: identifier)
        }
        lock.unlock()
        for sleeper in ready.values {
            sleeper.continuation.resume()
        }
    }

    private func cancel(_ identifier: UUID) {
        lock.lock()
        let sleeper = sleepers.removeValue(forKey: identifier)
        lock.unlock()
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}
