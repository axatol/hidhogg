import GenericBluetooth
import LogitechBolt
import MacOSActions
import UlanziD200X

enum MenuBarStatus: String, Equatable {
    case connected = "Connected"
    case permissionIncomplete = "Connected, permissions incomplete"
    case bluetoothPermissionIncomplete = "Bluetooth permission incomplete"
    case connecting = "Connecting"
    case enablingBindings = "Enabling bindings"
    case disconnecting = "Disconnecting"
    case disconnected = "Disconnected"
    case failed = "Failed"
    case cleanupUncertain = "Cleanup uncertain"
    case partiallyConnected = "Some devices disconnected"

    init(managedDevices: [MenuBarStatus]) {
        self = Self.aggregate(managedDevices, hasHealthyConnection: managedDevices.contains(.connected))
    }

    init(managedDeviceStates: [MenuBarDeviceState]) {
        let statuses = managedDeviceStates.map(\.status)
        let hasHealthyConnection = managedDeviceStates.contains { $0.isConnected && $0.status == .connected }
        self = Self.aggregate(statuses, hasHealthyConnection: hasHealthyConnection)
    }

    private static func aggregate(_ statuses: [MenuBarStatus], hasHealthyConnection: Bool) -> MenuBarStatus {
        guard !statuses.isEmpty else { return .disconnected }
        if statuses.contains(.cleanupUncertain) { return .cleanupUncertain }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.permissionIncomplete) { return .permissionIncomplete }
        if statuses.contains(.bluetoothPermissionIncomplete) { return .bluetoothPermissionIncomplete }
        if hasHealthyConnection { return .connected }
        if statuses.contains(where: { [.connecting, .enablingBindings, .disconnecting].contains($0) }) {
            return .connecting
        }
        if statuses.contains(.partiallyConnected) { return .partiallyConnected }
        return .disconnected
    }

    init(deck: D200XStatus) {
        switch deck {
        case .connected: self = .connected
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .disconnecting: self = .disconnecting
        case .failed: self = .failed
        }
    }

    init(base: MenuBarStatus, additional: MenuBarStatus?) {
        let statuses = [base] + (additional.map { [$0] } ?? [])
        self = Self.aggregate(statuses, hasHealthyConnection: statuses.contains(.connected))
    }

    init(mouse: MenuBarStatus, deck: D200XStatus?) {
        let statuses = [mouse] + (deck.map { [MenuBarStatus(deck: $0)] } ?? [])
        self = Self.aggregate(statuses, hasHealthyConnection: statuses.contains(.connected))
    }

    init(phase: BoltPhase, cleanupUncertain: Bool, permissionChecks: PermissionChecks) {
        guard !cleanupUncertain else {
            self = .cleanupUncertain
            return
        }

        switch phase {
        case .idle:
            self = .disconnected
        case .discovering:
            self = .connecting
        case .ready, .enabled:
            self = permissionChecks.accessibilityTrusted && permissionChecks.eventPostingAllowed
                ? .connected
                : .permissionIncomplete
        case .enabling:
            self = .enablingBindings
        case .stopping:
            self = .disconnecting
        case .failed:
            self = .failed
        }
    }

    init(genericBluetooth status: GenericBluetoothStatus) {
        if let failure = status.failure {
            switch failure {
            case .permissionRequired:
                self = .bluetoothPermissionIncomplete
                return
            case .batteryUnavailable, .cancelled:
                break
            case .inventoryUnavailable, .unsupportedReport, .reportFailed, .timedOut, .outputLimit:
                self = .failed
                return
            @unknown default:
                self = .failed
                return
            }
        }

        self = status.connection == .connected ? .connected : .disconnected
    }

    var accessibilityLabel: String {
        switch self {
        case .permissionIncomplete:
            "Hidhogg, Connected. One or more input permissions are incomplete; check Accessibility trust and event posting access in System Settings."
        case .bluetoothPermissionIncomplete:
            "Hidhogg, One or more Bluetooth devices need Bluetooth access. Check Bluetooth in System Settings."
        default:
            "Hidhogg, \(rawValue)"
        }
    }

    var iconColor: MenuBarIcon.StatusColor {
        switch self {
        case .connected: .connected
        case .permissionIncomplete, .bluetoothPermissionIncomplete, .partiallyConnected: .permissionIncomplete
        case .connecting, .enablingBindings, .disconnecting: .transitioning
        case .disconnected: .disconnected
        case .failed, .cleanupUncertain: .failed
        }
    }
}
