import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class MouseShortcutConfigurationTests: XCTestCase {
    func testMouseShortcutsRoundTripDefaultsAndApplicationOverridesAlongsideLegacyKeys() throws {
        var configuration = ConfigurationFixtures.configuration
        configuration.devices[0].defaults["thumbRest"] = .mouse(MouseShortcut(button: .left, modifiers: [.command]))
        configuration.devices[0].applications["com.example.Editor_ID"]?["middle"] = .mouse(
            MouseShortcut(button: .right, modifiers: [.control, .shift])
        )

        let data = try ConfigurationCodec.encode(configuration)
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(source.contains("kind = \"mouse_shortcut\""))
        XCTAssertTrue(source.contains("mouse_shortcut"))
        XCTAssertTrue(source.contains("key_code = 4"))
        XCTAssertEqual(try ConfigurationCodec.decode(data), configuration)
    }

    func testLegacyDocumentStillDecodesWithoutMouseFields() throws {
        XCTAssertEqual(try ConfigurationCodec.decode(ConfigurationFixtures.data(ConfigurationFixtures.toml)),
                       ConfigurationFixtures.configuration)
    }

    func testRejectsMissingMixedAndDuplicateMouseShortcutPayloads() {
        let click = MouseShortcut(button: .left, modifiers: [.command])
        let invalid: [ControlBinding] = [
            .init(kind: .mouseShortcut),
            .init(kind: .mouseShortcut, shortcut: KeyboardShortcut(keyCode: 0), mouseShortcut: click),
            .init(kind: .shortcut, shortcut: KeyboardShortcut(keyCode: 0), mouseShortcut: click),
            .init(kind: .disabled, mouseShortcut: click),
            .mouse(MouseShortcut(button: .middle, modifiers: [.command, .command]))
        ]
        for binding in invalid {
            var configuration = ConfigurationFixtures.configuration
            configuration.devices[0].defaults["back"] = binding
            XCTAssertThrowsError(try ConfigurationCodec.encode(configuration))
        }
    }

    func testRejectsUnknownMousePayloadKeysAndButtons() throws {
        var configuration = ConfigurationFixtures.configuration
        configuration.devices[0].defaults["back"] = .mouse(MouseShortcut(button: .left))
        let source = try XCTUnwrap(String(data: ConfigurationCodec.encode(configuration), encoding: .utf8))
        let unknown = source.replacingOccurrences(of: "button = \"left\"", with: "button = \"left\"\nunknown = true")
        XCTAssertThrowsError(try ConfigurationCodec.decode(Data(unknown.utf8))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("unknown"))
        }
        let invalidButton = source.replacingOccurrences(of: "button = \"left\"", with: "button = \"side99\"")
        XCTAssertThrowsError(try ConfigurationCodec.decode(Data(invalidButton.utf8)))
    }
}
