import AppKit

@MainActor
final class WorkspaceWindowLifecycleView: NSView {
    private let presentationCoordinator: WorkspacePresentationCoordinator

    init(presentationCoordinator: WorkspacePresentationCoordinator) {
        self.presentationCoordinator = presentationCoordinator
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        presentationCoordinator.workspaceWindowDidAttach(window)
    }
}
