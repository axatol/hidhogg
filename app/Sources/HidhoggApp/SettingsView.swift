import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Keyboard Permission") {
                LabeledContent("Post keyboard events", value: model.permission == .granted ? "Granted" : "Not granted")
                Text("Hidhogg posts a shortcut only after a physical button press, while bindings are enabled and permission is granted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(model.permission == .granted ? "Refresh Permission" : "Request Permission", systemImage: "hand.raised") {
                    if model.permission == .granted {
                        _ = model.refreshPermission()
                    } else {
                        _ = model.requestPermission()
                    }
                }
            }

            Section("Configuration File") {
                Text(model.configurationURL.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                LabeledContent("Document", value: model.configurationStatus)
                Button("Reload from File…", systemImage: "arrow.clockwise") { model.requestReload() }
                    .disabled(model.isLoading || model.isSaving)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { _ = model.refreshPermission() }
    }
}
