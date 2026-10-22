import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var loginItemController: LoginItemController

    var body: some View {
        Section("Startup") {
            Toggle("Attempt connection on launch", isOn: Binding(
                get: { model.document.draft.connectOnLaunch },
                set: { model.setConnectOnLaunch($0) }
            ))
            .disabled(model.isLoading || model.isRestarting || !model.canEditConfiguration)

            Text("Attempts one connection each time Hidhogg launches, including after Restart. Changing this setting does not connect immediately.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("Launch at login", isOn: Binding(
                get: { loginItemController.isLaunchAtLoginRequested },
                set: { enabled in
                    Task { @MainActor in
                        guard !model.isRestarting else { return }
                        await loginItemController.setLaunchAtLogin(enabled)
                    }
                }
            ))
            .disabled(!loginItemController.canChangeRegistration || model.isRestarting)

            LabeledContent("macOS status", value: loginItemController.statusTitle)
            if loginItemController.statusRequiresAttention {
                Label(loginItemController.statusDetail, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if loginItemController.status != .enabled {
                Text(loginItemController.statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = loginItemController.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Open Login Items Settings", systemImage: "arrow.up.forward.app") {
                loginItemController.openLoginItemsSettings()
            }
            .disabled(model.isRestarting)
        }
    }
}
