import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class LowBatteryNotificationConfigurationTests: XCTestCase {
    func testOmittedPreferenceDefaultsToFalseAndIsWrittenWithoutSchemaBump() throws {
        let decoded = try ConfigurationCodec.decode(ConfigurationFixtures.data(ConfigurationFixtures.toml))
        let device = try XCTUnwrap(decoded.mouse)

        XCTAssertEqual(AppConfiguration.currentVersion, 1)
        XCTAssertFalse(device.lowBatteryNotificationsEnabled)

        let encoded = try ConfigurationCodec.encode(decoded)
        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(source.contains("schema_version = 1"))
        XCTAssertTrue(source.contains("low_battery_notifications_enabled = false"))
        XCTAssertEqual(try ConfigurationCodec.decode(encoded), decoded)
    }

    func testExplicitPreferenceRoundTripsBothValues() throws {
        for enabled in [false, true] {
            var configuration = ConfigurationFixtures.configuration
            configuration.devices[0].lowBatteryNotificationsEnabled = enabled

            let encoded = try ConfigurationCodec.encode(configuration)
            let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

            XCTAssertTrue(source.contains("low_battery_notifications_enabled = \(enabled)"))
            XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
        }
    }

    func testRejectsWrongTypedAndUnknownPreferenceKeys() {
        let wrongType = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nlow_battery_notifications_enabled = \"true\""
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(wrongType))) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
        }

        let unknownKey = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nlow_battery_notification_enabled = true"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("low_battery_notification_enabled"))
        }
    }
}
