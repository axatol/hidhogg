import AppKit
import XCTest
@testable import HidhoggApp

@MainActor
final class TerminationCoordinatorTests: XCTestCase {
    func testAppDelegateForwardsNativeReopenToWorkspaceAdapter() {
        var opens = 0
        let delegate = HidhoggAppDelegate(
            terminationBootstrap: TerminationCoordinatorBootstrap(),
            openWorkspace: { opens += 1 }
        )
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(opens, 2)
    }

    func testDefaultAppDelegateUsesSharedTerminationBootstrap() {
        XCTAssertTrue(HidhoggAppDelegate().terminationBootstrap === TerminationCoordinatorBootstrap.shared)
    }

    func testAppDelegateKeepsMenuBarAppRunningAfterLastWindowCloses() {
        let delegate = HidhoggAppDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testAppDelegateUsesCoordinatorInstalledBeforeOpeningWorkspace() async {
        var events = [String]()
        let coordinator = TerminationCoordinator(
            prepareForQuit: { events.append("prepare") },
            cleanupForQuit: {
                events.append("cleanup")
                return true
            },
            terminate: { events.append("terminate") }
        )
        let bootstrap = TerminationCoordinatorBootstrap()
        bootstrap.install(coordinator)
        let delegate = HidhoggAppDelegate(terminationBootstrap: bootstrap)

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(events, ["prepare"])

        let terminationReissued = await eventually { events.last == "terminate" }
        XCTAssertTrue(terminationReissued)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
        XCTAssertEqual(events, ["prepare", "cleanup", "terminate"])
    }

    func testQuitCancelsImmediatelyAndReissuesOnlyAfterCleanupSucceeds() async {
        var events = [String]()
        var cleanupCount = 0
        var completeCleanup: CheckedContinuation<Bool, Never>?
        let coordinator = TerminationCoordinator(
            prepareForQuit: { events.append("prepare") },
            cleanupForQuit: {
                cleanupCount += 1
                events.append("cleanup")
                return await withCheckedContinuation { completeCleanup = $0 }
            },
            terminate: { events.append("terminate") }
        )

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateCancel)
        XCTAssertEqual(events, ["prepare"])
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateCancel)

        let cleanupStarted = await eventually { cleanupCount == 1 }
        XCTAssertTrue(cleanupStarted)
        XCTAssertEqual(events, ["prepare", "cleanup"])
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateCancel)
        XCTAssertEqual(cleanupCount, 1)

        completeCleanup?.resume(returning: true)
        let terminationReissued = await eventually { events.last == "terminate" }
        XCTAssertTrue(terminationReissued)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
        XCTAssertEqual(cleanupCount, 1)
    }

    func testFailedQuitCleanupLeavesApplicationOpenAndReleasesLifecycleReservation() async {
        var terminationCount = 0
        var quitWasCancelled = false
        let coordinator = TerminationCoordinator(
            prepareForQuit: {},
            cleanupForQuit: { false },
            cancelQuit: { quitWasCancelled = true },
            terminate: { terminationCount += 1 }
        )

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateCancel)
        let reservationReleased = await eventually { quitWasCancelled && coordinator.beginRestart() }
        XCTAssertTrue(reservationReleased)
        XCTAssertEqual(terminationCount, 0)
        coordinator.cancelRestart()
    }

    func testRestartReservationSuppressesQuitAndSkipsSecondCleanupAfterVerifiedLaunch() async {
        var events = [String]()
        let coordinator = TerminationCoordinator(
            prepareForQuit: { events.append("prepare-quit") },
            cleanupForQuit: {
                events.append("quit-cleanup")
                return true
            },
            terminate: { events.append("terminate") }
        )

        XCTAssertTrue(coordinator.beginRestart())
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateCancel)
        XCTAssertEqual(events, [])

        coordinator.terminateAfterVerifiedRestart()
        let terminationReissued = await eventually { events.last == "terminate" }
        XCTAssertTrue(terminationReissued)
        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateNow)
        XCTAssertEqual(events, ["terminate"])
    }

    func testRestartCannotReserveLifecycleWhileQuitCleanupIsPending() async {
        var cleanupStarted = false
        var completeCleanup: CheckedContinuation<Bool, Never>?
        let coordinator = TerminationCoordinator(
            prepareForQuit: {},
            cleanupForQuit: {
                cleanupStarted = true
                return await withCheckedContinuation { completeCleanup = $0 }
            },
            terminate: {}
        )

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateCancel)
        let started = await eventually { cleanupStarted }
        XCTAssertTrue(started)
        XCTAssertFalse(coordinator.beginRestart())

        completeCleanup?.resume(returning: false)
        let reservationReleased = await eventually { coordinator.beginRestart() }
        XCTAssertTrue(reservationReleased)
        coordinator.cancelRestart()
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
