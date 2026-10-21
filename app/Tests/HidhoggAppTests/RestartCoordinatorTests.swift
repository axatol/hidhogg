import XCTest
@testable import HidhoggApp

@MainActor
final class RestartCoordinatorTests: XCTestCase {
    func testCleanupCompletesBeforeFreshLaunchAndTermination() async {
        var events = [String]()
        let coordinator = RestartCoordinator(
            cleanup: {
                events.append("cleanup")
                return true
            },
            launch: {
                events.append("launch")
            },
            terminate: {
                events.append("terminate")
            },
            reportError: { _ in XCTFail("Successful restart must not report an error.") }
        )

        coordinator.requestRestart()

        let finished = await eventually { events.last == "terminate" }
        XCTAssertTrue(finished)
        XCTAssertEqual(events, ["cleanup", "launch", "terminate"])
        XCTAssertTrue(coordinator.inProgress)
    }

    func testUnverifiedCleanupPreventsLaunchAndTermination() async {
        var events = [String]()
        var reportedError: String?
        var cancellationCount = 0
        let coordinator = RestartCoordinator(
            cleanup: {
                events.append("cleanup")
                return false
            },
            launch: { events.append("launch") },
            cancelRestart: { cancellationCount += 1 },
            terminate: { events.append("terminate") },
            reportError: { reportedError = $0 }
        )

        coordinator.requestRestart()

        let finished = await eventually { !coordinator.inProgress }
        XCTAssertTrue(finished)
        XCTAssertEqual(events, ["cleanup"])
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(reportedError, "Restart stopped. Review configuration and device errors before retrying.")
    }

    func testLaunchFailureKeepsCurrentApplicationOpenAndClearsBusyState() async {
        var events = [String]()
        var reportedError: String?
        let coordinator = RestartCoordinator(
            cleanup: {
                events.append("cleanup")
                return true
            },
            launch: {
                events.append("launch")
                throw NSError(domain: "RestartCoordinatorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fresh launch failed."])
            },
            terminate: { events.append("terminate") },
            reportError: { reportedError = $0 }
        )

        coordinator.requestRestart()

        let finished = await eventually { !coordinator.inProgress }
        XCTAssertTrue(finished)
        XCTAssertEqual(events, ["cleanup", "launch"])
        XCTAssertEqual(reportedError, "Fresh launch failed.")
    }

    func testDuplicateRequestsDuringCleanupAreIgnored() async {
        var cleanupCalls = 0
        var launchCalls = 0
        var resumeCleanup: CheckedContinuation<Bool, Never>?
        let coordinator = RestartCoordinator(
            cleanup: {
                cleanupCalls += 1
                return await withCheckedContinuation { continuation in
                    resumeCleanup = continuation
                }
            },
            launch: { launchCalls += 1 },
            terminate: {},
            reportError: { _ in XCTFail("Successful restart must not report an error.") }
        )

        coordinator.requestRestart()
        let cleanupStarted = await eventually { cleanupCalls == 1 }
        XCTAssertTrue(cleanupStarted)
        coordinator.requestRestart()
        XCTAssertEqual(cleanupCalls, 1)

        resumeCleanup?.resume(returning: true)
        let launched = await eventually { launchCalls == 1 }
        XCTAssertTrue(launched)
        XCTAssertEqual(cleanupCalls, 1)
    }

    func testRestartReleasesOwnershipOnlyAfterVerifiedCleanup() async {
        var events = [String]()
        let coordinator = RestartCoordinator(
            cleanup: { events.append("cleanup"); return true },
            launch: { events.append("launch") },
            beginRestart: { events.append("freeze"); return true },
            releaseOwnership: { events.append("release") },
            reacquireOwnership: { XCTFail("Successful launch must not reacquire."); return false },
            terminate: { events.append("terminate") },
            reportError: { _ in XCTFail("Successful restart must not report an error.") }
        )
        coordinator.requestRestart()
        let finished = await eventually { events.last == "terminate" }
        XCTAssertTrue(finished)
        XCTAssertEqual(events, ["freeze", "cleanup", "release", "launch", "terminate"])
    }

    func testCleanupFailureKeepsLeaseAndDoesNotLaunch() async {
        var cancelled = false
        let coordinator = RestartCoordinator(
            cleanup: { false },
            launch: { XCTFail("Unverified cleanup must not launch.") },
            cancelRestart: { cancelled = true },
            releaseOwnership: { XCTFail("Unverified cleanup must retain ownership.") },
            reacquireOwnership: { XCTFail("Ownership was never released."); return false },
            terminate: { XCTFail("Cleanup failure must keep the current owner.") },
            reportError: { _ in }
        )
        coordinator.requestRestart()
        let finished = await eventually { cancelled }
        XCTAssertTrue(finished)
    }

    func testLaunchFailureReacquiresBeforeUnfreezing() async {
        var events = [String]()
        let coordinator = RestartCoordinator(
            cleanup: { true },
            launch: { events.append("launch"); throw RestartFailure.launchTimedOut },
            cancelRestart: { events.append("unfreeze") },
            releaseOwnership: { events.append("release") },
            reacquireOwnership: { events.append("reacquire"); return true },
            terminate: { XCTFail("Reacquired owner should remain available.") },
            reportError: { _ in events.append("error") }
        )
        coordinator.requestRestart()
        let finished = await eventually { !coordinator.inProgress }
        XCTAssertTrue(finished)
        XCTAssertEqual(events, ["release", "launch", "reacquire", "unfreeze", "error"])
    }

    func testFailedReacquisitionTerminatesWithoutUnfreezingOrAcceptingAnotherRestart() async {
        var terminated = false
        var cleanupCount = 0
        let coordinator = RestartCoordinator(
            cleanup: { cleanupCount += 1; return true },
            launch: { throw RestartFailure.launchTimedOut },
            cancelRestart: { XCTFail("A nonowner must stay frozen.") },
            releaseOwnership: {},
            reacquireOwnership: { false },
            terminate: { terminated = true },
            reportError: { _ in }
        )
        coordinator.requestRestart()
        let finished = await eventually { terminated }
        XCTAssertTrue(finished)
        XCTAssertTrue(coordinator.inProgress)
        coordinator.requestRestart()
        XCTAssertEqual(cleanupCount, 1)
    }

    func testReacquisitionErrorAlsoTerminatesFrozen() async {
        var terminated = false
        let coordinator = RestartCoordinator(
            cleanup: { true },
            launch: { throw RestartFailure.launchTimedOut },
            cancelRestart: { XCTFail("Unverified ownership must not unfreeze.") },
            reacquireOwnership: { throw InstanceLeaseFailure.unsafeFilesystem },
            terminate: { terminated = true },
            reportError: { _ in }
        )
        coordinator.requestRestart()
        let finished = await eventually { terminated }
        XCTAssertTrue(finished)
        XCTAssertTrue(coordinator.inProgress)
    }

    func testReleaseErrorAfterUnlockReacquiresOrExitsWithoutUnfreezing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try ApplicationInstanceLease(parentURL: root)
        let candidate = try ApplicationInstanceLease(parentURL: root)
        XCTAssertTrue(try owner.acquire())
        var terminated = false
        var reacquisitions = 0
        let coordinator = RestartCoordinator(
            cleanup: { true },
            launch: { XCTFail("An uncertain release must not launch.") },
            cancelRestart: { XCTFail("A nonowner must not resume.") },
            releaseOwnership: {
                try owner.release()
                XCTAssertTrue(try candidate.acquire())
                throw InstanceLeaseFailure.system(5)
            },
            reacquireOwnership: { reacquisitions += 1; return try owner.acquire() },
            isOwner: { owner.isHeld },
            terminate: { terminated = true },
            reportError: { _ in }
        )
        coordinator.requestRestart()
        let finished = await eventually { terminated }
        XCTAssertTrue(finished)
        XCTAssertEqual(reacquisitions, 1)
        XCTAssertTrue(coordinator.inProgress)
        XCTAssertFalse(owner.isHeld)
        XCTAssertTrue(candidate.isHeld)
    }

    func testNonownerCannotReserveRestartOrRunCleanup() {
        let coordinator = RestartCoordinator(
            cleanup: { XCTFail("A nonowner cannot clean up a new runtime."); return false },
            launch: { XCTFail("A nonowner cannot launch a restart.") },
            beginRestart: { XCTFail("A nonowner cannot reserve restart."); return true },
            isOwner: { false },
            terminate: {},
            reportError: { _ in }
        )
        coordinator.requestRestart()
        XCTAssertFalse(coordinator.inProgress)
    }

    func testBoundedLaunchTimeoutIgnoresLateSuccessAndFailure() async {
        var callback: (@MainActor (Result<Void, Error>) -> Void)?
        do {
            try await BoundedApplicationLaunch.wait(timeout: .milliseconds(5)) { callback = $0 }
            XCTFail("A missing launch callback must time out.")
        } catch {
            XCTAssertEqual(error.localizedDescription, RestartFailure.launchTimedOut.localizedDescription)
        }
        callback?(.success(()))
        callback?(.failure(RestartFailure.existingInstanceReturned))
    }

    func testBoundedLaunchSuccessIgnoresDuplicateCallbackAndDeadline() async throws {
        var callback: (@MainActor (Result<Void, Error>) -> Void)?
        try await BoundedApplicationLaunch.wait(timeout: .milliseconds(5)) { complete in
            callback = complete
            complete(.success(()))
            complete(.failure(RestartFailure.existingInstanceReturned))
        }
        try await Task.sleep(for: .milliseconds(10))
        callback?(.failure(RestartFailure.launchTimedOut))
    }

    func testTimeoutRecoveryRetainsNativeLeaseAgainstLateCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try ApplicationInstanceLease(parentURL: root)
        let candidate = try ApplicationInstanceLease(parentURL: root)
        XCTAssertTrue(try owner.acquire())
        var callback: (@MainActor (Result<Void, Error>) -> Void)?
        var cancelled = false
        let coordinator = RestartCoordinator(
            cleanup: { true },
            launch: {
                try await BoundedApplicationLaunch.wait(timeout: .milliseconds(5)) { callback = $0 }
            },
            cancelRestart: { XCTAssertTrue(owner.isHeld); cancelled = true },
            releaseOwnership: { try owner.release() },
            reacquireOwnership: { try owner.acquire() },
            terminate: { XCTFail("Recovered owner must stay running.") },
            reportError: { _ in }
        )
        coordinator.requestRestart()
        let finished = await eventually { cancelled }
        XCTAssertTrue(finished)
        XCTAssertFalse(try candidate.acquire())
        callback?(.success(()))
        XCTAssertTrue(owner.isHeld)
        XCTAssertFalse(coordinator.inProgress)
    }

    func testQuitDuringHandoffCannotCancelRestartOrRunQuitCleanup() async {
        var terminated = false
        let termination = TerminationCoordinator(
            prepareForQuit: { XCTFail("Restart already froze the runtime.") },
            cleanupForQuit: { XCTFail("Restart owns cleanup."); return false },
            terminate: { terminated = true }
        )
        let coordinator = RestartCoordinator(
            cleanup: { true },
            launch: {
                XCTAssertEqual(termination.applicationShouldTerminate(), .terminateCancel)
                throw RestartFailure.launchTimedOut
            },
            beginRestart: { termination.beginRestart() },
            cancelRestart: { XCTFail("Lost ownership must not release restart reservation.") },
            reacquireOwnership: { false },
            terminate: { termination.terminateAfterVerifiedRestart() },
            reportError: { _ in }
        )
        coordinator.requestRestart()
        let finished = await eventually { terminated }
        XCTAssertTrue(finished)
        XCTAssertEqual(termination.applicationShouldTerminate(), .terminateNow)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
