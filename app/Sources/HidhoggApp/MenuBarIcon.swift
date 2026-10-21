import AppKit
import ImageIO

@MainActor
enum MenuBarIcon {
    enum StatusColor: CaseIterable, Hashable {
        case connected
        case permissionIncomplete
        case transitioning
        case disconnected
        case failed

        var color: NSColor {
            switch self {
            case .connected: .systemGreen
            case .permissionIncomplete: .systemYellow
            case .transitioning: .systemOrange
            case .disconnected: .systemGray
            case .failed: .systemRed
            }
        }
    }

    private struct Key: Hashable {
        let statusColor: StatusColor
        let darkAppearance: Bool
    }

    private static let maximumGlyphSize = NSSize(width: 22, height: 18)
    private static let statusSlotWidth: CGFloat = 8
    private static let statusGap: CGFloat = 3
    private static let statusDiameter: CGFloat = 6.9
    private static let mask = makeMask()
    private static let compositeSize = NSSize(
        width: mask.size.width + statusGap + statusSlotWidth,
        height: maximumGlyphSize.height
    )
    private static let statusCenter = NSPoint(
        x: mask.size.width + statusGap + statusSlotWidth / 2,
        y: maximumGlyphSize.height / 2
    )
    private static let maximumCachedImages = StatusColor.allCases.count * 2
    private static var images: [Key: NSImage] = [:]

    static func image(statusColor: StatusColor, darkAppearance: Bool) -> NSImage {
        let key = Key(statusColor: statusColor, darkAppearance: darkAppearance)
        if let image = images[key] { return image }

        var image = NSImage(size: compositeSize)
        let appearance = NSAppearance(named: darkAppearance ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            image = raster(size: compositeSize) { rect in
                let headRect = NSRect(
                    x: 0,
                    y: rect.midY - mask.size.height / 2,
                    width: mask.size.width,
                    height: mask.size.height
                )
                mask.draw(in: headRect)
                (darkAppearance ? NSColor.white : NSColor.black).setFill()
                headRect.fill(using: .sourceIn)
                statusColor.color.setFill()
                NSBezierPath(ovalIn: circle(diameter: statusDiameter)).fill()
            }
        }
        image.isTemplate = false
        image.accessibilityDescription = "Hidhogg"
        assert(images.count < maximumCachedImages)
        images[key] = image
        return image
    }

    private static func makeMask() -> NSImage {
        guard
            let url = Bundle.main.url(forResource: "MenuBarIconHead", withExtension: "png"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let bounds = alphaBounds(of: sourceImage),
            let cropped = sourceImage.cropping(to: bounds)
        else {
            return fallbackMask()
        }

        let fittedSize = fittedSize(
            source: NSSize(width: CGFloat(cropped.width), height: CGFloat(cropped.height)),
            maximum: maximumGlyphSize
        )
        return raster(size: fittedSize) { rect in
            NSImage(cgImage: cropped, size: fittedSize).draw(in: rect)
        }
    }

    private static func fallbackMask() -> NSImage {
        guard let symbol = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil) else {
            return raster(size: maximumGlyphSize) { _ in }
        }
        let size = fittedSize(source: symbol.size, maximum: maximumGlyphSize)
        return raster(size: size) { rect in
            symbol.draw(in: rect)
        }
    }

    private static func fittedSize(source: NSSize, maximum: NSSize) -> NSSize {
        let scale = min(maximum.width / source.width, maximum.height / source.height)
        return NSSize(width: source.width * scale, height: source.height * scale)
    }

    private static func circle(diameter: CGFloat) -> NSRect {
        NSRect(
            x: statusCenter.x - diameter / 2,
            y: statusCenter.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    private static func alphaBounds(of image: CGImage) -> CGRect? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where data[y * context.bytesPerRow + x * 4 + 3] >= 8 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func raster(size: NSSize, draw: (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width * 2)),
                pixelsHigh: Int(ceil(size.height * 2)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return image }

        bitmap.size = size
        context.imageInterpolation = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.scaleBy(
            x: CGFloat(bitmap.pixelsWide) / size.width,
            y: CGFloat(bitmap.pixelsHigh) / size.height
        )
        let rect = NSRect(origin: .zero, size: size)
        context.cgContext.clear(rect)
        draw(rect)
        image.addRepresentation(bitmap)
        return image
    }
}
