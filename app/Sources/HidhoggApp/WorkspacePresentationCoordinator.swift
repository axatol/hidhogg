import AppKit
import Foundation

@MainActor
final class WorkspacePresentationCoordinator {
    typealias WindowIdentity = AnyObject
    typealias CloseHandler = @MainActor () -> Void
    typealias ObserveWindowClose = (WindowIdentity, @escaping CloseHandler) -> NSObjectProtocol

    private(set) var workspaceIsOpen = false
    private(set) weak var observedWindowIdentity: WindowIdentity?

    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool
    private let observeWindowClose: ObserveWindowClose
    private let removeWindowCloseObserver: (NSObjectProtocol) -> Void
    private var closeObserver: NSObjectProtocol?
    private var lastSuccessfulPolicy: NSApplication.ActivationPolicy = .accessory

    init(
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = {
            NSApplication.shared.setActivationPolicy($0)
        },
        observeWindowClose: @escaping ObserveWindowClose = { identity, handler in
            guard let window = identity as? NSWindow else { return NSObject() }
            return NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak window] notification in
                guard let window,
                      let closingWindow = notification.object as? NSWindow,
                      closingWindow === window else { return }
                MainActor.assumeIsolated { handler() }
            }
        },
        removeWindowCloseObserver: @escaping (NSObjectProtocol) -> Void = {
            NotificationCenter.default.removeObserver($0)
        }
    ) {
        self.setActivationPolicy = setActivationPolicy
        self.observeWindowClose = observeWindowClose
        self.removeWindowCloseObserver = removeWindowCloseObserver
    }

    func workspaceOpenRequested() {
        workspaceIsOpen = true
        applyActivationPolicy(.regular)
    }

    func workspaceWindowDidAttach(_ identity: WindowIdentity) {
        guard observedWindowIdentity !== identity else {
            workspaceOpenRequested()
            return
        }

        removeCurrentCloseObserver()
        observedWindowIdentity = identity
        closeObserver = observeWindowClose(identity) { [weak self, weak identity] in
            guard let identity else { return }
            self?.workspaceWindowWillClose(identity)
        }
        workspaceOpenRequested()
    }

    private func workspaceWindowWillClose(_ identity: WindowIdentity) {
        guard observedWindowIdentity === identity else { return }
        workspaceIsOpen = false
        applyActivationPolicy(.accessory)
    }

    private func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard lastSuccessfulPolicy != policy else { return }
        guard setActivationPolicy(policy) else { return }
        lastSuccessfulPolicy = policy
    }

    private func removeCurrentCloseObserver() {
        guard let closeObserver else { return }
        removeWindowCloseObserver(closeObserver)
        self.closeObserver = nil
    }
}
