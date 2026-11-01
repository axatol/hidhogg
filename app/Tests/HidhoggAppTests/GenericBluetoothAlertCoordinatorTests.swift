import Foundation
import GenericBluetooth
import HidhoggDomain
import XCTest
@testable import HidhoggApp

@MainActor
final class GenericBluetoothAlertCoordinatorTests: XCTestCase {
    func testInclusiveThresholdBatchesComponentsAndPersistsIndependentEpisodes() async {
        let center = BluetoothAlertTestCenter()
        let latch = BluetoothAlertTestLatch()
        let coordinator = GenericBluetoothAlertCoordinator(notificationCenter: center, latchStore: latch)
        let device = registration()
        observe(coordinator, device, battery: BluetoothBattery(left: 10, right: 9, caseLevel: 60))
        await settle()
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertTrue(center.requests[0].body.contains("Left 10%, Right 9%"))
        XCTAssertTrue(latch.isLatched(device: device.id, component: .left))
        XCTAssertTrue(latch.isLatched(device: device.id, component: .right))
        observe(coordinator, device, battery: BluetoothBattery(left: 9, right: 8, caseLevel: 10))
        await settle()
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertTrue(center.requests[1].body.contains("Case 10%"))
        XCTAssertFalse(center.requests[1].body.contains("Left"))
        let relaunched = GenericBluetoothAlertCoordinator(notificationCenter: center, latchStore: latch)
        observe(relaunched, device, battery: BluetoothBattery(left: 9, right: 8, caseLevel: 10))
        await settle()
        XCTAssertEqual(center.requests.count, 2)
        observe(relaunched, device, battery: BluetoothBattery(left: 14, right: 15, caseLevel: 10))
        observe(relaunched, device, battery: BluetoothBattery(left: 10, right: 10, caseLevel: 10))
        await settle()
        XCTAssertEqual(center.requests.count, 3)
        XCTAssertTrue(center.requests[2].body.contains("Right 10%"))
        XCTAssertFalse(center.requests[2].body.contains("Left"))
    }

    func testUUIDsAreIndependentAndThresholdCeilingNeverRearmsWhileLow() async {
        let center = BluetoothAlertTestCenter()
        let coordinator = GenericBluetoothAlertCoordinator(notificationCenter: center, latchStore: BluetoothAlertTestLatch())
        let first = registration(threshold: 100), second = registration(threshold: 100)
        sync(coordinator, [first, second], Dictionary(uniqueKeysWithValues: [first, second].map {
            ($0.id, GenericBluetoothStatus(connection: .connected, battery: BluetoothBattery(main: 100), sampleID: UUID()))
        }))
        await settle()
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(Set(center.requests.map(\.identifier)).count, 2)
        sync(coordinator, [first, second], Dictionary(uniqueKeysWithValues: [first, second].map {
            ($0.id, GenericBluetoothStatus(connection: .connected, battery: BluetoothBattery(main: 100), sampleID: UUID()))
        }))
        await settle()
        XCTAssertEqual(center.requests.count, 2)
    }

    func testRetainedAndUnavailableSamplesCannotAlertOrRearm() async {
        let center = BluetoothAlertTestCenter()
        let latch = BluetoothAlertTestLatch()
        let coordinator = GenericBluetoothAlertCoordinator(notificationCenter: center, latchStore: latch)
        var device = registration(enabled: false)
        let sample = GenericBluetoothStatus(connection: .connected, battery: BluetoothBattery(main: 5), sampleID: UUID())
        sync(coordinator, [device], [device.id: sample])
        device.configuration = .genericBluetooth(GenericBluetoothConfiguration(endpoint: device.bluetoothConfiguration!.endpoint, lowBatteryAlertsEnabled: true))
        sync(coordinator, [device], [device.id: sample])
        await settle()
        XCTAssertTrue(center.requests.isEmpty)
        observe(coordinator, device, battery: BluetoothBattery(main: 5))
        await settle()
        XCTAssertEqual(center.requests.count, 1)
        var failed = GenericBluetoothStatus(connection: .connected, battery: BluetoothBattery(main: 80), failure: .reportFailed, sampleID: UUID())
        sync(coordinator, [device], [device.id: failed])
        XCTAssertTrue(latch.isLatched(device: device.id, component: .main))
        failed.failure = nil
        sync(coordinator, [device], [device.id: failed])
        observe(coordinator, device, battery: BluetoothBattery(main: 5))
        await settle()
        XCTAssertEqual(center.requests.count, 1)
    }

    func testFailedEnqueueRetriesOnlyOnNextAcceptedSample() async {
        let center = BluetoothAlertTestCenter()
        center.fails = true
        let coordinator = GenericBluetoothAlertCoordinator(notificationCenter: center, latchStore: BluetoothAlertTestLatch())
        let device = registration()
        let status = GenericBluetoothStatus(connection: .connected, battery: BluetoothBattery(main: 5), sampleID: UUID())
        sync(coordinator, [device], [device.id: status])
        await settle()
        center.fails = false
        sync(coordinator, [device], [device.id: status])
        await settle()
        XCTAssertEqual(center.requests.count, 1)
        observe(coordinator, device, battery: BluetoothBattery(main: 5))
        await settle()
        XCTAssertEqual(center.requests.count, 2)
    }

    func testLateEnqueueCannotLatchAfterLifecycleAuthorizationOrPreferenceChanges() async {
        for change in 0..<8 {
            let center = BluetoothAlertTestCenter()
            center.delayed = true
            let latch = BluetoothAlertTestLatch()
            let coordinator = GenericBluetoothAlertCoordinator(notificationCenter: center, latchStore: latch)
            var device = registration()
            observe(coordinator, device, battery: BluetoothBattery(main: 5))
            await settle()
            XCTAssertEqual(center.requests.count, 1)
            let status = GenericBluetoothStatus(connection: change == 1 ? .disconnected : .connected,
                battery: BluetoothBattery(main: change == 7 ? 80 : 5), sampleID: UUID())
            if change == 2 { device.isEnabled = false }
            if change == 3 { device.configuration = .genericBluetooth(GenericBluetoothConfiguration(endpoint: device.bluetoothConfiguration!.endpoint)) }
            if change == 6 { device.configuration = .genericBluetooth(GenericBluetoothConfiguration(endpoint: device.bluetoothConfiguration!.endpoint, lowBatteryAlertsEnabled: true, lowBatteryThreshold: 4)) }
            coordinator.synchronize(devices: change == 4 ? [] : [device], statuses: [device.id: status],
                authorization: change == 5 ? .denied : .authorized, suspended: change == 0, bluetoothAllowed: true)
            let removals = center.removed.count
            center.finish()
            await settle()
            XCTAssertFalse(latch.isLatched(device: device.id, component: .main), "change \(change)")
            XCTAssertGreaterThan(center.removed.count, removals)
        }
    }

    func testInvalidAndUnknownComponentsDoNotAlert() async {
        let center = BluetoothAlertTestCenter()
        let coordinator = GenericBluetoothAlertCoordinator(notificationCenter: center, latchStore: BluetoothAlertTestLatch())
        observe(coordinator, registration(), battery: BluetoothBattery(main: -1, left: 101))
        await settle()
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testIconOnlyEditPreservesDelayedAlertAndLatchesAcceptedEpisode() async {
        let center = BluetoothAlertTestCenter()
        center.delayed = true
        let latch = BluetoothAlertTestLatch()
        let coordinator = GenericBluetoothAlertCoordinator(notificationCenter: center, latchStore: latch)
        var device = registration()
        let status = GenericBluetoothStatus(connection: .connected, battery: BluetoothBattery(main: 5), sampleID: UUID())
        sync(coordinator, [device], [device.id: status])
        await center.waitForEnqueueStart()
        XCTAssertEqual(center.requests.count, 1)
        let removals = center.removed.count

        var configuration = device.bluetoothConfiguration!
        configuration.iconOverride = .glasses
        device.configuration = .genericBluetooth(configuration)
        sync(coordinator, [device], [device.id: status])
        XCTAssertEqual(center.removed.count, removals)

        center.finish()
        await settle()
        XCTAssertTrue(latch.isLatched(device: device.id, component: .main))
        XCTAssertEqual(center.removed.count, removals)
        center.delayed = false
        observe(coordinator, device, battery: BluetoothBattery(main: 5))
        await settle()
        XCTAssertEqual(center.requests.count, 1)
    }

    private func registration(enabled: Bool = true, threshold: Int = 10) -> RegisteredDevice {
        RegisteredDevice(displayName: "Synthetic device", configuration: .genericBluetooth(GenericBluetoothConfiguration(
            endpoint: BluetoothEndpoint(address: "AA:00:00:00:00:01")!, lowBatteryAlertsEnabled: enabled, lowBatteryThreshold: threshold)))
    }

    private func observe(_ coordinator: GenericBluetoothAlertCoordinator, _ device: RegisteredDevice,
                         battery: BluetoothBattery, others: [RegisteredDevice] = []) {
        sync(coordinator, [device] + others, [device.id: GenericBluetoothStatus(connection: .connected, battery: battery, sampleID: UUID())])
    }

    private func sync(_ coordinator: GenericBluetoothAlertCoordinator, _ devices: [RegisteredDevice], _ statuses: [UUID: GenericBluetoothStatus]) {
        coordinator.synchronize(devices: devices, statuses: statuses, authorization: .authorized, suspended: false, bluetoothAllowed: true)
    }

    private func settle() async { for _ in 0..<50 { await Task.yield() } }
}

@MainActor
private final class BluetoothAlertTestLatch: GenericBluetoothAlertLatchStore {
    private var values: Set<String> = []
    func isLatched(device: UUID, component: BluetoothBatteryComponent) -> Bool { values.contains("\(device).\(component)") }
    func setLatched(_ latched: Bool, device: UUID, component: BluetoothBatteryComponent) {
        let key = "\(device).\(component)"
        if latched { values.insert(key) } else { values.remove(key) }
    }
}

@MainActor
private final class BluetoothAlertTestCenter: LowBatteryNotificationCenterAdapter {
    enum Failure: Error { case enqueue }
    var requests: [LowBatteryNotificationRequest] = []
    var removed: [String] = []
    var fails = false
    var delayed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func authorizationStatus() async -> LowBatteryNotificationAuthorizationState { .authorized }
    func requestAlertAuthorization() async throws -> Bool { true }
    func enqueue(_ request: LowBatteryNotificationRequest) async throws {
        requests.append(request)
        if delayed {
            await withCheckedContinuation {
                continuation = $0
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        if fails { throw Failure.enqueue }
    }
    func removePendingRequest(identifier: String) { removed.append(identifier) }
    func waitForEnqueueStart() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
