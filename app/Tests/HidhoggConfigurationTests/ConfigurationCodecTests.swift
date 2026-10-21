import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class ConfigurationCodecTests: XCTestCase {
    func testDecodesDefaultsAndExplicitDisabledOverride() throws {
        let configuration = try ConfigurationCodec.decode(ConfigurationFixtures.data(ConfigurationFixtures.toml))
        let device = try XCTUnwrap(configuration.mouse)

        XCTAssertTrue(configuration.connectOnLaunch)
        XCTAssertFalse(device.restorePreviousSettingsOnDisconnect)
        XCTAssertNil(device.wheelHighResolution)
        XCTAssertNil(device.wheelScrollAmount)
        XCTAssertNil(device.thumbwheelInverted)
        XCTAssertNil(device.thumbwheelScrollAmount)
        XCTAssertEqual(device.binding(for: .back, application: nil), .key(
            KeyboardShortcut(keyCode: 4, modifiers: [.command, .shift])
        ))
        XCTAssertEqual(device.binding(for: .back, application: "com.example.Other"), .key(
            KeyboardShortcut(keyCode: 4, modifiers: [.command, .shift])
        ))
        XCTAssertEqual(device.binding(for: .back, application: "com.example.Editor_ID"), .disabled)
        XCTAssertEqual(device.binding(for: .forward, application: "com.example.Editor_ID"), .disabled)
    }

    func testRoundTripUsesSortedSnakeCaseAndPreservesApplicationIdentifiers() throws {
        let first = try ConfigurationCodec.encode(ConfigurationFixtures.configuration)
        let second = try ConfigurationCodec.encode(ConfigurationFixtures.configuration)
        let source = try XCTUnwrap(String(data: first, encoding: .utf8))

        XCTAssertEqual(first, second)
        XCTAssertTrue(source.contains("schema_version = 1"))
        XCTAssertTrue(source.contains("connect_on_launch = true"))
        XCTAssertTrue(source.contains("key_code = 4"))
        XCTAssertTrue(source.contains("com.example.Editor_ID"))
        XCTAssertFalse(source.contains("wheel_inverted"))
        XCTAssertFalse(source.contains("thumbwheel_inverted"))
        XCTAssertFalse(source.contains("thumbwheel_scroll_amount"))
        XCTAssertEqual(try ConfigurationCodec.decode(first), ConfigurationFixtures.configuration)
    }

    func testConnectOnLaunchPreferenceRoundTripsExplicitFalse() throws {
        var configuration = ConfigurationFixtures.configuration
        configuration.connectOnLaunch = false

        let encoded = try ConfigurationCodec.encode(configuration)
        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(source.contains("connect_on_launch = false"))
        XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
    }

    func testRejectsWrongTypedAndUnknownRootConnectKeys() {
        let wrongType = ConfigurationFixtures.toml.replacingOccurrences(
            of: "schema_version = 1",
            with: "schema_version = 1\nconnect_on_launch = \"true\""
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(wrongType))) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
        }

        let unknownKey = ConfigurationFixtures.toml.replacingOccurrences(
            of: "schema_version = 1",
            with: "schema_version = 1\nconnect_automatically = false"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("connect_automatically"))
        }
    }

    func testWheelInversionIntentRoundTripsAndOmitsUnmanagedValue() throws {
        let intents: [Bool?] = [nil, false, true]

        for intent in intents {
            var configuration = ConfigurationFixtures.configuration
            configuration.devices[0].wheelInverted = intent

            let encoded = try ConfigurationCodec.encode(configuration)
            let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

            if let intent {
                XCTAssertTrue(source.contains("wheel_inverted = \(intent)"))
            } else {
                XCTAssertFalse(source.contains("wheel_inverted"))
            }
            XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
        }
    }

    func testWheelHighResolutionIntentRoundTripsAndOmitsUnmanagedValue() throws {
        for intent: Bool? in [nil, false, true] {
            var configuration = ConfigurationFixtures.configuration
            configuration.connectOnLaunch = false
            configuration.devices[0].wheelInverted = true
            configuration.devices[0].restorePreviousSettingsOnDisconnect = true
            configuration.devices[0].wheelHighResolution = intent

            let encoded = try ConfigurationCodec.encode(configuration)
            let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

            if let intent {
                XCTAssertTrue(source.contains("wheel_high_resolution = \(intent)"))
            } else {
                XCTAssertFalse(source.contains("wheel_high_resolution"))
            }
            XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
        }
    }

    func testWheelScrollAmountRoundTripsAndOmitsNativeDefault() throws {
        XCTAssertEqual(WheelScrollAmount.defaultSelection, 1.0)
        XCTAssertEqual(WheelScrollAmount.range, 0.25...10.0)

        for amount: Double? in [nil, 0.25, 1.0, 10.0] {
            var configuration = ConfigurationFixtures.configuration
            configuration.connectOnLaunch = false
            configuration.devices[0].wheelInverted = true
            configuration.devices[0].restorePreviousSettingsOnDisconnect = true
            configuration.devices[0].wheelHighResolution = false
            configuration.devices[0].wheelScrollAmount = amount

            let encoded = try ConfigurationCodec.encode(configuration)
            let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

            if let amount {
                XCTAssertTrue(source.contains("wheel_scroll_amount = \(amount)"))
            } else {
                XCTAssertFalse(source.contains("wheel_scroll_amount"))
            }
            XCTAssertTrue(source.contains("wheel_inverted = true"))
            XCTAssertTrue(source.contains("restore_previous_settings_on_disconnect = true"))
            XCTAssertTrue(source.contains("wheel_high_resolution = false"))
            XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
        }
    }

    func testThumbwheelPreferencesRoundTripWithoutChangingVerticalWheelSettings() throws {
        for inversion: Bool? in [nil, false, true] {
            for amount: Double? in [nil, 0.25, 1.0, 10.0] {
                var configuration = ConfigurationFixtures.configuration
                configuration.devices[0].wheelInverted = false
                configuration.devices[0].restorePreviousSettingsOnDisconnect = true
                configuration.devices[0].wheelHighResolution = true
                configuration.devices[0].wheelScrollAmount = 2.5
                configuration.devices[0].thumbwheelInverted = inversion
                configuration.devices[0].thumbwheelScrollAmount = amount

                let encoded = try ConfigurationCodec.encode(configuration)
                let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

                if let inversion {
                    XCTAssertTrue(source.contains("thumbwheel_inverted = \(inversion)"))
                } else {
                    XCTAssertFalse(source.contains("thumbwheel_inverted"))
                }
                if let amount {
                    XCTAssertTrue(source.contains("thumbwheel_scroll_amount = \(amount)"))
                } else {
                    XCTAssertFalse(source.contains("thumbwheel_scroll_amount"))
                }
                XCTAssertTrue(source.contains("wheel_inverted = false"))
                XCTAssertTrue(source.contains("restore_previous_settings_on_disconnect = true"))
                XCTAssertTrue(source.contains("wheel_high_resolution = true"))
                XCTAssertTrue(source.contains("wheel_scroll_amount = 2.5"))
                XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
            }
        }
    }

    func testRejectsWrongTypedThumbwheelInversion() {
        let values = ["\"true\"", "1", "[true]"]

        for value in values {
            let source = ConfigurationFixtures.toml.replacingOccurrences(
                of: "id = \"logitech.mx-master-3s\"",
                with: "id = \"logitech.mx-master-3s\"\nthumbwheel_inverted = \(value)"
            )
            XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(source))) {
                XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
            }
        }
    }

    func testRejectsWrongTypedUnknownNonFiniteAndOutOfRangeThumbwheelScrollAmounts() {
        for value in ["\"1.0\"", "true", "[1.0]"] {
            let source = ConfigurationFixtures.toml.replacingOccurrences(
                of: "id = \"logitech.mx-master-3s\"",
                with: "id = \"logitech.mx-master-3s\"\nthumbwheel_scroll_amount = \(value)"
            )
            XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(source))) {
                XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
            }
        }

        let unknownKey = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nthumbwheel_amount = 2.0"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("thumbwheel_amount"))
        }

        for value in ["0.249", "10.001", "nan", "inf", "-inf"] {
            let source = ConfigurationFixtures.toml.replacingOccurrences(
                of: "id = \"logitech.mx-master-3s\"",
                with: "id = \"logitech.mx-master-3s\"\nthumbwheel_scroll_amount = \(value)"
            )
            XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(source))) {
                guard case .invalidConfiguration = $0 as? ConfigurationError else {
                    return XCTFail("Expected domain validation error, received \($0)")
                }
            }
        }
    }

    func testDoesNotEncodeInvalidThumbwheelScrollAmount() {
        for amount in [0.249, 10.001, Double.nan, Double.infinity, -Double.infinity] {
            var configuration = ConfigurationFixtures.configuration
            configuration.devices[0].thumbwheelScrollAmount = amount

            XCTAssertThrowsError(try ConfigurationCodec.encode(configuration)) {
                guard case .invalidConfiguration = $0 as? ConfigurationError else {
                    return XCTFail("Expected domain validation error, received \($0)")
                }
            }
        }
    }

    func testRejectsWrongTypedUnknownNonFiniteAndOutOfRangeWheelScrollAmounts() {
        let wrongTypes = ["\"1.0\"", "true", "[1.0]"]
        for value in wrongTypes {
            let source = ConfigurationFixtures.toml.replacingOccurrences(
                of: "id = \"logitech.mx-master-3s\"",
                with: "id = \"logitech.mx-master-3s\"\nwheel_scroll_amount = \(value)"
            )
            XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(source))) {
                XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
            }
        }

        let unknownKey = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nwheel_scroll_multiplier = 2.0"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("wheel_scroll_multiplier"))
        }

        for value in ["0.249", "10.001", "nan", "inf", "-inf"] {
            let source = ConfigurationFixtures.toml.replacingOccurrences(
                of: "id = \"logitech.mx-master-3s\"",
                with: "id = \"logitech.mx-master-3s\"\nwheel_scroll_amount = \(value)"
            )
            XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(source))) {
                guard case .invalidConfiguration = $0 as? ConfigurationError else {
                    return XCTFail("Expected domain validation error, received \($0)")
                }
            }
        }
    }

    func testRestorationPolicyRoundTripsBothValuesWithoutObservedState() throws {
        for restore in [false, true] {
            var configuration = ConfigurationFixtures.configuration
            configuration.devices[0].restorePreviousSettingsOnDisconnect = restore
            let encoded = try ConfigurationCodec.encode(configuration)
            let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

            XCTAssertTrue(source.contains("restore_previous_settings_on_disconnect = \(restore)"))
            XCTAssertFalse(source.contains("baseline"))
            XCTAssertFalse(source.contains("observed"))
            XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
        }
    }

    func testRejectsWrongTypedRestorationPolicy() {
        let source = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nrestore_previous_settings_on_disconnect = \"true\""
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(source))) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
        }
    }

    func testRejectsWrongTypedAndUnknownDeviceWheelKeys() {
        let wrongType = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nwheel_inverted = \"true\""
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(wrongType))) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
        }

        let unknownKey = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nwheel_flip = false"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("wheel_flip"))
        }

        let wrongResolutionType = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nwheel_high_resolution = \"true\""
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(wrongResolutionType))) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
        }

        let unknownResolutionKey = ConfigurationFixtures.toml.replacingOccurrences(
            of: "id = \"logitech.mx-master-3s\"",
            with: "id = \"logitech.mx-master-3s\"\nwheel_resolution = true"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownResolutionKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("wheel_resolution"))
        }
    }

    func testRejectsInvalidTOMLUnsupportedVersionUnknownKeysAndInvalidDomainValues() {
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data("schema_version = ["))) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
        }

        let unsupportedVersion = ConfigurationFixtures.toml.replacingOccurrences(
            of: "schema_version = 1",
            with: "schema_version = 2"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unsupportedVersion))) {
            XCTAssertEqual($0 as? ConfigurationError, .unsupportedVersion(2))
        }

        let unknownShortcutKey = ConfigurationFixtures.toml.replacingOccurrences(
            of: "key_code = 4",
            with: "key_code = 4\nkeycode = 4"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownShortcutKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("keycode"))
        }

        let unsupportedShortcut = ConfigurationFixtures.toml.replacingOccurrences(
            of: "key_code = 4",
            with: "key_code = 55"
        )
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unsupportedShortcut))) {
            guard case .invalidConfiguration = $0 as? ConfigurationError else {
                return XCTFail("Expected domain validation error, received \($0)")
            }
        }
    }

    func testRejectsDocumentsLargerThanTheConfiguredLimit() {
        let data = Data(repeating: 32, count: ConfigurationCodec.maximumFileSize + 1)

        XCTAssertThrowsError(try ConfigurationCodec.decode(data)) {
            XCTAssertEqual($0 as? ConfigurationError, .fileTooLarge)
        }
    }

    func testDoesNotEncodeInvalidDomainValues() {
        let invalid = AppConfiguration(devices: [
            DeviceBindings(
                id: AppConfiguration.logitechProfileID,
                defaults: ["back": .disabled]
            )
        ])

        XCTAssertThrowsError(try ConfigurationCodec.encode(invalid)) {
            guard case .invalidConfiguration = $0 as? ConfigurationError else {
                return XCTFail("Expected domain validation error, received \($0)")
            }
        }
    }
}
