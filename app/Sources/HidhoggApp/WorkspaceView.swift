import SwiftUI
import AppKit

struct WorkspaceView: View {
    let presentationCoordinator: WorkspacePresentationCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var restartCoordinator: RestartCoordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { Optional(model.navigation.current.route) },
                set: { if let route = $0 { model.navigate(to: route) } }
            )) {
                Section("Devices") {
                    NavigationLink(value: WorkspaceRoute.devices) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MX Master 3S")

                                HStack(spacing: 9) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color(nsColor: model.connectionColor))
                                            .frame(width: 7, height: 7)
                                            .accessibilityHidden(true)
                                        Text(model.connectionTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    sidebarBatteryLabel
                                }
                            }
                        } icon: {
                            Image(systemName: "computermouse")
                                .font(.system(size: 18))
                                .accessibilityHidden(true)
                        }
                        .labelStyle(SidebarLabelStyle())
                    }
                }
                NavigationLink(value: WorkspaceRoute.settings) {
                    Label {
                        Text("Settings")
                    } icon: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18))
                    }
                    .labelStyle(SidebarLabelStyle())
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .tint(AppAppearance.sidebarSelection)
            .navigationTitle("Hidhogg")
        } detail: {
            Group {
                switch model.navigation.current.route {
                case .devices:
                    DevicesView()
                case .settings:
                    SettingsView()
                }
            }
        }
        .tint(AppAppearance.accent)
        .disabled(restartCoordinator.inProgress)
        .background {
            WorkspaceWindowLifecycleAdapter(
                presentationCoordinator: presentationCoordinator,
                onClose: { model.cancelRecording() }
            )
                .frame(width: 0, height: 0)
        }
        .task { _ = model.refreshPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { _ = model.refreshPermission() }
            else { model.cancelRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.cancelRecording()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.backward") { model.goBack() }
                    .disabled(!model.navigation.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { model.goForward() }
                    .disabled(!model.navigation.canGoForward)
            }
        }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { model.isReloadConfirmationPresented },
                set: { presented in
                    if !presented && model.isReloadConfirmationPresented { model.cancelReload() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Changes and Reload", role: .destructive) { model.confirmDiscardAndReload() }
            Button("Cancel", role: .cancel) { model.cancelReload() }
        } message: {
            Text("Reloading replaces the complete configuration draft with the saved file.")
        }
        .alert("Hidhogg", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebarBatteryLabel: some View {
        let information = DeviceInformationPresentation(status: model.boltStatus)
        let deviceInformation = model.boltStatus.deviceInformation
        let percentage = information.isConnected && deviceInformation.batteryState == .available
            ? deviceInformation.battery?.percentage
            : nil

        return Label(
            percentage.map { "\($0)%" } ?? "—",
            systemImage: information.batterySymbol
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("Battery: \(information.batteryText)")
        .accessibilityLabel("Battery: \(information.batteryText)")
        .labelStyle(.titleAndIcon)
    }
}

private struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 10) {
            configuration.icon
                .frame(width: 20, height: 20, alignment: .center)
            configuration.title
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension WorkspaceRoute {
    var title: String {
        switch self {
        case .devices: "Devices"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .devices: "rectangle.connected.to.line.below"
        case .settings: "gearshape"
        }
    }
}
