import Foundation
import XCTest
@testable import Hidhogg
import HidhoggCore

@MainActor
final class HostDisplayPowerCoordinatorTests: XCTestCase {
    func testDelayedWriteIsFollowedByTheLatestDesiredStateSerially() async {
        let observer = FakeHostDisplayPowerObserver(initialState: true)
        let operations = RecordingDisplayOperations()
        let writeGate = DisplayOperationGate()
        await operations.blockFirstWrite(using: writeGate)
        let coordinator = HostDisplayPowerCoordinator(observer: observer)

        coordinator.start()
        coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        await writeGate.waitForArrival()

        observer.emit(false)
        observer.emit(true)
        observer.emit(false)
        await writeGate.open()
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertEqual(snapshot.displayAwakeValues, [true, false])
        XCTAssertEqual(snapshot.maximumConcurrentCalls, 1)
        XCTAssertEqual(coordinator.desiredDisplayAwake, false)
        XCTAssertNil(coordinator.errorText)
        await coordinator.shutdown()
        XCTAssertEqual(observer.stopCount, 1)
    }

    func testEndpointReplacementUsesCurrentStateAfterAnOldReplyArrives() async {
        let observer = FakeHostDisplayPowerObserver(initialState: true)
        let oldOperations = RecordingDisplayOperations()
        let writeGate = DisplayOperationGate()
        await oldOperations.blockFirstWrite(using: writeGate)
        let newOperations = RecordingDisplayOperations()
        let coordinator = HostDisplayPowerCoordinator(observer: observer)

        coordinator.start()
        coordinator.setRuntimeOperations(handle(oldOperations, identity: "old"))
        await writeGate.waitForArrival()

        observer.emit(false)
        coordinator.setRuntimeOperations(handle(newOperations, identity: "new"))
        await writeGate.open()
        await coordinator.waitForIdle()

        let oldSnapshot = await oldOperations.snapshot()
        let newSnapshot = await newOperations.snapshot()
        XCTAssertEqual(oldSnapshot.displayAwakeValues, [true])
        XCTAssertEqual(newSnapshot.displayAwakeValues, [false])
        XCTAssertEqual(coordinator.runtimeIdentity, "new")
        XCTAssertEqual(coordinator.desiredDisplayAwake, false)
        await coordinator.shutdown()
    }

    func testUnknownInitialStateDoesNotSendSpeculativeDarkState() async {
        let observer = FakeHostDisplayPowerObserver(
            initialState: nil,
            reconciliationState: nil,
            initialError: "display query failed"
        )
        let operations = RecordingDisplayOperations()
        let coordinator = HostDisplayPowerCoordinator(observer: observer)

        coordinator.start()
        coordinator.setRuntimeOperations(handle(operations, identity: "runtime"))
        await coordinator.waitForIdle()

        let snapshot = await operations.snapshot()
        XCTAssertNil(coordinator.desiredDisplayAwake)
        XCTAssertEqual(coordinator.errorText, "display query failed")
        XCTAssertEqual(observer.reconciliationCount, 1)
        XCTAssertEqual(snapshot.callCount, 0)
        await coordinator.shutdown()
    }

    func testOutcomeUnknownWriteIsNotRetriedButReplacementGetsFreshApplication() async throws {
        let observer = FakeHostDisplayPowerObserver(initialState: true)
        let failingOperations = RecordingDisplayOperations(failsAllCalls: true)
        let replacementOperations = RecordingDisplayOperations()
        let coordinator = HostDisplayPowerCoordinator(observer: observer)

        coordinator.start()
        coordinator.setRuntimeOperations(handle(failingOperations, identity: "old"))
        await coordinator.waitForIdle()
        var snapshot = await failingOperations.snapshot()
        XCTAssertEqual(snapshot.callCount, 1)
        let failureText = try XCTUnwrap(coordinator.errorText)

        observer.emit(true)
        await coordinator.waitForIdle()
        snapshot = await failingOperations.snapshot()
        XCTAssertEqual(snapshot.callCount, 1)
        XCTAssertEqual(coordinator.errorText, failureText)

        coordinator.setRuntimeOperations(handle(replacementOperations, identity: "new"))
        await coordinator.waitForIdle()
        let replacementSnapshot = await replacementOperations.snapshot()
        XCTAssertEqual(replacementSnapshot.displayAwakeValues, [true])
        XCTAssertNil(coordinator.errorText)
        await coordinator.shutdown()
    }
}

private func handle(
    _ operations: RecordingDisplayOperations,
    identity: String
) -> RuntimeOperationsHandle {
    RuntimeOperationsHandle(identity: identity, operations: operations)
}

private struct RecordingDisplayOperationsSnapshot: Sendable {
    let displayAwakeValues: [Bool]
    let callCount: Int
    let maximumConcurrentCalls: Int
}

private actor RecordingDisplayOperations: HidhoggAppRuntimeOperations {
    private var displayAwakeValues: [Bool] = []
    private var inFlightCount = 0
    private var maximumConcurrentCalls = 0
    private var firstWriteGate: DisplayOperationGate?
    private let failsAllCalls: Bool

    init(failsAllCalls: Bool = false) {
        self.failsAllCalls = failsAllCalls
    }

    func blockFirstWrite(using gate: DisplayOperationGate) {
        firstWriteGate = gate
    }

    func snapshot() -> RecordingDisplayOperationsSnapshot {
        RecordingDisplayOperationsSnapshot(
            displayAwakeValues: displayAwakeValues,
            callCount: displayAwakeValues.count,
            maximumConcurrentCalls: maximumConcurrentCalls
        )
    }

    func profiles() async throws -> [RuntimeOperationProfile] {
        throw RuntimeOperationError.closed
    }

    func activateProfile(_ profileID: String) async throws -> RuntimeActivationResult {
        throw RuntimeOperationError.closed
    }

    func setHostDisplayAwake(_ awake: Bool) async throws -> RuntimeOperationDisplayResult {
        displayAwakeValues.append(awake)
        inFlightCount += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, inFlightCount)
        let gate = firstWriteGate
        firstWriteGate = nil
        defer { inFlightCount -= 1 }

        if let gate {
            await gate.arriveAndWait()
        }
        if failsAllCalls {
            throw RuntimeOperationError.deviceWriteFailed
        }
        return RuntimeOperationDisplayResult(displayAwake: awake, changed: true)
    }

    func editorSnapshot() async throws -> RuntimeOperationEditorSnapshot {
        throw RuntimeOperationError.closed
    }

    func editorProfile(
        sourceDigest: String,
        profileID: String
    ) async throws -> RuntimeOperationEditorProfile {
        throw RuntimeOperationError.closed
    }

    func editorPositions(
        sourceDigest: String,
        profileID: String
    ) async throws -> RuntimeOperationEditorPositions {
        throw RuntimeOperationError.closed
    }

    func editorPosition(
        sourceDigest: String,
        profileID: String,
        positionID: String
    ) async throws -> RuntimeOperationEditorPosition {
        throw RuntimeOperationError.closed
    }

    func edit(
        expectedDigest: String,
        edit: RuntimeConfigurationEdit
    ) async throws -> RuntimeOperationEditResult {
        throw RuntimeOperationError.closed
    }

    func cloneProfile(
        expectedDigest: String,
        sourceProfileID: String?,
        profileID: String,
        label: String
    ) async throws -> RuntimeOperationEditResult {
        throw RuntimeOperationError.closed
    }

    func reloadConfiguration() async throws -> RuntimeOperationReloadResult {
        throw RuntimeOperationError.closed
    }

    func configurationStatus() async throws -> RuntimeOperationConfigurationStatus {
        throw RuntimeOperationError.closed
    }

    func retire() async {}
}

private actor DisplayOperationGate {
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
private final class FakeHostDisplayPowerObserver: HostDisplayPowerObserving {
    private(set) var lastKnownDisplayAwake: Bool?
    private let initialState: Bool?
    private let reconciliationState: Bool?
    private let initialError: String?
    private var stateHandler: HostDisplayPowerStateHandler?
    private var errorHandler: HostDisplayPowerErrorHandler?
    private(set) var reconciliationCount = 0
    private(set) var stopCount = 0

    init(
        initialState: Bool?,
        reconciliationState: Bool? = nil,
        initialError: String? = nil
    ) {
        self.initialState = initialState
        self.reconciliationState = reconciliationState
        self.initialError = initialError
    }

    func start(
        stateHandler: @escaping HostDisplayPowerStateHandler,
        errorHandler: @escaping HostDisplayPowerErrorHandler
    ) {
        self.stateHandler = stateHandler
        self.errorHandler = errorHandler
        if let initialError {
            errorHandler(initialError)
        }
        if let initialState {
            emit(initialState)
        }
    }

    func reconcileIfUnknown() {
        reconciliationCount += 1
        guard lastKnownDisplayAwake == nil, let reconciliationState else { return }
        emit(reconciliationState)
    }

    func stop() {
        stopCount += 1
        stateHandler = nil
        errorHandler = nil
    }

    func emit(_ displayAwake: Bool) {
        guard lastKnownDisplayAwake != displayAwake else { return }
        lastKnownDisplayAwake = displayAwake
        errorHandler?(nil)
        stateHandler?(displayAwake)
    }
}
