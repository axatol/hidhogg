import AppKit
import SwiftUI
import HidhoggDomain

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ForEach(model.registeredDevices) { registration in
            switch registration.family {
            case .mxMaster3S:
                let information = DeviceInformationPresentation(status: model.boltStatus)
                Button(
                    "\(registration.displayName): \(registration.isEnabled ? mouseStatusText(information) : "Disabled")",
                    systemImage: registration.isEnabled && information.isConnected ? information.batterySymbol : "circle"
                ) { openDevice(.devices) }
            case .d200x:
                D200XMenuSection(model: model.d200x, registration: registration) { openDevice(.d200x) }
            case .flowLite84:
                FlowLite84MenuSection(model: model.flowLite, registration: registration) { openDevice(.flowLite) }
            }
        }

        Divider()

        Button("Open Hidhogg", systemImage: "macwindow") {
            openWorkspace()
        }

        Button("Open Settings…", systemImage: "gearshape") {
            model.navigate(to: .settings)
            openWorkspace()
        }

        if model.configurationSaveError != nil {
            Label("Configuration save failed", systemImage: "exclamationmark.triangle")
        }

        Divider()

        Button("Quit Hidhogg", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
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
        openWorkspace()
    }
}

private struct FlowLite84MenuSection: View {
    @ObservedObject var model: FlowLite84Model
    let registration: RegisteredDevice
    let openDevice: () -> Void

    var body: some View {
        Button(
            "\(registration.displayName): \(registration.isEnabled ? statusText : "Disabled")",
            systemImage: "keyboard",
            action: openDevice
        )
    }

    private var statusText: String {
        guard model.isConnected else { return model.connectionTitle }
        guard model.isKeyboardOnline else { return "Keyboard offline" }
        guard let level = model.snapshot?.battery?.reportedLevel else { return "Battery unavailable" }
        return "Battery level \(level)\(model.snapshot?.battery?.charging == true ? " · Charging" : "")"
    }
}

private struct D200XMenuSection: View {
    @ObservedObject var model: D200XModel
    let registration: RegisteredDevice
    let openDevice: () -> Void

    var body: some View {
        Button(
            "\(registration.displayName): \(!registration.isEnabled ? "Disabled" : model.isConnected ? "Connected" : "Disconnected")",
            systemImage: "square.grid.3x3",
            action: openDevice
        )
    }
}
