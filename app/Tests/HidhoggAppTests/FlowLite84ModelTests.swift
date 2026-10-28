import Foundation
import HidhoggDomain
import LofreeFlowLite84
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class FlowLite84ModelTests: XCTestCase {
    func testDefaultModelDoesNotCreateLiveSessionForConnect() {
        let model = FlowLite84Model()

        XCTAssertEqual(model.status, .disconnected)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.connectionRequested)
        XCTAssertFalse(model.isBusy)

        model.connect()

        XCTAssertEqual(model.status, .failed(.unavailable))
        XCTAssertEqual(model.errorMessage, "Flow Lite84 receiver session is unavailable.")
        XCTAssertFalse(model.connectionRequested)
        XCTAssertFalse(model.isConnected)
    }

    func testExplicitConnectAndManualRefreshNeedNoConfigurationOrInputPermission() async {
        let firstRead = snapshot(battery: FlowLite84Battery(reportedLevel: 52, charging: false, voltageMillivolts: 3975))
        let refreshedRead = snapshot(battery: FlowLite84Battery(reportedLevel: 51, charging: true, voltageMillivolts: 3960))
        let session = FixtureFlowLite84Session(snapshot: firstRead, refreshedSnapshot: refreshedRead)
        let model = FlowLite84Model(session: session)

        model.connect()

        let connected = await eventually { model.isConnected && model.snapshot == firstRead && !model.isBusy }
        XCTAssertTrue(connected)
        let connectionCount = await session.connectionCount()
        let initialRefreshCount = await session.refreshCount()
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(initialRefreshCount, 0)
        XCTAssertTrue(model.isKeyboardOnline)
        XCTAssertEqual(model.batteryText, "Reported level 52 · Not charging")

        model.refresh()

        let refreshed = await eventually { model.snapshot == refreshedRead && !model.isRefreshing }
        XCTAssertTrue(refreshed)
        let refreshCount = await session.refreshCount()
        XCTAssertEqual(refreshCount, 1)
        let batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)
        await model.stop()
    }

    func testConnectOnLaunchSkipsUnavailableSessionAndRespectsExplicitDisconnect() async {
        let unavailableModel = FlowLite84Model()
        unavailableModel.connectOnLaunch()
        XCTAssertEqual(unavailableModel.status, .disconnected)
        XCTAssertFalse(unavailableModel.connectionRequested)

        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let model = FlowLite84Model(session: session)
        model.disconnect()
        model.connectOnLaunch()

        XCTAssertFalse(model.connectionRequested)
        let connectionCount = await session.connectionCount()
        XCTAssertEqual(connectionCount, 0)
        await model.stop()
    }

    func testKeyboardActivityRefreshesBatteryOnlyAfterAnHourWithoutIdlePolling() async {
        let initialRead = snapshot(battery: FlowLite84Battery(reportedLevel: 62, charging: false, voltageMillivolts: 3990))
        let refreshedRead = snapshot(battery: FlowLite84Battery(reportedLevel: 61, charging: true, voltageMillivolts: 3970))
        let session = FixtureFlowLite84Session(snapshot: initialRead, refreshedSnapshot: refreshedRead)
        let monitor = FixtureKeyboardActivityMonitor()
        var now = ContinuousClock().now
        let model = FlowLite84Model(
            session: session,
            keyboardActivityMonitor: monitor,
            monotonicNow: { now }
        )
        model.connect()

        let connected = await eventually {
            model.isConnected && model.snapshot == initialRead && monitor.startCount == 1
        }
        XCTAssertTrue(connected)

        try? await Task.sleep(for: .milliseconds(10))
        var batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)

        monitor.sendActivity()
        batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)

        now = now.advanced(by: .seconds(3_599))
        monitor.sendActivity()
        batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)

        now = now.advanced(by: .seconds(1))
        monitor.sendActivity()
        let refreshed = await eventually {
            let batteryRefreshCount = await session.batteryRefreshCount()
            return batteryRefreshCount == 1 && !model.isBusy
        }
        XCTAssertTrue(refreshed)
        let refreshCount = await session.refreshCount()
        XCTAssertEqual(refreshCount, 0)

        monitor.sendActivity()
        batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 1)
        await model.stop()
    }

    func testFailedAutomaticBatteryRefreshIsClaimedForAnHour() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot(), failBatteryRefresh: true)
        let monitor = FixtureKeyboardActivityMonitor()
        var now = ContinuousClock().now
        let model = FlowLite84Model(
            session: session,
            keyboardActivityMonitor: monitor,
            monotonicNow: { now }
        )
        model.connect()
        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)

        now = now.advanced(by: .seconds(3_600))
        monitor.sendActivity()
        let failedAttempt = await eventually {
            let batteryRefreshCount = await session.batteryRefreshCount()
            return batteryRefreshCount == 1 && !model.isBusy && model.errorMessage != nil
        }
        XCTAssertTrue(failedAttempt)

        monitor.sendActivity()
        var batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 1)
        now = now.advanced(by: .seconds(3_599))
        monitor.sendActivity()
        batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 1)
        now = now.advanced(by: .seconds(1))
        monitor.sendActivity()
        let secondAttempt = await eventually {
            await session.batteryRefreshCount() == 2 && !model.isBusy
        }
        XCTAssertTrue(secondAttempt)
        await model.stop()
    }

    func testKeyboardActivityMonitorFollowsConnectionLifecycle() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let monitor = FixtureKeyboardActivityMonitor()
        let model = FlowLite84Model(session: session, keyboardActivityMonitor: monitor)
        model.connect()

        let initiallyMonitoring = await eventually { model.isConnected && monitor.startCount == 1 }
        XCTAssertTrue(initiallyMonitoring)

        model.sleep()
        let stoppedForSleep = await eventually { monitor.stopCount == 1 && !model.isConnected }
        XCTAssertTrue(stoppedForSleep)
        monitor.sendActivity()
        let batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)

        model.wake()
        let resumedAfterWake = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 2 && model.isConnected && monitor.startCount == 2
        }
        XCTAssertTrue(resumedAfterWake)

        model.setSuspended(true)
        let stoppedForSuspension = await eventually { monitor.stopCount == 2 && !model.isConnected }
        XCTAssertTrue(stoppedForSuspension)
        model.setSuspended(false)
        let resumedAfterSuspension = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 3 && model.isConnected && monitor.startCount == 3
        }
        XCTAssertTrue(resumedAfterSuspension)

        model.disconnect()
        let stoppedForDisconnect = await eventually { monitor.stopCount == 3 && !model.isConnected }
        XCTAssertTrue(stoppedForDisconnect)
        await model.stop()
    }

    func testDeinitRemovesKeyboardActivityMonitor() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let monitor = FixtureKeyboardActivityMonitor()
        var model: FlowLite84Model? = FlowLite84Model(
            session: session,
            keyboardActivityMonitor: monitor
        )
        model?.connect()

        let connected = await eventually {
            model?.isConnected == true && monitor.startCount == 1
        }
        XCTAssertTrue(connected)

        model = nil

        XCTAssertEqual(monitor.stopCount, 1)
    }

    func testOlderGenerationCannotReplaceCurrentStatusOrSnapshot() async {
        let originalRead = snapshot(online: true, at: Date(timeIntervalSince1970: 100))
        let session = FixtureFlowLite84Session(snapshot: originalRead)
        let model = FlowLite84Model(session: session)
        model.connect()

        let connected = await eventually { model.isConnected && model.snapshot == originalRead }
        XCTAssertTrue(connected)

        await session.emit(.status(.connecting, generation: 2))
        let reconnecting = await eventually {
            if case .connecting = model.status { true } else { false }
        }
        XCTAssertTrue(reconnecting)

        let staleRead = snapshot(online: false, at: Date(timeIntervalSince1970: 200))
        await session.emit(.status(.disconnected, generation: 1))
        await session.emit(.snapshot(staleRead, generation: 1))
        await session.emit(.status(.connected(identity()), generation: 2))

        let currentGenerationAccepted = await eventually {
            model.isConnected && model.snapshot == originalRead
        }
        XCTAssertTrue(currentGenerationAccepted)
        XCTAssertNotEqual(model.snapshot, staleRead)
        await model.stop()
    }

    func testOfflineKeyboardAndUnavailableFieldsRemainExplicit() async {
        let offlineRead = snapshot(online: false)
        let session = FixtureFlowLite84Session(snapshot: offlineRead)
        let model = FlowLite84Model(session: session)
        model.connect()

        let readArrived = await eventually { model.isConnected && model.snapshot == offlineRead }
        XCTAssertTrue(readArrived)
        XCTAssertFalse(model.isKeyboardOnline)
        XCTAssertEqual(model.batteryText, "Unavailable")
        await model.stop()
    }

    func testSleepReleasesHandleAndWakeReconnectsOnlyWhileRequested() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let model = FlowLite84Model(session: session)
        model.connect()

        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)

        model.sleep()
        XCTAssertTrue(model.connectionRequested)
        let released = await eventually {
            let disconnectCount = await session.disconnectCount()
            return disconnectCount == 1 && !model.isConnected
        }
        XCTAssertTrue(released)

        model.wake()
        let reconnected = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 2 && model.isConnected
        }
        XCTAssertTrue(reconnected)

        model.disconnect()
        let disconnected = await eventually { !model.connectionRequested && !model.isConnected }
        XCTAssertTrue(disconnected)
        model.sleep()
        model.wake()
        let connectionCountAfterWake = await session.connectionCount()
        XCTAssertEqual(connectionCountAfterWake, 2)
        await model.stop()
    }

    func testSleepCancelsPendingConnectAndRefreshBeforeDisconnecting() async {
        let pausedConnectSession = FixtureFlowLite84Session(snapshot: snapshot(), pauseConnect: true)
        let connectingModel = FlowLite84Model(session: pausedConnectSession)
        connectingModel.connect()

        let connectStarted = await eventually {
            let connectionCount = await pausedConnectSession.connectionCount()
            return connectionCount == 1 && connectingModel.connectionTitle == "Connecting"
        }
        XCTAssertTrue(connectStarted)
        connectingModel.sleep()
        let connectReleased = await eventually {
            let disconnectCount = await pausedConnectSession.disconnectCount()
            let cancelledCount = await pausedConnectSession.cancelledConnectCount()
            return disconnectCount == 1 && cancelledCount == 1 && !connectingModel.isConnected
        }
        XCTAssertTrue(connectReleased)

        let pausedRefreshSession = FixtureFlowLite84Session(snapshot: snapshot(), pauseRefresh: true)
        let monitor = FixtureKeyboardActivityMonitor()
        var now = ContinuousClock().now
        let refreshingModel = FlowLite84Model(
            session: pausedRefreshSession,
            keyboardActivityMonitor: monitor,
            monotonicNow: { now }
        )
        refreshingModel.connect()
        let connected = await eventually { refreshingModel.isConnected && !refreshingModel.isBusy }
        XCTAssertTrue(connected)
        now = now.advanced(by: .seconds(3_600))
        refreshingModel.refresh()
        let refreshStarted = await eventually {
            let refreshCount = await pausedRefreshSession.refreshCount()
            return refreshCount == 1 && refreshingModel.isRefreshing
        }
        XCTAssertTrue(refreshStarted)
        monitor.sendActivity()
        let batteryRefreshCount = await pausedRefreshSession.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)
        refreshingModel.sleep()
        let refreshReleased = await eventually {
            let disconnectCount = await pausedRefreshSession.disconnectCount()
            let cancelledCount = await pausedRefreshSession.cancelledRefreshCount()
            return disconnectCount == 1 && cancelledCount == 1 && !refreshingModel.isConnected && monitor.stopCount == 1
        }
        XCTAssertTrue(refreshReleased)
        await connectingModel.stop()
        await refreshingModel.stop()
    }

    func testSuspensionReleasesAndResumesOnlyAnRequestedConnection() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let model = FlowLite84Model(session: session)
        model.connect()
        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)

        model.setSuspended(true)
        XCTAssertTrue(model.connectionRequested)
        let released = await eventually {
            let disconnectCount = await session.disconnectCount()
            return disconnectCount == 1 && !model.isConnected
        }
        XCTAssertTrue(released)

        model.setSuspended(false)
        let resumed = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 2 && model.isConnected
        }
        XCTAssertTrue(resumed)
        await model.stop()
    }

    func testStopClearsConnectionIntentAndPreventsWakeReconnect() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let monitor = FixtureKeyboardActivityMonitor()
        let model = FlowLite84Model(session: session, keyboardActivityMonitor: monitor)
        model.connect()

        let connected = await eventually { model.isConnected && monitor.startCount == 1 }
        XCTAssertTrue(connected)
        await model.stop()
        XCTAssertEqual(monitor.stopCount, 1)
        monitor.sendActivity()
        model.wake()

        let connectionCount = await session.connectionCount()
        let batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertFalse(model.connectionRequested)
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(batteryRefreshCount, 0)
    }

    private func snapshot(
        online: Bool = true,
        battery: FlowLite84Battery? = nil,
        lighting: FlowLite84Lighting? = nil,
        systemMode: UInt8? = nil,
        at readAt: Date = Date(timeIntervalSince1970: 100)
    ) -> FlowLite84Snapshot {
        FlowLite84Snapshot(
            identity: identity(),
            online: online,
            battery: battery,
            lighting: lighting,
            systemMode: systemMode,
            readAt: readAt
        )
    }

    private func identity() -> FlowLite84Identity {
        FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)
    }

    private func eventually(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await predicate()
    }
}

private actor FixtureFlowLite84Session: FlowLite84SessionProtocol {
    nonisolated let events: AsyncStream<FlowLite84Event>
    private let continuation: AsyncStream<FlowLite84Event>.Continuation
    private let snapshot: FlowLite84Snapshot?
    private let refreshedSnapshot: FlowLite84Snapshot?
    private let pauseConnect: Bool
    private let pauseRefresh: Bool
    private let failBatteryRefresh: Bool
    private var generation: UInt64 = 0
    private var connects = 0
    private var disconnects = 0
    private var refreshes = 0
    private var batteryRefreshes = 0
    private var cancelledConnects = 0
    private var cancelledRefreshes = 0

    init(
        snapshot: FlowLite84Snapshot?,
        refreshedSnapshot: FlowLite84Snapshot? = nil,
        pauseConnect: Bool = false,
        pauseRefresh: Bool = false,
        failBatteryRefresh: Bool = false
    ) {
        let stream = AsyncStream<FlowLite84Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        self.snapshot = snapshot
        self.refreshedSnapshot = refreshedSnapshot
        self.pauseConnect = pauseConnect
        self.pauseRefresh = pauseRefresh
        self.failBatteryRefresh = failBatteryRefresh
    }

    func connect() async throws {
        connects += 1
        generation &+= 1
        continuation.yield(.status(.connecting, generation: generation))
        if pauseConnect {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancelledConnects += 1
                throw error
            }
        }
        continuation.yield(.status(.connected(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)), generation: generation))
        if let snapshot {
            continuation.yield(.snapshot(snapshot, generation: generation))
        }
    }

    func refresh() async throws {
        refreshes += 1
        if pauseRefresh {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancelledRefreshes += 1
                throw error
            }
        }
        if let refreshedSnapshot {
            continuation.yield(.snapshot(refreshedSnapshot, generation: generation))
        }
    }

    func refreshBattery() async throws {
        batteryRefreshes += 1
        if failBatteryRefresh { throw FixtureFailure.failed }
        if let refreshedSnapshot {
            continuation.yield(.snapshot(refreshedSnapshot, generation: generation))
        }
    }

    func disconnect() async {
        disconnects += 1
        continuation.yield(.status(.disconnected, generation: generation))
    }

    func emit(_ event: FlowLite84Event) {
        continuation.yield(event)
    }

    func connectionCount() -> Int { connects }
    func disconnectCount() -> Int { disconnects }
    func refreshCount() -> Int { refreshes }
    func batteryRefreshCount() -> Int { batteryRefreshes }
    func cancelledConnectCount() -> Int { cancelledConnects }
    func cancelledRefreshCount() -> Int { cancelledRefreshes }
}

@MainActor
private final class FixtureKeyboardActivityMonitor: KeyboardActivityMonitoring {
    private var onActivity: (@MainActor () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onActivity: @escaping @MainActor () -> Void) {
        startCount += 1
        self.onActivity = onActivity
    }

    func stop() {
        guard onActivity != nil else { return }
        stopCount += 1
        onActivity = nil
    }

    func sendActivity() {
        onActivity?()
    }
}

private enum FixtureFailure: Error {
    case failed
}
