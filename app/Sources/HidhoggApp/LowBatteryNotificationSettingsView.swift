import AppKit
import SwiftUI

struct LowBatteryNotificationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: LowBatteryNotificationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Notification permission", value: controller.statusTitle)
                .font(.callout)
            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Refresh Permission") {
                    model.refreshLowBatteryNotificationPermission()
                }
                Button("Open Notification Settings", systemImage: "arrow.up.forward.app") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
                          NSWorkspace.shared.open(url) else {
                        model.reportError("Open System Settings → Notifications → Hidhogg.")
                        return
                    }
                }
            }
        }
        .task { model.refreshLowBatteryNotificationPermission() }
    }
}
