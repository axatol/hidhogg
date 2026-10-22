import XCTest
@testable import HidhoggApp

@MainActor
final class LowBatteryNotificationControllerTests: XCTestCase {
    func testPolicyRequiresFreshKnownUnpluggedAuthorizedLowReading() {
        let authorized = LowBatteryNotificationAuthorizationState.authorized

        XCTAssertTrue(LowBatteryAlertPolicy.shouldAlert(
            percentage: 9, charging: false, isFresh: true, isEnabled: true,
            authorizationState: authorized, isLatched: false
        ))
        XCTAssertFalse(shouldAlert(percentage: 10, charging: false))
        XCTAssertFalse(shouldAlert(percentage: 9, charging: false, isFresh: false))
        XCTAssertFalse(shouldAlert(percentage: 9, charging: true))
        XCTAssertFalse(shouldAlert(percentage: 9, charging: nil))
        XCTAssertFalse(shouldAlert(percentage: nil, charging: false))
        XCTAssertFalse(shouldAlert(percentage: -1, charging: false))
        XCTAssertFalse(shouldAlert(percentage: 101, charging: false))
        XCTAssertFalse(shouldAlert(percentage: 9, charging: false, isEnabled: false))
        XCTAssertFalse(shouldAlert(percentage: 9, charging: false, isLatched: true))
        XCTAssertFalse(shouldAlert(
            percentage: 9, charging: false,
            authorizationState: .notDetermined
        ))
        XCTAssertTrue(shouldAlert(
            percentage: 9, charging: false,
            authorizationState: .provisional
        ))
    }

    func testRearmRequiresFreshValidatedTwentyPercentReading() {
        XCTAssertFalse(LowBatteryAlertPolicy.shouldRearm(percentage: nil, isFresh: true))
        XCTAssertFalse(LowBatteryAlertPolicy.shouldRearm(percentage: -1, isFresh: true))
        XCTAssertFalse(LowBatteryAlertPolicy.shouldRearm(percentage: 101, isFresh: true))
        XCTAssertFalse(LowBatteryAlertPolicy.shouldRearm(percentage: 20, isFresh: false))
        XCTAssertFalse(LowBatteryAlertPolicy.shouldRearm(percentage: 19, isFresh: true))
        XCTAssertTrue(LowBatteryAlertPolicy.shouldRearm(percentage: 20, isFresh: true))
    }

    func testPreferenceSyncAndAuthorizationRefreshNeverPrompt() async {
        let center = FakeLowBatteryNotificationCenter(status: .notDetermined)
        let controller = makeController(center: center)

        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()
        await controller.observe(percentage: 5, charging: false, isFresh: true)

        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(center.enqueueRequests.count, 0)
        XCTAssertEqual(controller.authorizationState, .notDetermined)

        await controller.setEnabled(true)

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(controller.authorizationState, .authorized)
    }

    func testDeniedAuthorizationIsVisibleAndDoesNotRetryPrompt() async {
        let center = FakeLowBatteryNotificationCenter(status: .denied)
        let controller = makeController(center: center)

        await controller.refreshAuthorization()
        await controller.setEnabled(true)
        await controller.observe(percentage: 4, charging: false, isFresh: true)

        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(center.enqueueRequests.count, 0)
        XCTAssertEqual(controller.authorizationState, .denied)
        XCTAssertTrue(controller.error?.contains("disabled") == true)
    }

    func testConcurrentEnableRequestsShareOneAuthorizationPrompt() async {
        let center = FakeLowBatteryNotificationCenter(status: .notDetermined)
        center.holdAuthorizationRequest = true
        let controller = makeController(center: center)
        let enable = Task { @MainActor in await controller.setEnabled(true) }

        let authorizationStarted = await eventually { center.authorizationRequestCount == 1 }
        XCTAssertTrue(authorizationStarted)
        await controller.setEnabled(true)
        XCTAssertEqual(center.authorizationRequestCount, 1)

        center.resumeAuthorizationRequest()
        await enable.value

        XCTAssertEqual(controller.authorizationState, .authorized)
    }

    func testAuthorizationRequestFailureIsVisible() async {
        let center = FakeLowBatteryNotificationCenter(status: .notDetermined)
        center.authorizationError = NotificationFailure(message: "Request failed.")
        let controller = makeController(center: center)

        await controller.setEnabled(true)

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(controller.authorizationState, .notDetermined)
        XCTAssertTrue(controller.authorizationError?.contains("Request failed.") == true)
    }

    func testAlertLatchesAfterSuccessfulEnqueueAndRearmsAtTwenty() async {
        let center = FakeLowBatteryNotificationCenter(status: .authorized)
        let latch = FakeLowBatteryAlertLatchStore()
        let controller = makeController(center: center, latch: latch)
        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()

        await controller.observe(percentage: 9, charging: false, isFresh: true)
        await controller.observe(percentage: 3, charging: false, isFresh: true)

        XCTAssertEqual(center.enqueueRequests.count, 1)
        XCTAssertTrue(latch.isLatched)
        XCTAssertEqual(center.enqueueRequests[0].identifier, LowBatteryNotificationController.notificationIdentifier)
        XCTAssertEqual(center.enqueueRequests[0].title, "Mouse battery low")
        XCTAssertTrue(center.enqueueRequests[0].body.contains("9%"))
        XCTAssertTrue(center.enqueueRequests[0].body.contains("MX Master 3S"))

        await controller.observe(percentage: 19, charging: true, isFresh: true)
        XCTAssertTrue(latch.isLatched)
        await controller.observe(percentage: 20, charging: nil, isFresh: true)
        XCTAssertFalse(latch.isLatched)
        await controller.observe(percentage: 8, charging: false, isFresh: true)

        XCTAssertEqual(center.enqueueRequests.count, 2)
        XCTAssertTrue(latch.isLatched)
    }

    func testLatchSurvivesControllerRestartAndUnknownReadsDoNotRearm() async {
        let center = FakeLowBatteryNotificationCenter(status: .authorized)
        let persistedLatch = FakeLowBatteryAlertLatchStore(isLatched: true)
        let controller = makeController(center: center, latch: persistedLatch)
        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()

        await controller.observe(percentage: nil, charging: nil, isFresh: true)
        await controller.observe(percentage: 20, charging: nil, isFresh: false)
        await controller.observe(percentage: 8, charging: nil, isFresh: true)

        XCTAssertTrue(persistedLatch.isLatched)
        XCTAssertEqual(center.enqueueRequests.count, 0)

        let restartedController = makeController(center: center, latch: persistedLatch)
        restartedController.synchronizeEnabled(true)
        await restartedController.refreshAuthorization()
        await restartedController.observe(percentage: 8, charging: false, isFresh: true)

        XCTAssertTrue(persistedLatch.isLatched)
        XCTAssertEqual(center.enqueueRequests.count, 0)
    }

    func testChargingOrUnknownChargingDoesNotAlertOrClearLatch() async {
        let center = FakeLowBatteryNotificationCenter(status: .authorized)
        let latch = FakeLowBatteryAlertLatchStore(isLatched: true)
        let controller = makeController(center: center, latch: latch)
        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()

        await controller.observe(percentage: 9, charging: true, isFresh: true)
        await controller.observe(percentage: 9, charging: nil, isFresh: true)

        XCTAssertTrue(latch.isLatched)
        XCTAssertEqual(center.enqueueRequests.count, 0)
    }

    func testFailedEnqueueDoesNotLatchAndCanRetry() async {
        let center = FakeLowBatteryNotificationCenter(status: .authorized)
        center.enqueueError = NotificationFailure(message: "Queue failed.")
        let latch = FakeLowBatteryAlertLatchStore()
        let controller = makeController(center: center, latch: latch)
        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()

        await controller.observe(percentage: 7, charging: false, isFresh: true)

        XCTAssertFalse(latch.isLatched)
        XCTAssertTrue(controller.error?.contains("Queue failed.") == true)

        center.enqueueError = nil
        await controller.observe(percentage: 6, charging: false, isFresh: true)

        XCTAssertEqual(center.enqueueRequests.count, 2)
        XCTAssertTrue(latch.isLatched)
    }

    func testPendingEnqueueCannotRemainAfterDisableAndReenable() async {
        let center = FakeLowBatteryNotificationCenter(status: .authorized)
        center.holdEnqueue = true
        let latch = FakeLowBatteryAlertLatchStore()
        let controller = makeController(center: center, latch: latch)
        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()
        let observation = Task { @MainActor in
            await controller.observe(percentage: 5, charging: false, isFresh: true)
        }

        let enqueueStarted = await eventually { center.enqueueRequests.count == 1 }
        XCTAssertTrue(enqueueStarted)
        controller.synchronizeEnabled(false)
        controller.synchronizeEnabled(true)
        await controller.observe(percentage: 5, charging: false, isFresh: true)

        center.resumeEnqueue()
        await observation.value

        XCTAssertFalse(latch.isLatched)
        XCTAssertGreaterThanOrEqual(center.removedRequestIdentifiers.count, 2)

        center.holdEnqueue = false
        await controller.observe(percentage: 5, charging: false, isFresh: true)
        XCTAssertTrue(latch.isLatched)
    }

    func testConcurrentLowReadingsEnqueueOnlyOnce() async {
        let center = FakeLowBatteryNotificationCenter(status: .authorized)
        center.holdEnqueue = true
        let latch = FakeLowBatteryAlertLatchStore()
        let controller = makeController(center: center, latch: latch)
        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()
        let first = Task { @MainActor in await controller.observe(percentage: 7, charging: false, isFresh: true) }

        let enqueueStarted = await eventually { center.enqueueRequests.count == 1 }
        XCTAssertTrue(enqueueStarted)
        let second = Task { @MainActor in await controller.observe(percentage: 5, charging: false, isFresh: true) }
        await second.value
        XCTAssertEqual(center.enqueueRequests.count, 1)

        center.resumeEnqueue()
        await first.value
        XCTAssertEqual(center.enqueueRequests.count, 1)
        XCTAssertTrue(latch.isLatched)
    }

    func testNewerChargingStaleOrRecoveredObservationInvalidatesPendingLowAlert() async {
        let center = FakeLowBatteryNotificationCenter(status: .authorized)
        let latch = FakeLowBatteryAlertLatchStore()
        let controller = makeController(center: center, latch: latch)
        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()

        await controller.observe(percentage: 8, charging: false, isFresh: true)
        XCTAssertTrue(latch.isLatched)
        await controller.observe(percentage: 20, charging: nil, isFresh: true)
        XCTAssertFalse(latch.isLatched)

        center.holdEnqueue = true
        let pendingAlert = Task { @MainActor in
            await controller.observe(percentage: 7, charging: false, isFresh: true)
        }
        let enqueueStarted = await eventually { center.enqueueRequests.count == 2 }
        XCTAssertTrue(enqueueStarted)

        await controller.observe(percentage: 7, charging: true, isFresh: true)
        await controller.observe(percentage: 7, charging: false, isFresh: false)
        await controller.observe(percentage: 20, charging: nil, isFresh: true)
        XCTAssertFalse(latch.isLatched)

        center.resumeEnqueue()
        await pendingAlert.value
        XCTAssertFalse(latch.isLatched)
        XCTAssertGreaterThanOrEqual(center.removedRequestIdentifiers.count, 4)

        center.holdEnqueue = false
        await controller.observe(percentage: 8, charging: false, isFresh: true)
        XCTAssertTrue(latch.isLatched)
        XCTAssertEqual(center.enqueueRequests.count, 3)
    }

    func testLowReadingAfterRecoveryWaitsForReplacementEnqueueBeforeLatching() async {
        let center = FakeLowBatteryNotificationCenter(status: .authorized)
        center.holdEnqueue = true
        let latch = FakeLowBatteryAlertLatchStore()
        let controller = makeController(center: center, latch: latch)
        controller.synchronizeEnabled(true)
        await controller.refreshAuthorization()
        let firstAlert = Task { @MainActor in
            await controller.observe(percentage: 5, charging: false, isFresh: true)
        }

        let firstEnqueueStarted = await eventually { center.enqueueRequests.count == 1 }
        XCTAssertTrue(firstEnqueueStarted)
        await controller.observe(percentage: 20, charging: nil, isFresh: true)
        await controller.observe(percentage: 8, charging: false, isFresh: true)
        XCTAssertFalse(latch.isLatched)

        center.resumeEnqueue()
        let replacementEnqueueStarted = await eventually { center.enqueueRequests.count == 2 }
        XCTAssertTrue(replacementEnqueueStarted)
        XCTAssertFalse(latch.isLatched)
        XCTAssertTrue(center.enqueueRequests[1].body.contains("8%"))

        center.resumeEnqueue()
        await firstAlert.value

        XCTAssertTrue(latch.isLatched)
        XCTAssertEqual(center.enqueueRequests.count, 2)
    }

    private func shouldAlert(
        percentage: Int?,
        charging: Bool?,
        isFresh: Bool = true,
        isEnabled: Bool = true,
        authorizationState: LowBatteryNotificationAuthorizationState = .authorized,
        isLatched: Bool = false
    ) -> Bool {
        LowBatteryAlertPolicy.shouldAlert(
            percentage: percentage,
            charging: charging,
            isFresh: isFresh,
            isEnabled: isEnabled,
            authorizationState: authorizationState,
            isLatched: isLatched
        )
    }

    private func makeController(
        center: FakeLowBatteryNotificationCenter,
        latch: FakeLowBatteryAlertLatchStore = FakeLowBatteryAlertLatchStore()
    ) -> LowBatteryNotificationController {
        LowBatteryNotificationController(notificationCenter: center, latchStore: latch)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

@MainActor
private final class FakeLowBatteryNotificationCenter: LowBatteryNotificationCenterAdapter {
    var status: LowBatteryNotificationAuthorizationState
    var authorizationRequestCount = 0
    var enqueueRequests: [LowBatteryNotificationRequest] = []
    var removedRequestIdentifiers: [String] = []
    var requestResult: LowBatteryNotificationAuthorizationState = .authorized
    var authorizationError: Error?
    var enqueueError: Error?
    var holdAuthorizationRequest = false
    var holdEnqueue = false

    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var enqueueContinuation: CheckedContinuation<Void, Never>?

    init(status: LowBatteryNotificationAuthorizationState) {
        self.status = status
    }

    func authorizationStatus() async -> LowBatteryNotificationAuthorizationState {
        status
    }

    func requestAlertAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        if holdAuthorizationRequest {
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
            }
        }
        if let authorizationError { throw authorizationError }
        status = requestResult
        return status.allowsAlerts
    }

    func enqueue(_ request: LowBatteryNotificationRequest) async throws {
        enqueueRequests.append(request)
        if holdEnqueue {
            await withCheckedContinuation { continuation in
                enqueueContinuation = continuation
            }
        }
        if let enqueueError { throw enqueueError }
    }

    func removePendingRequest(identifier: String) {
        removedRequestIdentifiers.append(identifier)
    }

    func resumeAuthorizationRequest() {
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume()
    }

    func resumeEnqueue() {
        let continuation = enqueueContinuation
        enqueueContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class FakeLowBatteryAlertLatchStore: LowBatteryAlertLatchStore {
    private(set) var isLatched: Bool

    init(isLatched: Bool = false) {
        self.isLatched = isLatched
    }

    func setLatched(_ value: Bool) {
        isLatched = value
    }
}

private struct NotificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
