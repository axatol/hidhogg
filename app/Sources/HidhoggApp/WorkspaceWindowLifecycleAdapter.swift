import SwiftUI

struct WorkspaceWindowLifecycleAdapter: NSViewRepresentable {
    let presentationCoordinator: WorkspacePresentationCoordinator
    var onClose: @MainActor () -> Void = {}

    func makeNSView(context: Context) -> WorkspaceWindowLifecycleView {
        WorkspaceWindowLifecycleView(presentationCoordinator: presentationCoordinator, onClose: onClose)
    }

    func updateNSView(_ nsView: WorkspaceWindowLifecycleView, context: Context) {}
}
