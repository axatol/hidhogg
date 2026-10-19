import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class ConfigurationCodecTests: XCTestCase {
    func testDecodesDefaultsAndExplicitDisabledOverride() throws {
        let configuration = try ConfigurationCodec.decode(ConfigurationFixtures.data(ConfigurationFixtures.toml))
        let device = try XCTUnwrap(configuration.mouse)

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
        XCTAssertTrue(source.contains("key_code = 4"))
        XCTAssertTrue(source.contains("com.example.Editor_ID"))
        XCTAssertEqual(try ConfigurationCodec.decode(first), ConfigurationFixtures.configuration)
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
