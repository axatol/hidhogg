import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let information = DeviceInformationPresentation(status: model.boltStatus)
        Label(
            "MX Master 3S: \(mouseStatusText(information))",
            systemImage: information.isConnected ? information.batterySymbol : "circle"
        )
        D200XMenuSection(model: model.d200x)

        Divider()

        Button("Open Hidhogg", systemImage: "macwindow") {
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
}

private struct D200XMenuSection: View {
    @ObservedObject var model: D200XModel

    var body: some View {
        Label(
            "D200X: \(model.isConnected ? "Connected" : "Disconnected")",
            systemImage: "square.grid.3x3"
        )
    }
}
