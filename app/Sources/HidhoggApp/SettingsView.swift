import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Settings") {
                Text("Settings will be available as supported device configuration is added.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
