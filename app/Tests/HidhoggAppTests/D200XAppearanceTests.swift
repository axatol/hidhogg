import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import HidhoggApp
import HidhoggDomain
import UniformTypeIdentifiers

final class D200XAppearanceTests: XCTestCase {
    func testImportStoresNormalizedContentAddressedPNG() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try makeImageData(type: .png, width: 2048, height: 1024).write(to: source)
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        let store = D200XAssetStore(directory: directory)

        let reference = try store.importImage(from: source)
        let normalized = try store.imageData(for: reference)
        let digest = SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(normalized as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        XCTAssertEqual(reference, "\(digest).png")
        XCTAssertEqual(normalized.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        XCTAssertLessThanOrEqual(image.width, 1024)
        XCTAssertLessThanOrEqual(image.height, 1024)
        XCTAssertEqual(try store.importImage(from: source), reference)

        let jpegSource = root.appendingPathComponent("source.jpeg")
        try makeImageData(type: .jpeg, width: 64, height: 32).write(to: jpegSource)
        let jpegReference = try store.importImage(from: jpegSource)
        XCTAssertEqual(try store.imageData(for: jpegReference).prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }

    func testRejectsOversizedStoredPNGDimensions() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oversizedPNG = try makeImageData(type: .png, width: 2048, height: 1)
        let digest = SHA256.hash(data: oversizedPNG).map { String(format: "%02x", $0) }.joined()
        let reference = "\(digest).png"
        try oversizedPNG.write(to: directory.appendingPathComponent(reference))

        XCTAssertThrowsError(try D200XAssetStore(directory: directory).imageData(for: reference))
    }

    func testRejectsMalformedAndOversizedInput() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = D200XAssetStore(directory: root.appendingPathComponent("assets", isDirectory: true))
        let malformed = root.appendingPathComponent("malformed.png")
        try Data("not an image".utf8).write(to: malformed)
        XCTAssertThrowsError(try store.importImage(from: malformed))

        let unsupported = root.appendingPathComponent("unsupported.gif")
        try makeImageData(type: .gif, width: 16, height: 16).write(to: unsupported)
        XCTAssertThrowsError(try store.importImage(from: unsupported))

        let oversized = root.appendingPathComponent("oversized.png")
        try Data(repeating: 0, count: D200XAssetStore.maximumInputBytes + 1).write(to: oversized)
        XCTAssertThrowsError(try store.importImage(from: oversized))
    }

    func testRejectsTraversalMissingReferencesAndAssetSymlinks() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = D200XAssetStore(directory: directory)

        XCTAssertThrowsError(try store.imageData(for: "../outside.png"))
        XCTAssertThrowsError(try store.imageData(for: "\(String(repeating: "0", count: 64)).png"))

        let linkedReference = "\(String(repeating: "a", count: 64)).png"
        let outsideImage = root.appendingPathComponent("outside.png")
        try makeImageData(type: .png, width: 16, height: 16).write(to: outsideImage)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(linkedReference),
            withDestinationURL: outsideImage
        )
        XCTAssertThrowsError(try store.imageData(for: linkedReference))
    }

    func testRejectsSymlinkInput() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try makeImageData(type: .png, width: 16, height: 16).write(to: source)
        let linkedSource = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: source)
        let store = D200XAssetStore(directory: root.appendingPathComponent("assets", isDirectory: true))

        XCTAssertThrowsError(try store.importImage(from: linkedSource))
    }

    func testRejectsSymlinkAssetDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("real-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let linkedDirectory = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: destination)
        let source = root.appendingPathComponent("source.png")
        try makeImageData(type: .png, width: 16, height: 16).write(to: source)

        XCTAssertThrowsError(try D200XAssetStore(directory: linkedDirectory).importImage(from: source))
    }

    func testRendererDrawsImageAndNotificationOverrideEvenWhenTitleIsHidden() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        let source = root.appendingPathComponent("tile.png")
        try makeImageData(type: .png, width: 64, height: 32).write(to: source)
        let assetReference = try D200XAssetStore(directory: directory).importImage(from: source)
        let configuration = D200XConfiguration(tiles: [
            "key0": D200XTileAppearance(
                label: "Fallback",
                backgroundHex: "000000",
                imageAsset: assetReference,
                titleSize: 22,
                titleColorHex: nil,
                titlePlacement: .center,
                showTitle: false
            )
        ])

        let imageOnly = try D200XPageRenderer.page(configuration: configuration, assetDirectory: directory)
        let notified = try D200XPageRenderer.page(
            configuration: configuration,
            labelOverrides: ["key0": "Notify"],
            assetDirectory: directory
        )
        let missingImageFallback = try D200XPageRenderer.page(configuration: configuration)
        let blankConfiguration = D200XConfiguration(tiles: [
            "key0": D200XTileAppearance(label: "Fallback", backgroundHex: "000000", showTitle: false)
        ])
        let blank = try D200XPageRenderer.page(configuration: blankConfiguration)
        let wideImageSource = try XCTUnwrap(CGImageSourceCreateWithData(
            try XCTUnwrap(imageOnly.slots["3_2"]?.image) as CFData,
            nil
        ))
        let wideImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(wideImageSource, 0, nil))

        XCTAssertNotEqual(try XCTUnwrap(imageOnly.slots["0_0"]?.image), try XCTUnwrap(blank.slots["0_0"]?.image))
        XCTAssertNotEqual(try XCTUnwrap(notified.slots["0_0"]?.image), try XCTUnwrap(imageOnly.slots["0_0"]?.image))
        XCTAssertEqual(wideImage.width, 458)
        XCTAssertEqual(wideImage.height, 196)
        XCTAssertNotEqual(
            try XCTUnwrap(missingImageFallback.slots["0_0"]?.image),
            try XCTUnwrap(blank.slots["0_0"]?.image)
        )
    }

    func testRendererReflectsTitleSizeColorAndPlacement() throws {
        let centered = D200XConfiguration(tiles: [
            "key0": D200XTileAppearance(
                label: "Visible",
                backgroundHex: "000000",
                titleSize: 12,
                titleColorHex: "FFFFFF",
                titlePlacement: .center
            )
        ])
        let customized = D200XConfiguration(tiles: [
            "key0": D200XTileAppearance(
                label: "Visible",
                backgroundHex: "000000",
                titleSize: 32,
                titleColorHex: "FF0000",
                titlePlacement: .top
            )
        ])

        let centeredPage = try D200XPageRenderer.page(configuration: centered)
        let customizedPage = try D200XPageRenderer.page(configuration: customized)

        XCTAssertNotEqual(centeredPage.slots["0_0"]?.image, customizedPage.slots["0_0"]?.image)
    }

    func testWideTitleMatchesSquareAtDisplayScaleWithoutChangingImagePixels() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appearance = D200XTileAppearance(
            label: "Wide glyph",
            backgroundHex: "000000",
            titleSize: 30,
            titleColorHex: "FFFFFF",
            titlePlacement: .center
        )

        for labelOverride in [nil, "Wide glyph"] as [String?] {
            let squareData = try D200XPageRenderer.tilePNG(
                appearance: appearance,
                wide: false,
                labelOverride: labelOverride
            )
            let wideData = try D200XPageRenderer.tilePNG(
                appearance: appearance,
                wide: true,
                labelOverride: labelOverride
            )
            let widePreviewData = try D200XPageRenderer.tilePNG(
                appearance: appearance,
                wide: true,
                labelOverride: labelOverride,
                destination: .preview
            )
            let squareNative = try rasterize(squareData)
            let wideNative = try rasterize(wideData)
            let widePreview = try rasterize(widePreviewData)

            XCTAssertEqual(squareNative.width, 196)
            XCTAssertEqual(squareNative.height, 196)
            XCTAssertEqual(wideNative.width, 458)
            XCTAssertEqual(wideNative.height, 196)
            XCTAssertEqual(widePreview.width, 196)
            XCTAssertEqual(widePreview.height, 98)

            let squareGlyphs = try glyphBounds(in: squareNative)
            let wideGlyphs = try glyphBounds(in: wideNative)
            XCTAssertLessThanOrEqual(
                abs(squareGlyphs.height - wideGlyphs.height),
                3,
                "Square and display-scaled wide titles should have comparable glyph height."
            )
        }

        let source = root.appendingPathComponent("tile.png")
        try makeImageData(type: .png, width: 64, height: 32).write(to: source)
        let assetReference = try D200XAssetStore(
            directory: root.appendingPathComponent("assets", isDirectory: true)
        ).importImage(from: source)
        var imageAppearance = appearance
        imageAppearance.imageAsset = assetReference
        var imageOnlyAppearance = imageAppearance
        imageOnlyAppearance.showTitle = false

        for wide in [false, true] {
            let titled = try rasterize(D200XPageRenderer.tilePNG(
                appearance: imageAppearance,
                wide: wide,
                assetDirectory: root.appendingPathComponent("assets", isDirectory: true)
            ))
            let imageOnly = try rasterize(D200XPageRenderer.tilePNG(
                appearance: imageOnlyAppearance,
                wide: wide,
                assetDirectory: root.appendingPathComponent("assets", isDirectory: true)
            ))
            let imageOnlyPreviewData = try D200XPageRenderer.tilePNG(
                appearance: imageOnlyAppearance,
                wide: wide,
                assetDirectory: root.appendingPathComponent("assets", isDirectory: true),
                destination: .preview
            )
            let imageOnlyPreview = try rasterize(
                imageOnlyPreviewData,
                width: wide ? 458 : 196,
                height: 196
            )

            XCTAssertEqual(titled.width, wide ? 458 : 196)
            XCTAssertEqual(titled.height, 196)
            XCTAssertEqual(imageOnly.width, titled.width)
            XCTAssertEqual(imageOnly.height, titled.height)
            XCTAssertEqual(imageOnlyPreview.width, imageOnly.width)
            XCTAssertEqual(imageOnlyPreview.height, imageOnly.height)
            let deviceImageBounds = try redBounds(in: imageOnly)
            let previewImageBounds = try redBounds(in: imageOnlyPreview)
            XCTAssertLessThanOrEqual(abs(deviceImageBounds.minX - previewImageBounds.minX), 2)
            XCTAssertLessThanOrEqual(abs(deviceImageBounds.midX - previewImageBounds.midX), 2)
            XCTAssertLessThanOrEqual(abs(deviceImageBounds.width - previewImageBounds.width), 2)
            let unchangedImagePixels = (0..<titled.height).reduce(into: 0) { count, y in
                for x in 0..<titled.width {
                    let original = imageOnly.pixel(x: x, y: y)
                    guard original[0] > 160, original[1] < 80, original[2] < 100 else { continue }
                    if titled.pixel(x: x, y: y) == original { count += 1 }
                }
            }
            XCTAssertGreaterThan(unchangedImagePixels, 200)
        }
    }

    func testDeviceWideTitleCalibrationPreservesPreviewSizeAndAlignmentAnchors() throws {
        let appearance = D200XTileAppearance(
            label: "Wide glyph",
            backgroundHex: "000000",
            titleSize: 30,
            titleColorHex: "FFFFFF",
            titlePlacement: .center
        )

        for alignment in [D200XTitleAlignment.left, .center, .right] {
            var alignedAppearance = appearance
            alignedAppearance.titleAlignment = alignment

            let squarePreview = try D200XPageRenderer.tilePNG(
                appearance: alignedAppearance,
                wide: false,
                destination: .preview
            )
            let squareDevice = try D200XPageRenderer.tilePNG(
                appearance: alignedAppearance,
                wide: false,
                destination: .device
            )
            XCTAssertEqual(squarePreview, squareDevice)
            let squareRaster = try rasterize(squarePreview)
            let squareGlyphs = try glyphBounds(in: squareRaster)
            XCTAssertEqual(squareRaster.width, 196)
            XCTAssertEqual(squareRaster.height, 196)

            for labelOverride in [nil, "Wide glyph"] as [String?] {
                let previewData = try D200XPageRenderer.tilePNG(
                    appearance: alignedAppearance,
                    wide: true,
                    labelOverride: labelOverride,
                    destination: .preview
                )
                let deviceData = try D200XPageRenderer.tilePNG(
                    appearance: alignedAppearance,
                    wide: true,
                    labelOverride: labelOverride,
                    destination: .device
                )
                let previewNative = try rasterize(previewData)
                let deviceNative = try rasterize(deviceData)
                let previewAtDeviceSize = try rasterize(previewData, width: 458, height: 196)

                XCTAssertEqual(previewNative.width, 196)
                XCTAssertEqual(previewNative.height, 98)
                XCTAssertEqual(deviceNative.width, 458)
                XCTAssertEqual(deviceNative.height, 196)
                XCTAssertEqual(previewAtDeviceSize.width, 458)
                XCTAssertEqual(previewAtDeviceSize.height, 196)

                let previewGlyphs = try glyphBounds(in: previewAtDeviceSize)
                let deviceGlyphs = try glyphBounds(in: deviceNative)
                let deviceWidthRatio = deviceGlyphs.width / previewGlyphs.width

                XCTAssertLessThanOrEqual(abs(squareGlyphs.height - previewGlyphs.height), 3)
                XCTAssertLessThanOrEqual(abs(previewGlyphs.height - deviceGlyphs.height), 3)
                XCTAssertEqual(deviceWidthRatio, 0.8, accuracy: 0.04)

                switch alignment {
                case .left:
                    XCTAssertLessThanOrEqual(abs(previewGlyphs.minX - deviceGlyphs.minX), 3)
                case .center:
                    XCTAssertLessThanOrEqual(abs(previewGlyphs.midX - deviceGlyphs.midX), 3)
                case .right:
                    XCTAssertLessThanOrEqual(abs(previewGlyphs.maxX - deviceGlyphs.maxX), 3)
                }
            }
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        let source = root.appendingPathComponent("tile.png")
        try makeImageData(type: .png, width: 64, height: 32).write(to: source)
        let assetReference = try D200XAssetStore(directory: directory).importImage(from: source)
        var imageAppearance = appearance
        imageAppearance.imageAsset = assetReference
        imageAppearance.showTitle = false

        let imagePreview = try D200XPageRenderer.tilePNG(
            appearance: imageAppearance,
            wide: true,
            assetDirectory: directory,
            destination: .preview
        )
        let imageDevice = try D200XPageRenderer.tilePNG(
            appearance: imageAppearance,
            wide: true,
            assetDirectory: directory,
            destination: .device
        )
        let imageRaster = try rasterize(imagePreview)
        XCTAssertEqual(imageRaster.width, 196)
        XCTAssertEqual(imageRaster.height, 98)
        let deviceRaster = try rasterize(imageDevice)
        XCTAssertEqual(deviceRaster.width, 458)
        XCTAssertEqual(deviceRaster.height, 196)
    }

    func testTilePreviewPNGMatchesPageSlotsForSquareAndWideTiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        let source = root.appendingPathComponent("tile.png")
        try makeImageData(type: .png, width: 48, height: 32).write(to: source)
        let assetReference = try D200XAssetStore(directory: directory).importImage(from: source)
        let appearance = D200XTileAppearance(
            label: "Tile",
            backgroundHex: "123456",
            imageAsset: assetReference,
            titleSize: 26,
            titleColorHex: "ABCDEF",
            titlePlacement: .bottom,
            showTitle: false
        )
        let configuration = D200XConfiguration(tiles: [
            "key0": appearance,
            "key13": appearance
        ])
        let page = try D200XPageRenderer.page(
            configuration: configuration,
            labelOverrides: ["key0": "Notification"],
            assetDirectory: directory
        )

        let square = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: false,
            labelOverride: "Notification",
            assetDirectory: directory
        )
        let wide = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: true,
            assetDirectory: directory
        )
        let widePreview = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: true,
            assetDirectory: directory,
            destination: .preview
        )

        XCTAssertEqual(page.slots["0_0"]?.image, square)
        XCTAssertEqual(page.slots["3_2"]?.image, wide)
        XCTAssertEqual(try rasterize(wide).width, 458)
        XCTAssertEqual(try rasterize(wide).height, 196)
        XCTAssertEqual(try rasterize(widePreview).width, 196)
        XCTAssertEqual(try rasterize(widePreview).height, 98)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("D200XAppearanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeImageData(type: UTType, width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw D200XAssetStore.Failure.invalidImage
        }
        context.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let filledImage = context.makeImage() else { throw D200XAssetStore.Failure.invalidImage }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw D200XAssetStore.Failure.invalidImage
        }
        CGImageDestinationAddImage(destination, filledImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw D200XAssetStore.Failure.invalidImage }
        return data as Data
    }

    private func rasterize(_ data: Data, scale: Int = 1) throws -> Raster {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width * scale
        let height = image.height * scale
        return try rasterize(image, width: width, height: height)
    }

    private func rasterize(_ data: Data, width: Int, height: Int) throws -> Raster {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try rasterize(image, width: width, height: height)
    }

    private func rasterize(_ image: CGImage, width: Int, height: Int) throws -> Raster {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try XCTUnwrap(context.data)
        return Raster(
            width: width,
            height: height,
            pixels: Array(UnsafeBufferPointer(
                start: pixels.assumingMemoryBound(to: UInt8.self),
                count: width * height * 4
            ))
        )
    }

    private func redBounds(in raster: Raster) throws -> CGRect {
        var minX = raster.width
        var minY = raster.height
        var maxX = -1
        var maxY = -1
        for y in 0..<raster.height {
            for x in 0..<raster.width {
                let pixel = raster.pixel(x: x, y: y)
                guard pixel[0] > 160, pixel[1] < 80, pixel[2] < 100 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { throw D200XAssetStore.Failure.invalidImage }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func glyphBounds(in raster: Raster) throws -> CGRect {
        var minX = raster.width
        var minY = raster.height
        var maxX = -1
        var maxY = -1
        for y in 0..<raster.height {
            for x in 0..<raster.width {
                let pixel = raster.pixel(x: x, y: y)
                guard pixel[0] > 64, pixel[1] > 64, pixel[2] > 64 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else {
            throw D200XAssetStore.Failure.invalidImage
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

private struct Raster {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    func pixel(x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[offset..<(offset + 4)])
    }
}
