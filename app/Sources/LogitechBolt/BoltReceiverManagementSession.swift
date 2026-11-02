import Foundation

public actor BoltReceiverManagementSession: BoltReceiverManaging {
    private let catalog: any LogitechEndpointCatalog
    private var locators: [UUID: LogitechEndpointLocator] = [:]
    private var transport: (any BoltReceiverTransport)?
    private var receiverID: UUID?
    private var snapshot: Snapshot?
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var poisoned = false

    public init() {
        self.init(catalog: IOKitLogitechEndpointCatalog())
    }

    init(catalog: any LogitechEndpointCatalog) {
        self.catalog = catalog
    }

    public func receivers() async throws -> [BoltReceiverCandidate] {
        try admit()
        defer { finishOperation() }
        guard transport == nil else { throw BoltReceiverTransportFailure.busy }
        snapshot = nil
        locators.removeAll()
        let endpoints = try await catalog.enumerate()
        try checkAdmission()
        guard endpoints.count <= 16 else { throw BoltReceiverTransportFailure.ambiguous }
        let eligible = endpoints.filter {
            $0.connection == .bolt && $0.productID == LogitechEndpointEligibility.boltProductID
        }
        guard Set(eligible.map(\.id)).count == eligible.count else {
            throw BoltReceiverTransportFailure.ambiguous
        }
        locators = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        return eligible.enumerated().map { index, endpoint in
            BoltReceiverCandidate(id: endpoint.id, label: eligible.count == 1
                                  ? "Logi Bolt receiver" : "Logi Bolt receiver \(index + 1)")
        }
    }

    public func inventory(receiverID: UUID) async throws -> BoltReceiverInventory {
        try admit()
        defer { finishOperation() }
        snapshot = nil
        do {
            let receiver = try await open(receiverID: receiverID)
            let records = try await readRecords(on: receiver, revocable: true, readNames: true)
            try checkAdmission()
            return publish(records: records, receiverID: receiverID)
        } catch {
            poisonIfNeeded(error)
            throw error
        }
    }

    public func unpair(recordID: UUID, inventoryID: UUID) async -> BoltUnpairOutcome {
        guard !closing, !closed, !poisoned, !operationActive, !Task.isCancelled,
              let baseline = snapshot, baseline.inventory.id == inventoryID,
              let slot = baseline.tokens[recordID], let receiver = transport else {
            return .notRemoved("The selected receiver record is stale or unavailable. Refresh the inventory.")
        }
        operationActive = true
        snapshot = nil
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            let task = Task {
                let outcome = await performUnpair(slot: slot, baseline: baseline,
                                                 receiver: receiver, cancellation: cancellation)
                finishOperation()
                return outcome
            }
            return await task.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func close() async {
        guard !closed else { return }
        if closing {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        closing = true
        snapshot = nil
        locators.removeAll()
        if operationActive {
            await withCheckedContinuation { operationWaiters.append($0) }
        }
        let receiver = transport
        transport = nil
        receiverID = nil
        await receiver?.close()
        closed = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func performUnpair(slot: UInt8, baseline: Snapshot, receiver: any BoltReceiverTransport,
                              cancellation: CancellationFlag) async -> BoltUnpairOutcome {
        do {
            let fresh = try await readRecords(on: receiver, revocable: true)
            guard !closing, !cancellation.isCancelled else {
                return .notRemoved("Unpairing was cancelled before the command was sent.")
            }
            guard stableRecords(fresh) == stableRecords(baseline.records) else {
                return .notRemoved("Receiver records changed. Refresh the inventory before selecting a record.")
            }
        } catch {
            poisonIfNeeded(error)
            return .notRemoved("Receiver records could not be verified. No unpair command was sent.")
        }

        do {
            let request = try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1, payload: [3, slot])
            let reply = try await receiver.registerRequest(request)
            guard reply.register == request.register else { throw BoltReceiverTransportFailure.malformed }
        } catch let failure as BoltReceiverTransportFailure {
            if case .registerRejected = failure {
                return .notRemoved("The receiver rejected the selected unpair command.")
            }
            poisoned = true
            return .uncertain("The unpair command may have completed. Close this session and refresh using a new session.")
        } catch {
            poisoned = true
            return .uncertain("The unpair command may have completed. Close this session and refresh using a new session.")
        }

        do {
            // Once dispatched, caller cancellation and close must drain verification without another write.
            let after = try await readRecords(on: receiver, revocable: false)
            var expected = stableRecords(baseline.records)
            expected.removeValue(forKey: slot)
            guard stableRecords(after) == expected else {
                return .uncertain("The receiver acknowledged unpairing, but the selected removal could not be verified. Refresh the inventory.")
            }
            let labelled = Dictionary(uniqueKeysWithValues: after.map { slot, record in
                (slot, Record(stable: record.stable, label: baseline.records[slot]?.label,
                              isReachable: record.isReachable))
            })
            let inventory = publish(records: labelled, receiverID: baseline.inventory.receiverID)
            if closing { snapshot = nil }
            return .verifiedRemoved(inventory)
        } catch {
            poisonIfNeeded(error)
            return .uncertain("The receiver acknowledged unpairing, but its final records could not be verified. Refresh using a new session.")
        }
    }

    private func admit() throws {
        try checkAdmission()
        guard !operationActive else { throw BoltReceiverTransportFailure.busy }
        operationActive = true
    }

    private func checkAdmission() throws {
        guard !closing, !closed, !Task.isCancelled else { throw BoltReceiverTransportFailure.unavailable }
        guard !poisoned else { throw BoltReceiverTransportFailure.timeout }
    }

    private func finishOperation() {
        operationActive = false
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func open(receiverID: UUID) async throws -> any BoltReceiverTransport {
        if let transport {
            if self.receiverID == receiverID { return transport }
            guard locators[receiverID] != nil else { throw BoltReceiverTransportFailure.unavailable }
            self.transport = nil
            self.receiverID = nil
            await transport.close()
            try checkAdmission()
        }
        guard let locator = locators[receiverID],
              let receiver = catalog.makeReceiverTransport(for: locator, onTerminal: {}) else {
            throw BoltReceiverTransportFailure.unavailable
        }
        transport = receiver
        self.receiverID = receiverID
        do {
            try await receiver.open()
            try checkAdmission()
            return receiver
        } catch {
            poisoned = true
            throw error
        }
    }

    private func readRecords(on receiver: any BoltReceiverTransport, revocable: Bool,
                             readNames: Bool = false) async throws -> [UInt8: Record] {
        var records: [UInt8: Record] = [:]
        for slot in UInt8(1)...UInt8(6) {
            if revocable { try checkAdmission() }
            let selector = 0x50 + slot
            let request = try BoltReceiverRegisterRequest(operation: .read, register: 0x02B5, payload: [selector])
            let reply: BoltReceiverRegisterReply
            do {
                reply = try await receiver.registerRequest(request)
            } catch let failure as BoltReceiverTransportFailure where failure == .registerRejected(code: 0x08) {
                continue
            }
            guard reply.register == 0x02B5, (8...16).contains(reply.payload.count),
                  reply.payload[0] == selector else { throw BoltReceiverTransportFailure.malformed }
            let payload = reply.payload
            let stable = StableRecord(kind: payload[1] & 0x0F,
                                      productID: UInt16(payload[3]) << 8 | UInt16(payload[2]),
                                      identity: Array(payload[4..<8]))
            guard stable.productID != 0, stable.productID != .max,
                  !stable.identity.allSatisfy({ $0 == 0 }),
                  !stable.identity.allSatisfy({ $0 == 0xFF }) else {
                throw BoltReceiverTransportFailure.malformed
            }
            if revocable { try checkAdmission() }
            let label = readNames ? try await readLabel(on: receiver, slot: slot) : nil
            records[slot] = Record(stable: stable, label: label, isReachable: payload[1] & 0x40 == 0)
        }
        return records
    }

    private func readLabel(on receiver: any BoltReceiverTransport, slot: UInt8) async throws -> String? {
        let selector = 0x60 + slot
        let request = try BoltReceiverRegisterRequest(operation: .read, register: 0x02B5, payload: [selector, 1])
        let reply: BoltReceiverRegisterReply
        do {
            reply = try await receiver.registerRequest(request)
        } catch let failure as BoltReceiverTransportFailure {
            if case .registerRejected = failure { return nil }
            throw failure
        }
        guard reply.register == 0x02B5, reply.payload.count >= 3, reply.payload[0] == selector,
              reply.payload[1] == 1 else { return nil }
        let count = min(Int(reply.payload[2]), 14)
        guard reply.payload.count >= 3 + count else { return nil }
        let bytes = reply.payload[3..<(3 + count)]
        guard !bytes.isEmpty, bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
              let label = String(bytes: bytes, encoding: .ascii),
              !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return label
    }

    private func stableRecords(_ records: [UInt8: Record]) -> [UInt8: StableRecord] {
        records.mapValues(\.stable)
    }

    private func publish(records: [UInt8: Record], receiverID: UUID) -> BoltReceiverInventory {
        var tokens: [UUID: UInt8] = [:]
        let rows = records.keys.sorted().compactMap { slot -> BoltReceiverInventoryRow? in
            guard let record = records[slot] else { return nil }
            let id = UUID()
            tokens[id] = slot
            return BoltReceiverInventoryRow(id: id, slot: slot,
                                            label: record.label ?? fallbackLabel(productID: record.stable.productID),
                                            isReachable: record.isReachable)
        }
        let inventory = BoltReceiverInventory(id: UUID(), receiverID: receiverID, capacity: 6, rows: rows)
        snapshot = Snapshot(inventory: inventory, records: records, tokens: tokens)
        return inventory
    }

    private func fallbackLabel(productID: UInt16) -> String {
        switch productID {
        case 0xB034: "MX Master 3S"
        case 0xB042: "MX Master 4"
        default: "Unknown device"
        }
    }

    private func poisonIfNeeded(_ error: any Error) {
        guard let failure = error as? BoltReceiverTransportFailure else { poisoned = true; return }
        switch failure {
        case .timeout, .transport, .disconnected, .malformed, .eventOverflow: poisoned = true
        default: break
        }
    }

    private struct StableRecord: Equatable, Sendable {
        let kind: UInt8
        let productID: UInt16
        let identity: [UInt8]
    }

    private struct Record: Sendable {
        let stable: StableRecord
        let label: String?
        let isReachable: Bool
    }

    private struct Snapshot: Sendable {
        let inventory: BoltReceiverInventory
        let records: [UInt8: Record]
        let tokens: [UUID: UInt8]
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
