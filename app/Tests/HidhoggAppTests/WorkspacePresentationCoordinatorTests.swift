import AppKit
import XCTest
@testable import HidhoggApp

@MainActor
final class WorkspacePresentationCoordinatorTests: XCTestCase {
    func testInitialLaunchDoesNotChangeMenuOnlyActivationPolicy() {
        var policies = [NSApplication.ActivationPolicy]()
        _ = makeCoordinator { policy in
            policies.append(policy)
            return true
        }

        XCTAssertEqual(policies, [])
    }

    func testOpenRequestAndWindowCloseToggleActivationPolicy() {
        var policies = [NSApplication.ActivationPolicy]()
        var closeHandler: WorkspacePresentationCoordinator.CloseHandler?
        let coordinator = makeCoordinator(
            setActivationPolicy: { policy in
                policies.append(policy)
                return true
            },
            observeWindowClose: { _, handler in
                closeHandler = handler
                return NSObject()
            }
        )
        let window = NSObject()

        coordinator.workspaceOpenRequested()
        coordinator.workspaceWindowDidAttach(window)
        XCTAssertEqual(policies, [.regular])

        closeHandler?()
        XCTAssertEqual(policies, [.regular, .accessory])
        XCTAssertFalse(coordinator.workspaceIsOpen)
    }

    func testSameRetainedWindowCanReopenAndCloseAgainWithoutReattaching() {
        var policies = [NSApplication.ActivationPolicy]()
        var closeHandler: WorkspacePresentationCoordinator.CloseHandler?
        let coordinator = makeCoordinator(
            setActivationPolicy: { policy in
                policies.append(policy)
                return true
            },
            observeWindowClose: { _, handler in
                closeHandler = handler
                return NSObject()
            }
        )
        let window = NSObject()

        coordinator.workspaceWindowDidAttach(window)
        closeHandler?()
        coordinator.workspaceOpenRequested()
        closeHandler?()

        XCTAssertEqual(policies, [.regular, .accessory, .regular, .accessory])
    }

    func testCloseFromSupersededWindowCannotHideNewWorkspaceWindow() {
        var policies = [NSApplication.ActivationPolicy]()
        var closeHandlers = [ObjectIdentifier: WorkspacePresentationCoordinator.CloseHandler]()
        var removedObservers = 0
        let coordinator = makeCoordinator(
            setActivationPolicy: { policy in
                policies.append(policy)
                return true
            },
            observeWindowClose: { identity, handler in
                closeHandlers[ObjectIdentifier(identity)] = handler
                return NSObject()
            },
            removeWindowCloseObserver: { _ in removedObservers += 1 }
        )
        let oldWindow = NSObject()
        let newWindow = NSObject()

        coordinator.workspaceWindowDidAttach(oldWindow)
        let delayedOldClose = closeHandlers[ObjectIdentifier(oldWindow)]
        delayedOldClose?()
        coordinator.workspaceOpenRequested()
        coordinator.workspaceWindowDidAttach(newWindow)
        delayedOldClose?()

        XCTAssertEqual(policies, [.regular, .accessory, .regular])
        XCTAssertTrue(coordinator.workspaceIsOpen)
        XCTAssertEqual(removedObservers, 1)

        closeHandlers[ObjectIdentifier(newWindow)]?()
        XCTAssertEqual(policies, [.regular, .accessory, .regular, .accessory])
    }

    func testCloseHandlerSurvivesLifecycleBridgeRelease() {
        var policies = [NSApplication.ActivationPolicy]()
        var closeHandler: WorkspacePresentationCoordinator.CloseHandler?
        let coordinator = makeCoordinator(
            setActivationPolicy: { policy in
                policies.append(policy)
                return true
            },
            observeWindowClose: { _, handler in
                closeHandler = handler
                return NSObject()
            }
        )
        let window = NSObject()
        var attachFromBridge: (() -> Void)? = {
            coordinator.workspaceWindowDidAttach(window)
        }

        attachFromBridge?()
        attachFromBridge = nil
        closeHandler?()

        XCTAssertEqual(policies, [.regular, .accessory])
        XCTAssertFalse(coordinator.workspaceIsOpen)
    }

    private func makeCoordinator(
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool = { _ in true },
        observeWindowClose: @escaping WorkspacePresentationCoordinator.ObserveWindowClose = { _, _ in NSObject() },
        removeWindowCloseObserver: @escaping (NSObjectProtocol) -> Void = { _ in }
    ) -> WorkspacePresentationCoordinator {
        WorkspacePresentationCoordinator(
            setActivationPolicy: setActivationPolicy,
            observeWindowClose: observeWindowClose,
            removeWindowCloseObserver: removeWindowCloseObserver
        )
    }
}
