import XCTest
import LogitechBolt
import MacOSActions
@testable import HidhoggApp

final class MenuBarStatusTests: XCTestCase {
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

    private func expectedIconColor(for status: MenuBarStatus) -> MenuBarIcon.StatusColor {
        switch status {
        case .connected: .connected
        case .permissionIncomplete: .permissionIncomplete
        case .connecting, .enablingBindings, .disconnecting: .transitioning
        case .disconnected: .disconnected
        case .failed, .cleanupUncertain: .failed
        }
    }
}
