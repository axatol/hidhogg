import HidhoggDomain
import SwiftUI

struct GenericBluetoothDeviceView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: GenericBluetoothModel
    let registrationID: UUID

    var body: some View {
        if let registration = app.registration(id: registrationID) {
            let status = model.status(for: registrationID)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label {
                                Text(registration.displayName)
                            } icon: {
                                BluetoothDeviceIcon(kind: BluetoothDeviceKind.preferred(
                                    iconOverride: registration.bluetoothConfiguration?.iconOverride,
                                    reported: status.reportedKind
                                ))
                                    .frame(width: 24, height: 24)
                            }
                            .font(.title2.bold())
                            DeviceManagementControls(registrationID: registrationID)
                            LabeledContent("Connection", value: status.connection.rawValue)
                            LabeledContent("macOS-reported battery", value: status.batteryText)
                            alertControls(for: registration)
                            iconOverrideControl(for: registration)
                            if let observedAt = status.observedAt {
                                LabeledContent("Last observation") { Text(observedAt, format: .dateTime) }
                            }
                            if status.failure != nil {
                                Text("The latest refresh was unavailable. Any retained reading is from an earlier macOS observation.")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Reported by macOS; values may be cached.")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    refreshButton(for: registration)
                                    bluetoothSettingsButtons
                                    if model.isRefreshing { ProgressView().controlSize(.small) }
                                }
                                .fixedSize(horizontal: true, vertical: false)

                                VStack(alignment: .leading, spacing: 8) {
                                    refreshButton(for: registration)
                                    bluetoothSettingsButtons
                                    if model.isRefreshing { ProgressView().controlSize(.small) }
                                }
                            }
                        }
                        .cardContentPadding()
                    }
                    Text("Monitoring is read-only. Pairing is managed in macOS System Settings.")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func alertControls(for registration: RegisteredDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Low battery alerts", isOn: Binding(
                get: { app.registration(id: registrationID)?.bluetoothConfiguration?.lowBatteryAlertsEnabled ?? false },
                set: { app.setBluetoothBatteryAlerts($0, for: registrationID) }
            ))
            .disabled(!app.canEditConfiguration)

            if registration.bluetoothConfiguration?.lowBatteryAlertsEnabled == true {
                BatteryAlertThresholdControl(threshold: Binding(
                    get: { app.registration(id: registrationID)?.bluetoothConfiguration?.lowBatteryThreshold ?? 10 },
                    set: { app.setBluetoothBatteryThreshold($0, for: registrationID) }
                ))
                .id(registrationID)
                .disabled(!app.canEditConfiguration)
            }
        }
    }

    private func refreshButton(for registration: RegisteredDevice) -> some View {
        Button("Refresh", systemImage: "arrow.clockwise") { model.discover() }
            .disabled(!registration.isEnabled || model.isRefreshing || !app.canEditConfiguration)
    }

    @ViewBuilder
    private var bluetoothSettingsButtons: some View {
        Button("Bluetooth Settings…") { openBluetoothSettings() }
        if model.access == .denied || model.access == .restricted {
            Button("Privacy Settings…") { openBluetoothPrivacySettings() }
        }
    }

    private func iconOverrideControl(for registration: RegisteredDevice) -> some View {
        Picker("Icon", selection: Binding<BluetoothDeviceKind?>(
            get: { app.registration(id: registrationID)?.bluetoothConfiguration?.iconOverride },
            set: { app.setBluetoothIconOverride($0, for: registrationID) }
        )) {
            Text("Automatic").tag(Optional<BluetoothDeviceKind>.none)
            ForEach(BluetoothDeviceKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(Optional(kind))
            }
        }
        .disabled(!app.canEditConfiguration)
        .accessibilityHint("Automatic uses the Bluetooth class reported by macOS when available.")
    }

}

private func bluetoothConnectionPresentation(for status: GenericBluetoothStatus, isEnabled: Bool) -> (title: String, color: Color) {
    guard isEnabled else { return ("Disabled", .secondary) }
    return switch status.connection {
    case .connected: ("Connected", .green)
    case .disconnected: ("Disconnected", .secondary)
    case .notPaired: ("Not listed by macOS", .secondary)
    case .unavailable, .disabled, .suspended: ("Unknown", .secondary)
    }
}

struct GenericBluetoothSidebarLabel: View {
    @ObservedObject var model: GenericBluetoothModel
    let registration: RegisteredDevice

    var body: some View {
        let status = model.status(for: registration.id)
        let presentation = bluetoothConnectionPresentation(for: status, isEnabled: registration.isEnabled)
        let batteryText = registration.isEnabled && status.connection == .connected ? status.batteryText : nil
        let hasEarlierObservation = status.failure != nil && status.observedAt != nil

        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(registration.displayName)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(presentation.color)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(presentation.title)
                    }
                    if let batteryText {
                        Text(batteryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hasEarlierObservation {
                        Text("Earlier observation")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityStatusLabel(
                    connection: presentation.title,
                    battery: batteryText,
                    hasEarlierObservation: hasEarlierObservation
                ))
            }
        } icon: {
            BluetoothDeviceIcon(kind: BluetoothDeviceKind.preferred(
                iconOverride: registration.bluetoothConfiguration?.iconOverride,
                reported: status.reportedKind
            ))
            .font(.system(size: 18))
            .foregroundStyle(.primary)
            .frame(width: 18, height: 18)
        }
        .labelStyle(SidebarLabelStyle())
    }

    private func accessibilityStatusLabel(
        connection: String,
        battery: String?,
        hasEarlierObservation: Bool
    ) -> String {
        var components = ["Connection: \(connection)"]
        if let battery { components.append(battery) }
        if hasEarlierObservation { components.append("Earlier observation") }
        return components.joined(separator: ". ") + "."
    }
}

struct GenericBluetoothMenuSection: View {
    @ObservedObject var model: GenericBluetoothModel
    let registration: RegisteredDevice
    let openDevice: () -> Void

    var body: some View {
        let status = model.status(for: registration.id)
        let summary = registration.isEnabled ? status.summary : "Disabled"
        Button(action: openDevice) {
            Label {
                Text("\(registration.displayName): \(summary)")
            } icon: {
                BluetoothDeviceIcon(kind: BluetoothDeviceKind.preferred(
                    iconOverride: registration.bluetoothConfiguration?.iconOverride,
                    reported: status.reportedKind
                ))
                .frame(width: 16, height: 16)
            }
        }
    }
}
