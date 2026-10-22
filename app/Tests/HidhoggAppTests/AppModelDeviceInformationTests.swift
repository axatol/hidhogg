import Foundation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class AppModelDeviceInformationTests: XCTestCase {
    func testAutomaticRefreshRunsOncePerConnectionAndManualRefreshRequiresConnection() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = DeviceInformationBindingSession()
        let model = makeModel(url: url, session: session)

        model.refreshDeviceInformation()
        try await Task.sleep(for: .milliseconds(20))
        let disconnectedRefreshCount = await session.informationRefreshCount
        XCTAssertEqual(disconnectedRefreshCount, 0)

        model.connect()
        let firstRead = await eventually {
            guard model.boltStatus.phase == .ready else { return false }
            return await session.informationRefreshCount == 1
        }
        XCTAssertTrue(firstRead)

        await session.emitStatus(.enabled, advancingGeneration: true)
        await session.emitStatus(.ready, advancingGeneration: true)
        try await Task.sleep(for: .milliseconds(20))
        let repeatedStatusReadCount = await session.informationRefreshCount
        XCTAssertEqual(repeatedStatusReadCount, 1)

        model.refreshDeviceInformation()
        let manualRead = await eventually { await session.informationRefreshCount == 2 }
        XCTAssertTrue(manualRead)

        model.disconnect()
        let disconnected = await eventually { model.boltStatus.phase == .idle }
        XCTAssertTrue(disconnected)
        model.refreshDeviceInformation()
        try await Task.sleep(for: .milliseconds(20))
        let afterOfflineRefreshCount = await session.informationRefreshCount
        XCTAssertEqual(afterOfflineRefreshCount, 2)

        model.connect()
        let secondConnectionRead = await eventually {
            guard model.boltStatus.phase == .ready else { return false }
            return await session.informationRefreshCount == 3
        }
        XCTAssertTrue(secondConnectionRead)
    }

    func testSavedAlertPreferenceSynchronizesWithoutPromptOrAutomaticPost() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var configuration = AppConfiguration.empty
        configuration.devices[0].lowBatteryNotificationsEnabled = true
        try ConfigurationCodec.encode(configuration).write(to: url)

        let session = DeviceInformationBindingSession(
            information: .init(
                batteryState: .available,
                battery: .init(percentage: 5, charging: .discharging, observedAt: .now)
            )
        )
        let center = DeviceInformationNotificationCenter()
        let notifications = LowBatteryNotificationController(
            notificationCenter: center,
            latchStore: DeviceInformationAlertLatchStore()
        )
        let model = makeModel(url: url, session: session, notifications: notifications, loadImmediately: true)

        let loaded = await eventually {
            !model.isLoading && notifications.isEnabled &&
                notifications.authorizationState == .notDetermined
        }
        XCTAssertTrue(loaded)

        let connected = await eventually {
            guard model.boltStatus.phase == .ready else { return false }
            return await session.informationRefreshCount == 1
        }
        XCTAssertTrue(connected)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(center.enqueuedRequests.count, 0)
    }

    func testPresentationSuppressesStaleInformationWhenDisconnected() {
        let staleInformation = BoltDeviceInformation(
            batteryState: .available,
            firmwareState: .available,
            battery: .init(percentage: 4, charging: .discharging, observedAt: .now),
            firmware: [.init(type: 1, prefix: "ABC", rawVersion: 0x1234, rawBuild: 0x5678, flags: 0)]
        )
        let disconnected = DeviceInformationPresentation(status: makeStatus(.idle, information: staleInformation))

        XCTAssertEqual(disconnected.batteryText, "Unavailable")
        XCTAssertEqual(disconnected.firmwareStateText, "Unavailable")

        let unknownCharging = BoltDeviceInformation(
            batteryState: .available,
            battery: .init(percentage: nil, charging: .unknown(7), observedAt: .now)
        )
        let connected = DeviceInformationPresentation(status: makeStatus(.ready, information: unknownCharging))
        XCTAssertEqual(connected.batteryText, "Percentage unavailable · Charging state unknown")
    }

    private func makeModel(
        url: URL,
        session: DeviceInformationBindingSession,
        notifications: LowBatteryNotificationController? = nil,
        loadImmediately: Bool = false
    ) -> AppModel {
        AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in }),
            lowBatteryNotifications: notifications,
            loadImmediately: loadImmediately,
            observeSleep: false
        )
    }

    private func makeStatus(_ phase: BoltPhase, information: BoltDeviceInformation) -> BoltStatus {
        BoltStatus(
            phase: phase,
            message: "Fixture status",
            availableControls: [],
            generation: 1,
            cleanupUncertain: false,
            deviceInformation: information
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-device-information-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

private actor DeviceInformationBindingSession: BindingSession {
    nonisolated let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private var generation: UInt64 = 0
    private var informationRefreshes = 0
    private let information: BoltDeviceInformation

    init(information: BoltDeviceInformation = .init()) {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        self.information = information
    }

    var informationRefreshCount: Int { informationRefreshes }

    func discover() async {
        generation &+= 1
        continuation.yield(.status(status(.discovering)))
        continuation.yield(.status(status(.ready)))
    }

    func refreshDeviceInformation() async {
        informationRefreshes += 1
    }

    nonisolated func withPressAdmission(
        generation requestedGeneration: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }

    func enable() async {
        await emitStatus(.enabled, advancingGeneration: true)
    }

    func disable() async {
        await emitStatus(.ready, advancingGeneration: true)
    }

    func stop() async {
        await emitStatus(.idle, advancingGeneration: true)
    }

    func emitStatus(_ phase: BoltPhase, advancingGeneration: Bool) async {
        if advancingGeneration { generation &+= 1 }
        continuation.yield(.status(status(phase)))
    }

    private func status(_ phase: BoltPhase) -> BoltStatus {
        BoltStatus(
            phase: phase,
            message: "Fixture status",
            availableControls: [],
            generation: generation,
            cleanupUncertain: false,
            deviceInformation: information
        )
    }
}

@MainActor
private final class DeviceInformationNotificationCenter: LowBatteryNotificationCenterAdapter {
    private(set) var authorizationRequestCount = 0
    private(set) var enqueuedRequests: [LowBatteryNotificationRequest] = []

    func authorizationStatus() async -> LowBatteryNotificationAuthorizationState { .notDetermined }

    func requestAlertAuthorization() async throws -> Bool {
        authorizationRequestCount += 1
        return true
    }

    func enqueue(_ request: LowBatteryNotificationRequest) async throws {
        enqueuedRequests.append(request)
    }

    func removePendingRequest(identifier: String) {}
}

@MainActor
private final class DeviceInformationAlertLatchStore: LowBatteryAlertLatchStore {
    private(set) var isLatched = false

    func setLatched(_ value: Bool) {
        isLatched = value
    }
}
