import AppKit
import SwiftUI

struct LowBatteryNotificationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: LowBatteryNotificationController
    @State private var isRequestingAuthorization = false

    var body: some View {
        VStack(alignment: .leading) {
            PermissionSettingsRow(
                title: "Notifications",
                detail: "Optional alerts when the mouse battery is low.",
                systemImage: "bell"
            ) {
                authorizationAction
            }

            if let error = controller.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var authorizationAction: some View {
        switch controller.authorizationState {
        case .authorized, .provisional:
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            Button(isRequestingAuthorization ? "Allowing…" : "Allow", systemImage: "bell.badge") {
                requestAuthorizationAndOpenSettings()
            }
            .disabled(isRequestingAuthorization)
        case .denied, .unknown:
            attentionAction
        }
    }

    private var attentionAction: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                attentionStatus
                openSettingsButton
            }

            VStack(alignment: .leading) {
                attentionStatus
                openSettingsButton
            }
        }
    }

    private var attentionStatus: some View {
        Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
    }

    private var openSettingsButton: some View {
        Button("Open Settings", systemImage: "arrow.up.forward.app") {
            openNotificationSettings()
        }
    }

    private func requestAuthorizationAndOpenSettings() {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true

        Task { @MainActor in
            defer { isRequestingAuthorization = false }
            await controller.requestAuthorization()
            openNotificationSettings()
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
              NSWorkspace.shared.open(url) else {
            model.reportError("Open System Settings → Notifications → Hidhogg.")
            return
        }
    }
}
