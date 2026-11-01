import AppKit
import GenericBluetooth
import HidhoggDomain
import SwiftUI

struct BluetoothDevicePicker: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: GenericBluetoothModel
    let add: (PairedBluetoothDevice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Paired Bluetooth Device").font(.title2.bold())
            Text("Hidhogg reads connection and macOS-reported battery information for devices you choose. Pair devices in System Settings first. Bluetooth access is required to discover your paired devices.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.access == .notDetermined ? "Allow Bluetooth and Discover" : "Refresh Paired Devices") { model.discover() }
                    .disabled(model.isRefreshing || model.access == .denied || model.access == .restricted)
                Button("Bluetooth Settings…") { openBluetoothSettings() }
                if model.access == .denied || model.access == .restricted {
                    Button("Privacy Settings…") { openBluetoothPrivacySettings() }
                }
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }
            if let failure = model.discoveryFailure {
                Text(failure == .permissionRequired ? "Bluetooth access is unavailable. Review the app’s permission in System Settings." : "Paired device information could not be refreshed. Try again.")
                    .foregroundStyle(.secondary)
            }
            List(model.devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                        Text(device.endpoint.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(device.isConnected ? "Connected" : "Disconnected").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let registered = app.registeredDevices.contains { $0.configuration == .genericBluetooth(device.endpoint) }
                    Button(registered ? "Added" : "Add") { add(device); dismiss() }
                        .disabled(registered || !model.canRegister(device.endpoint) || !app.canEditConfiguration || app.registeredDevices.count >= 256)
                        .accessibilityLabel("Add \(device.name), \(device.endpoint.address)")
                }
            }
            .overlay {
                if model.devices.isEmpty, !model.isRefreshing {
                    ContentUnavailableView("No Paired Devices Listed", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Use Discover to read the paired devices exposed by macOS. Some Bluetooth devices may not be exposed by this provider."))
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24)
        .frame(width: 560, height: 480)
        .onDisappear { model.endDiscovery() }
    }
}

@MainActor
func openBluetoothSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else { return }
    NSWorkspace.shared.open(url)
}

@MainActor
func openBluetoothPrivacySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else { return }
    NSWorkspace.shared.open(url)
}
