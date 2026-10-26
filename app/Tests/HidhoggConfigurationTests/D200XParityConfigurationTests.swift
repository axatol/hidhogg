import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class D200XParityConfigurationTests: XCTestCase {
    func testLegacyConfigurationDecodesWithoutD200XChanges() throws {
        let configuration = try ConfigurationCodec.decode(
            ConfigurationFixtures.data(ConfigurationFixtures.toml)
        )

        XCTAssertEqual(configuration, ConfigurationFixtures.configuration)
        XCTAssertNil(configuration.d200x)
    }

    func testCompleteD200XConfigurationRoundTripsAllNewFields() throws {
        let assetReference = String(repeating: "a", count: 64) + ".png"
        let action = ConfiguredExecutable(
            executable: "/usr/bin/true",
            arguments: ["--profile", "release"],
            workingDirectory: "/tmp",
            timeoutSeconds: 60
        )
        let d200x = D200XConfiguration(
            defaults: [
                "key0": .action("build-project"),
                "key1": .key(KeyboardShortcut(keyCode: 4, modifiers: [.command])),
                "key2": .disabled
            ],
            applications: [
                "com.example.Editor_ID": ["key0": .disabled]
            ],
            tiles: [
                "key0": D200XTileAppearance(
                    label: "Build",
                    backgroundHex: "12ABef",
                    imageAsset: assetReference,
                    titleSize: 32,
                    titleColorHex: "FFFFFF",
                    titlePlacement: .bottom,
                    showTitle: false
                )
            ],
            brightnessPercent: 25,
            actions: ["build-project": action],
            notificationTopics: ["key0": ["local-tool", "homeassistant"]]
        )
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = d200x

        let encoded = try ConfigurationCodec.encode(configuration)
        let topic = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let decoded = try ConfigurationCodec.decode(encoded)

        XCTAssertTrue(topic.contains("brightness_percent = 25"))
        XCTAssertTrue(topic.contains("action_id = \"build-project\""))
        XCTAssertTrue(topic.contains("timeout_seconds = 60"))
        XCTAssertTrue(topic.contains("image_asset = \"\(assetReference)\""))
        XCTAssertTrue(topic.contains("title_placement = \"bottom\""))
        XCTAssertTrue(topic.contains("notification_topics"))
        XCTAssertFalse(topic.contains("brightnessPercent"))
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.d200x?.binding(for: .key0, application: nil), .action("build-project"))
        XCTAssertEqual(decoded.d200x?.binding(for: .key0, application: "com.example.Editor_ID"), .disabled)
        XCTAssertEqual(decoded.d200x?.binding(for: .key0, application: "com.example.Browser"), .action("build-project"))
    }

    func testD200XLimitsAcceptTheirInclusiveBoundaries() throws {
        let maximumActionID = String(repeating: "a", count: 64)
        let maximumPath = "/" + String(repeating: "p", count: 4095)
        let maximumArguments = Array(repeating: String(repeating: "x", count: 256), count: 64)
        var actions = Dictionary(uniqueKeysWithValues: (0..<63).map { index in
            ("action-\(index)", ConfiguredExecutable(executable: "/usr/bin/true", timeoutSeconds: 1))
        })
        actions[maximumActionID] = ConfiguredExecutable(
            executable: maximumPath,
            arguments: maximumArguments,
            workingDirectory: maximumPath,
            timeoutSeconds: 60
        )
        let longestSourceID = String(repeating: "s", count: 64)
        let sourceIDs = [longestSourceID] + (1..<16).map { "topic-\($0)" }

        for brightness in [1, 25, 100] {
            var configuration = ConfigurationFixtures.configuration
            configuration.d200x = D200XConfiguration(
                tiles: ["key0": D200XTileAppearance(imageAsset: String(repeating: "b", count: 64) + ".png")],
                brightnessPercent: brightness,
                actions: actions,
                notificationTopics: ["key0": sourceIDs]
            )

            let encoded = try ConfigurationCodec.encode(configuration)

            XCTAssertEqual(try ConfigurationCodec.decode(encoded), configuration)
        }
    }

    func testRejectsUnknownKeysInsideD200XActionAndAppearanceTables() {
        let topics = [
            ConfigurationFixtures.toml + """


            [d200x.actions."build-project"]
            executable = "/usr/bin/true"
            extra_option = true
            """,
            ConfigurationFixtures.toml + """


            [d200x.tiles.key0]
            label = "Build"
            background_hex = "30343B"
            extra_option = true
            """
        ]

        for topic in topics {
            XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(topic))) {
                XCTAssertEqual($0 as? ConfigurationError, .unknownKey("extra_option"))
            }
        }
    }

    func testRejectsDanglingActionReferencesInDefaultsAndApplications() {
        assertInvalidConfiguration(D200XConfiguration(
            defaults: ["key0": .action("missing-action")]
        ))
        assertInvalidConfiguration(D200XConfiguration(
            applications: ["com.example.Editor": ["key0": .action("missing-action")]]
        ))
    }

    func testRejectsInvalidExecutablePathsTimeoutsAndArgumentBounds() {
        let maximumPath = "/" + String(repeating: "p", count: 4095)
        let tooLongPath = "/" + String(repeating: "p", count: 4096)
        let invalidActions = [
            ConfiguredExecutable(executable: "scripts/run.sh"),
            ConfiguredExecutable(executable: "/usr/bin/true", workingDirectory: "build"),
            ConfiguredExecutable(executable: "/usr/bin/true\0"),
            ConfiguredExecutable(executable: tooLongPath),
            ConfiguredExecutable(executable: "/usr/bin/true", workingDirectory: tooLongPath),
            ConfiguredExecutable(executable: "/usr/bin/true", timeoutSeconds: 0),
            ConfiguredExecutable(executable: "/usr/bin/true", timeoutSeconds: 61),
            ConfiguredExecutable(executable: "/usr/bin/true", arguments: Array(repeating: "x", count: 65)),
            ConfiguredExecutable(executable: "/usr/bin/true", arguments: [String(repeating: "x", count: 4097)]),
            ConfiguredExecutable(executable: "/usr/bin/true", arguments: [
                String(repeating: "x", count: 4096),
                String(repeating: "x", count: 4096),
                String(repeating: "x", count: 4096),
                String(repeating: "x", count: 4096),
                "x"
            ]),
            ConfiguredExecutable(executable: maximumPath, workingDirectory: "relative")
        ]

        for (index, action) in invalidActions.enumerated() {
            assertInvalidConfiguration(D200XConfiguration(actions: ["run-\(index)": action]))
        }

        let tooManyActions = Dictionary(uniqueKeysWithValues: (0..<65).map { index in
            ("action-\(index)", ConfiguredExecutable(executable: "/usr/bin/true"))
        })
        assertInvalidConfiguration(D200XConfiguration(actions: tooManyActions))
        assertInvalidConfiguration(D200XConfiguration(actions: [
            "invalid action": ConfiguredExecutable(executable: "/usr/bin/true")
        ]))
    }

    func testRejectsInvalidBrightnessNotificationTopicsAndImageAssets() {
        for brightness in [0, 101] {
            assertInvalidConfiguration(D200XConfiguration(brightnessPercent: brightness))
        }

        for titleSize in [7.99, 48.01, Double.nan, Double.infinity] {
            assertInvalidConfiguration(D200XConfiguration(tiles: [
                "key0": D200XTileAppearance(titleSize: titleSize)
            ]))
        }

        let invalidSources: [[String: [String]]] = [
            ["side0": ["local-tool"]],
            ["key0": ["same", "same"]],
            ["key0": ["not a topic"]],
            ["key0": ["sourcé"]],
            ["key0": [String(repeating: "a", count: 65)]],
            ["key0": (0..<17).map { "topic-\($0)" }]
        ]
        for topics in invalidSources {
            assertInvalidConfiguration(D200XConfiguration(notificationTopics: topics))
        }

        let invalidAssets = [
            "not-a-hash.png",
            String(repeating: "A", count: 64) + ".png",
            String(repeating: "a", count: 64) + ".jpg",
            "/" + String(repeating: "a", count: 64) + ".png"
        ]
        for asset in invalidAssets {
            assertInvalidConfiguration(D200XConfiguration(tiles: [
                "key0": D200XTileAppearance(imageAsset: asset)
            ]))
        }
    }

    private func assertInvalidConfiguration(
        _ d200x: D200XConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = d200x

        XCTAssertThrowsError(try ConfigurationCodec.encode(configuration), file: file, line: line) {
            guard case .invalidConfiguration = $0 as? ConfigurationError else {
                return XCTFail("Expected a D200X validation error, received \($0)", file: file, line: line)
            }
        }
    }
}
