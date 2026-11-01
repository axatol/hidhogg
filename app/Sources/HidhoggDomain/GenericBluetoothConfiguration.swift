import Foundation

public struct GenericBluetoothConfiguration: Equatable, Sendable {
    public var endpoint: BluetoothEndpoint
    public var lowBatteryAlertsEnabled: Bool
    public var lowBatteryThreshold: Int
    public var iconOverride: BluetoothDeviceKind?

    public init(endpoint: BluetoothEndpoint, lowBatteryAlertsEnabled: Bool = false,
                lowBatteryThreshold: Int = 10, iconOverride: BluetoothDeviceKind? = nil) {
        self.endpoint = endpoint
        self.lowBatteryAlertsEnabled = lowBatteryAlertsEnabled
        self.lowBatteryThreshold = lowBatteryThreshold
        self.iconOverride = iconOverride
    }
}
