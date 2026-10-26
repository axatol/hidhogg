import Foundation
import CoreGraphics
import ImageIO
import HidhoggAutomation
import HidhoggDomain
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class D200XWorkspaceEvolutionTests: XCTestCase {
    func testHorizontalTitleAlignmentChangesOnlyTextPosition() throws {
        for wide in [false, true] {
            var origins: [Int] = []
            for alignment in D200XTitleAlignment.allCases {
                let data = try D200XPageRenderer.tilePNG(appearance: .init(label: "I", backgroundHex: "000000",
                    titleSize: 24, titleColorHex: "FFFFFF", titleAlignment: alignment), wide: wide)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, wide ? 458 : 196)
                XCTAssertEqual(image.height, 196)
                let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                var whiteXs: [Int] = []
                for y in 0..<image.height {
                    for x in 0..<image.width where bytes[(y * image.width + x) * 4] > 180 { whiteXs.append(x) }
                }
                origins.append(try XCTUnwrap(whiteXs.min()))
            }
            XCTAssertLessThan(origins[0], origins[1])
            XCTAssertLessThan(origins[1], origins[2])
        }
    }

    func testEditingAnotherProfileDoesNotChangeRuntimeSelection() throws {
        var foreground: String? = "com.example.Editor"
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { foreground })
        var configuration = D200XConfiguration(defaults: ["key0": .disabled],
            applications: ["com.example.Editor": [:], "com.example.Browser": [:]],
            tiles: ["key0": .init(label: "Default")],
            applicationTiles: ["com.example.Editor": ["key0": .init(label: "Editor")]])
        model.onEdit = { configuration = $0; model.synchronize($0, canEdit: true) }
        model.synchronize(configuration, canEdit: true)
        model.applicationID = "com.example.Browser"
        model.setAppearance(.init(label: "Browser"))
        XCTAssertEqual(model.appearance.label, "Browser")
        XCTAssertEqual(model.runtimeConfiguration?.appearance(for: .key0).label, "Editor")
        foreground = "com.example.Unmapped"
        model.refreshActiveApplication()
        XCTAssertEqual(model.runtimeConfiguration?.appearance(for: .key0).label, "Default")
        XCTAssertEqual(model.applicationID, "com.example.Browser")
        try model.setNotificationTopics([])
        XCTAssertEqual(configuration.applicationNotificationTopics["com.example.Browser"]?["key0"], [])
        model.resetSelectedAppearanceAndTopics()
        XCTAssertEqual(model.appearance.label, "Default")
        model.removeSelectedApplication()
        XCTAssertNil(configuration.applicationTiles["com.example.Browser"])
    }

    func testLiveListenerIsOptInBoundedAndUsesCanonicalPublisher() async throws {
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        model.synchronize(.empty, canEdit: true)
        let ignored = await model.publishNotification(topic: "build.finished", text: "Before listening", ttlSeconds: nil)
        XCTAssertNil(ignored.error)
        XCTAssertTrue(model.liveNotifications.isEmpty)
        model.setListening(true)
        for index in 0..<105 {
            let response = await model.publishNotification(topic: "build.finished", text: "Event \(index)", ttlSeconds: 5)
            XCTAssertNil(response.error)
        }
        XCTAssertEqual(model.liveNotifications.count, 100)
        XCTAssertEqual(model.liveNotifications.first?.text, "Event 5")
        XCTAssertEqual(model.liveNotifications.last?.outcome, "unhandled")
        let invalid = await model.publishNotification(topic: "build.*", text: "Invalid", ttlSeconds: nil)
        XCTAssertNotNil(invalid.error)
        XCTAssertEqual(model.liveNotifications.count, 100)
        model.setListening(false)
        XCTAssertTrue(model.liveNotifications.isEmpty)
        await model.stop()
    }

    func testPresetCopiesRemainIndependentAndConflictsDoNotOverwrite() throws {
        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        var configuration = D200XConfiguration(defaults: ["key0": .action("build")],
            tiles: ["key0": .init(label: "Original")], actions: ["build": .init(executable: "/usr/bin/true")])
        model.onEdit = { configuration = $0; model.synchronize($0, canEdit: true) }
        model.synchronize(configuration, canEdit: true)
        try model.saveTilePreset(id: "build-tile", name: "Build", includeAction: true)
        model.setAppearance(.init(label: "Changed"))
        XCTAssertEqual(configuration.tilePresets["build-tile"]?.appearance.label, "Original")
        model.selectedControl = .key1
        try model.applyTilePreset(id: "build-tile", includeAction: true)
        XCTAssertEqual(model.appearance.label, "Original")
        XCTAssertEqual(model.binding, .action("build"))
        try model.saveAction(id: "build", action: .init(executable: "/usr/bin/false"))
        model.selectedControl = .key2
        XCTAssertThrowsError(try model.applyTilePreset(id: "build-tile", includeAction: true))
        XCTAssertEqual(configuration.actions["build"]?.executable, "/usr/bin/false")
        try model.applyTilePreset(id: "build-tile", includeAction: false)
        XCTAssertEqual(model.binding, .disabled)
    }

    func testPortablePresetValidatesImageAndImportsOnlyAfterReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("assets")
        let image = try D200XPageRenderer.tilePNG(appearance: .init(label: "Image"), wide: false)
        let source = root.appendingPathComponent("input.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try image.write(to: source)
        let reference = try D200XAssetStore(directory: directory).importImage(from: source)
        let stored = try D200XAssetStore(directory: directory).imageData(for: reference)
        let preset = D200XTilePreset(name: "Portable", appearance: .init(imageAsset: reference),
            binding: .action("build"), actions: ["build": .init(executable: "/usr/bin/true")])
        let package = D200XTilePresetPackage(preset: preset, image: stored)
        let decoded = try D200XTilePresetPackage.decode(package.encoded(), assetDirectory: directory)
        XCTAssertEqual(decoded, package)
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: package.encoded()) as? [String: Any])
        var unknownPreset = try XCTUnwrap(unknown["preset"] as? [String: Any])
        unknownPreset["unrecognized"] = true
        unknown["preset"] = unknownPreset
        XCTAssertThrowsError(try D200XTilePresetPackage.decode(JSONSerialization.data(withJSONObject: unknown), assetDirectory: directory))
        var broken = package
        broken.image = Data("bad".utf8)
        XCTAssertThrowsError(try broken.validated(assetDirectory: directory))
        broken = package; broken.version = 3
        XCTAssertThrowsError(try broken.validated(assetDirectory: directory))

        let model = D200XModel(sender: noInputSender(), frontmostApplication: { nil })
        model.configureStorage(configurationURL: root.appendingPathComponent("other/config.toml"))
        var configuration = D200XConfiguration.empty
        model.onEdit = { configuration = $0; model.synchronize($0, canEdit: true) }
        model.synchronize(configuration, canEdit: true)
        try model.importTilePreset(package, id: "imported", includeAction: false)
        XCTAssertNil(configuration.tilePresets["imported"]?.binding)
        XCTAssertTrue(configuration.actions.isEmpty)
        XCTAssertThrowsError(try model.importTilePreset(package, id: "imported", includeAction: true))
        XCTAssertEqual(try model.tilePresetPackage(id: "imported").image, stored)
    }

    private func noInputSender() -> ShortcutSender {
        ShortcutSender(preflight: { false }, request: { XCTFail("No permission should be requested"); return false },
            postPair: { _ in XCTFail("No input should be posted") })
    }
}
