import Foundation

final class BoltPressAdmission: @unchecked Sendable {
    enum Outcome { case accepted, rejected, stale }
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    private var terminal = false

    func prepare(generation: UInt64) {
        lock.withLock {
            enabled = false
            terminal = false
            self.generation = generation
        }
    }

    func enable(generation: UInt64) -> Bool {
        lock.withLock {
            guard !terminal, self.generation == generation else { return false }
            enabled = true
            return true
        }
    }

    func invalidate() {
        lock.withLock {
            enabled = false
            terminal = true
        }
    }

    func perform(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Outcome {
        lock.withLock {
            guard enabled, !terminal, self.generation == generation else { return .rejected }
            let age = observedAt.duration(to: .now)
            guard age >= .zero, age <= .milliseconds(250) else {
                enabled = false
                terminal = true
                return .stale
            }
            operation()
            return .accepted
        }
    }
}
