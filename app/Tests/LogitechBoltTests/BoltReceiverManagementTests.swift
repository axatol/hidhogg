import Foundation
import Testing
@testable import LogitechBolt

@Test func receiverManagementReadsSixSlotsIncludingOfflineRecordsAndBoundedNames() async throws {
    let fixture = try await managementFixture(records: [1: managementRecord(1), 6: managementRecord(6, offline: true)])
    let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
    #expect(inventory.capacity == 6)
    #expect(inventory.rows.map(\.slot) == [1, 6])
    #expect(inventory.rows.map(\.label) == ["Device 1", "Device 6"])
    #expect(inventory.rows.map(\.isReachable) == [true, false])
    #expect(await fixture.receiver.recordSelectors == Array(UInt8(0x51)...UInt8(0x56)))
    #expect(await fixture.receiver.nameRequests == [[0x61, 1], [0x66, 1]])
    #expect(await fixture.receiver.writeCount == 0)
    await fixture.session.close()
}

@Test func receiverManagementVerifiesOnlySelectedOfflineRecordRemovedAndConsumesTokens() async throws {
    let fixture = try await managementFixture(records: [1: managementRecord(1), 6: managementRecord(6, offline: true)])
    let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
    let target = try #require(inventory.rows.last)
    await fixture.receiver.setRecord(managementRecord(1, offline: true), slot: 1)
    let result = await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id)
    guard case .verifiedRemoved(let after) = result else { Issue.record("Expected verified selected removal"); return }
    #expect(after.rows.map(\.slot) == [1])
    #expect(after.rows.first?.isReachable == false)
    #expect(await fixture.receiver.writes == [[3, 6]])
    #expect(await fixture.receiver.nameRequests.count == 2)
    let duplicate = await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id)
    #expect(isManagementNotRemoved(duplicate))
    #expect(await fixture.receiver.writeCount == 1)
    await fixture.session.close()
}

@Test func receiverManagementErasedStableFieldsNeverAuthorizeUnpair() async throws {
    let invalidRecords: [[UInt8]] = [
        [0, 2, 0, 0, 1, 2, 3, 4],
        [0, 2, 0xFF, 0xFF, 1, 2, 3, 4],
        [0, 2, 0x34, 0xB0, 0, 0, 0, 0],
        [0, 2, 0x34, 0xB0, 0xFF, 0xFF, 0xFF, 0xFF]
    ]
    for invalid in invalidRecords {
        let fixture = try await managementFixture(records: [1: managementRecord(1)])
        let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
        let target = try #require(inventory.rows.first)
        await fixture.receiver.setRecord(invalid, slot: 1)
        #expect(isManagementNotRemoved(await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id)))
        #expect(await fixture.receiver.writeCount == 0)
        await fixture.session.close()
    }
}

@Test func receiverManagementNamesFallBackToKnownModelsAndRemainPresentationOnly() async throws {
    var newer = managementRecord(2)
    newer[2] = 0x42
    var unknown = managementRecord(3)
    unknown[2] = 0x48
    let fixture = try await managementFixture(records: [1: managementRecord(1), 2: newer, 3: unknown])
    await fixture.receiver.setNameFailure(.registerRejected(code: 7))
    let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
    #expect(inventory.rows.map(\.label) == ["MX Master 3S", "MX Master 4", "Unknown device"])
    await fixture.receiver.setNameFailure(.timeout)
    let target = try #require(inventory.rows.first)
    guard case .verifiedRemoved(let after) = await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id) else {
        Issue.record("Authority scans must not depend on name reads"); return
    }
    #expect(after.rows.map(\.label) == ["MX Master 4", "Unknown device"])
    #expect(await fixture.receiver.nameRequests.count == 3)
    await fixture.session.close()
}

@Test func receiverManagementBoundsNameBytesAndRejectsUnreadablePresentation() async throws {
    let cases: [(payload: [UInt8], expected: String)] = [
        ([0x61, 1, 0], "MX Master 3S"),
        ([0x61, 1, 2, 0x41], "MX Master 3S"),
        ([0x61, 1, 2, 0x41, 0], "MX Master 3S"),
        ([0x61, 1, 2, 0x20, 0x20], "MX Master 3S"),
        ([0x61, 1, 99] + Array("ABCDEFGHIJKLMNO".utf8), "ABCDEFGHIJKLMN")
    ]
    for scenario in cases {
        let fixture = try await managementFixture(records: [1: managementRecord(1)])
        await fixture.receiver.setNamePayload(scenario.payload)
        let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
        #expect(inventory.rows.first?.label == scenario.expected)
        await fixture.session.close()
    }
    let fixture = try await managementFixture(records: [1: managementRecord(1)])
    await fixture.receiver.setNameFailure(.timeout)
    await #expect(throws: BoltReceiverTransportFailure.timeout) {
        try await fixture.session.inventory(receiverID: fixture.receiverID)
    }
    let reads = await fixture.receiver.recordSelectors.count
    await #expect(throws: BoltReceiverTransportFailure.timeout) {
        try await fixture.session.inventory(receiverID: fixture.receiverID)
    }
    #expect(await fixture.receiver.recordSelectors.count == reads)
    await fixture.session.close()
}

@Test func receiverManagementStaleTargetOtherChangesAndRefreshPreventDispatch() async throws {
    for changedSlot in [UInt8(1), 2] {
        let fixture = try await managementFixture(records: [1: managementRecord(1), 2: managementRecord(2)])
        let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
        let target = try #require(inventory.rows.first)
        await fixture.receiver.setRecord(managementRecord(9), slot: changedSlot)
        #expect(isManagementNotRemoved(await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id)))
        #expect(await fixture.receiver.writeCount == 0)
        await fixture.session.close()
    }
    let fixture = try await managementFixture(records: [1: managementRecord(1)])
    let old = try await fixture.session.inventory(receiverID: fixture.receiverID)
    _ = try await fixture.session.inventory(receiverID: fixture.receiverID)
    let target = try #require(old.rows.first)
    #expect(isManagementNotRemoved(await fixture.session.unpair(recordID: target.id, inventoryID: old.id)))
    #expect(await fixture.receiver.writeCount == 0)
    await fixture.session.close()
}

@Test func receiverManagementUnknownOccupancyAndMalformedRecordsBlockMutation() async throws {
    for failure in [BoltReceiverTransportFailure.registerRejected(code: 7), .timeout, .malformed] {
        let fixture = try await managementFixture(records: [1: managementRecord(1)])
        let baseline = try await fixture.session.inventory(receiverID: fixture.receiverID)
        let target = try #require(baseline.rows.first)
        await fixture.receiver.setReadFailure(failure, slot: 6)
        #expect(isManagementNotRemoved(await fixture.session.unpair(recordID: target.id, inventoryID: baseline.id)))
        #expect(await fixture.receiver.writeCount == 0)
        await fixture.session.close()
    }
    let fixture = try await managementFixture(records: [1: [0, 2]])
    await #expect(throws: BoltReceiverTransportFailure.malformed) {
        try await fixture.session.inventory(receiverID: fixture.receiverID)
    }
    #expect(await fixture.receiver.writeCount == 0)
    await fixture.session.close()
}

@Test func receiverManagementAckAloneAndUnrelatedPostChangesNeverVerifyRemoval() async throws {
    for behavior in [ManagementReceiver.WriteBehavior.keep, .removeOther, .replaceOther, .insertOther, .readFailure] {
        let fixture = try await managementFixture(records: [1: managementRecord(1), 2: managementRecord(2)])
        let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
        let target = try #require(inventory.rows.first)
        await fixture.receiver.setBehavior(behavior)
        #expect(isManagementUncertain(await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id)))
        #expect(await fixture.receiver.writeCount == 1)
        await fixture.session.close()
    }
}

@Test func receiverManagementRejectionIsDefiniteButTimeoutPoisonsWithoutResend() async throws {
    for failure in [BoltReceiverTransportFailure.registerRejected(code: 7), .timeout, .disconnected] {
        let fixture = try await managementFixture(records: [1: managementRecord(1)])
        let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
        let target = try #require(inventory.rows.first)
        await fixture.receiver.setWriteFailure(failure)
        let result = await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id)
        if case .registerRejected = failure {
            #expect(isManagementNotRemoved(result))
        } else {
            #expect(isManagementUncertain(result))
            let reads = await fixture.receiver.recordSelectors.count
            await #expect(throws: BoltReceiverTransportFailure.timeout) {
                try await fixture.session.inventory(receiverID: fixture.receiverID)
            }
            #expect(await fixture.receiver.recordSelectors.count == reads)
        }
        #expect(isManagementNotRemoved(await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id)))
        #expect(await fixture.receiver.writeCount == 1)
        await fixture.session.close()
    }
}

@Test func receiverManagementCloseRevokesPrewriteAndSerializesReentrantCalls() async throws {
    let fixture = try await managementFixture(records: [1: managementRecord(1)])
    let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
    let target = try #require(inventory.rows.first)
    await fixture.receiver.pauseNextRead()
    let operation = Task { await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id) }
    await fixture.receiver.waitUntilPaused()
    #expect(isManagementNotRemoved(await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id)))
    await #expect(throws: BoltReceiverTransportFailure.busy) {
        try await fixture.session.inventory(receiverID: fixture.receiverID)
    }
    let close = Task { await fixture.session.close() }
    #expect(await managementWaitForRevocation(fixture.session))
    #expect(await fixture.receiver.closeCount == 0)
    await fixture.receiver.resume()
    #expect(isManagementNotRemoved(await operation.value))
    await close.value
    #expect(await fixture.receiver.writeCount == 0)
    #expect(await fixture.receiver.closeCount == 1)
}

@Test func receiverManagementAdmittedWriteDrainsAfterCancellationAndConcurrentClose() async throws {
    let fixture = try await managementFixture(records: [1: managementRecord(1), 2: managementRecord(2)])
    let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
    let target = try #require(inventory.rows.first)
    await fixture.receiver.pauseNextWrite()
    let operation = Task { await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id) }
    await fixture.receiver.waitUntilPaused()
    operation.cancel()
    let close = Task { await fixture.session.close() }
    let secondClose = Task { await fixture.session.close() }
    #expect(await managementWaitForRevocation(fixture.session))
    #expect(await fixture.receiver.closeCount == 0)
    await fixture.receiver.resume()
    guard case .verifiedRemoved(let after) = await operation.value else {
        Issue.record("Admitted command must reconcile despite cancellation"); return
    }
    #expect(after.rows.map(\.slot) == [2])
    await close.value
    await secondClose.value
    #expect(await fixture.receiver.writes == [[3, 1]])
    #expect(await fixture.receiver.closeCount == 1)
    #expect(await fixture.receiver.readAfterCloseCount == 0)
}

@Test func receiverManagementCancellationBeforeDispatchDoesNotWrite() async throws {
    let fixture = try await managementFixture(records: [1: managementRecord(1)])
    let inventory = try await fixture.session.inventory(receiverID: fixture.receiverID)
    let target = try #require(inventory.rows.first)
    await fixture.receiver.pauseNextRead()
    let operation = Task { await fixture.session.unpair(recordID: target.id, inventoryID: inventory.id) }
    await fixture.receiver.waitUntilPaused()
    operation.cancel()
    await fixture.receiver.resume()
    #expect(isManagementNotRemoved(await operation.value))
    #expect(await fixture.receiver.writeCount == 0)
    await fixture.session.close()
}

@Test func receiverManagementSwitchesPinnedReceiversAndRevokesPreviousSnapshot() async throws {
    let first = ManagementReceiver(records: [1: managementRecord(1)])
    let second = ManagementReceiver(records: [2: managementRecord(2)])
    let catalog = ManagementSwitchCatalog(first: first, second: second)
    let session = BoltReceiverManagementSession(catalog: catalog)
    let receivers = try await session.receivers()
    #expect(receivers.count == 2)
    let firstInventory = try await session.inventory(receiverID: receivers[0].id)
    let firstTarget = try #require(firstInventory.rows.first)
    let secondInventory = try await session.inventory(receiverID: receivers[1].id)
    #expect(secondInventory.receiverID == receivers[1].id)
    #expect(secondInventory.rows.map(\.slot) == [2])
    #expect(await first.closeCount == 1)
    #expect(await second.closeCount == 0)
    #expect(isManagementNotRemoved(await session.unpair(recordID: firstTarget.id, inventoryID: firstInventory.id)))
    #expect(await first.writeCount == 0)
    #expect(await second.writeCount == 0)
    let secondTarget = try #require(secondInventory.rows.first)
    guard case .verifiedRemoved = await session.unpair(recordID: secondTarget.id, inventoryID: secondInventory.id) else {
        Issue.record("Newly selected receiver must retain its original session locator"); return
    }
    #expect(await second.writes == [[3, 2]])
    await session.close()
    #expect(await first.closeCount == 1)
    #expect(await second.closeCount == 1)
}

private func managementRecord(_ identity: UInt8, offline: Bool = false) -> [UInt8] {
    [0, offline ? 0x42 : 2, 0x34, 0xB0, identity, 2, 3, 4]
}

private func managementWaitForRevocation(_ session: BoltReceiverManagementSession) async -> Bool {
    for _ in 0..<1_000 {
        do { _ = try await session.receivers() }
        catch let failure as BoltReceiverTransportFailure where failure == .unavailable { return true }
        catch {}
        await Task.yield()
    }
    return false
}

private func isManagementNotRemoved(_ outcome: BoltUnpairOutcome) -> Bool {
    if case .notRemoved = outcome { return true }
    return false
}

private func isManagementUncertain(_ outcome: BoltUnpairOutcome) -> Bool {
    if case .uncertain = outcome { return true }
    return false
}

private func managementFixture(records: [UInt8: [UInt8]]) async throws
    -> (session: BoltReceiverManagementSession, receiver: ManagementReceiver, receiverID: UUID) {
    let receiver = ManagementReceiver(records: records)
    let catalog = ManagementCatalog(receiver: receiver)
    let session = BoltReceiverManagementSession(catalog: catalog)
    let candidates = try await session.receivers()
    return (session, receiver, try #require(candidates.first?.id))
}

private struct ManagementCatalog: LogitechEndpointCatalog {
    let receiver: ManagementReceiver
    let locator = LogitechEndpointLocator(id: UUID(), key: 1, connection: .bolt, productID: 0xC548)
    func enumerate() async throws -> [LogitechEndpointLocator] { [locator] }
    func makeTransport(for locator: LogitechEndpointLocator,
                       onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport { receiver }
    func makeReceiverTransport(for locator: LogitechEndpointLocator,
                               onTerminal: @escaping @Sendable () -> Void) -> (any BoltReceiverTransport)? { receiver }
}

private struct ManagementSwitchCatalog: LogitechEndpointCatalog {
    let first: ManagementReceiver
    let second: ManagementReceiver
    let locators = [
        LogitechEndpointLocator(id: UUID(), key: 1, connection: .bolt, productID: 0xC548),
        LogitechEndpointLocator(id: UUID(), key: 2, connection: .bolt, productID: 0xC548)
    ]
    func enumerate() async throws -> [LogitechEndpointLocator] { locators }
    func makeTransport(for locator: LogitechEndpointLocator,
                       onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport {
        locator.id == locators[0].id ? first : second
    }
    func makeReceiverTransport(for locator: LogitechEndpointLocator,
                               onTerminal: @escaping @Sendable () -> Void) -> (any BoltReceiverTransport)? {
        locator.id == locators[0].id ? first : second
    }
}

private actor ManagementReceiver: BoltReceiverTransport {
    enum WriteBehavior: Sendable { case remove, keep, removeOther, replaceOther, insertOther, readFailure }
    nonisolated let events = AsyncStream<BoltTransportEvent> { $0.finish() }
    nonisolated let receiverEvents = AsyncStream<BoltReceiverEvent> { $0.finish() }
    private var records: [UInt8: [UInt8]]
    private var readFailure: (UInt8, BoltReceiverTransportFailure)?
    private var writeFailure: BoltReceiverTransportFailure?
    private var nameFailure: BoltReceiverTransportFailure?
    private var namePayload: [UInt8]?
    private var behavior = WriteBehavior.remove
    private var pauseRead = false
    private var pauseWrite = false
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var recordSelectors: [UInt8] = []
    private(set) var nameRequests: [[UInt8]] = []
    private(set) var writes: [[UInt8]] = []
    private(set) var closeCount = 0
    private(set) var readAfterCloseCount = 0
    var writeCount: Int { writes.count }

    init(records: [UInt8: [UInt8]]) { self.records = records }
    func open() async throws {}
    nonisolated func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int { 1 }
    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        throw BoltReceiverTransportFailure.unavailable
    }
    func cancelRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverCancellationResult {
        throw BoltReceiverTransportFailure.unavailable
    }
    func close() async { closeCount += 1 }
    func setRecord(_ record: [UInt8], slot: UInt8) { records[slot] = record }
    func setReadFailure(_ failure: BoltReceiverTransportFailure, slot: UInt8) { readFailure = (slot, failure) }
    func setWriteFailure(_ failure: BoltReceiverTransportFailure) { writeFailure = failure }
    func setNameFailure(_ failure: BoltReceiverTransportFailure) { nameFailure = failure }
    func setNamePayload(_ payload: [UInt8]) { namePayload = payload }
    func setBehavior(_ behavior: WriteBehavior) { self.behavior = behavior }
    func pauseNextRead() { pauseRead = true }
    func pauseNextWrite() { pauseWrite = true }

    func waitUntilPaused() async {
        guard paused == nil else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        let continuation = paused
        paused = nil
        continuation?.resume()
    }

    private func pause() async {
        await withCheckedContinuation { continuation in
            paused = continuation
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func registerRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverRegisterReply {
        if closeCount > 0 { readAfterCloseCount += 1; throw BoltReceiverTransportFailure.disconnected }
        if request.operation == .write {
            writes.append(request.payload)
            if pauseWrite { pauseWrite = false; await pause() }
            if let writeFailure { throw writeFailure }
            let slot = request.payload[1]
            switch behavior {
            case .remove: records.removeValue(forKey: slot)
            case .keep: break
            case .removeOther: records.removeValue(forKey: 2)
            case .replaceOther:
                records.removeValue(forKey: slot)
                records[2] = managementRecord(9)
            case .insertOther:
                records.removeValue(forKey: slot)
                records[3] = managementRecord(9)
            case .readFailure:
                records.removeValue(forKey: slot)
                readFailure = (6, .timeout)
            }
            return BoltReceiverRegisterReply(register: request.register, payload: request.payload)
        }
        let selector = try #require(request.payload.first)
        if (0x51...0x56).contains(selector) {
            recordSelectors.append(selector)
            if pauseRead { pauseRead = false; await pause() }
            let slot = selector - 0x50
            if let readFailure, readFailure.0 == slot { throw readFailure.1 }
            guard let record = records[slot] else { throw BoltReceiverTransportFailure.registerRejected(code: 8) }
            return BoltReceiverRegisterReply(register: request.register, payload: [selector] + record.dropFirst())
        }
        nameRequests.append(request.payload)
        if let nameFailure { throw nameFailure }
        if let namePayload { return BoltReceiverRegisterReply(register: request.register, payload: namePayload) }
        let bytes = Array("Device \(selector - 0x60)".utf8)
        return BoltReceiverRegisterReply(register: request.register, payload: [selector, 1, UInt8(bytes.count)] + bytes)
    }
}
