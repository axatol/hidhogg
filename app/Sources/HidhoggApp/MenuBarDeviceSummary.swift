import Foundation
import GenericBluetooth
import HidhoggDomain
import LofreeFlowLite84
import LogitechBolt
import MacOSActions

struct MenuBarDeviceState: Equatable {
    let status: MenuBarStatus
    let isConnected: Bool

    init(status: MenuBarStatus, isConnected: Bool) {
        self.status = status
        self.isConnected = isConnected
    }

    init(mousePhase: BoltPhase, cleanupUncertain: Bool, permissionChecks: PermissionChecks) {
        status = MenuBarStatus(phase: mousePhase, cleanupUncertain: cleanupUncertain, permissionChecks: permissionChecks)
        isConnected = [.ready, .enabling, .enabled].contains(mousePhase)
    }

    init(flowLiteStatus: FlowLite84ConnectionStatus, isKeyboardOnline: Bool) {
        self.isConnected = isKeyboardOnline
        switch flowLiteStatus {
        case .disconnected:
            status = .disconnected
        case .connecting:
            status = .connecting
        case .connected:
            status = isKeyboardOnline ? .connected : .disconnected
        case .disconnecting:
            status = .disconnecting
        case .failed:
            status = .failed
        }
    }

    init(genericBluetooth status: GenericBluetoothStatus) {
        self.status = MenuBarStatus(genericBluetooth: status)
        isConnected = status.connection == .connected
    }
}

struct MenuBarDeviceSummary: Equatable {
    let connectedCount: Int
    let enabledCount: Int
    let status: MenuBarStatus

    var countLabel: String { "\(connectedCount)/\(enabledCount)" }
    var accessibilityDescription: String { "\(connectedCount) of \(enabledCount) enabled devices connected" }

    init(registeredDevices: [RegisteredDevice], statuses: [UUID: MenuBarDeviceState]) {
        var seen = Set<UUID>()
        let enabledDevices = registeredDevices.filter { $0.isEnabled && seen.insert($0.id).inserted }
        let managedStates = enabledDevices.map {
            statuses[$0.id] ?? MenuBarDeviceState(status: .disconnected, isConnected: false)
        }

        connectedCount = managedStates.filter(\.isConnected).count
        enabledCount = enabledDevices.count
        status = MenuBarStatus(managedDeviceStates: managedStates)
    }
}
