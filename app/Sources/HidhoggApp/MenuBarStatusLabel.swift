import AppKit
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

    private var status: MenuBarStatus {
        overrideStatus ?? MenuBarStatus(phase: phase, cleanupUncertain: cleanupUncertain, permissionChecks: permissionChecks)
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.image(statusColor: status.iconColor, darkAppearance: colorScheme == .dark))
        .renderingMode(.original)
        .accessibilityLabel(status.accessibilityLabel)
        .help(status.accessibilityLabel)
    }
}

struct MultiDeviceMenuBarStatusLabel: View {
    @ObservedObject var deck: D200XModel
    @ObservedObject var keyboard: FlowLite84Model
    let phase: BoltPhase
    let cleanupUncertain: Bool
    let permissionChecks: PermissionChecks

    var body: some View {
        let mouse = MenuBarStatus(phase: phase, cleanupUncertain: cleanupUncertain, permissionChecks: permissionChecks)
        let devices = MenuBarStatus(mouse: mouse, deck: deck.isConfigured ? deck.status : nil)
        let status = MenuBarStatus(base: devices, additional: keyboardStatus)
        MenuBarStatusLabel(phase: phase, cleanupUncertain: cleanupUncertain, permissionChecks: permissionChecks,
                           overrideStatus: status)
    }

    private var keyboardStatus: MenuBarStatus? {
        guard keyboard.connectionRequested else { return nil }
        switch keyboard.status {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        case .connected: return keyboard.isKeyboardOnline ? .connected : .disconnected
        case .failed: return .failed
        }
    }
}
