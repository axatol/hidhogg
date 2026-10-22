import AppKit

@MainActor
final class WorkspaceWindowLifecycleView: NSView {
    private let presentationCoordinator: WorkspacePresentationCoordinator
    private let onClose: @MainActor () -> Void
    private var closeObserver: NSObjectProtocol?

    init(presentationCoordinator: WorkspacePresentationCoordinator, onClose: @escaping @MainActor () -> Void = {}) {
        self.presentationCoordinator = presentationCoordinator
        self.onClose = onClose
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let window else { return }
        presentationCoordinator.workspaceWindowDidAttach(window)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose() }
        }
    }

    isolated deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}
