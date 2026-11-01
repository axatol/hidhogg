import SwiftUI

struct BluetoothPermissionSettingsRow: View {
    @ObservedObject var model: GenericBluetoothModel

    var body: some View {
        PermissionSettingsRow(title: "Bluetooth", detail: "Required to discover and monitor paired Bluetooth devices.",
                              systemImage: "antenna.radiowaves.left.and.right") {
            switch model.access {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Button("Allow", systemImage: "hand.raised") { model.requestAuthorization() }
                    .disabled(model.isRequestingAccess)
            case .denied, .restricted:
                Button("Open Settings", systemImage: "arrow.up.forward.app") { openBluetoothPrivacySettings() }
            }
        }
    }
}
