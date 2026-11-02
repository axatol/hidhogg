import Foundation

public struct BoltReceiverInventoryRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let slot: UInt8
    public let label: String
    public let isReachable: Bool

    public init(id: UUID, slot: UInt8, label: String, isReachable: Bool) {
        self.id = id
        self.slot = slot
        self.label = label
        self.isReachable = isReachable
    }
}

public struct BoltReceiverInventory: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let receiverID: UUID
    public let capacity: Int
    public let rows: [BoltReceiverInventoryRow]

    public init(id: UUID, receiverID: UUID, capacity: Int, rows: [BoltReceiverInventoryRow]) {
        self.id = id
        self.receiverID = receiverID
        self.capacity = capacity
        self.rows = rows
    }
}

public enum BoltUnpairOutcome: Equatable, Sendable {
    case verifiedRemoved(BoltReceiverInventory)
    case notRemoved(String)
    case uncertain(String)
}

public protocol BoltReceiverManaging: Sendable {
    func receivers() async throws -> [BoltReceiverCandidate]
    func inventory(receiverID: UUID) async throws -> BoltReceiverInventory
    func unpair(recordID: UUID, inventoryID: UUID) async -> BoltUnpairOutcome
    func close() async
}
