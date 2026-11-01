import XCTest
import GenericBluetooth
import HidhoggDomain
import LofreeFlowLite84
import LogitechBolt
import MacOSActions
@testable import HidhoggApp

final class MenuBarStatusTests: XCTestCase {
    func testManagedDeviceAggregationHasNoPhantomDisconnectedMouse() {
        XCTAssertEqual(MenuBarStatus(managedDevices: []), .disconnected)
        XCTAssertEqual(MenuBarStatus(managedDevices: [.connected]), .connected)
        XCTAssertEqual(MenuBarStatus(managedDevices: [.connected, .disconnected]), .connected)
        XCTAssertEqual(MenuBarStatus(managedDevices: [.permissionIncomplete, .connected]), .permissionIncomplete)
        XCTAssertEqual(MenuBarStatus(managedDevices: [.failed, .connected]), .failed)
        XCTAssertEqual(MenuBarStatus(managedDevices: [.cleanupUncertain, .connected]), .cleanupUncertain)
    }

    func testAdditionalDevicePreservesWarningsAndHealthyConnection() {
        XCTAssertEqual(MenuBarStatus(base: .connected, additional: nil), .connected)
        XCTAssertEqual(MenuBarStatus(base: .connected, additional: .disconnected), .connected)
        XCTAssertEqual(MenuBarStatus(base: .disconnected, additional: .connected), .connected)
        XCTAssertEqual(MenuBarStatus(base: .disconnected, additional: .disconnected), .disconnected)
        XCTAssertEqual(MenuBarStatus(base: .permissionIncomplete, additional: .connected), .permissionIncomplete)
        XCTAssertEqual(MenuBarStatus(base: .cleanupUncertain, additional: .connected), .cleanupUncertain)
        XCTAssertEqual(MenuBarStatus(base: .connecting, additional: .failed), .failed)
        XCTAssertEqual(MenuBarStatus(base: .connected, additional: .connecting), .connected)
        XCTAssertEqual(MenuBarStatus(base: .disconnected, additional: .connecting), .connecting)
    }

    func testManagedDeviceAggregationIsOrderIndependent() {
        let statuses: [MenuBarStatus] = [.connected, .disconnected, .connecting, .permissionIncomplete]
        for ordering in permutations(statuses) {
            XCTAssertEqual(MenuBarStatus(managedDevices: ordering), .permissionIncomplete)
        }

        let connectedAndTransitioning: [MenuBarStatus] = [.connected, .disconnected, .connecting]
        for ordering in permutations(connectedAndTransitioning) {
            XCTAssertEqual(MenuBarStatus(managedDevices: ordering), .connected)
        }

        let permissionWarnings: [MenuBarStatus] = [.permissionIncomplete, .bluetoothPermissionIncomplete]
        for ordering in permutations(permissionWarnings) {
            XCTAssertEqual(MenuBarStatus(managedDevices: ordering), .permissionIncomplete)
        }
    }

    func testSummaryDisplaysConnectedOverEnabledDeviceCount() {
        let devices = (0..<5).map { _ in RegisteredDevice(configuration: .flowLite84) }
        let states = Dictionary(uniqueKeysWithValues: zip(devices.map(\.id), [
            MenuBarDeviceState(status: .connected, isConnected: true),
            MenuBarDeviceState(status: .connected, isConnected: true),
            MenuBarDeviceState(status: .connected, isConnected: true),
            MenuBarDeviceState(status: .enablingBindings, isConnected: true),
            MenuBarDeviceState(status: .disconnected, isConnected: false)
        ]))

        let summary = MenuBarDeviceSummary(registeredDevices: devices, statuses: states)

        XCTAssertEqual(summary.connectedCount, 4)
        XCTAssertEqual(summary.enabledCount, 5)
        XCTAssertEqual(summary.countLabel, "4/5")
        XCTAssertEqual(summary.accessibilityDescription, "4 of 5 enabled devices connected")
        XCTAssertEqual(summary.status, .connected)
    }

    func testSummaryExcludesDisabledAndUnregisteredStatusEntries() {
        let activeDevices = (0..<3).map { _ in RegisteredDevice(configuration: .flowLite84) }
        let disabledDevice = RegisteredDevice(isEnabled: false, configuration: .flowLite84)
        var states = Dictionary(uniqueKeysWithValues: zip(activeDevices.map(\.id), [
            MenuBarDeviceState(status: .connected, isConnected: true),
            MenuBarDeviceState(status: .connected, isConnected: true),
            MenuBarDeviceState(status: .disconnected, isConnected: false)
        ]))
        states[disabledDevice.id] = MenuBarDeviceState(status: .connected, isConnected: true)
        states[UUID()] = MenuBarDeviceState(status: .connected, isConnected: true)

        let summary = MenuBarDeviceSummary(
            registeredDevices: activeDevices + [disabledDevice],
            statuses: states
        )

        XCTAssertEqual(summary.connectedCount, 2)
        XCTAssertEqual(summary.enabledCount, 3)
        XCTAssertEqual(summary.countLabel, "2/3")
        XCTAssertEqual(summary.status, .connected)
    }

    func testSummaryWithNoEnabledDevicesIsNeutral() {
        let devices = [
            RegisteredDevice(isEnabled: false, configuration: .flowLite84),
            RegisteredDevice(isEnabled: false, configuration: .flowLite84)
        ]
        let states = Dictionary(uniqueKeysWithValues: zip(devices.map(\.id), [
            MenuBarDeviceState(status: .connected, isConnected: true),
            MenuBarDeviceState(status: .failed, isConnected: false)
        ]))

        let summary = MenuBarDeviceSummary(registeredDevices: devices, statuses: states)

        XCTAssertEqual(summary.countLabel, "0/0")
        XCTAssertEqual(summary.status, .disconnected)
        XCTAssertEqual(summary.status.iconColor, .disconnected)
    }

    func testGenericBluetoothBatteryUnavailableDoesNotFailConnectedDevice() {
        let status = GenericBluetoothStatus(connection: .connected, failure: .batteryUnavailable)
        let state = MenuBarDeviceState(genericBluetooth: status)

        XCTAssertEqual(state.status, .connected)
        XCTAssertTrue(state.isConnected)
    }

    func testGenericBluetoothErrorsRemainVisibleWhileNoDataAndCancellationFollowConnection() {
        let connectedFailure = GenericBluetoothStatus(connection: .connected, failure: .reportFailed)
        let permissionFailure = GenericBluetoothStatus(connection: .unavailable, failure: .permissionRequired)
        let unpaired = GenericBluetoothStatus(connection: .notPaired)
        let unavailable = GenericBluetoothStatus(connection: .unavailable, failure: .batteryUnavailable)
        let connectedCancellation = GenericBluetoothStatus(connection: .connected, failure: .cancelled)
        let disconnectedCancellation = GenericBluetoothStatus(connection: .disconnected, failure: .cancelled)
        let realFailures: [BluetoothObservationFailure] = [
            .inventoryUnavailable, .unsupportedReport, .reportFailed, .timedOut, .outputLimit
        ]
        let connections: [GenericBluetoothStatus.Connection] = [
            .connected, .disconnected, .notPaired, .unavailable
        ]

        XCTAssertEqual(MenuBarStatus(genericBluetooth: connectedFailure), .failed)
        XCTAssertEqual(MenuBarStatus(genericBluetooth: permissionFailure), .bluetoothPermissionIncomplete)
        XCTAssertEqual(MenuBarStatus(genericBluetooth: unpaired), .disconnected)
        XCTAssertEqual(MenuBarStatus(genericBluetooth: unavailable), .disconnected)
        XCTAssertEqual(MenuBarStatus(genericBluetooth: connectedCancellation), .connected)
        XCTAssertEqual(MenuBarStatus(genericBluetooth: disconnectedCancellation), .disconnected)

        for failure in realFailures {
            for connection in connections {
                let status = GenericBluetoothStatus(connection: connection, failure: failure)
                XCTAssertEqual(MenuBarStatus(genericBluetooth: status), .failed, "failure=\(failure), connection=\(connection)")
            }
        }
    }

    func testSummaryCountsConnectedDevicesWhenPermissionOrFailureStatusIsSurfaced() {
        let devices = (0..<3).map { _ in RegisteredDevice(configuration: .flowLite84) }
        let incompletePermissions = PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: false)
        let states = Dictionary(uniqueKeysWithValues: zip(devices.map(\.id), [
            MenuBarDeviceState(mousePhase: .ready, cleanupUncertain: false, permissionChecks: incompletePermissions),
            MenuBarDeviceState(genericBluetooth: GenericBluetoothStatus(connection: .connected, failure: .reportFailed)),
            MenuBarDeviceState(status: .disconnected, isConnected: false)
        ]))

        let summary = MenuBarDeviceSummary(registeredDevices: devices, statuses: states)

        XCTAssertEqual(summary.connectedCount, 2)
        XCTAssertEqual(summary.enabledCount, 3)
        XCTAssertEqual(summary.status, .failed)
    }

    func testMouseCountsPhysicalConnectionDuringPermissionAndBindingTransitions() {
        let incompletePermissions = PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: false)
        let ready = MenuBarDeviceState(mousePhase: .ready, cleanupUncertain: false, permissionChecks: incompletePermissions)
        let enabling = MenuBarDeviceState(
            mousePhase: .enabling,
            cleanupUncertain: false,
            permissionChecks: PermissionChecks(accessibilityTrusted: true, eventPostingAllowed: true)
        )

        XCTAssertEqual(ready.status, .permissionIncomplete)
        XCTAssertTrue(ready.isConnected)
        XCTAssertEqual(enabling.status, .enablingBindings)
        XCTAssertTrue(enabling.isConnected)
    }

    func testFlowLiteConnectionRequiresKeyboardOnline() {
        let identity = FlowLite84Identity(cid: 0, mid: 0, connectionType: 0)
        let receiverConnected = MenuBarDeviceState(
            flowLiteStatus: .connected(identity),
            isKeyboardOnline: false
        )
        let keyboardOnline = MenuBarDeviceState(
            flowLiteStatus: .connected(identity),
            isKeyboardOnline: true
        )

        XCTAssertEqual(receiverConnected.status, .disconnected)
        XCTAssertFalse(receiverConnected.isConnected)
        XCTAssertEqual(keyboardOnline.status, .connected)
        XCTAssertTrue(keyboardOnline.isConnected)
    }

    func testEveryPhaseAndPermissionCombinationMapsToExpectedStatusAndColor() {
        let permissionCombinations = [
            PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: false),
            PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: true),
            PermissionChecks(accessibilityTrusted: true, eventPostingAllowed: false),
            PermissionChecks(accessibilityTrusted: true, eventPostingAllowed: true)
        ]
        let phases: [BoltPhase] = [.idle, .discovering, .ready, .enabling, .enabled, .stopping, .failed]

        for phase in phases {
            for permissions in permissionCombinations {
                let hasBothPermissions = permissions.accessibilityTrusted && permissions.eventPostingAllowed
                let expected: MenuBarStatus
                switch phase {
                case .idle: expected = .disconnected
                case .discovering: expected = .connecting
                case .ready, .enabled: expected = hasBothPermissions ? .connected : .permissionIncomplete
                case .enabling: expected = .enablingBindings
                case .stopping: expected = .disconnecting
                case .failed: expected = .failed
                }
                let status = MenuBarStatus(phase: phase, cleanupUncertain: false, permissionChecks: permissions)
                XCTAssertEqual(status, expected, "phase=\(phase), permissions=\(permissions)")
                XCTAssertEqual(status.iconColor, expectedIconColor(for: expected))

                let cleanupStatus = MenuBarStatus(phase: phase, cleanupUncertain: true, permissionChecks: permissions)
                XCTAssertEqual(cleanupStatus, .cleanupUncertain)
                XCTAssertEqual(cleanupStatus.iconColor, .failed)
            }
        }
    }

    func testAccessibleLabelsExplainIncompleteInputPermissions() {
        XCTAssertEqual(MenuBarStatus.connected.accessibilityLabel, "Hidhogg, Connected")
        XCTAssertEqual(MenuBarStatus.connecting.accessibilityLabel, "Hidhogg, Connecting")
        XCTAssertEqual(MenuBarStatus.enablingBindings.accessibilityLabel, "Hidhogg, Enabling bindings")
        XCTAssertEqual(MenuBarStatus.disconnecting.accessibilityLabel, "Hidhogg, Disconnecting")
        XCTAssertEqual(MenuBarStatus.disconnected.accessibilityLabel, "Hidhogg, Disconnected")
        XCTAssertEqual(MenuBarStatus.failed.accessibilityLabel, "Hidhogg, Failed")
        XCTAssertEqual(MenuBarStatus.cleanupUncertain.accessibilityLabel, "Hidhogg, Cleanup uncertain")

        let warning = MenuBarStatus.permissionIncomplete.accessibilityLabel
        XCTAssertTrue(warning.contains("Accessibility trust"))
        XCTAssertTrue(warning.contains("event posting access"))
        XCTAssertEqual(MenuBarStatus.permissionIncomplete.iconColor, .permissionIncomplete)
    }

    func testBluetoothPermissionLabelNamesItsOwnPermission() {
        let label = MenuBarStatus.bluetoothPermissionIncomplete.accessibilityLabel

        XCTAssertTrue(label.contains("Bluetooth"))
        XCTAssertFalse(label.contains("Accessibility"))
        XCTAssertEqual(MenuBarStatus.bluetoothPermissionIncomplete.iconColor, .permissionIncomplete)
    }

    private func expectedIconColor(for status: MenuBarStatus) -> MenuBarIcon.StatusColor {
        switch status {
        case .connected: .connected
        case .permissionIncomplete, .bluetoothPermissionIncomplete, .partiallyConnected: .permissionIncomplete
        case .connecting, .enablingBindings, .disconnecting: .transitioning
        case .disconnected: .disconnected
        case .failed, .cleanupUncertain: .failed
        }
    }

    private func permutations<Value>(_ values: [Value]) -> [[Value]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index in
            var remaining = values
            let next = remaining.remove(at: index)
            return permutations(remaining).map { [next] + $0 }
        }
    }
}
