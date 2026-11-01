import AppKit
import SwiftUI

struct PermissionsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            accessibilityPermissionRow
            BluetoothPermissionSettingsRow(model: model.bluetooth)

            if let mismatch = accessibilityMismatchMessage {
                Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notifications = model.lowBatteryNotifications {
                LowBatteryNotificationSettingsView(controller: notifications)
            }
        } header: {
            Text("Permissions")
        } footer: {
            permissionFooter
        }
        .task {
            model.refreshLowBatteryNotificationPermission()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshPermissionStatuses()
        }
    }

    private var accessibilityPermissionRow: some View {
        PermissionSettingsRow(
            title: "Accessibility",
            detail: "Required to send shortcuts and custom scroll events.",
            systemImage: "keyboard"
        ) {
            if accessibilityIsAllowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if accessibilityNeedsAttention {
                accessibilityAttentionAction
            } else {
                Button("Allow", systemImage: "hand.raised") {
                    _ = model.requestPermission()
                    openAccessibilitySettings()
                }
            }
        }
    }

    private var permissionFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                draggableAppIdentity
                Spacer()
                HStack {
                    refreshButton
                    RestartSettingsButton()
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading) {
                draggableAppIdentity
                ViewThatFits(in: .horizontal) {
                    HStack {
                        refreshButton
                        RestartSettingsButton()
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    VStack(alignment: .leading) {
                        refreshButton
                        RestartSettingsButton()
                    }
                }
            }
        }
    }

    private var draggableAppIdentity: some View {
        HStack {
            Image(nsImage: AppAppearance.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Drag Hidhogg into the Accessibility list")
        }
        .onDrag {
            NSItemProvider(object: ApplicationIdentity.current.bundleURL as NSURL)
        } preview: {
            Image(nsImage: AppAppearance.icon)
                .resizable()
                .frame(width: 64, height: 64)
        }
        .help("Drag Hidhogg into System Settings → Privacy & Security → Accessibility.")
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            refreshPermissionStatuses(retryingFailedInput: true)
        }
    }

    private var accessibilityIsAllowed: Bool {
        model.permissionChecks.accessibilityTrusted && model.permissionChecks.eventPostingAllowed
    }

    private var accessibilityAttentionAction: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                attentionStatus
                openAccessibilitySettingsButton
            }

            VStack(alignment: .leading) {
                attentionStatus
                openAccessibilitySettingsButton
            }
        }
    }

    private var attentionStatus: some View {
        Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    private var openAccessibilitySettingsButton: some View {
        Button("Open Settings", systemImage: "arrow.up.forward.app") {
            openAccessibilitySettings()
        }
    }

    private var accessibilityNeedsAttention: Bool {
        model.permissionChecks.accessibilityTrusted != model.permissionChecks.eventPostingAllowed
    }

    private var accessibilityMismatchMessage: String? {
        let checks = model.permissionChecks
        guard checks.accessibilityTrusted != checks.eventPostingAllowed else { return nil }

        if checks.accessibilityTrusted {
            return "Accessibility is trusted, but macOS still reports event posting as denied for this process. Refresh or restart Hidhogg. If this persists, remove and re-add this copy in System Settings."
        }

        return "macOS reports event posting as allowed, but Accessibility trust is denied for this process. Refresh or restart Hidhogg. If this persists, remove and re-add this copy in System Settings."
    }

    private func refreshPermissionStatuses(retryingFailedInput: Bool = false) {
        _ = model.refreshPermission(retryScrollCapture: retryingFailedInput)
        model.refreshLowBatteryNotificationPermission()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else {
            model.reportError("Open System Settings → Privacy & Security → Accessibility, then add Hidhogg and enable it.")
            return
        }
    }
}
