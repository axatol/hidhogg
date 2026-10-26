import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class NativeActionConfigurationTests: XCTestCase {
    func testLegacyExecutableConfigurationRemainsReadableBesideNativeActions() throws {
        let source = ConfigurationFixtures.toml + """


        [d200x.defaults.key0]
        kind = "action"
        action_id = "legacy-build"

        [d200x.actions."legacy-build"]
        executable = "/synthetic/build"
        arguments = ["--release"]
        timeout_seconds = 30

        [d200x.native_actions."native-bell"]
        kind = "bell"
        """

        let configuration = try ConfigurationCodec.decode(ConfigurationFixtures.data(source))
        let d200x = try XCTUnwrap(configuration.d200x)

        XCTAssertEqual(d200x.actions["legacy-build"], .init(executable: "/synthetic/build", arguments: ["--release"], timeoutSeconds: 30))
        XCTAssertEqual(d200x.nativeActions["native-bell"], .init(kind: .bell))
        XCTAssertEqual(d200x.actionIDs, ["legacy-build", "native-bell"])
    }

    func testAllNativeActionKindsRoundTripWithStrictSnakeCaseAndSharedReferences() throws {
        let nativeActions = allNativeActions()
        let executable = ConfiguredExecutable(executable: "/synthetic/build", arguments: ["--release"], timeoutSeconds: 30)
        let d200x = D200XConfiguration(
            defaults: ["key0": .action("media-play")],
            actions: ["legacy-build": executable],
            nativeActions: nativeActions
        )
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = d200x

        let encoded = try ConfigurationCodec.encode(configuration)
        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let decoded = try ConfigurationCodec.decode(encoded)
        let decodedD200x = try XCTUnwrap(decoded.d200x)

        XCTAssertTrue(source.contains("native_actions"))
        XCTAssertTrue(source.contains("kind = \"play_sound\""))
        XCTAssertTrue(source.contains("kind = \"open_application\""))
        XCTAssertTrue(source.contains("ttl_seconds = 86400"))
        XCTAssertTrue(source.contains("nativeActions") == false)
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decodedD200x.nativeActions, nativeActions)
        XCTAssertEqual(decodedD200x.actions["legacy-build"], executable)
        XCTAssertEqual(decodedD200x.actionDefinition(id: "media-play"), .native(nativeActions["media-play"]!))
        XCTAssertEqual(decodedD200x.actionDefinition(id: "legacy-build"), .executable(executable))
        XCTAssertEqual(decodedD200x.actionIDs, (Array(nativeActions.keys) + ["legacy-build"]).sorted())
        XCTAssertEqual(
            Set(nativeActions.values.map(\.kind.rawValue)),
            Set(NativeAction.Kind.allCases.map(\.rawValue))
        )
    }

    func testNativeActionsAcceptInclusiveFieldAndRegistryLimits() throws {
        let longestPath = "/" + String(repeating: "p", count: 4095)
        let urlPrefix = "https://example.test/"
        let longestURL = urlPrefix + String(repeating: "x", count: 4096 - urlPrefix.utf8.count)
        let maximumText = String(repeating: "💾", count: 64)
        let longestTopic = String(repeating: "a", count: 64)
        let boundaryActions = [
            NativeAction(kind: .volume, volume: .set, percent: 0),
            NativeAction(kind: .volume, volume: .set, percent: 100),
            NativeAction(kind: .openFile, target: longestPath),
            NativeAction(kind: .openURL, target: longestURL),
            NativeAction(kind: .deckNotification, topic: longestTopic, text: maximumText, ttlSeconds: 1),
            NativeAction(kind: .deckNotification, topic: "build.finished", text: "Ready", ttlSeconds: 86_400)
        ]

        for action in boundaryActions {
            XCTAssertNoThrow(try action.validated(), "Expected inclusive boundary to be accepted: \(action.kind)")
        }

        let maximumRegistry = Dictionary(uniqueKeysWithValues: (0..<64).map { index in
            ("native-\(index)", NativeAction(kind: .bell))
        })
        XCTAssertNoThrow(try D200XConfiguration(nativeActions: maximumRegistry).validated())

        let mixedMaximum = D200XConfiguration(
            actions: Dictionary(uniqueKeysWithValues: (0..<63).map { index in
                ("script-\(index)", ConfiguredExecutable(executable: "/synthetic/script"))
            }),
            nativeActions: ["native-final": .init(kind: .bell)]
        )
        XCTAssertNoThrow(try mixedMaximum.validated())

        let tooManyActions = Dictionary(uniqueKeysWithValues: (0..<65).map { index in
            ("native-\(index)", NativeAction(kind: .bell))
        })
        XCTAssertThrowsError(try D200XConfiguration(nativeActions: tooManyActions).validated())
        XCTAssertThrowsError(try D200XConfiguration(
            actions: mixedMaximum.actions,
            nativeActions: ["native-final": .init(kind: .bell), "native-overflow": .init(kind: .bell)]
        ).validated())
    }

    func testNativeActionValidationRejectsHybridMalformedAndOutOfRangeValues() {
        let tooLongPath = "/" + String(repeating: "p", count: 4096)
        let tooLongURL = "https://example.test/" + String(repeating: "x", count: 4096)
        let invalidActions = [
            NativeAction(kind: .media),
            NativeAction(kind: .media, media: .playPause, target: "/synthetic/extra"),
            NativeAction(kind: .volume, volume: .set),
            NativeAction(kind: .volume, volume: .set, percent: 101),
            NativeAction(kind: .volume, volume: .mute, percent: 50),
            NativeAction(kind: .bell, target: "/synthetic/extra"),
            NativeAction(kind: .playSound, target: "relative/chime.aiff"),
            NativeAction(kind: .openFile, target: tooLongPath),
            NativeAction(kind: .openURL, target: "file:///synthetic/document"),
            NativeAction(kind: .openURL, target: "https://user:password@example.test/"),
            NativeAction(kind: .openURL, target: tooLongURL),
            NativeAction(kind: .deckNotification, topic: "build.*", text: "Ready"),
            NativeAction(kind: .deckNotification, topic: "build.finished", text: "\n"),
            NativeAction(kind: .deckNotification, topic: "build.finished", text: "Ready", ttlSeconds: 0),
            NativeAction(kind: .deckNotification, topic: "build.finished", text: String(repeating: "💾", count: 65)),
            NativeAction(kind: .shortcut, shortcut: KeyboardShortcut(keyCode: 55))
        ]

        for action in invalidActions {
            XCTAssertThrowsError(try action.validated(), "Expected malformed native action to be rejected: \(action.kind)")
        }

        let collidingID = "shared-id"
        XCTAssertThrowsError(try D200XConfiguration(
            actions: [collidingID: .init(executable: "/synthetic/build")],
            nativeActions: [collidingID: .init(kind: .bell)]
        ).validated())
    }

    func testNativeActionTOMLRejectsUnknownKeysHybridsAndRegistryCollisions() {
        let unknownNativeField = ConfigurationFixtures.toml + """


        [d200x.native_actions."native-bell"]
        kind = "bell"
        extra = true
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownNativeField))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("extra"))
        }

        let unknownShortcutField = ConfigurationFixtures.toml + """


        [d200x.native_actions."native-shortcut"]
        kind = "shortcut"

        [d200x.native_actions."native-shortcut".shortcut]
        key_code = 4
        modifiers = ["command"]
        extra = true
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(unknownShortcutField))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("extra"))
        }

        let camelCaseField = ConfigurationFixtures.toml + """


        [d200x.native_actions."native-notification"]
        kind = "deck_notification"
        topic = "build.finished"
        text = "Ready"
        ttlSeconds = 60
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(camelCaseField))) {
            XCTAssertEqual($0 as? ConfigurationError, .unknownKey("ttlSeconds"))
        }

        let hybrid = ConfigurationFixtures.toml + """


        [d200x.native_actions."native-media"]
        kind = "media"
        media = "play_pause"
        target = "/synthetic/extra"
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(hybrid)))

        let collision = ConfigurationFixtures.toml + """


        [d200x.actions."shared-id"]
        executable = "/synthetic/build"

        [d200x.native_actions."shared-id"]
        kind = "bell"
        """
        XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(collision)))
    }

    private func allNativeActions() -> [String: NativeAction] {
        [
            "media-play": .init(kind: .media, media: .playPause),
            "media-next": .init(kind: .media, media: .nextTrack),
            "media-previous": .init(kind: .media, media: .previousTrack),
            "volume-up": .init(kind: .volume, volume: .up),
            "volume-down": .init(kind: .volume, volume: .down),
            "volume-mute": .init(kind: .volume, volume: .mute),
            "volume-set": .init(kind: .volume, volume: .set, percent: 40),
            "bell": .init(kind: .bell),
            "play-sound": .init(kind: .playSound, target: "/synthetic/chime.aiff"),
            "open-application": .init(kind: .openApplication, target: "/Applications/Synthetic.app"),
            "open-file": .init(kind: .openFile, target: "/synthetic/document.txt"),
            "open-url": .init(kind: .openURL, target: "https://example.test/path"),
            "deck-notification": .init(kind: .deckNotification, topic: "build.finished", text: "Complete", ttlSeconds: 86_400),
            "shortcut": .init(kind: .shortcut, shortcut: KeyboardShortcut(keyCode: 4, modifiers: [.command]))
        ]
    }
}
