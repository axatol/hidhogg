import Foundation
import HidhoggDomain

public struct PairedBluetoothDevice: Equatable, Identifiable, Sendable {
    public var id: BluetoothEndpoint { endpoint }
    public let endpoint: BluetoothEndpoint
    public let name: String
    public let isConnected: Bool
    public let reportedKind: BluetoothDeviceKind?

    public init(endpoint: BluetoothEndpoint, name: String, isConnected: Bool, reportedKind: BluetoothDeviceKind? = nil) {
        self.endpoint = endpoint
        self.name = name
        self.isConnected = isConnected
        self.reportedKind = reportedKind
    }
}

public struct BluetoothBattery: Equatable, Sendable {
    public let main: Int?
    public let left: Int?
    public let right: Int?
    public let caseLevel: Int?

    public init(main: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.main = main
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
    }

    public var isAvailable: Bool { [main, left, right, caseLevel].contains { $0 != nil } }
}

public enum BluetoothAccess: Equatable, Sendable {
    case notDetermined, allowed, denied, restricted
}

public enum BluetoothObservationFailure: Error, Equatable, Sendable {
    case permissionRequired, inventoryUnavailable, unsupportedReport, reportFailed, timedOut, outputLimit, cancelled
    case batteryUnavailable
}

@MainActor
public protocol PairedBluetoothInventory: AnyObject {
    var access: BluetoothAccess { get }
    func requestAccess() async -> BluetoothAccess
    func pairedDevices() throws -> [PairedBluetoothDevice]
    func observeChanges(for endpoints: Set<BluetoothEndpoint>, _ changed: @escaping @MainActor @Sendable () -> Void)
    func stopObserving()
}

public protocol BluetoothReportReading: Sendable {
    func read() async throws -> Data
}
