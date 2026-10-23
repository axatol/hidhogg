import Foundation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class ApplicationContextRemovalTests: XCTestCase {
    func testApplicationRemovalBoundariesAndPersistence() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configurationURL = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: configurationURL)
        let model = makeModel(configurationURL: configurationURL, store: store)
        let mouseApplicationToRemove = "com.example.mouse-removed"
        let mouseApplicationToKeep = "com.example.mouse-kept"
        let deckApplicationToRemove = "com.example.deck-removed"
        let deckApplicationToKeep = "com.example.deck-kept"
        let initialConfiguration = makeConfiguration(
            mouseApplicationToRemove: mouseApplicationToRemove,
            mouseApplicationToKeep: mouseApplicationToKeep,
            deckApplicationToRemove: deckApplicationToRemove,
            deckApplicationToKeep: deckApplicationToKeep
        )
        let initialDeckConfiguration = try XCTUnwrap(initialConfiguration.d200x)

        model.updateDraft(initialConfiguration)
        XCTAssertEqual(model.document.draft, initialConfiguration)

        model.removeSelectedApplication()
        XCTAssertNil(model.selectedApplicationID)
        XCTAssertEqual(model.document.draft, initialConfiguration)

        model.selectApplication(mouseApplicationToRemove)
        model.beginRecording(for: .back, applicationID: mouseApplicationToRemove)
        XCTAssertNotNil(model.captureSessionID)
        XCTAssertEqual(
            model.recordingTarget,
            ShortcutRecordingTarget(control: .back, applicationID: mouseApplicationToRemove)
        )

        model.removeSelectedApplication()

        var expectedMouseConfiguration = try XCTUnwrap(initialConfiguration.mouse)
        expectedMouseConfiguration.applications.removeValue(forKey: mouseApplicationToRemove)
        XCTAssertNil(model.selectedApplicationID)
        XCTAssertNil(model.captureSessionID)
        XCTAssertNil(model.recordingTarget)
        XCTAssertEqual(model.document.draft.mouse, expectedMouseConfiguration)
        XCTAssertEqual(model.document.draft.d200x, initialDeckConfiguration)
        XCTAssertEqual(
            model.document.draft.mouse?.applications[mouseApplicationToKeep],
            initialConfiguration.mouse?.applications[mouseApplicationToKeep]
        )
        XCTAssertEqual(model.document.draft.mouse?.defaults, initialConfiguration.mouse?.defaults)

        model.updateDraft(initialConfiguration)
        model.d200x.applicationID = nil
        model.d200x.removeSelectedApplication()
        XCTAssertNil(model.d200x.applicationID)
        XCTAssertEqual(model.document.draft, initialConfiguration)

        model.d200x.applicationID = deckApplicationToRemove
        model.d200x.synchronize(initialDeckConfiguration, canEdit: false)
        model.d200x.removeSelectedApplication()
        XCTAssertEqual(model.d200x.applicationID, deckApplicationToRemove)
        XCTAssertEqual(model.d200x.configuration, initialDeckConfiguration)
        XCTAssertEqual(model.document.draft, initialConfiguration)

        model.d200x.synchronize(initialDeckConfiguration, canEdit: true)
        model.d200x.removeSelectedApplication()

        var expectedDeckConfiguration = initialDeckConfiguration
        expectedDeckConfiguration.applications.removeValue(forKey: deckApplicationToRemove)
        var expectedConfiguration = initialConfiguration
        expectedConfiguration.d200x = expectedDeckConfiguration
        XCTAssertNil(model.d200x.applicationID)
        XCTAssertEqual(model.document.draft, expectedConfiguration)
        XCTAssertEqual(model.document.draft.mouse, initialConfiguration.mouse)
        XCTAssertEqual(model.document.draft.d200x?.applications[deckApplicationToKeep], initialDeckConfiguration.applications[deckApplicationToKeep])
        XCTAssertEqual(model.document.draft.d200x?.defaults, initialDeckConfiguration.defaults)
        XCTAssertEqual(model.document.draft.d200x?.tiles, initialDeckConfiguration.tiles)

        let saveSucceeded = await model.flushPendingSave()
        XCTAssertTrue(saveSucceeded)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded.configuration, expectedConfiguration)
    }

    private func makeConfiguration(
        mouseApplicationToRemove: String,
        mouseApplicationToKeep: String,
        deckApplicationToRemove: String,
        deckApplicationToKeep: String
    ) -> AppConfiguration {
        var configuration = AppConfiguration.empty
        configuration.connectOnLaunch = false
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 12))
        configuration.devices[0].defaults[MouseControl.forward.rawValue] = .key(KeyboardShortcut(keyCode: 13))
        configuration.devices[0].applications[mouseApplicationToRemove] = [
            MouseControl.back.rawValue: .key(KeyboardShortcut(keyCode: 14))
        ]
        configuration.devices[0].applications[mouseApplicationToKeep] = [
            MouseControl.forward.rawValue: .key(KeyboardShortcut(keyCode: 15))
        ]
        configuration.devices[0].wheelInverted = true
        configuration.devices[0].restorePreviousSettingsOnDisconnect = true
        configuration.devices[0].wheelHighResolution = true
        configuration.devices[0].wheelScrollAmount = 2.5
        configuration.devices[0].thumbwheelInverted = true
        configuration.devices[0].thumbwheelScrollAmount = 3.5
        configuration.devices[0].lowBatteryNotificationsEnabled = true
        configuration.d200x = D200XConfiguration(
            defaults: [
                D200XControl.key0.rawValue: .key(KeyboardShortcut(keyCode: 16)),
                D200XControl.key1.rawValue: .key(KeyboardShortcut(keyCode: 17))
            ],
            applications: [
                deckApplicationToRemove: [
                    D200XControl.key0.rawValue: .key(KeyboardShortcut(keyCode: 18))
                ],
                deckApplicationToKeep: [
                    D200XControl.key1.rawValue: .key(KeyboardShortcut(keyCode: 19))
                ]
            ],
            tiles: [
                D200XControl.key0.rawValue: D200XTileAppearance(label: "Home", backgroundHex: "112233"),
                D200XControl.key1.rawValue: D200XTileAppearance(label: "Work", backgroundHex: "445566")
            ]
        )
        return configuration
    }

    private func makeModel(configurationURL: URL, store: ConfigurationStore) -> AppModel {
        AppModel(
            configurationURL: configurationURL,
            store: store,
            bolt: ApplicationContextRemovalNoopBindingSession(),
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
                XCTFail("Application removal tests must not post keyboard events")
            }),
            loadImmediately: false,
            observeSleep: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggApplicationContextRemoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct ApplicationContextRemovalNoopBindingSession: BindingSession {
    let events = AsyncStream<BoltEvent> { $0.finish() }

    func discover() async {}
    func enable() async {}
    func disable() async {}
    func stop() async {}

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }
}
