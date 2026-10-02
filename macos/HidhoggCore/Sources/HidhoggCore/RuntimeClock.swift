import Foundation

public struct RuntimeMonotonicInstant: Sendable, Equatable, Comparable {
    public let durationFromOrigin: Duration

    public init(durationFromOrigin: Duration) {
        self.durationFromOrigin = durationFromOrigin
    }

    public func advanced(by duration: Duration) -> Self {
        Self(durationFromOrigin: durationFromOrigin + duration)
    }

    public func duration(to other: Self) -> Duration {
        other.durationFromOrigin - durationFromOrigin
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.durationFromOrigin < rhs.durationFromOrigin
    }
}

public protocol RuntimeMonotonicClock: Sendable {
    func now() -> RuntimeMonotonicInstant
    func sleep(until deadline: RuntimeMonotonicInstant) async throws
}

public struct SystemRuntimeMonotonicClock: RuntimeMonotonicClock, Sendable {
    private let clock: ContinuousClock
    private let origin: ContinuousClock.Instant

    public init() {
        let clock = ContinuousClock()
        self.clock = clock
        origin = clock.now
    }

    public func now() -> RuntimeMonotonicInstant {
        RuntimeMonotonicInstant(durationFromOrigin: origin.duration(to: clock.now))
    }

    public func sleep(until deadline: RuntimeMonotonicInstant) async throws {
        try await clock.sleep(until: origin.advanced(by: deadline.durationFromOrigin), tolerance: nil)
    }
}
