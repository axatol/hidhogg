import Foundation
import HidhoggDomain
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class D200XPresetApplicationTests: XCTestCase {
    func testNoneOverridesInheritedActionAndCopiesTileAppearanceOnlyToScreens() throws {
        let profile = "com.example.Editor"
        let initial = D200XConfiguration(defaults: ["key0": .action("bell"), "dial0Press": .action("bell")],
            tiles: ["key0": .init(label: "Old")], nativeActions: ["bell": .init(kind: .bell)])
        let preset = D200XTilePreset(name: "Blank", appearance: .init(label: "Blank"))
        let result = try D200XPresetApplication.applying(preset, to: initial, control: .key0, applicationID: profile)
        XCTAssertEqual(result.applications[profile]?["key0"], .disabled)
        XCTAssertEqual(result.binding(for: .key0, application: profile), .disabled)
        XCTAssertEqual(result.defaults, initial.defaults)
        XCTAssertEqual(result.applicationTiles[profile]?["key0"], preset.appearance)
        for control in [D200XControl.dial0Press, .side0, .side1] {
            let actionOnly = try D200XPresetApplication.applying(preset, to: initial, control: control, applicationID: profile)
            XCTAssertEqual(actionOnly.applications[profile]?[control.rawValue], .disabled)
            XCTAssertEqual(actionOnly.tiles, initial.tiles)
            XCTAssertTrue(actionOnly.applicationTiles.isEmpty)
        }
        XCTAssertThrowsError(try D200XPresetApplication.applying(preset, to: initial, control: .dial0Left, applicationID: nil))
    }

    func testCollisionsAcrossBothActionMapsRemapWithoutOverwritingDefinitions() throws {
        let existingNative = NativeAction(kind: .bell)
        let existingExecutable = ConfiguredExecutable(executable: "/synthetic/existing")
        let preset = D200XDialRotationPreset(name: "Pair", left: .action("shared"), right: .action("other"),
            actions: ["shared": .init(executable: "/synthetic/copied")],
            nativeActions: ["other": .init(kind: .volume, volume: .up)])
        let initial = D200XConfiguration(actions: ["other": existingExecutable, "shared-preset-1": existingExecutable],
            nativeActions: ["shared": existingNative])
        let result = try D200XPresetApplication.applying(preset, to: initial, dialIndex: 0, applicationID: nil)
        XCTAssertEqual(result.nativeActions["shared"], existingNative)
        XCTAssertEqual(result.actions["other"], existingExecutable)
        XCTAssertEqual(result.actions["shared-preset-1"], existingExecutable)
        XCTAssertEqual(result.defaults["dial0Left"], .action("shared-preset-2"))
        XCTAssertEqual(result.defaults["dial0Right"], .action("other-preset-1"))
        XCTAssertEqual(result.actions["shared-preset-2"], preset.actions["shared"])
        XCTAssertEqual(result.nativeActions["other-preset-1"], preset.nativeActions["other"])
        XCTAssertEqual(try D200XPresetApplication.applying(preset, to: result, dialIndex: 0, applicationID: nil), result)
    }

    func testPairedApplicationPreservesOtherGesturesTopicsAppearanceAndOtherProfiles() throws {
        let initial = D200XConfiguration(defaults: ["dial1Press": .disabled, "dial1HeldLeft": .disabled],
            applications: ["com.example.Other": ["dial1Right": .disabled]],
            tiles: ["key0": .init(label: "Untouched")], notificationTopics: ["key0": ["build.*"]])
        let preset = rotation()
        let result = try D200XPresetApplication.applying(preset, to: initial, dialIndex: 1, applicationID: "com.example.Editor")
        XCTAssertEqual(result.defaults, initial.defaults)
        XCTAssertEqual(result.applications["com.example.Other"], initial.applications["com.example.Other"])
        XCTAssertEqual(result.applications["com.example.Editor"], ["dial1Left": preset.left, "dial1Right": preset.right])
        XCTAssertEqual(result.tiles, initial.tiles)
        XCTAssertEqual(result.notificationTopics, initial.notificationTopics)
        XCTAssertThrowsError(try D200XPresetApplication.applying(preset, to: initial, dialIndex: 3, applicationID: nil))
    }

    func testFreshSourceIdentifiersReuseIdenticalLockScreenWithoutActionGrowth() throws {
        var configuration = D200XConfiguration.empty
        for index in 0..<100 {
            let id = "fresh-\(index)"
            let preset = D200XTilePreset(name: "Lock Screen", appearance: .init(label: "Lock"), binding: .action(id),
                nativeActions: [id: .init(kind: .lockScreen)])
            configuration = try D200XPresetApplication.applying(preset, to: configuration, control: .key0, applicationID: nil)
            XCTAssertEqual(configuration.actionIDs, ["fresh-0"])
            XCTAssertEqual(configuration.defaults["key0"], .action("fresh-0"))
        }
    }

    func testDefinitionReusePrefersExactSourceThenSortedMatchAndSharesPairedDuplicates() throws {
        let bell = NativeAction(kind: .bell)
        let initial = D200XConfiguration(nativeActions: ["a": bell, "z": bell])
        let preset = D200XDialRotationPreset(name: "Bells", left: .action("z"), right: .action("fresh"),
            nativeActions: ["z": bell, "fresh": bell])
        let result = try D200XPresetApplication.applying(preset, to: initial, dialIndex: 0, applicationID: nil)
        XCTAssertEqual(result.defaults["dial0Left"], .action("z"))
        XCTAssertEqual(result.defaults["dial0Right"], .action("a"))
        XCTAssertEqual(result.nativeActions, initial.nativeActions)
        let duplicated = D200XDialRotationPreset(name: "Locks", left: .action("left"), right: .action("right"),
            nativeActions: ["left": .init(kind: .lockScreen), "right": .init(kind: .lockScreen)])
        let shared = try D200XPresetApplication.applying(duplicated, to: .empty, dialIndex: 0, applicationID: nil)
        XCTAssertEqual(shared.actionIDs, ["left"])
        XCTAssertEqual(shared.defaults["dial0Left"], shared.defaults["dial0Right"])
    }

    func testDefinitionReusePreservesDifferentNativeAndExecutableDefinitions() throws {
        let executable = ConfiguredExecutable(executable: "/synthetic/copied")
        let native = NativeAction(kind: .lockScreen)
        let initial = D200XConfiguration(actions: ["custom": .init(executable: "/synthetic/existing")],
            nativeActions: ["native": .init(kind: .bell)])
        let preset = D200XDialRotationPreset(name: "Mixed", left: .action("custom"), right: .action("native"),
            actions: ["custom": executable], nativeActions: ["native": native])
        let result = try D200XPresetApplication.applying(preset, to: initial, dialIndex: 0, applicationID: nil)
        XCTAssertEqual(result.actions["custom"], initial.actions["custom"])
        XCTAssertEqual(result.nativeActions["native"], initial.nativeActions["native"])
        XCTAssertEqual(result.actions["custom-preset-1"], executable)
        XCTAssertEqual(result.nativeActions["native-preset-1"], native)
        let fresh = D200XDialRotationPreset(name: "Mixed", left: .action("fresh-custom"), right: .action("fresh-native"),
            actions: ["fresh-custom": executable], nativeActions: ["fresh-native": native])
        XCTAssertEqual(try D200XPresetApplication.applying(fresh, to: result, dialIndex: 0, applicationID: nil), result)
    }

    func testActionLimitFailurePublishesNoPartialPairOrAppearance() throws {
        let actions = Dictionary(uniqueKeysWithValues: (0..<63).map { ("a\($0)", ConfiguredExecutable(executable: "/synthetic/action")) })
        let initial = D200XConfiguration(actions: actions)
        XCTAssertThrowsError(try D200XPresetApplication.applying(rotation(), to: initial, dialIndex: 0, applicationID: nil))
        XCTAssertTrue(initial.defaults.isEmpty)
        let tile = D200XTilePreset(name: "Bell", appearance: .init(label: "Bell"), binding: .action("new"),
            nativeActions: ["new": .init(kind: .bell)])
        let atLimit = try D200XPresetApplication.applying(tile, to: initial, control: .key0, applicationID: nil)
        XCTAssertEqual(atLimit.actionIDs.count, 64)
        XCTAssertThrowsError(try D200XPresetApplication.applying(rotation(), to: atLimit, dialIndex: 0, applicationID: nil))
        let newAction = D200XTilePreset(name: "Lock", appearance: .init(label: "Lock"), binding: .action("lock"),
            nativeActions: ["lock": .init(kind: .lockScreen)])
        XCTAssertThrowsError(try D200XPresetApplication.applying(newAction, to: atLimit, control: .key0, applicationID: nil))
    }

    func testSameActionInBothDirectionsRegistersOnceAndBoundsLongCollisionIDs() throws {
        let id = String(repeating: "a", count: 64)
        let preset = D200XDialRotationPreset(name: "Bell", left: .action(id), right: .action(id),
            nativeActions: [id: .init(kind: .bell)])
        let initial = D200XConfiguration(actions: [id: .init(executable: "/synthetic/existing")])
        let result = try D200XPresetApplication.applying(preset, to: initial, dialIndex: 0, applicationID: nil)
        XCTAssertEqual(result.actionIDs.count, 2)
        XCTAssertEqual(result.defaults["dial0Left"], result.defaults["dial0Right"])
        XCTAssertEqual(result.defaults["dial0Left"]?.actionID?.utf8.count, 64)
    }

    func testModelRejectsStaleTargetsAndPublishesOneCompletePairWithoutExecuting() throws {
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        let preset = rotation()
        let initial = D200XConfiguration(dialRotationPresets: ["volume": preset])
        model.synchronize(initial, canEdit: true)
        var edits: [D200XConfiguration] = []
        model.onEdit = { edits.append($0) }
        model.selectedControl = .dial1Press
        XCTAssertThrowsError(try model.applyDialRotationPreset(preset: preset, dialIndex: 0, applicationID: nil))
        XCTAssertThrowsError(try model.applyDialRotationPreset(preset: preset, dialIndex: 1, applicationID: "com.example.Stale"))
        XCTAssertThrowsError(try model.applyTilePreset(preset: .init(name: "Blank", appearance: .init()), control: .key0, applicationID: nil))
        XCTAssertTrue(edits.isEmpty)
        try model.applyDialRotationPreset(id: "volume", dialIndex: 1)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].defaults["dial1Left"], preset.left)
        XCTAssertEqual(edits[0].defaults["dial1Right"], preset.right)
        XCTAssertTrue(model.actionHistory.isEmpty)
    }

    func testDirectModelApplicationsRejectDeletedProfileWithoutRecreatingItAndAcceptExistingProfile() throws {
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        let profile = "com.example.Editor"
        let existing = D200XConfiguration(applications: [profile: [:]])
        model.synchronize(existing, canEdit: true)
        model.applicationID = profile
        model.synchronize(.empty, canEdit: true)
        var edits: [D200XConfiguration] = []
        model.onEdit = { edits.append($0) }
        let tile = D200XTilePreset(name: "Blank", appearance: .init(label: "Blank"))
        model.selectedControl = .key0
        XCTAssertThrowsError(try model.applyTilePreset(preset: tile, control: .key0, applicationID: profile))
        model.selectedControl = .dial0Press
        XCTAssertThrowsError(try model.applyDialRotationPreset(preset: rotation(), dialIndex: 0, applicationID: profile))
        XCTAssertTrue(edits.isEmpty)
        XCTAssertEqual(model.configuration, .empty)

        model.synchronize(existing, canEdit: true)
        model.selectedControl = .key0
        try model.applyTilePreset(preset: tile, control: .key0, applicationID: profile)
        model.selectedControl = .dial0Press
        try model.applyDialRotationPreset(preset: rotation(), dialIndex: 0, applicationID: profile)
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0].applications[profile]?["key0"], .disabled)
        XCTAssertEqual(edits[1].applications[profile]?["dial0Left"], rotation().left)
        XCTAssertEqual(edits[1].applications[profile]?["dial0Right"], rotation().right)
    }

    func testModelLimitFailureAndLibrarySaveImportDoNotPublishOrExecuteAssignments() throws {
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        var configuration = D200XConfiguration()
        var edits = 0
        model.onEdit = { configuration = $0; edits += 1; model.synchronize($0, canEdit: true) }
        model.synchronize(configuration, canEdit: true)
        let preset = rotation()
        try model.saveDialRotationPreset(id: "volume", preset: preset)
        XCTAssertTrue(configuration.nativeActions.isEmpty)
        XCTAssertTrue(configuration.defaults.isEmpty)
        XCTAssertThrowsError(try model.saveDialRotationPreset(id: "volume", preset: preset))
        let package = try model.dialRotationPresetPackage(id: "volume")
        try model.importDialRotationPreset(package, id: "imported")
        XCTAssertTrue(configuration.nativeActions.isEmpty)
        XCTAssertEqual(edits, 2)
        var changed = preset
        changed.name = "Changed"
        try model.saveDialRotationPreset(id: "volume", preset: changed, replacing: preset)
        XCTAssertThrowsError(try model.saveDialRotationPreset(id: "volume", preset: preset, replacing: preset))
        model.removeDialRotationPreset(id: "volume")
        XCTAssertNil(configuration.dialRotationPresets["volume"])
        configuration.actions = Dictionary(uniqueKeysWithValues: (0..<63).map { ("a\($0)", .init(executable: "/synthetic/action")) })
        model.synchronize(configuration, canEdit: true)
        model.selectedControl = .dial0Press
        let before = edits
        XCTAssertThrowsError(try model.applyDialRotationPreset(id: "imported", dialIndex: 0))
        XCTAssertEqual(edits, before)
        XCTAssertTrue(model.actionHistory.isEmpty)
    }

    func testDataImageImportUsesNormalizedAssetPathWithoutConfigurationEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        model.configureStorage(configurationURL: root.appendingPathComponent("config.toml"))
        model.synchronize(.empty, canEdit: true)
        model.onEdit = { _ in XCTFail("Import must not publish a configuration edit") }
        let png = try D200XPageRenderer.tilePNG(appearance: .init(label: "Icon"), wide: false)
        let reference = try await model.importPresetImage(data: png)
        XCTAssertTrue(D200XTileAppearance.isValidAssetReference(reference))
        let store = D200XAssetStore(directory: try XCTUnwrap(model.assetDirectory))
        try store.validateAsset(store.imageData(for: reference), reference: reference)
        XCTAssertThrowsError(try store.importImage(data: Data(repeating: 0, count: D200XAssetStore.maximumInputBytes + 1)))
    }

    private func rotation() -> D200XDialRotationPreset {
        .init(name: "Volume", left: .action("down"), right: .action("up"),
            nativeActions: ["down": .init(kind: .volume, volume: .down), "up": .init(kind: .volume, volume: .up)])
    }

    private func noInputSender() -> ShortcutSender {
        ShortcutSender(preflight: { XCTFail("No permission checks"); return false },
            request: { XCTFail("No permission requests"); return false }, postPair: { _ in XCTFail("No input") })
    }
}
