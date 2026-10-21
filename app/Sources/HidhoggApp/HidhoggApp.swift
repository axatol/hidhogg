import SwiftUI
import AppKit

struct HidhoggApp: App {
    @NSApplicationDelegateAdaptor(HidhoggAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var diagnostics: DiagnosticsStore
    @StateObject private var loginItemController: LoginItemController
    @StateObject private var restartCoordinator: RestartCoordinator
    @StateObject private var terminationCoordinator: TerminationCoordinator
    @State private var workspacePresentationCoordinator = WorkspacePresentationCoordinator()

    init() {
        precondition(ApplicationInstanceBootstrap.shared.isOwner)
        _ = ApplicationIdentity.current
        let model = ApplicationInstanceBootstrap.shared.constructOwner { AppModel() }!
        _model = StateObject(wrappedValue: model)
        _diagnostics = StateObject(wrappedValue: DiagnosticsStore(model: model))
        _loginItemController = StateObject(wrappedValue: LoginItemController())
        let terminationCoordinator = TerminationCoordinator(
            prepareForQuit: { model.setRestarting(true) },
            cleanupForQuit: { await model.stopForTermination() },
            cancelQuit: { model.setRestarting(false) },
            terminate: { NSApplication.shared.terminate(nil) }
        )
        _terminationCoordinator = StateObject(wrappedValue: terminationCoordinator)
        _restartCoordinator = StateObject(wrappedValue: RestartCoordinator(
            cleanup: { await model.stopForRestart() },
            beginRestart: {
                guard ApplicationInstanceBootstrap.shared.isOwner else { return false }
                guard terminationCoordinator.beginRestart() else { return false }
                model.setRestarting(true)
                return true
            },
            cancelRestart: {
                guard ApplicationInstanceBootstrap.shared.isOwner else { return }
                terminationCoordinator.cancelRestart()
                model.setRestarting(false)
            },
            releaseOwnership: {
                guard let lease = ApplicationInstanceBootstrap.shared.lease else { throw InstanceLeaseFailure.notOwner }
                try lease.release()
            },
            reacquireOwnership: {
                guard let lease = ApplicationInstanceBootstrap.shared.lease else { throw InstanceLeaseFailure.notOwner }
                return try lease.acquire()
            },
            isOwner: { ApplicationInstanceBootstrap.shared.isOwner },
            terminate: { terminationCoordinator.terminateAfterVerifiedRestart() },
            reportError: { model.reportError($0, code: .restartFailed, diagnosticMessage: "Restart could not complete.") }
        ))
        TerminationCoordinatorBootstrap.shared.install(terminationCoordinator)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(restartCoordinator)
        } label: {
            MenuBarStatusLabel(
                phase: model.boltStatus.phase,
                cleanupUncertain: model.boltStatus.cleanupUncertain,
                permissionChecks: model.permissionChecks
            )
                .background {
                    WorkspaceActivationAdapter(presentationCoordinator: workspacePresentationCoordinator)
                }
        }
        .menuBarExtraStyle(.menu)

        Window("Hidhogg", id: HidhoggWorkspaceWindow.id) {
            WorkspaceView(presentationCoordinator: workspacePresentationCoordinator)
                .environmentObject(model)
                .environmentObject(diagnostics)
                .environmentObject(loginItemController)
                .environmentObject(restartCoordinator)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            WorkspaceNavigationCommands(model: model)
        }
    }
}

@MainActor
final class HidhoggAppDelegate: NSObject, NSApplicationDelegate {
    let terminationBootstrap: TerminationCoordinatorBootstrap
    private let openWorkspace: () -> Void

    override init() {
        terminationBootstrap = .shared
        openWorkspace = { ApplicationInstanceBootstrap.shared.requestWorkspace() }
        super.init()
    }

    init(
        terminationBootstrap: TerminationCoordinatorBootstrap,
        openWorkspace: @escaping () -> Void = { ApplicationInstanceBootstrap.shared.requestWorkspace() }
    ) {
        self.terminationBootstrap = terminationBootstrap
        self.openWorkspace = openWorkspace
        super.init()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWorkspace()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationBootstrap.applicationShouldTerminate()
    }
}

@MainActor
final class TerminationCoordinatorBootstrap {
    static let shared = TerminationCoordinatorBootstrap()

    private var coordinator: TerminationCoordinator?

    func install(_ coordinator: TerminationCoordinator) {
        self.coordinator = coordinator
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        coordinator?.applicationShouldTerminate() ?? .terminateNow
    }
}

enum HidhoggWorkspaceWindow {
    static let id = "workspace"
}
