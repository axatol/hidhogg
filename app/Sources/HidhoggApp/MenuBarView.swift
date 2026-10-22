import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Label("Connection: \(model.connectionTitle)", systemImage: connectionSymbol)

        let information = DeviceInformationPresentation(status: model.boltStatus)
        Label("MX Master 3S battery: \(information.batteryText)", systemImage: information.batterySymbol)

        Divider()

        Button("Open Hidhogg", systemImage: "macwindow") {
            openWorkspace()
        }

        if model.boltStatus.phase == .idle || model.boltStatus.phase == .failed {
            Button("Connect", systemImage: "link") {
                model.connect()
            }
            .disabled(!model.canDiscover)
        } else {
            Button("Disconnect", systemImage: "xmark.circle") {
                model.disconnect()
            }
            .disabled(model.isRestarting || model.boltStatus.phase == .stopping)
        }

        if model.configurationSaveError != nil {
            Label("Configuration save failed", systemImage: "exclamationmark.triangle")
        }

        Divider()

        Button("Quit Hidhogg", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var connectionSymbol: String {
        switch model.boltStatus.phase {
        case .idle: "circle"
        case .discovering, .enabling, .stopping: "arrow.triangle.2.circlepath"
        case .ready, .enabled: "circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private func openWorkspace() {
        ApplicationInstanceBootstrap.shared.requestWorkspace()
    }
}
