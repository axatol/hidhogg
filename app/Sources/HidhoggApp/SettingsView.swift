import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var loginItemController: LoginItemController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                GeneralSettingsView()
                    .id(SettingsCategory.general)

                PermissionsSettingsView()
                    .id(SettingsCategory.permissions)

                ConfigurationSettingsView()
                    .id(SettingsCategory.configuration)

                DiagnosticsSettingsView()
                    .id(SettingsCategory.diagnostics)
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .task {
                loginItemController.refreshStatus()
                _ = model.refreshPermission()
            }
            .task(id: model.settingsScrollRequestID) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(model.selectedSettingsCategory, anchor: .top)
            }
            .onChange(of: model.selectedSettingsCategory) { _, category in
                proxy.scrollTo(category, anchor: .top)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loginItemController.refreshStatus() }
        }
    }
}
