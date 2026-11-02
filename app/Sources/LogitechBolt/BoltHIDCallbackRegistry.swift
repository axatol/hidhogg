import Foundation

final class BoltHIDCallbackRegistry: @unchecked Sendable {
    static let shared = BoltHIDCallbackRegistry()

    private final class Entry {
        weak var owner: BoltHIDWorker?
        var active = 0

        init(owner: BoltHIDWorker) { self.owner = owner }
    }

    private let condition = NSCondition()
    private var nextToken: UInt = 1
    private var entries: [UInt: Entry] = [:]

    var registrationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return entries.count
    }

    func register(_ owner: BoltHIDWorker) -> UnsafeMutableRawPointer {
        condition.lock()
        defer { condition.unlock() }
        precondition(nextToken < UInt.max)
        let token = nextToken
        nextToken += 1
        entries[token] = Entry(owner: owner)
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    func withOwner(_ context: UnsafeMutableRawPointer?, _ body: (BoltHIDWorker) -> Void) {
        guard let context else { return }
        condition.lock()
        guard let entry = entries[UInt(bitPattern: context)], let owner = entry.owner else {
            condition.unlock()
            return
        }
        entry.active += 1
        condition.unlock()
        defer {
            condition.lock()
            entry.active -= 1
            condition.broadcast()
            condition.unlock()
        }
        body(owner)
    }

    func retireAndWait(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        condition.lock()
        defer { condition.unlock() }
        guard let entry = entries.removeValue(forKey: UInt(bitPattern: context)) else { return }
        while entry.active > 0 { condition.wait() }
    }
}
