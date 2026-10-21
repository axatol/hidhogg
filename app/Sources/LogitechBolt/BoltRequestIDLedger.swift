import Foundation

final class BoltRequestIDLedger: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let slot: UInt8
        let feature: UInt8
        let function: UInt8
    }

    struct Lease: Equatable, Sendable {
        let key: Key
        let softwareID: UInt8
        let issuance: UInt64
        var functionSoftware: UInt8 { key.function << 4 | softwareID }
    }

    private struct Pool {
        var next: UInt8 = 1
        var active: [UInt8: UInt64] = [:]
        var retired: Set<UInt8> = []
    }

    private let lock = NSLock()
    private var pools: [Key: Pool] = [:]
    private var issuance: UInt64 = 0

    func available(slot: UInt8, feature: UInt8, function: UInt8) -> Int {
        lock.withLock {
            let pool = pools[Key(slot: slot, feature: feature, function: function), default: Pool()]
            return 15 - pool.active.count - pool.retired.count
        }
    }

    func acquire(slot: UInt8, feature: UInt8, function: UInt8) throws -> Lease {
        try lock.withLock {
            guard function <= 15, issuance < UInt64.max else { throw BoltFailure.tokenExhausted }
            let key = Key(slot: slot, feature: feature, function: function)
            var pool = pools[key, default: Pool()]
            for _ in 0..<15 {
                let candidate = pool.next
                pool.next = candidate == 15 ? 1 : candidate + 1
                guard pool.active[candidate] == nil, !pool.retired.contains(candidate) else { continue }
                issuance += 1
                pool.active[candidate] = issuance
                pools[key] = pool
                return Lease(key: key, softwareID: candidate, issuance: issuance)
            }
            throw BoltFailure.tokenExhausted
        }
    }

    @discardableResult
    func complete(_ lease: Lease, reusable: Bool) -> Bool {
        lock.withLock {
            guard var pool = pools[lease.key], pool.active[lease.softwareID] == lease.issuance else { return false }
            pool.active.removeValue(forKey: lease.softwareID)
            if !reusable { pool.retired.insert(lease.softwareID) }
            pools[lease.key] = pool
            return true
        }
    }
}

struct BoltRequestTransaction: Sendable {
    let lease: BoltRequestIDLedger.Lease
    let frame: [UInt8]
    private let ledger: BoltRequestIDLedger

    init(ledger: BoltRequestIDLedger, slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) throws {
        guard parameters.count <= 16, function <= 15 else { throw BoltFailure.malformed }
        self.ledger = ledger
        lease = try ledger.acquire(slot: slot, feature: feature, function: function)
        frame = [0x11, slot, feature, lease.functionSoftware] + parameters + Array(repeating: 0, count: 16 - parameters.count)
    }

    func reply(_ report: [UInt8]) -> Result<[UInt8], BoltFailure>? {
        BoltWire.reply(report, slot: lease.key.slot, feature: lease.key.feature, functionSoftware: lease.functionSoftware)
    }

    func complete(matchedReply: Result<[UInt8], BoltFailure>?, sendSucceeded: Bool) throws -> [UInt8] {
        guard sendSucceeded else { retire(); throw BoltFailure.transport }
        guard let matchedReply else { retire(); throw BoltFailure.timeout }
        do {
            let payload = try matchedReply.get()
            guard ledger.complete(lease, reusable: true) else { throw BoltFailure.stale }
            return payload
        } catch {
            retire()
            throw error
        }
    }

    func retire() { ledger.complete(lease, reusable: false) }
}
