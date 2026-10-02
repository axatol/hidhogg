import Foundation

public struct RuntimeTransitionStamp: Sendable, Equatable {
    public let generation: UInt64
    public let active: Bool

    fileprivate init(generation: UInt64, active: Bool) {
        self.generation = generation
        self.active = active
    }
}

public final class RuntimeTransitionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false

    public init() {}

    public func stampAtReceipt() -> RuntimeTransitionStamp {
        lock.lock()
        defer { lock.unlock() }
        return RuntimeTransitionStamp(generation: generation, active: active)
    }

    @discardableResult
    public func beginTransition() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return false }
        generation += 1
        active = true
        return true
    }

    @discardableResult
    func beginTransition(after stamp: RuntimeTransitionStamp) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !active, !stamp.active, stamp.generation == generation else { return false }
        generation += 1
        active = true
        return true
    }

    @discardableResult
    public func endTransition() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return false }
        generation += 1
        active = false
        return true
    }

    public func accepts(_ stamp: RuntimeTransitionStamp) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !active && !stamp.active && stamp.generation == generation
    }
}
