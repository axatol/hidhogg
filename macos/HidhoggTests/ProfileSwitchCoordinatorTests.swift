import Foundation
import XCTest
@testable import Hidhogg
import HidhoggCore

@MainActor
final class ProfileSwitchCoordinatorTests: XCTestCase {
    func testInitialMatchingApplicationActivatesMappedProfile() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))
    }

    func testUnmappedApplicationActivatesDefaultAfterMappedApplicationAndOnlyOnce() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()

        source.emit("com.example.unmapped")
        await coordinator.waitForIdle()
        source.emit("com.example.unmapped")
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile", "Default"])
        XCTAssertEqual(coordinator.currentProfileID, "Default")
        XCTAssertEqual(coordinator.state, .current(profileID: "Default"))
    }

    func testUnmappedApplicationAlreadyOnDefaultDoesNotActivate() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.unmapped")
        let coordinator = makeCoordinator()

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, [])
        XCTAssertEqual(coordinator.currentProfileID, "Default")
        XCTAssertEqual(coordinator.state, .current(profileID: "Default"))
    }

    func testNilAndEmptyEventsClearForegroundIdentityWithoutChangingProfile() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        let listCount = await operations.snapshot().listCount

        source.emit(nil)
        source.emit("")
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile"])
        XCTAssertEqual(snapshot.listCount, listCount)
        XCTAssertNil(coordinator.currentBundleIdentifier)
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))
    }

    func testClearedForegroundIdentityIsNotReusedByMappingEditOrEndpointReplacement() async throws {
        let oldOperations = RecordingProfileOperations(currentProfileID: "Default")
        let newOperations = RecordingProfileOperations(currentProfileID: "Work.Profile")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(oldOperations, identity: "old"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")

        source.emit(nil)
        await coordinator.waitForIdle()
        source.emit("")
        await coordinator.waitForIdle()
        XCTAssertNil(coordinator.currentBundleIdentifier)
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")

        _ = try coordinator.setMapping(
            profileID: "Gaming.Profile",
            forBundleIdentifier: "com.example.editor"
        )
        await coordinator.waitForIdle()
        let oldSnapshot = await oldOperations.snapshot()
        XCTAssertEqual(oldSnapshot.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")

        await coordinator.setRuntimeOperations(handle(newOperations, identity: "new"))
        await coordinator.waitForIdle()
        let newSnapshot = await newOperations.snapshot()
        XCTAssertEqual(newSnapshot.listCount, 1)
        XCTAssertEqual(newSnapshot.activationIDs, [])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))

        source.emit("com.example.editor")
        await coordinator.waitForIdle()
        let refreshedSnapshot = await newOperations.snapshot()
        XCTAssertEqual(refreshedSnapshot.activationIDs, ["Gaming.Profile"])
        XCTAssertEqual(coordinator.currentProfileID, "Gaming.Profile")
    }

    func testNilEventDuringCatalogReadPreventsStaleActivation() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let catalogGate = ProfileOperationGate()
        await operations.blockNextCatalogRead(using: catalogGate)
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        coordinator.startObserving(source)
        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        await catalogGate.waitForArrival()

        source.emit(nil)
        await catalogGate.open()
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertNil(coordinator.currentBundleIdentifier)
        XCTAssertEqual(snapshot.activationIDs, [])
        XCTAssertEqual(coordinator.currentProfileID, "Default")
        XCTAssertEqual(coordinator.state, .current(profileID: "Default"))
    }

    func testExplicitCatalogRefreshDoesNotActivateProfile() async {
        let operations = RecordingProfileOperations(currentProfileID: "Work.Profile")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Gaming.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.refreshCatalog()
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.listCount, 1)
        XCTAssertEqual(snapshot.activationIDs, [])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))
    }

    func testRepeatedSameEffectiveProfileDoesNotActivateAgain() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        source.emit("com.example.editor")
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile"])
        XCTAssertEqual(snapshot.listCount, 2)
    }

    func testRapidAThenBEventsSerializeActivationInArrivalOrder() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let activationGate = ProfileOperationGate()
        await operations.blockActivation("Work.Profile", using: activationGate)
        let source = TestForegroundObserver(initialBundleIdentifier: nil)
        let coordinator = makeCoordinator(mappings: [
            "com.example.a": "Work.Profile",
            "com.example.b": "Gaming.Profile"
        ])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        source.emit("com.example.a")
        await activationGate.waitForArrival()

        XCTAssertEqual(coordinator.state, .switching(profileID: "Work.Profile"))
        source.emit("com.example.b")
        await activationGate.open()
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile", "Gaming.Profile"])
    }

    func testMappingToMissingCatalogProfileIsRejectedWithoutActivation() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Missing.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, [])
        XCTAssertEqual(
            coordinator.state,
            .invalidMapping(bundleIdentifier: "com.example.editor", profileID: "Missing.Profile")
        )
    }

    func testUnavailableRuntimeDoesNotIssueActivationAndRecoversOnEndpoint() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.state, .waitingForRuntime)

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile"])
    }

    func testOutcomeUnknownWaitsForNewEventBeforeRetrying() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        await operations.failActivation("Work.Profile")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.state, .outcomeUnknown(profileID: "Work.Profile"))
        var snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile"])

        await operations.clearActivationFailure("Work.Profile")
        await coordinator.waitForIdle()
        snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile"])
        source.emit("com.example.editor")
        await coordinator.waitForIdle()

        snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile", "Work.Profile"])
    }

    func testMappingEditReevaluatesCurrentForegroundApplication() async throws {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator()

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        XCTAssertEqual(coordinator.state, .current(profileID: "Default"))

        _ = try coordinator.setMapping(
            profileID: "Work.Profile",
            forBundleIdentifier: "com.example.editor"
        )
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.currentProfileID, "Work.Profile")
    }

    func testEndpointReplacementDiscardsOldCatalogAndReevaluatesCurrentApplication() async {
        let oldOperations = RecordingProfileOperations(currentProfileID: "Default")
        let newOperations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(oldOperations, identity: "old"))
        coordinator.startObserving(source)
        await coordinator.waitForIdle()
        await coordinator.setRuntimeOperations(handle(newOperations, identity: "new"))
        await coordinator.waitForIdle()

        let oldSnapshot = await oldOperations.snapshot()
        let newSnapshot = await newOperations.snapshot()
        XCTAssertEqual(oldSnapshot.activationIDs, ["Work.Profile"])
        XCTAssertEqual(newSnapshot.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.runtimeIdentity, "new")
    }

    func testEndpointReplacementWaitsForBlockedActivationBeforeFinalizing() async {
        let oldOperations = RecordingProfileOperations(currentProfileID: "Default")
        let activationGate = ProfileOperationGate()
        await oldOperations.blockActivation("Work.Profile", using: activationGate)
        let newOperations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(oldOperations, identity: "old"))
        coordinator.startObserving(source)
        await activationGate.waitForArrival()

        let replacementStatus = TaskStatus()
        let replacement = Task { @MainActor in
            replacementStatus.didStart = true
            await coordinator.setRuntimeOperations(handle(newOperations, identity: "new"))
            replacementStatus.didFinish = true
        }
        for _ in 0..<100 where !replacementStatus.didStart {
            await Task.yield()
        }
        XCTAssertTrue(replacementStatus.didStart)
        XCTAssertFalse(replacementStatus.didFinish)

        let newSnapshotBeforeRelease = await newOperations.snapshot()
        XCTAssertEqual(coordinator.runtimeIdentity, "old")
        XCTAssertEqual(newSnapshotBeforeRelease.listCount, 0)
        let oldSnapshot = await oldOperations.snapshot()
        XCTAssertEqual(oldSnapshot.inFlightCount, 1)

        await activationGate.open()
        await replacement.value
        await coordinator.waitForIdle()

        let finishedOldSnapshot = await oldOperations.snapshot()
        let newSnapshot = await newOperations.snapshot()
        XCTAssertEqual(finishedOldSnapshot.inFlightCount, 0)
        XCTAssertEqual(newSnapshot.activationIDs, ["Work.Profile"])
        XCTAssertEqual(coordinator.runtimeIdentity, "new")
        XCTAssertEqual(coordinator.state, .current(profileID: "Work.Profile"))
    }

    func testShutdownStopsObservationAndAdmission() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let source = TestForegroundObserver(initialBundleIdentifier: nil)
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await coordinator.shutdown()
        source.emit("com.example.editor")
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(coordinator.state, .stopped)
        XCTAssertEqual(snapshot.activationIDs, [])
        XCTAssertEqual(source.stopCount, 1)
    }

    func testShutdownWaitsForBlockedActivationBeforeFinalizing() async {
        let operations = RecordingProfileOperations(currentProfileID: "Default")
        let activationGate = ProfileOperationGate()
        await operations.blockActivation("Work.Profile", using: activationGate)
        let source = TestForegroundObserver(initialBundleIdentifier: "com.example.editor")
        let coordinator = makeCoordinator(mappings: ["com.example.editor": "Work.Profile"])

        await coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        coordinator.startObserving(source)
        await activationGate.waitForArrival()

        let shutdownStatus = TaskStatus()
        let shutdown = Task { @MainActor in
            shutdownStatus.didStart = true
            await coordinator.shutdown()
            shutdownStatus.didFinish = true
        }
        for _ in 0..<100 where !shutdownStatus.didStart {
            await Task.yield()
        }
        XCTAssertTrue(shutdownStatus.didStart)
        XCTAssertFalse(shutdownStatus.didFinish)

        XCTAssertNotEqual(coordinator.state, .stopped)
        var snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.inFlightCount, 1)

        source.emit("com.example.editor")
        snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.activationIDs, ["Work.Profile"])

        await activationGate.open()
        await shutdown.value

        snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.inFlightCount, 0)
        XCTAssertEqual(coordinator.state, .stopped)
        XCTAssertNil(coordinator.runtimeIdentity)
    }

    private func makeCoordinator(
        mappings: [String: String] = [:]
    ) -> ProfileSwitchCoordinator {
        ProfileSwitchCoordinator(mappings: ProfileMappingPreferences(mappings: mappings))
    }
}

private func handle(
    _ operations: RecordingProfileOperations,
    identity: String
) -> RuntimeOperationsHandle {
    RuntimeOperationsHandle(identity: identity, operations: operations)
}

private struct RecordingProfileOperationsSnapshot: Sendable {
    let activationIDs: [String]
    let listCount: Int
    let inFlightCount: Int
}

private actor RecordingProfileOperations: HidhoggAppRuntimeOperations {
    private static let profileIDs = ["Default", "Work.Profile", "Gaming.Profile"]

    private var currentProfileID: String
    private var activationIDs: [String] = []
    private var listCount = 0
    private var inFlightCount = 0
    private var nextCatalogGate: ProfileOperationGate?
    private var activationGates: [String: ProfileOperationGate] = [:]
    private var failedActivations = Set<String>()

    init(currentProfileID: String) {
        self.currentProfileID = currentProfileID
    }

    func snapshot() -> RecordingProfileOperationsSnapshot {
        RecordingProfileOperationsSnapshot(
            activationIDs: activationIDs,
            listCount: listCount,
            inFlightCount: inFlightCount
        )
    }

    func blockNextCatalogRead(using gate: ProfileOperationGate) {
        nextCatalogGate = gate
    }

    func blockActivation(_ profileID: String, using gate: ProfileOperationGate) {
        activationGates[profileID] = gate
    }

    func failActivation(_ profileID: String) {
        failedActivations.insert(profileID)
    }

    func clearActivationFailure(_ profileID: String) {
        failedActivations.remove(profileID)
    }

    func profiles() async throws -> [RuntimeOperationProfile] {
        listCount += 1
        let currentProfileID = self.currentProfileID
        let response = Self.profileIDs.map { profileID in
            RuntimeOperationProfile(
                id: profileID,
                label: profileID,
                isDefault: profileID == "Default",
                isCurrent: profileID == currentProfileID
            )
        }
        let gate = nextCatalogGate
        nextCatalogGate = nil
        if let gate {
            inFlightCount += 1
            defer { inFlightCount -= 1 }
            await gate.arriveAndWait()
        }
        return response
    }

    func activateProfile(_ profileID: String) async throws -> RuntimeActivationResult {
        activationIDs.append(profileID)
        inFlightCount += 1
        let gate = activationGates.removeValue(forKey: profileID)
        let shouldFail = failedActivations.contains(profileID)
        defer { inFlightCount -= 1 }

        if let gate {
            await gate.arriveAndWait()
        }
        guard !shouldFail else {
            throw TestCoordinatorOperationError.activationFailed
        }

        currentProfileID = profileID
        return RuntimeActivationResult(
            profileID: profileID,
            changed: true,
            revision: UInt64(activationIDs.count)
        )
    }

    func setHostDisplayAwake(_ awake: Bool) async throws -> RuntimeOperationDisplayResult {
        RuntimeOperationDisplayResult(displayAwake: awake, changed: true)
    }

    func editorSnapshot() async throws -> RuntimeOperationEditorSnapshot {
        throw TestCoordinatorOperationError.unused
    }

    func editorProfile(
        sourceDigest: String,
        profileID: String
    ) async throws -> RuntimeOperationEditorProfile {
        throw TestCoordinatorOperationError.unused
    }

    func editorPositions(
        sourceDigest: String,
        profileID: String
    ) async throws -> RuntimeOperationEditorPositions {
        throw TestCoordinatorOperationError.unused
    }

    func editorPosition(
        sourceDigest: String,
        profileID: String,
        positionID: String
    ) async throws -> RuntimeOperationEditorPosition {
        throw TestCoordinatorOperationError.unused
    }

    func edit(
        expectedDigest: String,
        edit: RuntimeConfigurationEdit
    ) async throws -> RuntimeOperationEditResult {
        throw TestCoordinatorOperationError.unused
    }

    func cloneProfile(
        expectedDigest: String,
        sourceProfileID: String?,
        profileID: String,
        label: String
    ) async throws -> RuntimeOperationEditResult {
        throw TestCoordinatorOperationError.unused
    }

    func reloadConfiguration() async throws -> RuntimeOperationReloadResult {
        throw TestCoordinatorOperationError.unused
    }

    func configurationStatus() async throws -> RuntimeOperationConfigurationStatus {
        throw TestCoordinatorOperationError.unused
    }

    func retire() async {}
}

private actor ProfileOperationGate {
    private var isOpen = false
    private var hasArrived = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        hasArrived = true
        let arrivals = arrivalWaiters
        arrivalWaiters.removeAll()
        arrivals.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class TaskStatus {
    var didStart = false
    var didFinish = false
}

private enum TestCoordinatorOperationError: Error, Sendable {
    case unused
    case activationFailed
}

@MainActor
private final class TestForegroundObserver: ForegroundApplicationObserving {
    private let initialBundleIdentifier: String?
    private var handler: ForegroundApplicationHandler?
    private(set) var stopCount = 0

    init(initialBundleIdentifier: String?) {
        self.initialBundleIdentifier = initialBundleIdentifier
    }

    func start(handler: @escaping ForegroundApplicationHandler) {
        self.handler = handler
        handler(initialBundleIdentifier)
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ bundleIdentifier: String?) {
        handler?(bundleIdentifier)
    }
}
