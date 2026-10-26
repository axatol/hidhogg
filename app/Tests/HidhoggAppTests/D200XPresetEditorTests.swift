import Foundation
import HidhoggDomain
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class D200XPresetEditorTests: XCTestCase {
    func testIndependentPresetSaveAndUpdateDoNotChangeAppliedConfiguration() throws {
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        var configuration = fixtureConfiguration()
        model.onEdit = { value in
            configuration = value
            model.synchronize(value, canEdit: true)
        }
        model.synchronize(configuration, canEdit: true)
        model.selectedControl = .side0
        model.applicationID = "com.example.Editor"

        let presetID = "release-card"
        let original = fixturePreset(name: "Release")
        try model.saveTilePreset(id: presetID, preset: original)

        XCTAssertEqual(model.selectedControl, .side0)
        XCTAssertEqual(configuration.tilePresets[presetID], original)
        var expected = fixtureConfiguration()
        expected.tilePresets[presetID] = original
        XCTAssertEqual(configuration, expected)

        let capturedOriginal = try XCTUnwrap(configuration.tilePresets[presetID])
        var edited = capturedOriginal
        edited.name = "Release candidate"
        edited.appearance = .init(label: "Candidate", backgroundHex: "AA5500", titleSize: 31,
            titleColorHex: "FFFFFF", titlePlacement: .top, titleAlignment: .right)
        edited.binding = .action("candidate-action")
        edited.actions = ["candidate-action": .init(executable: "/usr/bin/true", arguments: ["--dry-run"])]

        try model.saveTilePreset(id: presetID, preset: edited, replacing: capturedOriginal)

        XCTAssertEqual(model.selectedControl, .side0)
        XCTAssertEqual(configuration.tilePresets[presetID], edited)
        expected.tilePresets[presetID] = edited
        XCTAssertEqual(configuration, expected)
    }

    func testPresetEditorRejectsDuplicateStaleDeletedAndInvalidSnapshotsWithoutOverwrite() throws {
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        var configuration = fixtureConfiguration()
        model.onEdit = { value in
            configuration = value
            model.synchronize(value, canEdit: true)
        }
        model.synchronize(configuration, canEdit: true)
        model.selectedControl = .side0

        let presetID = "release-card"
        let initial = fixturePreset(name: "Initial")
        try model.saveTilePreset(id: presetID, preset: initial)
        let afterCreate = configuration

        XCTAssertThrowsError(try model.saveTilePreset(id: presetID, preset: fixturePreset(name: "Duplicate")))
        XCTAssertEqual(configuration, afterCreate)

        var updated = initial
        updated.name = "Updated"
        try model.saveTilePreset(id: presetID, preset: updated, replacing: initial)
        let afterUpdate = configuration

        var staleEdit = initial
        staleEdit.name = "Stale edit"
        XCTAssertThrowsError(try model.saveTilePreset(id: presetID, preset: staleEdit, replacing: initial))
        XCTAssertEqual(configuration, afterUpdate)

        var invalid = fixturePreset(name: " ")
        invalid.appearance.titleSize = 49
        XCTAssertThrowsError(try model.saveTilePreset(id: "invalid-card", preset: invalid))
        XCTAssertEqual(configuration, afterUpdate)

        model.removeTilePreset(id: presetID)
        let afterDelete = configuration
        XCTAssertThrowsError(try model.saveTilePreset(id: presetID, preset: fixturePreset(name: "Resurrected"), replacing: updated))
        XCTAssertEqual(configuration, afterDelete)
    }

    func testPresetImageImportDoesNotRequireTileSelectionOrEditConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        let initial = fixtureConfiguration()
        var configuration = initial
        model.onEdit = { value in
            configuration = value
            model.synchronize(value, canEdit: true)
        }
        model.configureStorage(configurationURL: root.appendingPathComponent("config.toml"))
        model.synchronize(initial, canEdit: true)
        model.selectedControl = .side0
        model.applicationID = "com.example.Editor"

        let source = root.appendingPathComponent("preset.png")
        try D200XPageRenderer.tilePNG(appearance: .init(label: "Preset image"), wide: false).write(to: source)

        let reference = try await model.importPresetImage(from: source)

        XCTAssertEqual(model.selectedControl, .side0)
        XCTAssertEqual(configuration, initial)
        XCTAssertEqual(try D200XAssetStore(directory: try XCTUnwrap(model.assetDirectory)).imageData(for: reference).prefix(8),
            Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }

    func testPortablePresetPackagesKeepExecutableV1AndRequireV2ForNativeActions() throws {
        let assetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = D200XTilePresetPackage(
            version: 1,
            preset: D200XTilePreset(
                name: "Legacy build",
                appearance: .init(label: "Build"),
                binding: .action("build"),
                actions: ["build": .init(executable: "/synthetic/build")]
            ),
            image: nil
        )

        let encodedExecutable = try executable.encoded()
        XCTAssertEqual(try D200XTilePresetPackage.decode(encodedExecutable, assetDirectory: assetDirectory), executable)

        let nativeAction = NativeAction(kind: .deckNotification, topic: "build.finished", text: "Complete", ttlSeconds: 60)
        let nativePreset = D200XTilePreset(
            name: "Build notice",
            appearance: .init(label: "Build"),
            binding: .action("notify"),
            nativeActions: ["notify": nativeAction]
        )
        let nativeVersionOne = D200XTilePresetPackage(version: 1, preset: nativePreset, image: nil)
        XCTAssertThrowsError(try D200XTilePresetPackage.decode(try nativeVersionOne.encoded(), assetDirectory: assetDirectory))

        let nativeVersionTwo = D200XTilePresetPackage(version: 2, preset: nativePreset, image: nil)
        let encodedNative = try nativeVersionTwo.encoded()
        XCTAssertEqual(try D200XTilePresetPackage.decode(encodedNative, assetDirectory: assetDirectory), nativeVersionTwo)

        let unsupported = D200XTilePresetPackage(version: 3, preset: nativePreset, image: nil)
        XCTAssertThrowsError(try D200XTilePresetPackage.decode(try unsupported.encoded(), assetDirectory: assetDirectory))

        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        model.configureStorage(configurationURL: assetDirectory.appendingPathComponent("config.toml"))
        model.synchronize(D200XConfiguration(tilePresets: ["legacy-build": executable.preset, "native-notice": nativePreset]), canEdit: true)
        XCTAssertEqual(try model.tilePresetPackage(id: "legacy-build").version, 1)
        XCTAssertEqual(try model.tilePresetPackage(id: "native-notice").version, 2)
    }

    func testApplyingNativePresetActionRejectsConflictWithoutChangingTilesOrRegistry() throws {
        let existingAction = NativeAction(kind: .bell)
        let conflictingPresetAction = NativeAction(kind: .volume, volume: .up)
        let preset = D200XTilePreset(
            name: "Volume preset",
            appearance: .init(label: "Volume", backgroundHex: "334455"),
            binding: .action("shared-native-action"),
            nativeActions: ["shared-native-action": conflictingPresetAction]
        )
        let configuration = D200XConfiguration(
            defaults: ["key0": .disabled],
            tiles: ["key1": .init(label: "Unchanged", backgroundHex: "112233")],
            tilePresets: ["volume-copy": preset],
            nativeActions: ["shared-native-action": existingAction]
        )
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        model.synchronize(configuration, canEdit: true)
        model.selectedControl = .key1

        XCTAssertThrowsError(try model.applyTilePreset(id: "volume-copy", includeAction: true))
        XCTAssertEqual(model.configuration, configuration)
        XCTAssertEqual(model.appearance.label, "Unchanged")
        XCTAssertEqual(model.configuration?.actionDefinition(id: "shared-native-action"), .native(existingAction))
    }

    private func fixtureConfiguration() -> D200XConfiguration {
        D200XConfiguration(
            defaults: ["key0": .disabled],
            applications: ["com.example.Editor": ["key0": .disabled]],
            tiles: ["key0": .init(label: "Default tile", backgroundHex: "112233")],
            actions: ["existing-action": .init(executable: "/usr/bin/true")],
            notificationTopics: ["key0": ["build.finished"]],
            applicationTiles: ["com.example.Editor": ["key0": .init(label: "Editor tile", backgroundHex: "445566")]],
            applicationNotificationTopics: ["com.example.Editor": ["key0": ["build.started"]]]
        )
    }

    private func fixturePreset(name: String) -> D200XTilePreset {
        D200XTilePreset(
            name: name,
            appearance: .init(label: "Release", backgroundHex: "225577", titleSize: 18),
            binding: .action("release-action"),
            actions: ["release-action": .init(executable: "/usr/bin/true")]
        )
    }

    private func noInputSender() -> ShortcutSender {
        ShortcutSender(preflight: { false }, request: { XCTFail("No permission should be requested"); return false },
            postPair: { _ in XCTFail("No input should be posted") })
    }
}
