import SwiftUI
import AppKit
import HidhoggDomain

struct WorkspaceView: View {
    let presentationCoordinator: WorkspacePresentationCoordinator
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var restartCoordinator: RestartCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var isDevicesInspectorPresented = true
    @State private var isD200XInspectorPresented = true
    @State private var inspectorContentID = UUID()

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
                            Image("DeviceMouse")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                        }
                        .labelStyle(SidebarLabelStyle())
                    }
                    NavigationLink(value: WorkspaceRoute.d200x) {
                        D200XSidebarLabel(model: model.d200x)
                    }
                    NavigationLink(value: WorkspaceRoute.flowLite) {
                        FlowLite84SidebarLabel(model: model.flowLite)
                    }
                }
                Section("Workspace") {
                    ForEach([WorkspaceRoute.actions, .notifications, .tilePresets]) { route in
                        NavigationLink(value: route) {
                            Label(route.title, systemImage: route.symbol)
                                .labelStyle(SidebarLabelStyle())
                                .padding(.vertical, 4)
                        }
                    }
                }
                NavigationLink(value: WorkspaceRoute.settings) {
                    Label("Settings", systemImage: WorkspaceRoute.settings.symbol)
                        .labelStyle(SidebarLabelStyle())
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .tint(AppAppearance.sidebarSelection)
            .navigationTitle("Hidhogg")
        } detail: {
            HSplitView {
                Group {
                    switch model.navigation.current.route {
                    case .devices:
                        DevicesView(isInspectorPresented: $isDevicesInspectorPresented)
                    case .d200x:
                        D200XDeviceView(
                            model: model.d200x,
                            isInspectorPresented: $isD200XInspectorPresented
                        )
                    case .flowLite:
                        FlowLite84DeviceView(model: model.flowLite)
                    case .actions:
                        ActionsView(model: model.d200x, onOpenTile: openD200XTile)
                    case .notifications:
                        NotificationsView(model: model.d200x, onOpenTile: openD200XTile)
                    case .tilePresets:
                        TilePresetsView(model: model.d200x)
                    case .settings:
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if isInspectorPresentedForCurrentRoute {
                    WorkspaceInspectorView(
                        route: model.navigation.current.route,
                        d200xModel: model.d200x
                    )
                    .id(inspectorContentID)
                    .accessibilityIdentifier("workspace.control-inspector")
                    .frame(
                        minWidth: 320,
                        idealWidth: 320,
                        maxWidth: 480,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .background {
                        WorkspaceInspectorInitialWidthAdapter(targetWidth: 320)
                            .frame(width: 0, height: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(AppAppearance.accent)
        .disabled(restartCoordinator.inProgress)
        .background {
            WorkspaceWindowLifecycleAdapter(
                presentationCoordinator: presentationCoordinator,
                onClose: {
                    model.cancelRecording()
                    inspectorContentID = UUID()
                }
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

    private var isInspectorPresentedForCurrentRoute: Bool {
        switch model.navigation.current.route {
        case .devices:
            isDevicesInspectorPresented
        case .d200x:
            isD200XInspectorPresented
        case .flowLite, .actions, .notifications, .tilePresets, .settings:
            false
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

    private func openD200XTile(_ profile: String?, _ controlIdentifier: String) {
        guard let control = D200XControl(rawValue: controlIdentifier) else { return }

        let applicationID: String?
        if let profile, profile != "Default" {
            guard model.d200x.configuration?.applicationIDs.contains(profile) == true else { return }
            applicationID = profile
        } else {
            applicationID = nil
        }

        model.d200x.applicationID = applicationID
        model.d200x.selectedControl = control
        model.navigate(to: .d200x)
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

fileprivate extension WorkspaceRoute {
    var title: String {
        switch self {
        case .devices: "Devices"
        case .d200x: "Ulanzi D200X"
        case .flowLite: "Lofree Flow Lite84"
        case .actions: "Actions"
        case .notifications: "Notifications"
        case .tilePresets: "Tile Presets"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .devices: "rectangle.connected.to.line.below"
        case .d200x: "square.grid.3x3"
        case .flowLite: "keyboard"
        case .actions: "bolt.fill"
        case .notifications: "bell.badge"
        case .tilePresets: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }
}

private struct FlowLite84SidebarLabel: View {
    @ObservedObject var model: FlowLite84Model

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lofree Flow Lite84")
                HStack(spacing: 4) {
                    Circle().fill(model.isKeyboardOnline ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(model.isConnected && !model.isKeyboardOnline ? "Keyboard offline" : model.connectionTitle)
                    if model.isKeyboardOnline, let level = model.snapshot?.battery?.reportedLevel {
                        Image(systemName: model.snapshot?.battery?.charging == true ? "battery.100percent.bolt" : "battery.100percent")
                        Text("\(level)")
                            .help("Reported battery level")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "keyboard")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
        .labelStyle(SidebarLabelStyle())
    }
}

private struct D200XSidebarLabel: View {
    @ObservedObject var model: D200XModel

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ulanzi D200X")
                HStack(spacing: 4) {
                    Circle().fill(model.isConnected ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(model.connectionTitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image("DeviceDeck")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
        .labelStyle(SidebarLabelStyle())
    }
}
