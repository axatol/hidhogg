import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI
import XCTest
@testable import HidhoggApp

@MainActor
final class D200XPresetOfflineLayoutTests: XCTestCase {
    func testPresetViewsRenderWithoutSavingRunningOrShowingWindows() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifacts = URL(fileURLWithPath: "/Volumes/Data/tmp/DX-PRESET-offscreen", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        let model = D200XModel(
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
                XCTFail("Rendering presets must not post input.")
            }),
            frontmostApplication: { nil }
        )
        model.configureStorage(configurationURL: directory.appendingPathComponent("config.toml"))
        let icon = try D200XPresetIconRenderer.pngData(systemSymbol: "lock.fill")
        let store = D200XAssetStore(directory: try XCTUnwrap(model.assetDirectory))
        let reference = try store.importImage(data: icon)
        let appearance = D200XTileAppearance(label: "Lock Screen", imageAsset: reference, titlePlacement: .bottom)
        let preset = D200XTilePreset(name: "Lock Screen", appearance: appearance, binding: .action("lock"),
                                    nativeActions: ["lock": .init(kind: .lockScreen)])
        let rotation = try D200XPresetRotationStarter.volume.makePreset()
        let configuration = D200XConfiguration(
            actions: ["example-script": .init(executable: "/usr/bin/true")],
            tilePresets: ["lock": preset],
            nativeActions: ["existing-lock": .init(kind: .lockScreen)],
            dialRotationPresets: ["volume": rotation]
        )
        model.synchronize(configuration, canEdit: true)
        var edits = 0
        model.onEdit = { _ in edits += 1 }

        let initialChooser = NSHostingView(rootView: D200XPresetChooserView(
            model: model,
            context: .init(control: .key0, applicationID: nil),
            onApply: { XCTFail("Measuring the chooser must not apply.") }
        ))
        XCTAssertEqual(initialChooser.fittingSize.width, 760, accuracy: 1)
        XCTAssertEqual(initialChooser.fittingSize.height, 580, accuracy: 1)

        let fixtures: [(String, AnyView, NSSize)] = [
            ("scripts", AnyView(ActionsView(model: model,
                onOpenTile: { _, _ in XCTFail("Rendering scripts must not navigate.") })), NSSize(width: 960, height: 760)),
            ("library", AnyView(TilePresetsView(model: model)), NSSize(width: 960, height: 760)),
            ("chooser", AnyView(D200XPresetChooserView(model: model,
                context: .init(control: .key0, applicationID: nil),
                onApply: { XCTFail("Rendering a chooser must not apply.") })), NSSize(width: 780, height: 660)),
            ("tile-editor", AnyView(ScrollView {
                TilePresetEditorView(model: model, selectedID: .constant(nil), draftID: .constant(UUID()),
                    onSaved: { _ in XCTFail("Rendering an editor must not save.") }, initialTemplate: .lockScreen)
                    .padding(16)
            }), NSSize(width: 580, height: 760)),
            ("rotation-editor", AnyView(ScrollView {
                DialRotationPresetEditorView(model: model, selectedID: .constant(nil), draftID: .constant(UUID()),
                    onSaved: { _ in XCTFail("Rendering an editor must not save.") }, initialPreset: rotation)
                    .padding(16)
            }), NSSize(width: 580, height: 760))
        ]

        for (name, root, size) in fixtures {
            let view = NSHostingView(rootView: root.frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            for _ in 0..<10 {
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(window.isVisible, "Offscreen fixture must never show a window.")
            XCTAssertFalse(window.isKeyWindow)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: artifacts.appendingPathComponent("\(name).png"))
            window.contentView = nil
            window.close()
        }

        for wide in [false, true] {
            let png = try D200XPageRenderer.tilePNG(appearance: appearance, wide: wide,
                                                  assetDirectory: model.assetDirectory, destination: .preview)
            try png.write(to: artifacts.appendingPathComponent(wide ? "wide-tile.png" : "square-tile.png"))
        }
        XCTAssertEqual(edits, 0)
        XCTAssertEqual(model.configuration, configuration)
        XCTAssertTrue(model.actionHistory.isEmpty)
        await model.stop()
    }
}
