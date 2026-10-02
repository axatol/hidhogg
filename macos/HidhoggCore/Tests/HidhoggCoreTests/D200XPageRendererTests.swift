import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import HidhoggCore

final class D200XPageRendererTests: XCTestCase {
    func testBlankFullPageArchiveHasCanonicalManifestDeduplicatedImagesAndSafePadding() throws {
        let update = try D200XPageRenderer.render(profile: decodeD200XProfile())
        let repeated = try D200XPageRenderer.render(profile: decodeD200XProfile())
        XCTAssertEqual(update.archive, repeated.archive)
        XCTAssertEqual(update.positions.map(\.position), HidhoggConfiguration.supportedPositions.map(\.name))

        let members = try parseClassicZIP(update.archive.data)
        let manifest = try JSONDecoder().decode([String: TestManifestEntry].self, from: XCTUnwrap(members.first(where: { $0.name == "manifest.json" })).data)
        XCTAssertEqual(Set(manifest.keys), Set(HidhoggConfiguration.supportedPositions.map(\.name)))
        XCTAssertEqual(manifest.count, 14)

        let images = Dictionary(uniqueKeysWithValues: members.filter { $0.name.hasPrefix("Images/") }.map { ($0.name, $0.data) })
        XCTAssertEqual(images.count, 2)
        var squarePaths = Set<String>()
        for (index, spec) in HidhoggConfiguration.supportedPositions.enumerated() {
            let entry = try XCTUnwrap(manifest[spec.name])
            XCTAssertEqual(entry.state, 0)
            XCTAssertEqual(entry.viewParam.count, 1)
            let view = try XCTUnwrap(entry.viewParam.first)
            XCTAssertEqual(view.text, "")
            XCTAssertEqual(view.font.align, "bottom")
            XCTAssertEqual(view.font.color, 16_777_215)
            XCTAssertEqual(view.font.fontName, "Source Han Sans SC")
            XCTAssertFalse(view.font.showTitle)
            XCTAssertEqual(view.font.size, 10)
            XCTAssertEqual(view.font.weight, 80)
            XCTAssertEqual(entry.smallViewMode, spec.isWide ? 2 : nil)
            if !spec.isWide { squarePaths.insert(view.icon) }

            let png = try XCTUnwrap(images[view.icon])
            XCTAssertEqual(view.icon, "Images/\(sha256Hex(png)).png")
            let geometry = try XCTUnwrap(pngGeometry(png))
            XCTAssertEqual(geometry.width, spec.isWide ? 458 : 196)
            XCTAssertEqual(geometry.height, 196)
            XCTAssertEqual(index, Int(spec.wireIndex))
        }
        XCTAssertEqual(squarePaths.count, 1)

        for offset in stride(from: D200XFrameCodec.firstPayloadCapacity, to: update.archive.data.count, by: D200XFrameCodec.packetSize) {
            XCTAssertNotEqual(update.archive.data[offset], 0)
            XCTAssertNotEqual(update.archive.data[offset], 0x7c)
        }
        if update.archive.paddingLength > 0 {
            XCTAssertEqual(members.first?.name, "dummy.txt")
            XCTAssertEqual(members.first?.method, 0)
            XCTAssertEqual(members.first?.data.count, update.archive.paddingLength)
            XCTAssertTrue(try XCTUnwrap(members.first?.data).allSatisfy { $0 == 0 })
        }
    }

    func testManifestKeepsFirmwareLabelFieldsAndWideImageContentAddressing() throws {
        let base = try D200XPageRenderer.render(profile: decodeD200XProfile())
        let profile = try decodeD200XProfile(positionFields: [
            "0_0": "label = \"Square\"",
            "3_2": "label = \"Enter 0123456789.*+\", background = \"#10203080\", label_alignment = \"center\", label_size = 24",
        ])
        let first = try D200XPageRenderer.render(profile: profile)
        let second = try D200XPageRenderer.render(profile: profile)
        XCTAssertEqual(first.archive, second.archive)
        XCTAssertNotEqual(base.archive.data, first.archive.data)

        let members = try parseClassicZIP(first.archive.data)
        let manifest = try JSONDecoder().decode([String: TestManifestEntry].self, from: XCTUnwrap(members.first(where: { $0.name == "manifest.json" })).data)
        let square = try XCTUnwrap(manifest["0_0"])
        XCTAssertTrue(try XCTUnwrap(square.viewParam.first).font.showTitle)
        XCTAssertNil(square.smallViewMode)

        let wide = try XCTUnwrap(manifest["3_2"])
        XCTAssertEqual(wide.smallViewMode, 2)
        XCTAssertFalse(try XCTUnwrap(wide.viewParam.first).font.showTitle)
        XCTAssertEqual(try XCTUnwrap(wide.viewParam.first).font.align, "center")
        XCTAssertEqual(try XCTUnwrap(wide.viewParam.first).font.size, 24)
        XCTAssertEqual(try XCTUnwrap(wide.viewParam.first).text, "Enter 0123456789.*+")

        let images = Dictionary(uniqueKeysWithValues: members.filter { $0.name.hasPrefix("Images/") }.map { ($0.name, $0.data) })
        let widePNG = try XCTUnwrap(images[try XCTUnwrap(wide.viewParam.first).icon])
        XCTAssertEqual(try XCTUnwrap(wide.viewParam.first).icon, "Images/\(sha256Hex(widePNG)).png")
        let baseMembers = try parseClassicZIP(base.archive.data)
        let baseManifestData = try XCTUnwrap(baseMembers.first(where: { $0.name == "manifest.json" })).data
        let baseManifest = try JSONDecoder().decode([String: TestManifestEntry].self, from: baseManifestData)
        let baseWideIcon = try XCTUnwrap(baseManifest["3_2"]?.viewParam.first?.icon)
        XCTAssertNotEqual(try XCTUnwrap(wide.viewParam.first).icon, baseWideIcon)
    }

    func testBlankAndLabeledTilesPreserveRGBAAndBorderSemantics() throws {
        let blankProfile = try decodeD200XProfile(positionFields: ["0_0": "background = \"#10203080\""])
        let blank = try D200XPageRenderer.render(profile: blankProfile)
        let blankMembers = try parseClassicZIP(blank.archive.data)
        let blankManifest = try JSONDecoder().decode([String: TestManifestEntry].self, from: XCTUnwrap(blankMembers.first(where: { $0.name == "manifest.json" })).data)
        let blankIcon = try XCTUnwrap(blankManifest["0_0"]?.viewParam.first?.icon)
        let blankPNG = try XCTUnwrap(blankMembers.first(where: { $0.name == blankIcon }))
        let blankPixels = try decodeRGBA(blankPNG.data)
        XCTAssertEqual(blankPixels.pixel(x: 0, y: 0), [16, 32, 48, 128])
        XCTAssertEqual(blankPixels.pixel(x: 5, y: 5), [16, 32, 48, 128])
        XCTAssertTrue((0..<blankPixels.height).allSatisfy { y in
            (0..<blankPixels.width).allSatisfy { x in blankPixels.pixel(x: x, y: y) == [16, 32, 48, 128] }
        })

        let labeledProfile = try decodeD200XProfile(positionFields: ["0_0": "label = \"A\", background = \"#10203080\""])
        let labeled = try D200XPageRenderer.render(profile: labeledProfile)
        let labeledMembers = try parseClassicZIP(labeled.archive.data)
        let labeledManifest = try JSONDecoder().decode([String: TestManifestEntry].self, from: XCTUnwrap(labeledMembers.first(where: { $0.name == "manifest.json" })).data)
        let labeledIcon = try XCTUnwrap(labeledManifest["0_0"]?.viewParam.first?.icon)
        let labeledPNG = try XCTUnwrap(labeledMembers.first(where: { $0.name == labeledIcon }))
        let labeledPixels = try decodeRGBA(labeledPNG.data)
        XCTAssertEqual(labeledPixels.pixel(x: 0, y: 0), [250, 245, 239, 255])
        XCTAssertEqual(labeledPixels.pixel(x: 5, y: 5), [16, 32, 48, 128])
        XCTAssertEqual(labeledPixels.pixel(x: 195, y: 195), [250, 245, 239, 255])

    }

    func testTranslucentBackgroundsUseStraightRGBAAndNormalizeZeroAlphaRGB() throws {
        let cases: [(String, [UInt8])] = [
            ("#12345600", [0, 0, 0, 0]),
            ("#12345601", [18, 52, 86, 1]),
            ("#abcdef02", [171, 205, 239, 2]),
            ("#00ff7f7f", [0, 255, 127, 127]),
            ("#10203080", [16, 32, 48, 128]),
            ("#fedcbaFE", [254, 220, 186, 254]),
            ("#7f80ff", [127, 128, 255, 255]),
        ]
        for (background, expected) in cases {
            let wide = try widePixels(profile: decodeD200XProfile(positionFields: [
                "3_2": "background = \(tomlQuoted(background))",
            ]))
            XCTAssertTrue((0..<wide.height).allSatisfy { y in
                (0..<wide.width).allSatisfy { x in wide.pixel(x: x, y: y) == expected }
            }, "background \(background) should decode as straight RGBA \(expected)")
        }

        let labeled = try widePixels(profile: decodeD200XProfile(positionFields: [
            "3_2": "label = \"A\", background = \"#12345601\", label_alignment = \"center\", label_size = 24",
        ]))
        XCTAssertEqual(labeled.pixel(x: 10, y: 10), [18, 52, 86, 1])
        XCTAssertTrue(stride(from: 0, to: labeled.pixels.count, by: 4).allSatisfy { offset in
            let alpha = labeled.pixels[offset + 3]
            return alpha == 0 || labeled.pixels[offset] >= 18 && labeled.pixels[offset + 1] >= 52 && labeled.pixels[offset + 2] >= 86
        })
        XCTAssertTrue(stride(from: 0, to: labeled.pixels.count, by: 4).contains { offset in
            let alpha = labeled.pixels[offset + 3]
            return alpha > 1 && alpha < 255
        })
    }

    func testWideTextUsesContrastColorAndCompositesAntialiasingOverTranslucentBackground() throws {
        let fields = ["3_2": "label = \"Enter 0123456789.*+\", background = \"#10203080\", label_alignment = \"center\", label_size = 24"]
        let swift = try widePixels(profile: decodeD200XProfile(positionFields: fields))
        XCTAssertEqual(swift.pixel(x: 0, y: 0), [250, 245, 239, 255])
        XCTAssertEqual(swift.pixel(x: 10, y: 10), [16, 32, 48, 128])

        let antialiasedPixel = (5..<swift.height - 5).lazy.flatMap { y in
            (5..<swift.width - 5).lazy.map { x in swift.pixel(x: x, y: y) }
        }.first { $0[3] > 128 && $0[3] < 255 }
        XCTAssertNotNil(antialiasedPixel)
        let blendedPixel = try XCTUnwrap(antialiasedPixel)
        XCTAssertGreaterThan(blendedPixel[0], 16)
        XCTAssertGreaterThan(blendedPixel[3], 128)
        XCTAssertLessThan(blendedPixel[3], 255)

        let hasWhiteText = stride(from: 0, to: swift.pixels.count, by: 4).contains { offset in
            swift.pixels[offset] == 255 && swift.pixels[offset + 1] == 255 && swift.pixels[offset + 2] == 255 && swift.pixels[offset + 3] == 255
        }
        XCTAssertTrue(hasWhiteText)

        let brightBackground = try widePixels(profile: decodeD200XProfile(positionFields: [
            "3_2": "label = \"A\", background = \"#f0f0f0\", label_alignment = \"center\", label_size = 24",
        ]))
        let hasBlackText = stride(from: 0, to: brightBackground.pixels.count, by: 4).contains { offset in
            brightBackground.pixels[offset] == 0 && brightBackground.pixels[offset + 1] == 0 && brightBackground.pixels[offset + 2] == 0 && brightBackground.pixels[offset + 3] == 255
        }
        XCTAssertTrue(hasBlackText)
    }

    func testWideTextContrastSwitchesAtLuminanceThreshold() throws {
        let cases: [(String, [UInt8])] = [
            ("#7f7f7f", [255, 255, 255]),
            ("#808080", [0, 0, 0]),
        ]
        for (background, foreground) in cases {
            let image = try widePixels(profile: decodeD200XProfile(positionFields: [
                "3_2": "label = \"A\", background = \(tomlQuoted(background)), label_alignment = \"center\", label_size = 24",
            ]))
            let hasForeground = stride(from: 0, to: image.pixels.count, by: 4).contains { offset in
                image.pixels[offset] == foreground[0] &&
                    image.pixels[offset + 1] == foreground[1] &&
                    image.pixels[offset + 2] == foreground[2] &&
                    image.pixels[offset + 3] == 255
            }
            XCTAssertTrue(hasForeground, "background \(background) should use foreground \(foreground)")
        }
    }

    func testRejectsMissingDuplicateUnsupportedPositionsAndInvalidStyle() throws {
        let profile = try decodeD200XProfile()

        var missingPositions = profile.positions
        missingPositions.removeLast()
        let missing = profile.replacingPositions(missingPositions)
        XCTAssertThrowsError(try D200XPageRenderer.render(profile: missing)) {
            XCTAssertEqual($0 as? D200XPageRenderError, .invalidPositionCount(13))
        }

        var duplicatePositions = profile.positions
        duplicatePositions[13] = replacing(duplicatePositions[13], position: duplicatePositions[0].position)
        let duplicate = profile.replacingPositions(duplicatePositions)
        XCTAssertThrowsError(try D200XPageRenderer.render(profile: duplicate)) {
            XCTAssertEqual($0 as? D200XPageRenderError, .invalidPositionOrder(index: 13, actual: "0_0", expected: "unique coordinate"))
        }

        var unsupportedPositions = profile.positions
        unsupportedPositions[0] = replacing(unsupportedPositions[0], position: "0_9")
        let unsupported = profile.replacingPositions(unsupportedPositions)
        XCTAssertThrowsError(try D200XPageRenderer.render(profile: unsupported)) {
            XCTAssertEqual($0 as? D200XPageRenderError, .invalidPositionOrder(index: 0, actual: "missing", expected: "0_0"))
        }

        var invalidStylePositions = profile.positions
        invalidStylePositions[0] = replacing(invalidStylePositions[0], labelAlignment: "top")
        let invalidStyle = profile.replacingPositions(invalidStylePositions)
        XCTAssertThrowsError(try D200XPageRenderer.render(profile: invalidStyle)) {
            XCTAssertEqual($0 as? D200XPageRenderError, .invalidLabelStyle(index: 0))
        }
    }

    func testWideLabelShrinksAndWrapsAndLShapeStaysUprightInCenterAndBottomRegions() throws {
        let longLabel = String(repeating: "W", count: 60)
        let requested32 = try widePixels(profile: decodeD200XProfile(positionFields: [
            "3_2": "label = \(tomlQuoted(longLabel)), background = \"#102030\", label_size = 32",
        ]))
        let requested8 = try widePixels(profile: decodeD200XProfile(positionFields: [
            "3_2": "label = \(tomlQuoted(longLabel)), background = \"#102030\", label_size = 8",
        ]))
        XCTAssertEqual(requested32.pixels, requested8.pixels)

        let centerL = try widePixels(profile: decodeD200XProfile(positionFields: [
            "3_2": "label = \"L\", background = \"#102030\", label_alignment = \"center\", label_size = 32",
        ]))
        let bottomL = try widePixels(profile: decodeD200XProfile(positionFields: [
            "3_2": "label = \"L\", background = \"#102030\", label_alignment = \"bottom\", label_size = 32",
        ]))
        let goL = try decodeRGBA(resource("GoWideLabel-Orientation", extension: "png"))
        let centerBounds = try XCTUnwrap(inkBounds(centerL))
        let bottomBounds = try XCTUnwrap(inkBounds(bottomL))
        let goBounds = try XCTUnwrap(inkBounds(goL))
        XCTAssertEqual(centerBounds.minY, goBounds.minY, accuracy: 8)
        XCTAssertEqual(centerBounds.maxY, goBounds.maxY, accuracy: 8)
        XCTAssertEqual(centerBounds.midY, 98.5, accuracy: 12)
        XCTAssertLessThanOrEqual(centerBounds.minY, 90)
        XCTAssertGreaterThanOrEqual(centerBounds.maxY, 108)

        let centerRows = inkRowCounts(centerL)
        let boxStart = max(0, Int(centerBounds.minY.rounded(.down)))
        let boxEnd = min(centerRows.count, Int(centerBounds.maxY.rounded(.up)))
        let bandSize = max(1, (boxEnd - boxStart) / 3)
        let topStemMax = centerRows.enumerated()
            .filter { $0.offset >= boxStart && $0.offset < boxStart + bandSize }
            .map(\.element)
            .max() ?? 0
        let bottomFootMax = centerRows.enumerated()
            .filter { $0.offset >= boxEnd - bandSize && $0.offset < boxEnd }
            .map(\.element)
            .max() ?? 0
        XCTAssertLessThan(topStemMax, bottomFootMax / 2)

        XCTAssertGreaterThan(bottomBounds.minY, centerBounds.maxY)
        XCTAssertGreaterThanOrEqual(bottomBounds.minY, 115)
        XCTAssertLessThan(bottomBounds.maxY, 190)
    }

    func testMixedUnicodeLabelRemainsVisibleWithoutAssumingFallbackIdentity() throws {
        let swift = try widePixels(profile: decodeD200XProfile(positionFields: [
            "3_2": "label = \"A\\u0378\", background = \"#10203080\", label_alignment = \"center\", label_size = 24",
        ]))
        XCTAssertGreaterThan(rowInkCounts(swift, foreground: [255, 255, 255]).reduce(0, +), 0)
    }

    private func widePixels(profile: ConfiguredProfile) throws -> RGBAImage {
        let update = try D200XPageRenderer.render(profile: profile)
        let members = try parseClassicZIP(update.archive.data)
        let manifestData = try XCTUnwrap(members.first(where: { $0.name == "manifest.json" })).data
        let manifest = try JSONDecoder().decode([String: TestManifestEntry].self, from: manifestData)
        let icon = try XCTUnwrap(manifest["3_2"]?.viewParam.first?.icon)
        return try decodeRGBA(XCTUnwrap(members.first(where: { $0.name == icon })).data)
    }

    private func resource(_ name: String, extension fileExtension: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension) else {
            throw D200XTestFailure.pngDecodeFailed
        }
        return try Data(contentsOf: url)
    }

    private func replacing(
        _ position: ConfiguredPosition,
        position name: String? = nil,
        labelAlignment: String? = nil
    ) -> ConfiguredPosition {
        ConfiguredPosition(
            id: position.id,
            position: name ?? position.position,
            label: position.label,
            background: position.background,
            notificationSources: position.notificationSources,
            labelAlignment: labelAlignment ?? position.labelAlignment,
            labelSize: position.labelSize,
            action: position.action
        )
    }

    private func inkBounds(_ image: RGBAImage) -> CGRect? {
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where isWhiteInk(image.pixel(x: x, y: y)) {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func inkRowCounts(_ image: RGBAImage) -> [Int] {
        (0..<image.height).map { y in
            (0..<image.width).reduce(into: 0) { count, x in
                if isWhiteInk(image.pixel(x: x, y: y)) { count += 1 }
            }
        }
    }

    private func isWhiteInk(_ pixel: [UInt8]) -> Bool {
        pixel[0] == 255 && pixel[1] == 255 && pixel[2] == 255 && pixel[3] > 220
    }
}

private extension ConfiguredProfile {
    func replacingPositions(_ positions: [ConfiguredPosition]) -> ConfiguredProfile {
        ConfiguredProfile(id: id, label: label, positions: positions)
    }
}

private struct TestManifestEntry: Decodable {
    let smallViewMode: Int?
    let state: Int
    let viewParam: [TestManifestView]

    enum CodingKeys: String, CodingKey {
        case smallViewMode = "SmallViewMode"
        case state = "State"
        case viewParam = "ViewParam"
    }
}

private struct TestManifestView: Decodable {
    let font: TestManifestFont
    let icon: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case font = "Font"
        case icon = "Icon"
        case text = "Text"
    }
}

private struct TestManifestFont: Decodable {
    let align: String
    let color: Int
    let fontName: String
    let showTitle: Bool
    let size: Int
    let weight: Int

    enum CodingKeys: String, CodingKey {
        case align = "Align"
        case color = "Color"
        case fontName = "FontName"
        case showTitle = "ShowTitle"
        case size = "Size"
        case weight = "Weight"
    }
}

private struct RGBAImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    func pixel(x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(pixels[offset..<(offset + 4)])
    }
}

private func decodeRGBA(_ data: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw D200XTestFailure.pngDecodeFailed
    }
    guard image.alphaInfo == .last,
          image.bitsPerComponent == 8,
          image.bitsPerPixel == 32,
          image.bytesPerRow >= image.width * 4,
          let providerData = image.dataProvider?.data else {
        throw D200XTestFailure.pngDecodeFailed
    }
    let rawBytes = providerData as Data
    guard rawBytes.count >= image.bytesPerRow * image.height else { throw D200XTestFailure.pngDecodeFailed }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    for y in 0..<image.height {
        let sourceStart = y * image.bytesPerRow
        let destinationStart = y * image.width * 4
        pixels.replaceSubrange(destinationStart..<(destinationStart + image.width * 4), with: rawBytes[sourceStart..<(sourceStart + image.width * 4)])
    }
    return RGBAImage(width: image.width, height: image.height, pixels: pixels)
}

private func pngGeometry(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
}

private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    let digits = Array("0123456789abcdef".utf8)
    return String(decoding: digest.flatMap { [digits[Int($0) >> 4], digits[Int($0) & 0x0f]] }, as: UTF8.self)
}

private func rowInkCounts(_ image: RGBAImage, foreground: [UInt8]) -> [Int] {
    (0..<image.height).map { y in
        (0..<image.width).reduce(into: 0) { count, x in
            let pixel = image.pixel(x: x, y: y)
            if Array(pixel.prefix(3)) == foreground && pixel[3] > 128 { count += 1 }
        }
    }
}
