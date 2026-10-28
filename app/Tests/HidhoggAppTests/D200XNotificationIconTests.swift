import AppKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import HidhoggApp
import HidhoggDomain
import UniformTypeIdentifiers

@MainActor
final class D200XNotificationIconTests: XCTestCase {
    func testResolverProducesCachedBoundedPNGFromInjectedIconProvider() throws {
        let source = try D200XIconTestFixture.png(red: 0.15, green: 0.8, blue: 0.2)
        let image = try XCTUnwrap(NSImage(data: source))
        var requestedBundleIDs = [String]()
        let resolver = D200XApplicationIconResolver { bundleID in
            requestedBundleIDs.append(bundleID)
            return image
        }

        let first = try XCTUnwrap(resolver.pngData(for: "com.example.Builder"))
        XCTAssertEqual(resolver.pngData(for: "com.example.Builder"), first)
        XCTAssertEqual(requestedBundleIDs, ["com.example.Builder"])
        XCTAssertLessThanOrEqual(first.count, D200XApplicationIconResolver.maximumPNGBytes)

        let sourceRef = try XCTUnwrap(CGImageSourceCreateWithData(first as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sourceRef, 0, nil))
        XCTAssertEqual(decoded.width, D200XApplicationIconResolver.iconPixelDimension)
        XCTAssertEqual(decoded.height, D200XApplicationIconResolver.iconPixelDimension)
        XCTAssertNil(resolver.pngData(for: "../Builder.app"))
        XCTAssertEqual(requestedBundleIDs.count, 1)

        for index in 0..<D200XApplicationIconResolver.maximumCacheEntries {
            XCTAssertNotNil(resolver.pngData(for: "org.example.Cache\(index)"))
        }
        XCTAssertNotNil(resolver.pngData(for: "com.example.Builder"))
        XCTAssertEqual(requestedBundleIDs.filter { $0 == "com.example.Builder" }.count, 2)
    }

    func testRendererUsesSyntheticIconAndFallsBackToTextForMissingOrInvalidIcon() throws {
        let appearance = D200XTileAppearance(label: "Default", backgroundHex: "000000", showTitle: false)
        let greenIcon = try D200XIconTestFixture.png(red: 0.1, green: 0.9, blue: 0.2)
        let blueIcon = try D200XIconTestFixture.png(red: 0.1, green: 0.2, blue: 0.9)
        let label = "com.example.Builder"
        let greenTile = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: false,
            labelOverride: label,
            notificationIcon: greenIcon
        )
        let blueTile = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: false,
            labelOverride: label,
            notificationIcon: blueIcon
        )
        let fallbackTile = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: false,
            labelOverride: label
        )
        let invalidIconFallback = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: false,
            labelOverride: label,
            notificationIcon: Data("not a PNG".utf8)
        )
        let page = try D200XPageRenderer.page(
            configuration: D200XConfiguration(tiles: ["key0": appearance]),
            labelOverrides: ["key0": label],
            notificationIcons: ["key0": greenIcon]
        )

        XCTAssertNotEqual(greenTile, blueTile)
        XCTAssertEqual(fallbackTile, invalidIconFallback)
        XCTAssertEqual(page.slots["0_0"]?.image, greenTile)

        let wideDevice = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: true,
            labelOverride: label,
            notificationIcon: greenIcon
        )
        let widePreview = try D200XPageRenderer.tilePNG(
            appearance: appearance,
            wide: true,
            labelOverride: label,
            destination: .preview,
            notificationIcon: greenIcon
        )
        XCTAssertEqual(try rasterSize(wideDevice), CGSize(width: 458, height: 196))
        XCTAssertEqual(try rasterSize(widePreview), CGSize(width: 196, height: 98))
    }

    private func rasterSize(_ data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
    }
}

@MainActor
final class FixedD200XApplicationIconResolver: D200XApplicationIconResolving {
    let data: Data?
    private(set) var requestedBundleIDs = [String]()

    init(pngData: Data? = nil) {
        data = pngData
    }

    func pngData(for bundleIdentifier: String) -> Data? {
        requestedBundleIDs.append(bundleIdentifier)
        return data
    }
}

enum D200XIconTestFixture {
    enum Failure: Error { case imageCreation }

    static func png(red: CGFloat = 0.2, green: CGFloat = 0.5, blue: CGFloat = 0.9) throws -> Data {
        let dimension = D200XApplicationIconResolver.iconPixelDimension
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.imageCreation }
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        guard let image = context.makeImage() else { throw Failure.imageCreation }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.imageCreation
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.imageCreation }
        return output as Data
    }
}
