import SwiftUI
import AppKit

struct PermissionsSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Input Permission") {
            LabeledContent("Accessibility trust", value: model.permissionChecks.accessibilityTrusted ? "Granted" : "Not granted")
            LabeledContent("Post input events", value: model.permission == .granted ? "Granted" : "Not granted")

            if model.permissionChecks.accessibilityTrusted && !model.permissionChecks.eventPostingAllowed {
                Text("Accessibility is trusted, but macOS still reports event posting as denied for this process. Refresh or restart Hidhogg. If this persists, remove and re-add this copy in System Settings.")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Text("Hidhogg posts shortcuts and custom wheel or thumb-wheel scroll events only while their connected session and input permission are active.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(model.permission == .granted ? "Refresh Permission" : "Request Permission", systemImage: "hand.raised") {
                if model.permission == .granted {
                    _ = model.refreshPermission(retryScrollCapture: true)
                } else {
                    _ = model.requestPermission()
                    openPermissionSettings()
                }
            }

            Button("Open Accessibility Settings", systemImage: "arrow.up.forward.app") {
                openPermissionSettings()
            }

            HStack(spacing: 8) {
                Image(nsImage: AppAppearance.icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text("Drag Hidhogg into the permission list")
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .onDrag {
                NSItemProvider(object: ApplicationIdentity.current.bundleURL as NSURL)
            } preview: {
                Image(nsImage: AppAppearance.icon).resizable().frame(width: 64, height: 64)
            }
            .help("Adds the running app’s file URL to the drag. Enable its switch in System Settings afterward.")

            RestartSettingsButton()
        }

        if let notifications = model.lowBatteryNotifications {
            Section("Notifications") {
                LowBatteryNotificationSettingsView(controller: notifications)
            }
        }
    }

    private func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else {
            model.reportError("Open System Settings → Privacy & Security → Accessibility, then add Hidhogg and enable it.")
            return
        }
    }
}
