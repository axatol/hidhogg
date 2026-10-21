import Foundation
import Testing
@testable import LogitechBolt

@Test func requestLedgerReusesCompletedIDsAndRetiresEveryUnresolvedLease() throws {
    let ledger = BoltRequestIDLedger()
    var used: [UInt8] = []
    for _ in 0..<45 {
        let request = try BoltRequestTransaction(ledger: ledger, slot: 2, feature: 15, function: 1, parameters: [])
        used.append(request.lease.softwareID)
        #expect(request.frame.count == 20)
        let report = [UInt8(0x11), 2, 15, request.lease.functionSoftware] + Array(repeating: UInt8(0), count: 16)
        #expect(try request.complete(matchedReply: request.reply(report), sendSucceeded: true).count == 16)
        request.retire()
    }
    #expect(used == Array(repeating: Array(UInt8(1)...15), count: 3).flatMap { $0 })
    #expect(ledger.available(slot: 2, feature: 15, function: 1) == 15)
    for _ in 0..<15 {
        let lease = try ledger.acquire(slot: 2, feature: 15, function: 1)
        #expect(ledger.complete(lease, reusable: false))
    }
    #expect(ledger.available(slot: 2, feature: 15, function: 1) == 0)
    #expect(throws: BoltFailure.tokenExhausted) { try ledger.acquire(slot: 2, feature: 15, function: 1) }
    #expect(ledger.available(slot: 2, feature: 16, function: 1) == 15)
    #expect(ledger.available(slot: 3, feature: 15, function: 1) == 15)
    #expect(ledger.available(slot: 2, feature: 15, function: 2) == 15)
}

@Test func requestLedgerOldOrDoubleCompletionCannotReleaseReissuedLease() throws {
    let ledger = BoltRequestIDLedger()
    let original = try ledger.acquire(slot: 2, feature: 15, function: 1)
    #expect(ledger.complete(original, reusable: true))
    for _ in 0..<14 {
        let lease = try ledger.acquire(slot: 2, feature: 15, function: 1)
        #expect(ledger.complete(lease, reusable: true))
    }
    let replacement = try ledger.acquire(slot: 2, feature: 15, function: 1)
    #expect(replacement.softwareID == original.softwareID)
    #expect(replacement.issuance != original.issuance)
    #expect(!ledger.complete(original, reusable: true))
    #expect(!ledger.complete(original, reusable: false))
    #expect(ledger.available(slot: 2, feature: 15, function: 1) == 14)
    #expect(ledger.complete(replacement, reusable: false))
    #expect(!ledger.complete(replacement, reusable: true))
    #expect(ledger.available(slot: 2, feature: 15, function: 1) == 14)
}

@Test func requestTransactionIgnoresLateRetiredAndWrongTupleReplies() throws {
    let ledger = BoltRequestIDLedger()
    let retired = try BoltRequestTransaction(ledger: ledger, slot: 2, feature: 15, function: 1, parameters: [])
    retired.retire()
    let current = try BoltRequestTransaction(ledger: ledger, slot: 2, feature: 15, function: 1, parameters: [4])
    let tail = Array(repeating: UInt8(0), count: 16)
    #expect(current.reply([0x11, 2, 15, retired.lease.functionSoftware] + tail) == nil)
    #expect(current.reply([0x11, 3, 15, current.lease.functionSoftware] + tail) == nil)
    #expect(current.reply([0x11, 2, 16, current.lease.functionSoftware] + tail) == nil)
    #expect(current.reply([0x11, 2, 15, 0x20 | current.lease.softwareID] + tail) == nil)
    #expect(current.reply([0x11, 2, 15, current.lease.functionSoftware] + Array(tail.prefix(15))) == nil)
    #expect(current.reply([0x11, 2, 15, 0] + tail) == nil)
    #expect(throws: BoltFailure.timeout) { try current.complete(matchedReply: nil, sendSucceeded: true) }
    #expect(ledger.available(slot: 2, feature: 15, function: 1) == 13)
}

@Test func requestTransactionNeedsSuccessfulSendAndReplyBeforeReuse() throws {
    let ledger = BoltRequestIDLedger()
    let request = try BoltRequestTransaction(ledger: ledger, slot: 2, feature: 15, function: 1, parameters: [])
    let report = [UInt8(0x11), 2, 15, request.lease.functionSoftware] + Array(repeating: UInt8(0), count: 16)
    #expect(ledger.available(slot: 2, feature: 15, function: 1) == 14)
    let matched = request.reply(report)
    #expect(ledger.available(slot: 2, feature: 15, function: 1) == 14)
    #expect(throws: BoltFailure.transport) { try request.complete(matchedReply: matched, sendSucceeded: false) }
    #expect(ledger.available(slot: 2, feature: 15, function: 1) == 14)
    let rejected = try BoltRequestTransaction(ledger: ledger, slot: 2, feature: 0, function: 1, parameters: [])
    let error: [UInt8] = [0x10, 2, 0x8F, 0, rejected.lease.functionSoftware, 4, 0]
    #expect(throws: BoltFailure.unavailable) { try rejected.complete(matchedReply: rejected.reply(error), sendSucceeded: true) }
    #expect(ledger.available(slot: 2, feature: 0, function: 1) == 14)
}

extension BoltRequestIDLedger {
    func retireForFixture(feature: UInt8, function: UInt8, count: Int) throws {
        for _ in 0..<count {
            let lease = try acquire(slot: 2, feature: feature, function: function)
            guard complete(lease, reusable: false) else { throw BoltFailure.stale }
        }
    }
}

final class BoltFixtureRequestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var current: BoltRequestIDLedger?

    func makeTransportLedger() -> BoltRequestIDLedger {
        lock.withLock {
            let ledger = BoltRequestIDLedger()
            current = ledger
            return ledger
        }
    }

    func available(slot: UInt8, feature: UInt8, function: UInt8) -> Int {
        lock.withLock { current?.available(slot: slot, feature: feature, function: function) ?? 15 }
    }

    func retireForFixture(feature: UInt8, function: UInt8, count: Int) throws {
        let ledger = try lock.withLock {
            guard let current else { throw BoltFailure.disconnected }
            return current
        }
        try ledger.retireForFixture(feature: feature, function: function, count: count)
    }
}
