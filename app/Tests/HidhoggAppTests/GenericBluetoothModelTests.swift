import Foundation
import GenericBluetooth
import HidhoggDomain
import XCTest
@testable import HidhoggApp

@MainActor
final class GenericBluetoothModelTests: XCTestCase {
    private let first = BluetoothEndpoint(address: "AA:00:00:00:00:01")!
    private let second = BluetoothEndpoint(address: "AA:00:00:00:00:02")!

    func testScheduledRefreshLimitsBatteryPublicationAndFallbackToEligibleRegistrations() async {
        let third = BluetoothEndpoint(address: "AA:00:00:00:00:03")!
        let fourth = BluetoothEndpoint(address: "AA:00:00:00:00:04")!
        let inventory = inventory()
        inventory.devices.append(PairedBluetoothDevice(endpoint: third, name: "Synthetic disconnected", isConnected: false))
        let initial = primaryData([primaryEntry(first, ["device_batteryLevelMain": 50]),
            primaryEntry(second, ["device_batteryLevelMain": 60]), primaryEntry(third, ["device_batteryLevelMain": 70])])
        let report = SyntheticBluetoothReport(results: [.success(initial), .success(data(11, nil)), .success(data(nil, nil))])
        let fallback = registryData([registryEntry(first, 12), registryEntry(second, 22), registryEntry(third, 32)])
        let registry = SyntheticBluetoothReport(results: [.success(fallback), .success(fallback)])
        let scheduler = SyntheticBluetoothCheckScheduler()
        let model = GenericBluetoothModel(inventory: inventory, report: report, registryReport: registry, scheduler: scheduler)
        let monitored = alertRegistration(first)
        let alertsOff = registration(second)
        let disconnected = alertRegistration(third)
        var disabled = alertRegistration(fourth)
        disabled.isEnabled = false
        model.synchronize([monitored, alertsOff, disconnected, disabled], suspended: false)
        await expect { !model.isRefreshing }
        let unchanged = [alertsOff, disconnected, disabled].map { model.status(for: $0.id) }

        scheduler.tick?()
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: monitored.id).battery?.main, 11)
        XCTAssertEqual([alertsOff, disconnected, disabled].map { model.status(for: $0.id) }, unchanged)
        let firstFallbackCount = await registry.count
        XCTAssertEqual(firstFallbackCount, 0)

        scheduler.tick?()
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: monitored.id).battery?.main, 12)
        XCTAssertEqual([alertsOff, disconnected, disabled].map { model.status(for: $0.id) }, unchanged)
        let secondFallbackCount = await registry.count
        XCTAssertEqual(secondFallbackCount, 1)
    }

    func testManualRefreshDuringScheduledReadRemainsFullDespiteLaterTicks() async {
        let report = SyntheticBluetoothReport(results: [.success(data(50, 60))])
        let scheduler = SyntheticBluetoothCheckScheduler()
        let model = GenericBluetoothModel(inventory: inventory(), report: report, scheduler: scheduler)
        let monitored = alertRegistration(first), alertsOff = registration(second)
        model.synchronize([monitored, alertsOff], suspended: false)
        await expect { !model.isRefreshing }
        let original = model.status(for: alertsOff.id)
        scheduler.tick?()
        await expect { await report.count == 2 }
        model.refresh()
        for _ in 0..<10 { scheduler.tick?() }
        await report.complete(.success(data(10, 20)))
        await expect { await report.count == 3 }
        XCTAssertEqual(model.status(for: alertsOff.id), original)
        await report.complete(.success(data(30, 40)))
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: alertsOff.id).battery?.main, 40)
        let count = await report.count, maximum = await report.maximumInFlight
        XCTAssertEqual(count, 3)
        XCTAssertEqual(maximum, 1)
    }

    func testScheduledFollowupToManualReadDoesNotRepublishAlertsOffRegistration() async {
        let report = SyntheticBluetoothReport(results: [.success(data(50, 60))])
        let scheduler = SyntheticBluetoothCheckScheduler()
        let model = GenericBluetoothModel(inventory: inventory(), report: report, scheduler: scheduler)
        let monitored = alertRegistration(first), alertsOff = registration(second)
        model.synchronize([monitored, alertsOff], suspended: false)
        await expect { !model.isRefreshing }
        model.refresh()
        await expect { await report.count == 2 }
        for _ in 0..<10 { scheduler.tick?() }
        await report.complete(.success(data(10, 20)))
        await expect { await report.count == 3 }
        let manualStatus = model.status(for: alertsOff.id)
        await report.complete(.success(data(30, 40)))
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: monitored.id).battery?.main, 30)
        XCTAssertEqual(model.status(for: alertsOff.id), manualStatus)
        let count = await report.count, maximum = await report.maximumInFlight
        XCTAssertEqual(count, 3)
        XCTAssertEqual(maximum, 1)
    }

    func testScheduledReadRechecksAlertPreferenceBeforeFallbackAndPublication() async {
        let report = SyntheticBluetoothReport(results: [.success(data(50, nil))])
        let registry = SyntheticBluetoothReport(results: [.success(registryData([registryEntry(first, 10)]))])
        let scheduler = SyntheticBluetoothCheckScheduler()
        let model = GenericBluetoothModel(inventory: inventory(), report: report, registryReport: registry, scheduler: scheduler)
        var monitored = alertRegistration(first)
        model.synchronize([monitored], suspended: false)
        await expect { !model.isRefreshing }
        let original = model.status(for: monitored.id)
        scheduler.tick?()
        await expect { await report.count == 2 }
        monitored.configuration = .genericBluetooth(first)
        model.synchronize([monitored], suspended: false)
        await report.complete(.success(data(nil, nil)))
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: monitored.id), original)
        let fallbackCount = await registry.count
        XCTAssertEqual(fallbackCount, 0)
        XCTAssertNil(scheduler.tick)
    }

    func testScheduledInventoryDisconnectStopsBeforeReadingBatteryReport() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport(results: [.success(data(50, nil))])
        let scheduler = SyntheticBluetoothCheckScheduler()
        let model = GenericBluetoothModel(inventory: inventory, report: report, scheduler: scheduler)
        let monitored = alertRegistration(first)
        model.synchronize([monitored], suspended: false)
        await expect { !model.isRefreshing }
        let sample = model.status(for: monitored.id).sampleID
        inventory.devices[0] = PairedBluetoothDevice(endpoint: first, name: "Synthetic", isConnected: false)
        scheduler.tick?()
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: monitored.id).connection, .disconnected)
        XCTAssertEqual(model.status(for: monitored.id).sampleID, sample)
        let count = await report.count
        XCTAssertEqual(count, 1)
        XCTAssertNil(scheduler.tick)
    }

    func testScheduledChecksRequireEnabledAlertsConnectedAwakeAndAllowedAccess() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport(results: [.success(data(10, 20))])
        let scheduler = SyntheticBluetoothCheckScheduler()
        let model = GenericBluetoothModel(inventory: inventory, report: report, scheduler: scheduler)
        var device = registration(first)
        model.synchronize([device], suspended: false)
        await expect { !model.isRefreshing }
        XCTAssertNil(scheduler.tick)
        device.configuration = .genericBluetooth(GenericBluetoothConfiguration(endpoint: first, lowBatteryAlertsEnabled: true))
        model.synchronize([device], suspended: false)
        XCTAssertEqual(scheduler.interval, 600)
        XCTAssertEqual(scheduler.starts, 1)
        for _ in 0..<20 { scheduler.tick?() }
        await expect { await report.count == 2 }
        await report.complete(.success(data(9, 20)))
        await expect { await report.count == 3 }
        await report.complete(.success(data(8, 20)))
        await expect { !model.isRefreshing }
        XCTAssertEqual(scheduler.starts, 1)
        let maximum = await report.maximumInFlight
        XCTAssertEqual(maximum, 1)
        model.synchronize([device], suspended: true)
        XCTAssertNil(scheduler.tick)
        model.synchronize([device], suspended: false)
        await expect { await report.count == 4 }
        await report.complete(.success(data(8, 20)))
        await expect { !model.isRefreshing }
        XCTAssertNotNil(scheduler.tick)
        inventory.access = .denied
        scheduler.tick?()
        XCTAssertNil(scheduler.tick)
        XCTAssertEqual(inventory.requestCount, 0)
    }

    func testDisconnectedAndDisabledRegistrationsStopSchedulerAndSuccessAloneAdvancesSample() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport(results: [.success(data(10, 20)), .failure(.timedOut), .success(data(10, 20))])
        let scheduler = SyntheticBluetoothCheckScheduler()
        let model = GenericBluetoothModel(inventory: inventory, report: report, scheduler: scheduler)
        var device = registration(first)
        device.configuration = .genericBluetooth(GenericBluetoothConfiguration(endpoint: first, lowBatteryAlertsEnabled: true))
        model.synchronize([device], suspended: false)
        await expect { !model.isRefreshing }
        let sample = model.status(for: device.id).sampleID
        XCTAssertNotNil(sample)
        model.refresh()
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: device.id).sampleID, sample)
        inventory.devices[0] = PairedBluetoothDevice(endpoint: first, name: "Synthetic", isConnected: false)
        model.refresh()
        await expect { !model.isRefreshing }
        XCTAssertNotEqual(model.status(for: device.id).sampleID, sample)
        XCTAssertNil(scheduler.tick)
        device.isEnabled = false
        model.synchronize([device], suspended: false)
        XCTAssertNil(scheduler.tick)
        model.synchronize([], suspended: false)
        XCTAssertNil(scheduler.tick)
    }

    func testConstructionAndUnapprovedResumeAreInert() async {
        let inventory = SyntheticBluetoothInventory()
        let report = SyntheticBluetoothReport()
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        model.synchronize([registration(first)], suspended: false)
        await settle()
        XCTAssertEqual(inventory.readCount, 0)
        XCTAssertEqual(inventory.requestCount, 0)
        let count = await report.count
        XCTAssertEqual(count, 0)
    }

    func testExplicitPermissionRowRequestsAccessWithoutInventoryOrReport() async {
        let inventory = SyntheticBluetoothInventory()
        inventory.delayPermission = true
        let report = SyntheticBluetoothReport()
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        model.requestAuthorization()
        await expect { inventory.requestCount == 1 }
        inventory.access = .allowed
        inventory.grantPermission()
        await expect { !model.isRequestingAccess }
        XCTAssertEqual(model.access, .allowed)
        XCTAssertEqual(inventory.readCount, 0)
        let count = await report.count
        XCTAssertEqual(count, 0)
    }

    func testAuthorizedResumeKeepsSameNameEntriesDistinctAndScopesEvents() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport(results: [.success(data(81, 23))])
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        let one = registration(first), two = registration(second)
        model.synchronize([one, two], suspended: false)
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: one.id).battery?.main, 81)
        XCTAssertEqual(model.status(for: two.id).battery?.main, 23)
        XCTAssertEqual(inventory.observed, [first, second])
        XCTAssertTrue(model.devices.isEmpty)
        inventory.emit(BluetoothEndpoint(address: "AA:00:00:00:00:03")!)
        await settle()
        let count = await report.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(inventory.requestCount, 0)
    }

    func testRegistryFallbackFillsMissingBatteryWithoutReplacingPrimaryComponents() async {
        let inventory = inventory()
        let primary = SyntheticBluetoothReport(results: [.success(primaryData([
            primaryEntry(first, ["device_batteryLevelMain": 55, "device_batteryLevelLeft": 65])
        ]))])
        let registry = SyntheticBluetoothReport(results: [.success(registryData([
            registryEntry(first, 99), registryEntry(second, 22)
        ]))])
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry)
        let one = registration(first), two = registration(second)
        model.synchronize([one, two], suspended: false)
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: one.id).battery, BluetoothBattery(main: 55, left: 65))
        XCTAssertEqual(model.status(for: two.id).battery, BluetoothBattery(main: 22))
        let registryReads = await registry.count
        XCTAssertEqual(registryReads, 1)
    }

    func testRegistryFallbackIsSkippedWhenEveryPrimaryBatteryIsUsable() async {
        let inventory = inventory()
        let primary = SyntheticBluetoothReport(results: [.success(data(10, 20))])
        let registry = SyntheticBluetoothReport(results: [.success(registryData([registryEntry(first, 30)]))])
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry)
        model.synchronize([registration(first), registration(second)], suspended: false)
        await expect { !model.isRefreshing }
        let registryReads = await registry.count
        XCTAssertEqual(registryReads, 0)
    }

    func testRegistryFallbackProvidesFreshBatteryWhenPrimaryReportFails() async {
        let inventory = inventory()
        let primary = SyntheticBluetoothReport(results: [.failure(.timedOut)])
        let registry = SyntheticBluetoothReport(results: [.success(registryData([
            registryEntry(first, 30), registryEntry(second, 40)
        ]))])
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry)
        let one = registration(first), two = registration(second)
        model.synchronize([one, two], suspended: false)
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: one.id).battery, BluetoothBattery(main: 30))
        XCTAssertEqual(model.status(for: one.id).failure, nil)
        XCTAssertEqual(model.status(for: two.id).battery, BluetoothBattery(main: 40))
        XCTAssertEqual(model.status(for: two.id).failure, nil)
    }

    func testPrimarySuccessRemainsFreshWhenFallbackFailsAndPriorFallbackIsStale() async {
        let inventory = inventory()
        let primaryFixture = primaryData([primaryEntry(first, ["device_batteryLevelMain": 50])])
        let primary = SyntheticBluetoothReport(results: [.success(primaryFixture), .success(primaryFixture)])
        let registry = SyntheticBluetoothReport(results: [
            .success(registryData([registryEntry(second, 30)])), .failure(.timedOut)
        ])
        var instant = Date(timeIntervalSince1970: 100)
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry, now: { instant })
        let one = registration(first), two = registration(second)
        model.synchronize([one, two], suspended: false)
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: two.id).battery, BluetoothBattery(main: 30))
        instant = Date(timeIntervalSince1970: 200)
        model.refresh()
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: one.id).battery, BluetoothBattery(main: 50))
        XCTAssertEqual(model.status(for: one.id).observedAt, instant)
        XCTAssertNil(model.status(for: one.id).failure)
        XCTAssertEqual(model.status(for: two.id).battery, BluetoothBattery(main: 30))
        XCTAssertEqual(model.status(for: two.id).observedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(model.status(for: two.id).failure, .timedOut)
        XCTAssertTrue(model.status(for: two.id).summary.contains("Earlier observation"))
    }

    func testMissingSourcesKeepPreviousBatteryAsStale() async {
        let inventory = inventory()
        let primaryFixture = primaryData([primaryEntry(first, ["device_batteryLevelMain": 50])])
        let primary = SyntheticBluetoothReport(results: [.success(primaryFixture), .success(primaryFixture)])
        let registry = SyntheticBluetoothReport(results: [
            .success(registryData([registryEntry(second, 30)])), .success(registryData([]))
        ])
        let instant = Date(timeIntervalSince1970: 100)
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry, now: { instant })
        let one = registration(first), two = registration(second)
        model.synchronize([one, two], suspended: false)
        await expect { !model.isRefreshing }
        model.refresh()
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: two.id).battery, BluetoothBattery(main: 30))
        XCTAssertEqual(model.status(for: two.id).observedAt, instant)
        XCTAssertEqual(model.status(for: two.id).failure, .batteryUnavailable)
        XCTAssertTrue(model.status(for: two.id).summary.contains("Earlier observation"))
    }

    func testDisablingOnlyMissingEntryBeforePrimaryCompletesSkipsRegistryFallback() async {
        let inventory = inventory()
        let primary = SyntheticBluetoothReport()
        let registry = SyntheticBluetoothReport(results: [.success(registryData([registryEntry(first, 40)]))])
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry)
        var one = registration(first)
        model.synchronize([one], suspended: false)
        await expect { await primary.count == 1 }
        one.isEnabled = false
        model.synchronize([one], suspended: false)
        await primary.complete(.success(data(nil, nil)))
        await settle()
        let registryReads = await registry.count
        XCTAssertEqual(registryReads, 0)
    }

    func testCanceledPrimaryReadSkipsRegistryFallback() async {
        let inventory = inventory()
        let primary = SyntheticBluetoothReport()
        let registry = SyntheticBluetoothReport(results: [.success(registryData([registryEntry(first, 40)]))])
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry)
        model.synchronize([registration(first)], suspended: false)
        await expect { await primary.count == 1 }
        model.stop()
        await primary.complete(.success(data(nil, nil)))
        await settle()
        let registryReads = await registry.count
        XCTAssertEqual(registryReads, 0)
    }

    func testPermissionRevokedAfterPrimaryReadSkipsRegistryFallback() async {
        let inventory = inventory()
        let primary = SyntheticBluetoothReport()
        let registry = SyntheticBluetoothReport(results: [.success(registryData([registryEntry(first, 40)]))])
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry)
        let one = registration(first)
        model.synchronize([one], suspended: false)
        await expect { await primary.count == 1 }
        inventory.access = .denied
        await primary.complete(.success(data(nil, nil)))
        await expect { !model.isRefreshing }
        let registryReads = await registry.count
        XCTAssertEqual(registryReads, 0)
        XCTAssertEqual(model.status(for: one.id).failure, .permissionRequired)
    }

    func testChangedRegistrationTokenBeforeFallbackSkipsOldEndpoint() async {
        let inventory = inventory()
        let primary = SyntheticBluetoothReport()
        let registry = SyntheticBluetoothReport(results: [.success(registryData([registryEntry(first, 40)]))])
        let model = GenericBluetoothModel(inventory: inventory, report: primary, registryReport: registry)
        model.synchronize([registration(first)], suspended: false)
        await expect { await primary.count == 1 }
        let replacement = registration(second)
        model.synchronize([replacement], suspended: false)
        await primary.complete(.success(data(nil, nil)))
        await expect { await primary.count == 2 }
        let registryReads = await registry.count
        XCTAssertEqual(registryReads, 0)
        await primary.complete(.success(data(10, 20)))
        await expect { !model.isRefreshing }
    }

    func testLateRegistryCompletionIsFencedAfterDisableRemoveSleepAndStop() async {
        let (disabledModel, disabledRegistration, disabledRegistry) = await pendingRegistryRead()
        var disabled = disabledRegistration
        disabled.isEnabled = false
        disabledModel.synchronize([disabled], suspended: false)
        await disabledRegistry.complete(.success(registryData([registryEntry(first, 70)])))
        await settle()
        XCTAssertEqual(disabledModel.status(for: disabled.id).connection, .disabled)
        XCTAssertNil(disabledModel.status(for: disabled.id).battery)

        let (removedModel, removedRegistration, removedRegistry) = await pendingRegistryRead()
        removedModel.synchronize([], suspended: false)
        await removedRegistry.complete(.success(registryData([registryEntry(first, 70)])))
        await settle()
        XCTAssertNil(removedModel.statuses[removedRegistration.id])

        let (sleepingModel, sleepingRegistration, sleepingRegistry) = await pendingRegistryRead()
        sleepingModel.synchronize([sleepingRegistration], suspended: true)
        await sleepingRegistry.complete(.success(registryData([registryEntry(first, 70)])))
        await settle()
        XCTAssertEqual(sleepingModel.status(for: sleepingRegistration.id).connection, .suspended)
        XCTAssertNil(sleepingModel.status(for: sleepingRegistration.id).battery)

        let (stoppedModel, stoppedRegistration, stoppedRegistry) = await pendingRegistryRead()
        let statusBeforeStop = stoppedModel.status(for: stoppedRegistration.id)
        stoppedModel.stop()
        await stoppedRegistry.complete(.success(registryData([registryEntry(first, 70)])))
        await settle()
        XCTAssertEqual(stoppedModel.status(for: stoppedRegistration.id), statusBeforeStop)
    }

    func testDiscoveryListsPairedInventoryAndClearsItOnDismissal() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport()
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        model.beginDiscovery()
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.devices.count, 2)
        XCTAssertTrue(model.canRegister(first))
        let count = await report.count
        XCTAssertEqual(count, 0)
        model.endDiscovery()
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertFalse(model.canRegister(first))
    }

    func testRefreshesCoalesceIntoOneInFlightAndOneFollowup() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport()
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        model.synchronize([registration(first)], suspended: false)
        await expect { await report.count == 1 }
        for _ in 0..<20 { model.refresh() }
        await report.complete(.success(data(1, 2)))
        await expect { await report.count == 2 }
        await report.complete(.success(data(3, 4)))
        await expect { !model.isRefreshing }
        let maximum = await report.maximumInFlight
        XCTAssertEqual(maximum, 1)
        let count = await report.count
        XCTAssertEqual(count, 2)
    }

    func testDisableAndRemoveFenceLateReportAndStopObservation() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport()
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        var one = registration(first)
        let two = registration(second)
        model.synchronize([one, two], suspended: false)
        await expect { await report.count == 1 }
        one.isEnabled = false
        model.synchronize([one], suspended: false)
        XCTAssertTrue(inventory.observed.isEmpty)
        await report.complete(.success(data(70, 40)))
        await settle()
        XCTAssertEqual(model.status(for: one.id).connection, .disabled)
        XCTAssertNil(model.status(for: one.id).battery)
        XCTAssertNil(model.statuses[two.id])
        XCTAssertFalse(model.isRefreshing)
    }

    func testDisableThenReenableRejectsEarlierEntryGeneration() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport()
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        var one = registration(first)
        let two = registration(second)
        model.synchronize([one, two], suspended: false)
        await expect { await report.count == 1 }
        one.isEnabled = false
        model.synchronize([one, two], suspended: false)
        XCTAssertEqual(inventory.observed, [second])
        one.isEnabled = true
        model.synchronize([one, two], suspended: false)
        await report.complete(.success(data(10, 20)))
        await expect { await report.count == 2 }
        XCTAssertNil(model.status(for: one.id).battery)
        XCTAssertEqual(model.status(for: two.id).battery?.main, 20)
        await report.complete(.success(data(30, 40)))
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: one.id).battery?.main, 30)
    }

    func testReportFailureRetainsEarlierReadingWithoutLosingConnectionAuthority() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport(results: [.success(data(50, 20)), .failure(.timedOut)])
        let instant = Date(timeIntervalSince1970: 100)
        let model = GenericBluetoothModel(inventory: inventory, report: report, now: { instant })
        let one = registration(first)
        model.synchronize([one], suspended: false)
        await expect { !model.isRefreshing }
        inventory.devices[0] = PairedBluetoothDevice(endpoint: first, name: "Same Name", isConnected: false)
        inventory.emit(first)
        await expect { !model.isRefreshing }
        let status = model.status(for: one.id)
        XCTAssertEqual(status.connection, .disconnected)
        XCTAssertEqual(status.battery?.main, 50)
        XCTAssertEqual(status.observedAt, instant)
        XCTAssertEqual(status.failure, .timedOut)
        XCTAssertTrue(status.summary.contains("Earlier observation"))
    }

    func testInventoryFailureKeepsEarlierObservationAndBlocksAdd() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport(results: [.success(data(50, 20))])
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        let one = registration(first)
        model.synchronize([one], suspended: false)
        await expect { !model.isRefreshing }
        model.beginDiscovery()
        await expect { model.devices.count == 2 }
        await report.complete(.success(data(50, 20)))
        await expect { !model.isRefreshing }
        inventory.failInventory = true
        model.discover()
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: one.id).connection, .connected)
        XCTAssertEqual(model.status(for: one.id).battery?.main, 50)
        XCTAssertEqual(model.discoveryFailure, .inventoryUnavailable)
        XCTAssertFalse(model.canRegister(second))
    }

    func testPermissionDeniedAndRevokedNeverPromptFromRefresh() async {
        let inventory = inventory()
        inventory.access = .denied
        let report = SyntheticBluetoothReport()
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        let one = registration(first)
        model.synchronize([one], suspended: false)
        model.refresh()
        await expect { !model.isRefreshing }
        XCTAssertEqual(inventory.readCount, 0)
        XCTAssertEqual(inventory.requestCount, 0)
        XCTAssertEqual(model.status(for: one.id).failure, .permissionRequired)
        inventory.access = .allowed
        model.refresh()
        await expect { await report.count == 1 }
        inventory.access = .denied
        await report.complete(.success(data(50, 20)))
        await expect { !model.isRefreshing }
        XCTAssertNil(model.status(for: one.id).battery)
        XCTAssertEqual(model.status(for: one.id).failure, .permissionRequired)
        XCTAssertTrue(inventory.observed.isEmpty)
    }

    func testSuspensionFencesLatePermissionAndAllowsFreshDiscovery() async {
        let inventory = inventory()
        inventory.access = .notDetermined
        inventory.delayPermission = true
        let model = GenericBluetoothModel(inventory: inventory, report: SyntheticBluetoothReport())
        model.beginDiscovery()
        model.discover()
        await expect { inventory.requestCount == 1 }
        model.synchronize([], suspended: true)
        await expect { inventory.cancelledPermissions == 1 }
        inventory.access = .allowed
        inventory.grantPermission()
        await settle()
        XCTAssertEqual(inventory.readCount, 0)
        XCTAssertTrue(model.devices.isEmpty)
        model.synchronize([], suspended: false)
        model.beginDiscovery()
        await expect { model.devices.count == 2 && !model.isRefreshing }
        model.endDiscovery()
    }

    func testAccessRecheckStopsRevokedMonitoringWithoutReportOrPrompt() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport(results: [.success(data(10, 20))])
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        let one = registration(first)
        model.synchronize([one], suspended: false)
        await expect { !model.isRefreshing }
        inventory.access = .denied
        model.recheckAccess()
        XCTAssertEqual(model.access, .denied)
        XCTAssertEqual(model.status(for: one.id).failure, .permissionRequired)
        XCTAssertNil(model.status(for: one.id).battery)
        XCTAssertTrue(inventory.observed.isEmpty)
        for _ in 0..<5 { model.recheckAccess() }
        let count = await report.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(inventory.requestCount, 0)
    }

    func testSleepSuspendsAndResumeReadsOnlyEnabledEntries() async {
        let inventory = inventory()
        let report = SyntheticBluetoothReport(results: [.success(data(10, 20)), .success(data(30, 40))])
        let model = GenericBluetoothModel(inventory: inventory, report: report)
        let one = registration(first)
        var two = registration(second)
        two.isEnabled = false
        model.synchronize([one, two], suspended: false)
        await expect { !model.isRefreshing }
        model.synchronize([one, two], suspended: true)
        model.refresh()
        XCTAssertEqual(model.status(for: one.id).connection, .suspended)
        XCTAssertTrue(inventory.observed.isEmpty)
        model.synchronize([one, two], suspended: false)
        await expect { !model.isRefreshing }
        XCTAssertEqual(model.status(for: one.id).battery?.main, 30)
        XCTAssertEqual(model.status(for: two.id).connection, .disabled)
        XCTAssertEqual(inventory.observed, [first])
    }

    private func registration(_ endpoint: BluetoothEndpoint) -> RegisteredDevice {
        RegisteredDevice(displayName: "Same Name", configuration: .genericBluetooth(endpoint))
    }

    private func alertRegistration(_ endpoint: BluetoothEndpoint) -> RegisteredDevice {
        RegisteredDevice(displayName: "Synthetic", configuration: .genericBluetooth(GenericBluetoothConfiguration(
            endpoint: endpoint, lowBatteryAlertsEnabled: true)))
    }

    private func inventory() -> SyntheticBluetoothInventory {
        let inventory = SyntheticBluetoothInventory()
        inventory.access = .allowed
        inventory.devices = [first, second].map { PairedBluetoothDevice(endpoint: $0, name: "Same Name", isConnected: true) }
        return inventory
    }

    private func pendingRegistryRead() async -> (GenericBluetoothModel, RegisteredDevice, SyntheticBluetoothReport) {
        let primary = SyntheticBluetoothReport(results: [.success(data(nil, nil))])
        let registry = SyntheticBluetoothReport()
        let model = GenericBluetoothModel(inventory: inventory(), report: primary, registryReport: registry)
        let registeredDevice = registration(first)
        model.synchronize([registeredDevice], suspended: false)
        await expect { await registry.count == 1 }
        return (model, registeredDevice, registry)
    }

    private func data(_ one: Int?, _ two: Int?) -> Data {
        let entries = zip([first, second], [one, two]).compactMap { endpoint, level -> [String: Any]? in
            guard let level else { return nil }
            return primaryEntry(endpoint, ["device_batteryLevelMain": level])
        }
        return primaryData(entries)
    }

    private func primaryData(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [["device_connected": entries]]])
    }

    private func primaryEntry(_ endpoint: BluetoothEndpoint, _ fields: [String: Any]) -> [String: Any] {
        ["Same Name": fields.merging(["device_address": endpoint.address]) { first, _ in first }]
    }

    private func registryData(_ entries: [[String: Any]]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }

    private func registryEntry(_ endpoint: BluetoothEndpoint, _ percent: Int) -> [String: Any] {
        ["DeviceAddress": endpoint.address, "BD_ADDR": Data([1, 2, 3, 4, 5, 6]), "BatteryPercent": percent]
    }

    private func wait(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private func expect(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () async -> Bool) async {
        let success = await wait(condition)
        XCTAssertTrue(success, file: file, line: line)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
private final class SyntheticBluetoothCheckScheduler: BluetoothCheckScheduling {
    var tick: (@MainActor @Sendable () -> Void)?
    var interval: TimeInterval?
    var starts = 0
    func start(every interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void) {
        starts += 1
        self.interval = interval
        self.tick = tick
    }
    func stop() { tick = nil }
}

@MainActor
final class SyntheticBluetoothInventory: PairedBluetoothInventory {
    var access: BluetoothAccess = .notDetermined
    var devices: [PairedBluetoothDevice] = []
    var requestCount = 0
    var readCount = 0
    var failInventory = false
    var delayPermission = false
    var cancelledPermissions = 0
    var observed: Set<BluetoothEndpoint> = []
    private var changed: (@MainActor @Sendable () -> Void)?
    private var permission: CheckedContinuation<BluetoothAccess, Never>?

    func requestAccess() async -> BluetoothAccess {
        requestCount += 1
        guard delayPermission else { return access }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { permission = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelledPermissions += 1
                self?.permission?.resume(returning: .notDetermined)
                self?.permission = nil
            }
        }
    }

    func grantPermission() { permission?.resume(returning: access); permission = nil }

    func pairedDevices() throws -> [PairedBluetoothDevice] {
        readCount += 1
        if failInventory { throw BluetoothObservationFailure.inventoryUnavailable }
        return devices
    }

    func observeChanges(for endpoints: Set<BluetoothEndpoint>, _ changed: @escaping @MainActor @Sendable () -> Void) {
        observed = endpoints
        self.changed = changed
    }

    func stopObserving() { observed = []; changed = nil }
    func emit(_ endpoint: BluetoothEndpoint) { if observed.contains(endpoint) { changed?() } }
}

actor SyntheticBluetoothReport: BluetoothReportReading {
    var count = 0
    var maximumInFlight = 0
    private var inFlight = 0
    private var results: [Result<Data, BluetoothObservationFailure>]
    private var pending: CheckedContinuation<Data, any Error>?

    init(results: [Result<Data, BluetoothObservationFailure>] = []) { self.results = results }

    func read() async throws -> Data {
        count += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if !results.isEmpty { return try results.removeFirst().get() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    func complete(_ result: Result<Data, BluetoothObservationFailure>) {
        if let pending { self.pending = nil; pending.resume(with: result.mapError { $0 as any Error }) }
        else { results.append(result) }
    }
}
