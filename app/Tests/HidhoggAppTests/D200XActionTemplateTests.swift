import AppKit
import HidhoggDomain
import XCTest
@testable import HidhoggApp

@MainActor
final class D200XActionTemplateTests: XCTestCase {
    func testCatalogCoversAllSupportedActionsAndNone() throws {
        XCTAssertEqual(D200XActionTemplate.allCases.count, 16)
        XCTAssertEqual(
            Set(D200XActionTemplate.allCases.map(\.title)),
            Set([
                "Play/Pause", "Next Track", "Previous Track", "Volume Up", "Volume Down", "Mute",
                "Set Volume", "Bell", "Play Sound…", "Open Application…", "Open File…", "Open URL",
                "Deck Notification", "Keyboard Shortcut", "Lock Screen", "Custom Executable"
            ])
        )
        XCTAssertTrue(D200XActionTemplate.allCases.allSatisfy { !$0.systemSymbol.isEmpty })
        XCTAssertEqual(D200XPresetActionDraft().summary, "None")
        XCTAssertEqual(D200XPresetActionDraft().systemSymbol, "minus.circle")
        XCTAssertNil(try D200XPresetActionDraft().snapshot(actionID: "unused").binding)
    }

    func testBuiltInTilePresetAppearanceIsBlackAndIconOnly() {
        for template in D200XActionTemplate.allCases {
            XCTAssertEqual(template.defaultTilePresetAppearance.backgroundHex, "000000", template.title)
            XCTAssertFalse(template.defaultTilePresetAppearance.showTitle, template.title)
        }
    }

    func testReadyTemplatesHaveUsableDefaultsAndConfigurableTemplatesDoNotUseExamples() throws {
        let configurable: Set<D200XActionTemplate> = [
            .playSound, .openApplication, .openFile, .openURL, .deckNotification, .shortcut, .customExecutable
        ]

        for template in D200XActionTemplate.allCases {
            let draft = D200XPresetActionDraft(template: template)
            XCTAssertEqual(template.requiresConfiguration, configurable.contains(template), template.title)
            if template.requiresConfiguration {
                XCTAssertNotNil(draft.validationMessage, template.title)
                XCTAssertThrowsError(try draft.snapshot(actionID: "copy-action"), template.title)
            } else {
                XCTAssertNil(draft.validationMessage, template.title)
            }
        }

        for template in [D200XActionTemplate.playSound, .openApplication, .openFile, .openURL] {
            XCTAssertNil(D200XPresetActionDraft(template: template).nativeAction.target)
        }
        let notification = D200XPresetActionDraft(template: .deckNotification).nativeAction
        XCTAssertNil(notification.topic)
        XCTAssertNil(notification.text)
        XCTAssertNil(notification.appID)
        XCTAssertNil(D200XPresetActionDraft(template: .shortcut).nativeAction.shortcut)

        let setVolume = D200XPresetActionDraft(template: .volumeSet)
        XCTAssertEqual(setVolume.nativeAction.volume, .set)
        XCTAssertEqual(setVolume.nativeAction.percent, 50)

        for level in [0, 37, 100] {
            var customLevel = setVolume
            customLevel.nativeAction.percent = level
            XCTAssertNil(customLevel.validationMessage)
            XCTAssertEqual(customLevel.template, .volumeSet)
            let snapshot = try customLevel.snapshot(actionID: "volume-\(level)")
            XCTAssertEqual(snapshot.nativeActions["volume-\(level)"]?.percent, level)
        }

        let executable = D200XPresetActionDraft(template: .customExecutable).executable
        XCTAssertTrue(executable.executable.isEmpty)
        XCTAssertTrue(executable.arguments.isEmpty)
        XCTAssertNil(executable.workingDirectory)
    }

    func testDraftSnapshotsAreCopiesAndKeepInlineShortcutAssignments() throws {
        let media = D200XPresetActionDraft(template: .playPause)
        let mediaSnapshot = try media.snapshot(actionID: "generated-action")
        XCTAssertEqual(mediaSnapshot.binding, .action("generated-action"))
        XCTAssertEqual(mediaSnapshot.nativeActions["generated-action"], NativeAction(kind: .media, media: .playPause))

        var shortcut = D200XPresetActionDraft(template: .shortcut)
        let key = HidhoggDomain.KeyboardShortcut(keyCode: 4, modifiers: [.command])
        shortcut.nativeAction.shortcut = key
        let shortcutSnapshot = try shortcut.snapshot(actionID: "unused")
        XCTAssertEqual(shortcutSnapshot.binding, .key(key))
        XCTAssertTrue(shortcutSnapshot.nativeActions.isEmpty)

        let lockScreen = try D200XPresetActionDraft(template: .lockScreen).snapshot(actionID: "lock-copy")
        XCTAssertEqual(lockScreen.nativeActions["lock-copy"], NativeAction(kind: .lockScreen))
    }

    func testExistingDefinitionsBecomeIndependentEditableSnapshots() throws {
        let executable = ConfiguredExecutable(executable: "/synthetic/build", arguments: ["--dry-run"])
        let executableDraft = D200XPresetActionDraft(
            binding: .action("source"),
            actions: ["source": executable],
            nativeActions: [:]
        )
        XCTAssertEqual(executableDraft.kind, .executable)
        XCTAssertEqual(try executableDraft.snapshot(actionID: "copied-action").actions, ["copied-action": executable])

        let lock = NativeAction(kind: .lockScreen)
        let nativeDraft = D200XPresetActionDraft(
            binding: .action("source"),
            actions: [:],
            nativeActions: ["source": lock]
        )
        XCTAssertEqual(nativeDraft.kind, .native)
        XCTAssertEqual(try nativeDraft.snapshot(actionID: "copied-lock").nativeActions, ["copied-lock": lock])
    }

    func testTemplateIconsAreBoundedTransparentWhitePNGFiles() throws {
        let symbols = D200XActionTemplate.allCases.map(\.systemSymbol) + ["minus.circle"]
        for symbol in symbols {
            let data = try D200XPresetIconRenderer.pngData(systemSymbol: symbol)
            XCTAssertLessThanOrEqual(data.count, D200XPresetIconRenderer.maximumPNGBytes, symbol)
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10], symbol)

            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), symbol)
            XCTAssertEqual(bitmap.pixelsWide, D200XPresetIconRenderer.pixelSize, symbol)
            XCTAssertEqual(bitmap.pixelsHigh, D200XPresetIconRenderer.pixelSize, symbol)
            let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB), symbol)
            XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.01, symbol)

            let hasOpaqueWhiteGlyphPixel = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.alphaComponent >= 0.99
                        && color.redComponent > 0.9
                        && color.greenComponent > 0.9
                        && color.blueComponent > 0.9
                }
            }
            XCTAssertTrue(hasOpaqueWhiteGlyphPixel, symbol)
        }
    }

    func testTemplateIconGlyphIsVerticallyCentered() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: D200XPresetIconRenderer.pngData(systemSymbol: "lock.fill")))
        var minimumY = bitmap.pixelsHigh
        var maximumY = -1

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.1 else { continue }
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)
            }
        }

        let glyphCenter = Double(minimumY + maximumY) / 2
        let canvasCenter = Double(bitmap.pixelsHigh - 1) / 2
        XCTAssertLessThanOrEqual(abs(glyphCenter - canvasCenter), 10)
    }

    func testPresetPreviewIconMatchesStoredAssetAndKeepsTitleVisible() throws {
        let icon = try D200XPresetIconRenderer.pngData(systemSymbol: "lock.fill")
        let assetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: assetDirectory) }
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)

        let assetReference = try D200XAssetStore(directory: assetDirectory).importImage(data: icon)
        let appearance = D200XTileAppearance(label: "Lock Screen", titlePlacement: .bottom)
        XCTAssertEqual(appearance.titlePlacement, .bottom)

        let generatedIconPreview = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: false,
            destination: .preview,
            presetIcon: icon
        )
        var materializedAppearance = appearance
        materializedAppearance.imageAsset = assetReference
        let materializedAssetPreview = try D200XPageRenderer.tilePNG(
            appearance: materializedAppearance,
            wide: false,
            assetDirectory: assetDirectory,
            destination: .preview
        )
        XCTAssertEqual(generatedIconPreview, materializedAssetPreview)

        let noIconPreview = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: false,
            destination: .preview
        )
        XCTAssertNotEqual(generatedIconPreview, noIconPreview)

        var noTitleAppearance = appearance
        noTitleAppearance.showTitle = false
        let noTitlePreview = try D200XPageRenderer.tilePNG(
            appearance: noTitleAppearance,
            wide: false,
            destination: .preview,
            presetIcon: icon
        )
        XCTAssertNotEqual(generatedIconPreview, noTitlePreview)
    }
}
