import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class ConfigurationCodecTests: XCTestCase {
    func testDecodesDefaultsAndExplicitDisabledOverride() throws {
        let configuration = try ConfigurationCodec.decode(ConfigurationFixtures.data(ConfigurationFixtures.toml))
        let device = try XCTUnwrap(configuration.mouse)

        XCTAssertTrue(configuration.connectOnLaunch)
        XCTAssertNil(configuration.d200x)
        XCTAssertFalse(device.restorePreviousSettingsOnDisconnect)
        XCTAssertNil(device.wheelHighResolution)
        XCTAssertNil(device.wheelScrollAmount)
        XCTAssertEqual(device.effectiveWheelInverted, false)
        XCTAssertEqual(device.effectiveThumbwheelInverted, true)
        XCTAssertEqual(device.wheelInverted, false)
        XCTAssertEqual(device.thumbwheelInverted, true)
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
        XCTAssertTrue(source.contains("wheel_inverted = false"))
        XCTAssertTrue(source.contains("thumbwheel_inverted = true"))
        XCTAssertFalse(source.contains("thumbwheel_scroll_amount"))
        XCTAssertFalse(source.contains("d200x"))
        XCTAssertEqual(try ConfigurationCodec.decode(first), ConfigurationFixtures.configuration)
    }

    func testD200XConfigurationRoundTripsSparseBindingsAndTileAppearance() throws {
        let d200x = D200XConfiguration(
            defaults: [
                "key0": .key(KeyboardShortcut(keyCode: 4, modifiers: [.command])),
                "side0": .disabled
            ],
            applications: [
                "com.example.Editor_ID": [
                    "dial2HeldRight": .key(KeyboardShortcut(keyCode: 12, modifiers: [.option]))
                ]
            ],
            tiles: ["key13": D200XTileAppearance(label: "Wide status", backgroundHex: "12ABef")]
        )
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = d200x

        let encoded = try ConfigurationCodec.encode(configuration)
        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let decoded = try ConfigurationCodec.decode(encoded)

        XCTAssertTrue(source.contains("background_hex = \"12ABef\""))
        XCTAssertFalse(source.contains("backgroundHex"))
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.d200x?.binding(for: .key0, application: nil), d200x.defaults["key0"])
        XCTAssertEqual(
            decoded.d200x?.binding(for: .dial2HeldRight, application: "com.example.Editor_ID"),
            d200x.applications["com.example.Editor_ID"]?["dial2HeldRight"]
        )
        XCTAssertEqual(decoded.d200x?.binding(for: .dial0Left, application: nil), .disabled)
        XCTAssertEqual(decoded.d200x?.appearance(for: .key13), d200x.tiles["key13"])
        XCTAssertEqual(decoded.d200x?.appearance(for: .key0), D200XTileAppearance(label: "Key 1"))
    }

    func testExplicitEmptyD200XConfigurationRoundTripsAsPresent() throws {
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = .empty

        let encoded = try ConfigurationCodec.encode(configuration)

        XCTAssertEqual(try ConfigurationCodec.decode(encoded).d200x, .empty)
    }

    func testD200XControlTitlesWireIndicesAndGestures() {
        XCTAssertEqual(D200XControl.allCases.count, 31)
        XCTAssertEqual(D200XControl.key13.title, "Key 14")
        XCTAssertEqual(D200XControl.key13.wireIndex, 13)
        XCTAssertEqual(D200XControl.side0.wireIndex, 15)
        XCTAssertEqual(D200XControl.side1.wireIndex, 16)
        XCTAssertNil(D200XControl.side0.gesture)
        XCTAssertEqual(D200XControl.dial2HeldRight.wireIndex, 19)
        XCTAssertEqual(D200XControl.dial2HeldRight.gesture, .heldRight)
        XCTAssertEqual(D200XControl.dial2HeldRight.title, "Dial 3 Held Right")
        XCTAssertEqual(D200XGesture.allCases.map(\.rawValue), [1, 2, 3, 4, 5])
    }

    func testRejectsInvalidD200XControlsAppearanceAndShortcuts() {
        let tooManyApplications = Dictionary(uniqueKeysWithValues: (0..<129).map { index in
            ("com.example.\(index)", ["key0": D200XBinding.disabled])
        })
        let invalidConfigurations = [
            D200XConfiguration(defaults: ["unknown": .disabled]),
            D200XConfiguration(applications: ["com.example.Editor": ["unknown": .disabled]]),
            D200XConfiguration(applications: tooManyApplications),
            D200XConfiguration(tiles: ["key14": D200XTileAppearance()]),
            D200XConfiguration(tiles: ["key0": D200XTileAppearance(label: String(repeating: "x", count: 65))]),
            D200XConfiguration(tiles: ["key0": D200XTileAppearance(backgroundHex: "#30343B")]),
            D200XConfiguration(defaults: ["key0": .key(KeyboardShortcut(keyCode: 55))])
        ]

        for d200x in invalidConfigurations {
            var configuration = ConfigurationFixtures.configuration
            configuration.d200x = d200x

            XCTAssertThrowsError(try ConfigurationCodec.encode(configuration)) {
                guard case .invalidConfiguration = $0 as? ConfigurationError else {
                    return XCTFail("Expected D200X domain validation error, received \($0)")
                }
            }
        }
    }

    func testRejectsUnknownKeysWithinD200XScopes() {
        let unknownD200XKey = ConfigurationFixtures.toml + """

        [d200x]
        unknown = true
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownD200XKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("unknown"))
        }

        let unknownBindingKey = ConfigurationFixtures.toml + """

        [d200x.defaults.key0]
        kind = "disabled"
        extra = true
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownBindingKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("extra"))
        }

        let unknownAppearanceKey = ConfigurationFixtures.toml + """

        [d200x.tiles.key0]
        label = "Key 1"
        background_hex = "30343B"
        extra = true
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownAppearanceKey))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("extra"))
        }

        let unknownControl = ConfigurationFixtures.toml + """

        [d200x.defaults.key14]
        kind = "disabled"
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownControl))) {
            guard case .invalidConfiguration = $0 as? ConfigurationError else {
                return XCTFail("Expected D200X domain validation error, received \($0)")
            }
        }
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

    func testWheelDirectionDefaultsAndExplicitValuesRoundTripDeterministically() throws {
        let intents: [(Bool?, Bool)] = [(nil, false), (false, false), (true, true)]

        for (intent, effectiveValue) in intents {
            var configuration = ConfigurationFixtures.configuration
            configuration.devices[0].wheelInverted = intent

            let encoded = try ConfigurationCodec.encode(configuration)
            let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

            XCTAssertTrue(source.contains("wheel_inverted = \(effectiveValue)"))
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
        let inversions: [(Bool?, Bool)] = [(nil, true), (false, false), (true, true)]

        for (inversion, effectiveValue) in inversions {
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

                XCTAssertTrue(source.contains("thumbwheel_inverted = \(effectiveValue)"))
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

    func testMouseHardwarePreferencesRoundTripAndValidateProtocolIndependentValues() throws {
        let preferences = MouseHardwarePreferences(
            smartShiftMode: .freeSpin,
            smartShiftThreshold: 255,
            smartShiftTorque: 80,
            dpi: 1600,
            pointerSpeed: 1.25,
            hapticsEnabled: true,
            hapticIntensity: 0,
            hapticPowerSaving: false,
            forceThreshold: 0
        )
        var configuration = ConfigurationFixtures.configuration
        configuration.devices[0].hardwarePreferences = preferences

        let encoded = try ConfigurationCodec.encode(configuration)
        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let decoded = try ConfigurationCodec.decode(encoded)

        XCTAssertTrue(source.contains("smart_shift_mode = \"freeSpin\""))
        XCTAssertTrue(source.contains("smart_shift_threshold = 255"))
        XCTAssertTrue(source.contains("smart_shift_torque = 80"))
        XCTAssertTrue(source.contains("dpi = 1600"))
        XCTAssertTrue(source.contains("pointer_speed = 1.25"))
        XCTAssertTrue(source.contains("haptics_enabled = true"))
        XCTAssertTrue(source.contains("haptic_intensity = 0"))
        XCTAssertTrue(source.contains("haptic_power_saving = false"))
        XCTAssertTrue(source.contains("force_threshold = 0"))
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(try preferences.validated(), preferences)
    }

    func testMouseHardwarePreferencesRejectInvalidDeviceIndependentValues() {
        let invalidPreferences = [
            MouseHardwarePreferences(smartShiftMode: .automatic, smartShiftThreshold: 255),
            MouseHardwarePreferences(smartShiftThreshold: 0),
            MouseHardwarePreferences(smartShiftTorque: 0),
            MouseHardwarePreferences(smartShiftTorque: 101),
            MouseHardwarePreferences(dpi: 0),
            MouseHardwarePreferences(pointerSpeed: 0),
            MouseHardwarePreferences(pointerSpeed: MousePointerSpeed.range.lowerBound.nextDown),
            MouseHardwarePreferences(pointerSpeed: MousePointerSpeed.range.upperBound.nextUp),
            MouseHardwarePreferences(pointerSpeed: .infinity),
            MouseHardwarePreferences(hapticIntensity: 101)
        ]

        for preferences in invalidPreferences {
            var configuration = ConfigurationFixtures.configuration
            configuration.devices[0].hardwarePreferences = preferences
            XCTAssertThrowsError(try configuration.validated())
        }

        XCTAssertTrue(MousePointerSpeed.contains(MousePointerSpeed.range.lowerBound))
        XCTAssertTrue(MousePointerSpeed.contains(MousePointerSpeed.range.upperBound))
        XCTAssertNoThrow(try MouseHardwarePreferences(smartShiftMode: .automatic, smartShiftThreshold: 254).validated())
    }

    func testMouseHardwarePreferenceCodecRejectsInvalidAndUnknownFields() throws {
        var configuration = ConfigurationFixtures.configuration
        configuration.devices[0].hardwarePreferences = MouseHardwarePreferences(
            smartShiftMode: .automatic,
            smartShiftThreshold: 120,
            smartShiftTorque: 40,
            dpi: 1600,
            pointerSpeed: 1.0,
            hapticsEnabled: true,
            hapticIntensity: 50,
            hapticPowerSaving: false,
            forceThreshold: 0
        )
        let encoded = try ConfigurationCodec.encode(configuration)
        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let outsidePointerSpeed = MousePointerSpeed.range.lowerBound.nextDown
        let invalidSources = [
            source.replacingOccurrences(of: "smart_shift_threshold = 120", with: "smart_shift_threshold = 0"),
            source.replacingOccurrences(of: "smart_shift_threshold = 120", with: "smart_shift_threshold = 1.5"),
            source.replacingOccurrences(of: "smart_shift_torque = 40", with: "smart_shift_torque = 101"),
            source.replacingOccurrences(of: "dpi = 1600", with: "dpi = 0"),
            source.replacingOccurrences(of: "pointer_speed = 1.0", with: "pointer_speed = \(outsidePointerSpeed)"),
            source.replacingOccurrences(of: "haptic_intensity = 50", with: "haptic_intensity = 101"),
            source.replacingOccurrences(
                of: "haptic_intensity = 50",
                with: "haptic_intensity = 50\nunknown_preference = true"
            )
        ]

        for invalidSource in invalidSources {
            XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(invalidSource)))
        }
    }

    func testLegacyMissingAndNullDirectionFieldsUseDefaultsAndPreserveExplicitValues() throws {
        let legacyBase = #"{"id":"logitech.mx-master-3s","defaults":{"back":{"kind":"disabled"},"forward":{"kind":"disabled"}},"applications":{},"restorePreviousSettingsOnDisconnect":false}"#
        let decoder = JSONDecoder()
        let missing = try decoder.decode(DeviceBindings.self, from: Data(legacyBase.utf8))

        XCTAssertEqual(missing.wheelInverted, false)
        XCTAssertEqual(missing.thumbwheelInverted, true)
        XCTAssertEqual(missing.effectiveWheelInverted, false)
        XCTAssertEqual(missing.effectiveThumbwheelInverted, true)

        let nullable = legacyBase.replacingOccurrences(
            of: "\"applications\":{}",
            with: "\"applications\":{},\"wheelInverted\":null,\"thumbwheelInverted\":null"
        )
        let nullValues = try decoder.decode(DeviceBindings.self, from: Data(nullable.utf8))
        XCTAssertEqual(nullValues.effectiveWheelInverted, false)
        XCTAssertEqual(nullValues.effectiveThumbwheelInverted, true)

        let explicit = legacyBase.replacingOccurrences(
            of: "\"applications\":{}",
            with: "\"applications\":{},\"wheelInverted\":true,\"thumbwheelInverted\":false"
        )
        let explicitValues = try decoder.decode(DeviceBindings.self, from: Data(explicit.utf8))
        XCTAssertEqual(explicitValues.effectiveWheelInverted, true)
        XCTAssertEqual(explicitValues.effectiveThumbwheelInverted, false)
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

    func testOptionalMouseControlsRemainUnassignedUntilExplicitlyConfigured() throws {
        XCTAssertEqual(MouseControl.allCases, [.back, .forward, .middle, .wheelMode, .thumbRest])
        XCTAssertEqual(MouseControl.middle.title, "Middle button")
        XCTAssertEqual(MouseControl.wheelMode.title, "Wheel mode button")
        XCTAssertEqual(MouseControl.thumbRest.title, "Thumb button")

        var configuration = ConfigurationFixtures.configuration
        configuration.devices[0].defaults[MouseControl.middle.rawValue] = .disabled
        configuration.devices[0].applications["com.example.Editor_ID"] = [
            MouseControl.middle.rawValue: .key(KeyboardShortcut(keyCode: 4)),
            MouseControl.wheelMode.rawValue: .key(KeyboardShortcut(keyCode: 5)),
            MouseControl.thumbRest.rawValue: .disabled
        ]

        let device = try XCTUnwrap(configuration.mouse)
        XCTAssertEqual(device.configuredBinding(for: .middle, application: nil), .disabled)
        XCTAssertNil(device.configuredBinding(for: .thumbRest, application: nil))
        XCTAssertNil(device.configuredBinding(for: .thumbRest, application: "com.example.Other"))
        XCTAssertEqual(device.configuredBinding(for: .middle, application: "com.example.Other"), .disabled)
        XCTAssertEqual(
            device.configuredBinding(for: .middle, application: "com.example.Editor_ID"),
            .key(KeyboardShortcut(keyCode: 4))
        )
        XCTAssertEqual(
            device.configuredBinding(for: .wheelMode, application: "com.example.Editor_ID"),
            .key(KeyboardShortcut(keyCode: 5))
        )
        XCTAssertEqual(device.configuredBinding(for: .thumbRest, application: "com.example.Editor_ID"), .disabled)

        let encoded = try ConfigurationCodec.encode(configuration)
        XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
    }

    func testMouseValidationRequiresBackAndForwardButAllowsSparseKnownControls() throws {
        let defaults: [String: ControlBinding] = ["back": .disabled, "forward": .disabled]
        let sparse = DeviceBindings(
            id: AppConfiguration.logitechProfileID,
            defaults: defaults,
            applications: ["com.example.Editor": ["wheelMode": .disabled]]
        )
        XCTAssertNoThrow(try AppConfiguration(devices: [sparse]).validated())

        let missingRequired = DeviceBindings(
            id: AppConfiguration.logitechProfileID,
            defaults: ["back": .disabled]
        )
        XCTAssertThrowsError(try AppConfiguration(devices: [missingRequired]).validated())

        let unknownDefault = DeviceBindings(
            id: AppConfiguration.logitechProfileID,
            defaults: defaults.merging(["unknown": .disabled]) { _, replacement in replacement }
        )
        XCTAssertThrowsError(try AppConfiguration(devices: [unknownDefault]).validated())

        let unknownOverride = DeviceBindings(
            id: AppConfiguration.logitechProfileID,
            defaults: defaults,
            applications: ["com.example.Editor": ["unknown": .disabled]]
        )
        XCTAssertThrowsError(try AppConfiguration(devices: [unknownOverride]).validated())
    }
}
