import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class D200XWorkspaceConfigurationTests: XCTestCase {
    func testProfilesAndPresetsRoundTripWithoutChangingExistingOverrides() throws {
        let appearance = D200XTileAppearance(label: "Editor", titleAlignment: .right)
        let action = ConfiguredExecutable(executable: "/usr/bin/true", arguments: ["literal"])
        let deck = D200XConfiguration(defaults: ["key0": .action("build")],
            applications: ["com.example.Editor": ["key1": .disabled]],
            tiles: ["key0": .init(label: "Default")], brightnessPercent: 1,
            actions: ["build": action], notificationTopics: ["key0": ["build.*"]],
            applicationTiles: ["com.example.Editor": ["key0": appearance]],
            applicationNotificationTopics: ["com.example.Editor": ["key0": []]],
            tilePresets: ["editor": .init(name: "Editor", appearance: appearance,
                binding: .action("build"), actions: ["build": action])])
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = deck
        let encoded = try ConfigurationCodec.encode(configuration)
        XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
        let resolved = deck.resolved(application: "com.example.Editor")
        XCTAssertEqual(resolved.appearance(for: .key0), appearance)
        XCTAssertEqual(resolved.binding(for: .key0, application: nil), .action("build"))
        XCTAssertEqual(resolved.notificationTopics["key0"], [])
        XCTAssertEqual(deck.resolved(application: "com.example.Unmapped").tiles, deck.tiles)
        XCTAssertEqual(deck.appearance(for: .key0).label, "Default")
    }

    func testRejectsLegacySourceNamingAndInvalidProfileFields() throws {
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = D200XConfiguration(notificationTopics: ["key0": ["*"]])
        let encoded = try ConfigurationCodec.encode(configuration)
        let legacy = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "notification_topics", with: "notification_sources")
        XCTAssertThrowsError(try ConfigurationCodec.decode(Data(legacy.utf8)))
        XCTAssertThrowsError(try D200XConfiguration(applicationTiles: ["invalid app": ["key0": .init()]]).validated())
        XCTAssertThrowsError(try D200XConfiguration(applicationNotificationTopics: ["com.example.Editor": ["dial0Press": ["*"]]]).validated())
        XCTAssertThrowsError(try D200XConfiguration(tilePresets: ["invalid id": .init(name: "Tile", appearance: .init())]).validated())
    }
}
