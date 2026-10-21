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

    private var status: MenuBarStatus {
        MenuBarStatus(phase: phase, cleanupUncertain: cleanupUncertain, permissionChecks: permissionChecks)
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.image(statusColor: status.iconColor, darkAppearance: colorScheme == .dark))
        .renderingMode(.original)
        .accessibilityLabel(status.accessibilityLabel)
        .help(status.accessibilityLabel)
    }
}
