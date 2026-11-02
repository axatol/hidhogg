import AppKit
import Foundation

@MainActor
enum D200XPresetIconRenderer {
    enum Failure: Error {
        case unavailableSymbol
        case renderFailed
        case oversizedOutput
    }

    nonisolated static let pixelSize = 256
    nonisolated static let maximumPNGBytes = 262_144

    static func pngData(systemSymbol: String) throws -> Data {
        guard (1...128).contains(systemSymbol.utf8.count) else { throw Failure.unavailableSymbol }
        guard let symbol = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 84, weight: .medium)) else {
            throw Failure.unavailableSymbol
        }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw Failure.renderFailed
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

        symbol.isTemplate = true
        NSColor.white.set()
        let sourceSize = symbol.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { throw Failure.renderFailed }
        let maximumGlyphSize = CGFloat(pixelSize) * 0.56
        let scale = min(maximumGlyphSize / sourceSize.width, maximumGlyphSize / sourceSize.height)
        let destinationSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        symbol.draw(
            in: NSRect(
                x: (CGFloat(pixelSize) - destinationSize.width) / 2,
                y: (CGFloat(pixelSize) - destinationSize.height) / 2,
                width: destinationSize.width,
                height: destinationSize.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        context.cgContext.setBlendMode(.sourceIn)
        context.cgContext.setFillColor(NSColor.white.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        context.cgContext.setBlendMode(.normal)
        context.flushGraphics()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure.renderFailed
        }
        guard data.count <= maximumPNGBytes else { throw Failure.oversizedOutput }
        return data
    }
}
