import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HidhoggApp

@MainActor
final class D200XScreensaverPreviewStoreTests: XCTestCase {
    func testSentImageSurvivesReopeningAndLatestImageWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hidhogg-saver-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try jpeg(gray: 0.2)
        let latest = try jpeg(gray: 0.8)
        let store = D200XScreensaverPreviewStore()
        store.configure(directory: directory)
        store.recordSent(first)
        store.recordSent(latest)
        XCTAssertEqual(store.image, latest)
        for _ in 0..<200 {
            if (try? D200XAssetStore(directory: directory).screensaverImage()) == latest { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let reopened = D200XScreensaverPreviewStore()
        reopened.configure(directory: directory)
        for _ in 0..<200 {
            if reopened.image == latest { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reopened.image, latest)
        XCTAssertNil(store.message)
    }

    func testInvalidImageCannotReplaceSavedPreviewAndSymlinkIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hidhogg-saver-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let assetStore = D200XAssetStore(directory: directory)
        let image = try jpeg(gray: 0.5)
        try assetStore.saveScreensaverImage(image)
        XCTAssertThrowsError(try assetStore.saveScreensaverImage(Data("invalid".utf8)))
        XCTAssertEqual(try assetStore.screensaverImage(), image)
        let saved = directory.appendingPathComponent("d200x-screensaver.jpg")
        let target = directory.appendingPathComponent("target.jpg")
        try image.write(to: target)
        try FileManager.default.removeItem(at: saved)
        try FileManager.default.createSymbolicLink(at: saved, withDestinationURL: target)
        XCTAssertThrowsError(try assetStore.screensaverImage())
        XCTAssertThrowsError(try assetStore.saveScreensaverImage(image))
        XCTAssertEqual(try Data(contentsOf: target), image)
    }

    private func jpeg(gray: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try D200XScreensaverImage.crop(bytes as Data)
    }
}
