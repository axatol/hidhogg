import LogitechBolt
import MacOSActions
import UlanziD200X

enum MenuBarStatus: String, Equatable {
    case connected = "Connected"
    case permissionIncomplete = "Connected, permissions incomplete"
    case connecting = "Connecting"
    case enablingBindings = "Enabling bindings"
    case disconnecting = "Disconnecting"
    case disconnected = "Disconnected"
    case failed = "Failed"
    case cleanupUncertain = "Cleanup uncertain"
    case partiallyConnected = "Some devices disconnected"

    init(base: MenuBarStatus, additional: MenuBarStatus?) {
        guard let additional else { self = base; return }
        let states = [base, additional]
        if states.contains(.cleanupUncertain) { self = .cleanupUncertain; return }
        if states.contains(.failed) { self = .failed; return }
        if states.contains(where: { [.connecting, .enablingBindings, .disconnecting].contains($0) }) {
            self = .connecting
            return
        }
        if states.contains(.partiallyConnected) { self = .partiallyConnected; return }
        if states.contains(.disconnected) {
            self = states.allSatisfy { $0 == .disconnected } ? .disconnected : .partiallyConnected
            return
        }
        self = states.contains(.permissionIncomplete) ? .permissionIncomplete : .connected
    }

    init(mouse: MenuBarStatus, deck: D200XStatus?) {
        guard let deck else { self = mouse; return }
        if mouse == .cleanupUncertain || mouse == .failed { self = mouse; return }
        switch deck {
        case .failed: self = .failed
        case .connecting, .disconnecting: self = .connecting
        case .connected:
            switch mouse {
            case .connected, .permissionIncomplete: self = mouse
            case .connecting, .disconnecting, .enablingBindings: self = .connecting
            default: self = .partiallyConnected
            }
        case .disconnected:
            switch mouse {
            case .connected, .permissionIncomplete: self = .partiallyConnected
            default: self = mouse
            }
        }
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
        case .permissionIncomplete, .partiallyConnected: .permissionIncomplete
        case .connecting, .enablingBindings, .disconnecting: .transitioning
        case .disconnected: .disconnected
        case .failed, .cleanupUncertain: .failed
        }
    }
}
