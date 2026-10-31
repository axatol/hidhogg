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
    @State private var pendingRemoval: RegisteredDevice?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { Optional(model.navigation.current.route) },
                set: { if let route = $0 { model.navigate(to: route) } }
            )) {
                Section("Devices") {
                    ForEach(model.registeredDevices) { registration in
                        NavigationLink(value: AppModel.route(for: registration.family)) {
                            registeredDeviceLabel(registration)
                        }
                        .contextMenu {
                            Button(registration.isEnabled ? "Disable Device" : "Enable Device") {
                                model.setDeviceEnabled(registration.id, enabled: !registration.isEnabled)
                            }
                            Button("Remove Device…", role: .destructive) { pendingRemoval = registration }
                        }
                    }
                    if model.registeredDevices.isEmpty {
                        Text("No registered devices").foregroundStyle(.secondary)
                    }
                    Menu("Add Device", systemImage: "plus") {
                        ForEach(model.availableDeviceFamilies, id: \.self) { family in
                            Button(family.title) { model.addDevice(family) }
                        }
                    }
                    .disabled(!model.canEditConfiguration || model.availableDeviceFamilies.isEmpty)
                    .help("One device per supported model. Add registers settings for an existing supported adapter.")
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
                workspaceContent
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
            "Remove device and its settings?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Device", role: .destructive) {
                if let registration = pendingRemoval { model.removeDevice(registration.id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This removes the registration and its saved settings from Hidhogg. macOS pairing is retained. Older configuration files remain on disk for recovery.")
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

    @ViewBuilder
    private var workspaceContent: some View {
        if currentDeviceMissing {
            ContentUnavailableView("Device Removed", systemImage: "keyboard.badge.ellipsis",
                                   description: Text("Add a supported device from the sidebar to configure it."))
        } else {
            switch model.navigation.current.route {
            case .devices: DevicesView(isInspectorPresented: $isDevicesInspectorPresented)
            case .d200x: D200XDeviceView(model: model.d200x, isInspectorPresented: $isD200XInspectorPresented)
            case .flowLite: FlowLite84DeviceView(model: model.flowLite)
            case .actions: ActionsView(model: model.d200x, onOpenTile: openD200XTile)
            case .notifications: NotificationsView(model: model.d200x, onOpenTile: openD200XTile)
            case .tilePresets: TilePresetsView(model: model.d200x)
            case .settings: SettingsView()
            }
        }
    }

    @ViewBuilder
    private func registeredDeviceLabel(_ registration: RegisteredDevice) -> some View {
        switch registration.family {
        case .d200x: D200XSidebarLabel(model: model.d200x, registration: registration)
        case .flowLite84: FlowLite84SidebarLabel(model: model.flowLite, registration: registration)
        case .mxMaster3S:
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(registration.displayName)
                    HStack(spacing: 9) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(registration.isEnabled ? Color(nsColor: model.connectionColor) : .secondary)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(registration.isEnabled ? model.connectionTitle : "Disabled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if registration.isEnabled { sidebarBatteryLabel }
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
    }

    private var isInspectorPresentedForCurrentRoute: Bool {
        if currentDeviceMissing { return false }
        return switch model.navigation.current.route {
        case .devices:
            isDevicesInspectorPresented
        case .d200x:
            isD200XInspectorPresented
        case .flowLite, .actions, .notifications, .tilePresets, .settings:
            false
        }
    }

    private var currentFamily: DeviceFamily? {
        switch model.navigation.current.route {
        case .devices: .mxMaster3S
        case .d200x: .d200x
        case .flowLite: .flowLite84
        default: nil
        }
    }

    private var currentRegistration: RegisteredDevice? {
        currentFamily.flatMap { model.registration(for: $0) }
    }

    private var currentDeviceMissing: Bool { currentFamily != nil && currentRegistration == nil }

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
    let registration: RegisteredDevice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(registration.displayName)
                HStack(spacing: 4) {
                    Circle().fill(model.isKeyboardOnline ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(!registration.isEnabled ? "Disabled" : model.isConnected && !model.isKeyboardOnline ? "Keyboard offline" : model.connectionTitle)
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
    let registration: RegisteredDevice

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(registration.displayName)
                HStack(spacing: 4) {
                    Circle().fill(model.isConnected ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(registration.isEnabled ? model.connectionTitle : "Disabled").font(.caption).foregroundStyle(.secondary)
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
