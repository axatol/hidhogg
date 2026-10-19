import SwiftUI

struct DevicesView: View {
    var body: some View {
        Form {
            Section {
                Label("Logitech integration not yet available", systemImage: "info.circle")
                    .font(.headline)

                Text("Device discovery and configuration are planned. Back and Forward bindings are part of that scope.")
                    .foregroundStyle(.secondary)

                Button("Discover devices", systemImage: "arrow.clockwise") {}
                    .disabled(true)
            } header: {
                Text("Devices")
            } footer: {
                Text("Discovery is unavailable in this foundation build.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
    }
}
