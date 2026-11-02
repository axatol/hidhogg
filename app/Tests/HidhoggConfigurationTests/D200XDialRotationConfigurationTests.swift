import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class D200XDialRotationConfigurationTests: XCTestCase {
    func testRotationAndLegacyTileLibrariesRoundTripAndResolveAway() throws {
        let preset = D200XDialRotationPreset(name: "Volume", left: .action("down"), right: .action("up"),
            nativeActions: ["down": .init(kind: .volume, volume: .down), "up": .init(kind: .volume, volume: .up)])
        let deck = D200XConfiguration(tilePresets: ["blank": .init(name: "Legacy", appearance: .init())],
            dialRotationPresets: ["volume": preset])
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = deck
        let encoded = try ConfigurationCodec.encode(configuration)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("dial_rotation_presets"))
        XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
        XCTAssertTrue(deck.resolved(application: nil).dialRotationPresets.isEmpty)
        XCTAssertTrue(deck.resolved(application: nil).tilePresets.isEmpty)
    }

    func testLegacyConfigurationsDefaultRotationLibraryToEmptyInTOMLAndDomainCoding() throws {
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = .empty
        let encoded = try ConfigurationCodec.encode(configuration)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("dial_rotation_presets"))
        XCTAssertEqual(try ConfigurationCodec.decode(encoded).d200x?.dialRotationPresets, [:])
        let data = try JSONEncoder().encode(D200XConfiguration.empty)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "dialRotationPresets")
        XCTAssertEqual(try JSONDecoder().decode(D200XConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)), .empty)
    }

    func testRotationValidationRequiresExactReferencedDefinitionsAndDisjointMaps() throws {
        let action = ConfiguredExecutable(executable: "/synthetic/action")
        let valid = D200XDialRotationPreset(name: "Mixed", left: .action("action"), right: .disabled, actions: ["action": action])
        XCTAssertNoThrow(try valid.validated())
        var invalid = valid
        invalid.actions["unused"] = action
        XCTAssertThrowsError(try invalid.validated())
        invalid = valid
        invalid.nativeActions["action"] = .init(kind: .bell)
        XCTAssertThrowsError(try invalid.validated())
        invalid = valid
        invalid.actions = [:]
        XCTAssertThrowsError(try invalid.validated())
        XCTAssertThrowsError(try D200XConfiguration(dialRotationPresets: ["invalid id": valid]).validated())
        let oversized = Dictionary(uniqueKeysWithValues: (0..<129).map { ("preset\($0)", valid) })
        XCTAssertThrowsError(try D200XConfiguration(dialRotationPresets: oversized).validated())
    }

    func testStrictRotationCodecRejectsUnknownFieldsAtEveryBoundary() throws {
        let prefix = ConfigurationFixtures.toml + "\n\n"
        let preset = "[d200x.dial_rotation_presets.blank]\nname = 'Blank'\n"
        let left = "[d200x.dial_rotation_presets.blank.left]\nkind = 'disabled'\n"
        let right = "[d200x.dial_rotation_presets.blank.right]\nkind = 'disabled'\n"
        var expected = ConfigurationFixtures.configuration
        expected.d200x = D200XConfiguration(dialRotationPresets: ["blank": .init(name: "Blank", left: .disabled, right: .disabled)])
        XCTAssertEqual(try ConfigurationCodec.decode(Data((prefix + preset + left + right).utf8)), expected)
        for (content, unknownKey) in [
            (prefix + "[d200x]\nd200x_extra = true\n", "d200x_extra"),
            (prefix + preset + "preset_extra = true\n" + left + right, "preset_extra"),
            (prefix + preset + left + "left_extra = true\n" + right, "left_extra"),
            (prefix + preset + left + right + "right_extra = true\n", "right_extra")
        ] {
            XCTAssertThrowsError(try ConfigurationCodec.decode(Data(content.utf8))) {
                XCTAssertEqual($0 as? ConfigurationError, .unknownKey(unknownKey))
            }
        }
        XCTAssertThrowsError(try ConfigurationCodec.decode(Data((prefix + preset + left).utf8))) {
            XCTAssertEqual($0 as? ConfigurationError, .invalidDocument)
        }
    }
}
