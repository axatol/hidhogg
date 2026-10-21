import SwiftUI

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
                ForEach(WorkspaceRoute.allCases) { route in
                    NavigationLink(value: route) {
                        Label(route.title, systemImage: route.symbol)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Hidhogg")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
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
            WorkspaceWindowLifecycleAdapter(presentationCoordinator: presentationCoordinator)
                .frame(width: 0, height: 0)
        }
        .task { _ = model.refreshPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { _ = model.refreshPermission() }
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
