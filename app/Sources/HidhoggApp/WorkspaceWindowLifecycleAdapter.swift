import SwiftUI

struct WorkspaceWindowLifecycleAdapter: NSViewRepresentable {
    let presentationCoordinator: WorkspacePresentationCoordinator

    func makeNSView(context: Context) -> WorkspaceWindowLifecycleView {
        WorkspaceWindowLifecycleView(presentationCoordinator: presentationCoordinator)
    }

    func updateNSView(_ nsView: WorkspaceWindowLifecycleView, context: Context) {}
}
