import AppKit
import HidhoggDomain
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MenuBarContentView(model: model, deck: model.d200x, keyboard: model.flowLite, bluetooth: model.bluetooth)
    }
}

private struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var deck: D200XModel
    @ObservedObject var keyboard: FlowLite84Model
    @ObservedObject var bluetooth: GenericBluetoothModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MenuBarDeviceList(rowCount: model.registeredDevices.count) {
                if model.registeredDevices.isEmpty {
                    Text("No registered devices")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    ForEach(model.registeredDevices) { registration in
                        deviceRow(registration)
                    }
                }
            }

            Divider()

            VStack(spacing: 2) {
                MenuBarCommandButton(
                    title: "Open Hidhogg",
                    symbol: "macwindow",
                    hint: "Opens the Hidhogg workspace."
                ) {
                    dismiss()
                    openWorkspace()
                }

                MenuBarCommandButton(
                    title: "Open Settings…",
                    symbol: "gearshape",
                    hint: "Opens Hidhogg settings."
                ) {
                    model.navigate(to: .settings)
                    dismiss()
                    openWorkspace()
                }

                if model.configurationSaveError != nil {
                    Label("Configuration save failed", systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }

            Divider()

            MenuBarCommandButton(
                title: "Quit Hidhogg",
                symbol: "power",
                hint: "Quits Hidhogg."
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 356, alignment: .leading)
        .padding(12)
        .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private func deviceRow(_ registration: RegisteredDevice) -> some View {
        switch registration.family {
        case .mxMaster3S:
            mouseRow(registration)
        case .d200x:
            d200xRow(registration)
        case .flowLite84:
            flowLiteRow(registration)
        case .genericBluetooth:
            bluetoothRow(registration)
        }
    }

    private func mouseRow(_ registration: RegisteredDevice) -> some View {
        let information = DeviceInformationPresentation(status: model.boltStatus)
        let connection = registration.isEnabled
            ? information.isConnected ? "Connected" : "Disconnected"
            : "Disabled"
        let value = registration.isEnabled ? mouseStatusText(information) : "Disabled"
        let indicator: MenuBarDeviceRow.Status = if !registration.isEnabled {
            .disabled
        } else if information.isConnected {
            .connected
        } else {
            .disconnected
        }

        return MenuBarDeviceRow(
            title: registration.displayName,
            symbol: .system("computermouse"),
            status: indicator,
            primaryValue: value,
            accessibilityLabel: "\(registration.displayName), \(connection), \(value)",
            accessibilityHint: "Opens \(registration.displayName) in Hidhogg.",
            action: { openDevice(AppModel.route(for: registration)) }
        )
    }

    private func d200xRow(_ registration: RegisteredDevice) -> some View {
        let connection = registration.isEnabled ? deck.connectionTitle : "Disabled"
        let indicator: MenuBarDeviceRow.Status = if !registration.isEnabled {
            .disabled
        } else if deck.isConnected {
            .connected
        } else if deck.isBusy {
            .transitioning
        } else {
            .disconnected
        }

        return MenuBarDeviceRow(
            title: registration.displayName,
            symbol: .system("square.grid.3x3"),
            status: indicator,
            primaryValue: connection,
            accessibilityLabel: "\(registration.displayName), \(connection)",
            accessibilityHint: "Opens \(registration.displayName) in Hidhogg.",
            action: { openDevice(AppModel.route(for: registration)) }
        )
    }

    private func flowLiteRow(_ registration: RegisteredDevice) -> some View {
        let connection: String
        let value: String
        let indicator: MenuBarDeviceRow.Status

        if !registration.isEnabled {
            connection = "Disabled"
            value = "Disabled"
            indicator = .disabled
        } else if keyboard.isConnected && !keyboard.isKeyboardOnline {
            connection = "Keyboard offline"
            value = "Keyboard offline"
            indicator = .disconnected
        } else if keyboard.isConnected {
            connection = "Connected"
            value = keyboard.snapshot?.battery?.reportedLevel.map { "Reported level \($0)" }
                ?? "Battery unavailable"
            indicator = .connected
        } else {
            connection = keyboard.connectionTitle
            value = connection
            indicator = keyboard.isBusy ? .transitioning : .disconnected
        }

        return MenuBarDeviceRow(
            title: registration.displayName,
            symbol: .system("keyboard"),
            status: indicator,
            primaryValue: value,
            accessibilityLabel: "\(registration.displayName), \(connection), \(value)",
            accessibilityHint: "Opens \(registration.displayName) in Hidhogg.",
            action: { openDevice(AppModel.route(for: registration)) }
        )
    }

    private func bluetoothRow(_ registration: RegisteredDevice) -> some View {
        let status = bluetooth.status(for: registration.id)
        let battery = registration.isEnabled ? status.battery : nil
        let hasComponents = battery.map { $0.left != nil || $0.right != nil || $0.caseLevel != nil } == true
        let isConnected = registration.isEnabled && status.connection == .connected
        let isEarlierObservation = status.failure != nil && status.observedAt != nil
        let components = hasComponents && isConnected
            ? [
                MenuBarDeviceRow.BatteryComponent(label: "Left", value: battery?.left.map { "\($0)%" } ?? "Unavailable"),
                MenuBarDeviceRow.BatteryComponent(label: "Right", value: battery?.right.map { "\($0)%" } ?? "Unavailable"),
                MenuBarDeviceRow.BatteryComponent(label: "Case", value: battery?.caseLevel.map { "\($0)%" } ?? "Unavailable")
            ]
            : []
        let connection = registration.isEnabled ? status.connection.rawValue : "Disabled"
        let value: String

        if !registration.isEnabled {
            value = "Disabled"
        } else if status.connection != .connected {
            value = status.connection.rawValue
        } else if let level = battery?.main {
            value = isEarlierObservation ? "Last reported \(level)%" : "\(level)%"
        } else if hasComponents {
            value = isEarlierObservation ? "Last reported" : "Connected"
        } else {
            value = "Battery unavailable"
        }

        let indicator: MenuBarDeviceRow.Status = if !registration.isEnabled || status.connection == .disabled {
            .disabled
        } else if status.connection == .connected {
            .connected
        } else {
            .disconnected
        }
        let componentSummary = components.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
        let accessibleValue = componentSummary.isEmpty ? value : "\(value), \(componentSummary)"
        let kind = BluetoothDeviceKind.preferred(
            iconOverride: registration.bluetoothConfiguration?.iconOverride,
            reported: status.reportedKind
        )

        return MenuBarDeviceRow(
            title: registration.displayName,
            symbol: .bluetooth(kind),
            status: indicator,
            primaryValue: value,
            components: components,
            accessibilityLabel: "\(registration.displayName), \(connection), \(accessibleValue)",
            accessibilityHint: "Opens \(registration.displayName) in Hidhogg.",
            action: { openDevice(AppModel.route(for: registration)) }
        )
    }

    private func mouseStatusText(_ information: DeviceInformationPresentation) -> String {
        guard information.isConnected else { return "Disconnected" }

        let battery = information.status.deviceInformation
        switch battery.batteryState {
        case .unknown, .loading:
            return "Checking battery…"
        case .available:
            guard battery.battery?.percentage != nil else { return "Battery unavailable" }
            return information.batteryText
        case .unsupported:
            return "Battery unsupported"
        case .unavailable:
            return "Battery unavailable"
        }
    }

    private func openWorkspace() {
        ApplicationInstanceBootstrap.shared.requestWorkspace()
    }

    private func openDevice(_ route: WorkspaceRoute) {
        model.navigate(to: route)
        dismiss()
        openWorkspace()
    }
}
