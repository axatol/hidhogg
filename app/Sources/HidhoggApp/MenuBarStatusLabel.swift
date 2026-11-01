import AppKit
import HidhoggDomain
import LogitechBolt
import MacOSActions
import SwiftUI

@MainActor
struct MenuBarStatusLabel: View {
    @Environment(\.colorScheme) private var colorScheme

    let phase: BoltPhase
    let cleanupUncertain: Bool
    let permissionChecks: PermissionChecks
    var overrideStatus: MenuBarStatus? = nil
    var summary: MenuBarDeviceSummary? = nil

    private var status: MenuBarStatus {
        summary?.status ?? overrideStatus ?? MenuBarStatus(phase: phase, cleanupUncertain: cleanupUncertain, permissionChecks: permissionChecks)
    }

    private var accessibilityLabel: String {
        guard let summary else { return status.accessibilityLabel }
        let prefix = "Hidhogg, "
        let detail = status.accessibilityLabel.hasPrefix(prefix)
            ? String(status.accessibilityLabel.dropFirst(prefix.count))
            : status.accessibilityLabel
        return "Hidhogg, \(summary.accessibilityDescription). \(detail)"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image(statusColor: status.iconColor, darkAppearance: colorScheme == .dark))
                .renderingMode(.original)
            if let summary {
                Text(summary.countLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

struct MultiDeviceMenuBarStatusLabel: View {
    @ObservedObject var deck: D200XModel
    @ObservedObject var keyboard: FlowLite84Model
    @ObservedObject var bluetooth: GenericBluetoothModel
    let phase: BoltPhase
    let cleanupUncertain: Bool
    let permissionChecks: PermissionChecks
    let registeredDevices: [RegisteredDevice]

    var body: some View {
        let summary = deviceSummary
        MenuBarStatusLabel(phase: phase, cleanupUncertain: cleanupUncertain, permissionChecks: permissionChecks,
                           summary: summary)
    }

    private var deviceSummary: MenuBarDeviceSummary {
        var statuses: [UUID: MenuBarDeviceState] = [:]
        for registration in registeredDevices where registration.isEnabled && statuses[registration.id] == nil {
            statuses[registration.id] = deviceState(for: registration)
        }
        return MenuBarDeviceSummary(registeredDevices: registeredDevices, statuses: statuses)
    }

    private func deviceState(for registration: RegisteredDevice) -> MenuBarDeviceState {
        switch registration.family {
        case .mxMaster3S:
            return MenuBarDeviceState(mousePhase: phase, cleanupUncertain: cleanupUncertain, permissionChecks: permissionChecks)
        case .d200x:
            guard deck.managementEnabled, deck.isConfigured else {
                return MenuBarDeviceState(status: .disconnected, isConnected: false)
            }
            let status = MenuBarStatus(deck: deck.status)
            return MenuBarDeviceState(status: status, isConnected: status == .connected)
        case .flowLite84:
            return MenuBarDeviceState(flowLiteStatus: keyboard.status, isKeyboardOnline: keyboard.isKeyboardOnline)
        case .genericBluetooth:
            return MenuBarDeviceState(genericBluetooth: bluetooth.status(for: registration.id))
        }
    }
}
