import LogitechBolt
import MacOSActions

enum MenuBarStatus: String, Equatable {
    case connected = "Connected"
    case permissionIncomplete = "Connected, permissions incomplete"
    case connecting = "Connecting"
    case enablingBindings = "Enabling bindings"
    case disconnecting = "Disconnecting"
    case disconnected = "Disconnected"
    case failed = "Failed"
    case cleanupUncertain = "Cleanup uncertain"

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

    var accessibilityLabel: String {
        switch self {
        case .permissionIncomplete:
            "Hidhogg, Connected. One or more input permissions are incomplete; check Accessibility trust and event posting access in System Settings."
        default:
            "Hidhogg, \(rawValue)"
        }
    }

    var iconColor: MenuBarIcon.StatusColor {
        switch self {
        case .connected: .connected
        case .permissionIncomplete: .permissionIncomplete
        case .connecting, .enablingBindings, .disconnecting: .transitioning
        case .disconnected: .disconnected
        case .failed, .cleanupUncertain: .failed
        }
    }
}
