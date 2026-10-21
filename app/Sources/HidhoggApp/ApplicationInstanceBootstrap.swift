import AppKit
import Darwin
import SwiftUI

@MainActor
final class ApplicationInstanceBootstrap {
    static let shared = ApplicationInstanceBootstrap()
    static let activationNotification = Notification.Name("com.hidhogg.instance.show-workspace")

    private(set) var lease: (any ApplicationInstanceOwnership)?
    private var observer: NSObjectProtocol?
    private var pendingActivation = false
    private var openWorkspace: (() -> Void)?
    private let observeActivation: (@escaping @MainActor () -> Void) -> NSObjectProtocol
    private let postActivation: () -> Void

    var isOwner: Bool { lease?.isHeld == true }

    init(
        observeActivation: @escaping (@escaping @MainActor () -> Void) -> NSObjectProtocol = { handler in
            DistributedNotificationCenter.default().addObserver(
                forName: ApplicationInstanceBootstrap.activationNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in handler() }
            }
        },
        postActivation: @escaping () -> Void = {
            DistributedNotificationCenter.default().postNotificationName(
                ApplicationInstanceBootstrap.activationNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    ) {
        self.observeActivation = observeActivation
        self.postActivation = postActivation
    }

    func start(lease: any ApplicationInstanceOwnership) throws -> Bool {
        self.lease = lease
        observer = observeActivation { [weak self] in self?.requestWorkspace() }
        guard try lease.acquire() else {
            postActivation()
            return false
        }
        return true
    }

    func run(
        diagnostics: () -> Bool,
        makeLease: () throws -> any ApplicationInstanceOwnership,
        owner: () -> Void
    ) throws {
        if diagnostics() { return }
        guard try start(lease: makeLease()) else { return }
        _ = constructOwner(owner)
    }

    func constructOwner<Value>(_ factory: () -> Value) -> Value? {
        guard isOwner else { return nil }
        return factory()
    }

    func installWorkspace(_ openWorkspace: @escaping () -> Void) {
        self.openWorkspace = openWorkspace
        guard isOwner, pendingActivation else { return }
        pendingActivation = false
        openWorkspace()
    }

    func requestWorkspace() {
        guard isOwner else { return }
        guard let openWorkspace else {
            pendingActivation = true
            return
        }
        openWorkspace()
    }
}

struct WorkspaceActivationAdapter: View {
    let presentationCoordinator: WorkspacePresentationCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear {
                ApplicationInstanceBootstrap.shared.installWorkspace {
                    presentationCoordinator.workspaceOpenRequested()
                    openWindow(id: HidhoggWorkspaceWindow.id)
                    NSApplication.shared.activate()
                }
            }
    }
}

@main
enum HidhoggEntryPoint {
    @MainActor
    static func main() {
        do {
            try ApplicationInstanceBootstrap.shared.run(
                diagnostics: {
                    PermissionProbe.runIfRequested()
                    return false
                },
                makeLease: {
                    let parent = try FileManager.default.url(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: true
                    )
                    return try ApplicationInstanceLease(parentURL: parent)
                },
                owner: { HidhoggApp.main() }
            )
        } catch {
            let event = DiagnosticEvent(
                code: .instanceOwnershipFailed,
                message: "Hidhogg could not establish private application ownership.",
                isError: true,
                source: DiagnosticSource(fileID: #fileID, line: #line)
            )
            DiagnosticsStore.log(event)
            FileHandle.standardError.write(Data("Hidhogg could not establish application ownership [\(event.code.rawValue)].\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
