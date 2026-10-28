import AppKit
import Foundation
import HidhoggDomain

@MainActor
protocol D200XApplicationIconResolving {
    func pngData(for bundleIdentifier: String) -> Data?
}

@MainActor
final class D200XApplicationIconResolver: D200XApplicationIconResolving {
    nonisolated static let maximumBundleIdentifierBytes = 255
    nonisolated static let maximumPNGBytes = 64 * 1024
    nonisolated static let maximumCacheEntries = 24
    nonisolated static let maximumCacheBytes = 512 * 1024
    nonisolated static let iconPixelDimension = 64

    private enum CachedIcon {
        case unavailable
        case data(Data)
    }

    private let iconProvider: @MainActor (String) -> NSImage?
    private var cache: [String: CachedIcon] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0

    init() {
        iconProvider = Self.workspaceIcon(for:)
    }

    init(iconProvider: @escaping @MainActor (String) -> NSImage?) {
        self.iconProvider = iconProvider
    }

    func pngData(for bundleIdentifier: String) -> Data? {
        guard bundleIdentifier.utf8.count <= Self.maximumBundleIdentifierBytes,
              NativeAction.isValidBundleIdentifier(bundleIdentifier) else { return nil }

        if let cached = cache[bundleIdentifier] {
            moveToMostRecent(bundleIdentifier)
            if case .data(let data) = cached { return data }
            return nil
        }

        guard let image = iconProvider(bundleIdentifier), let data = Self.pngData(for: image),
              data.count <= Self.maximumPNGBytes else {
            remember(.unavailable, for: bundleIdentifier)
            return nil
        }
        remember(.data(data), for: bundleIdentifier)
        return data
    }

    private func remember(_ entry: CachedIcon, for bundleIdentifier: String) {
        if case .data(let data) = entry { cacheBytes += data.count }
        cache[bundleIdentifier] = entry
        moveToMostRecent(bundleIdentifier)

        while cacheOrder.count > Self.maximumCacheEntries || cacheBytes > Self.maximumCacheBytes {
            let oldest = cacheOrder.removeFirst()
            if case .data(let data)? = cache.removeValue(forKey: oldest) {
                cacheBytes -= data.count
            }
        }
    }

    private func moveToMostRecent(_ bundleIdentifier: String) {
        cacheOrder.removeAll { $0 == bundleIdentifier }
        cacheOrder.append(bundleIdentifier)
    }

    private static func workspaceIcon(for bundleIdentifier: String) -> NSImage? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    private static func pngData(for image: NSImage) -> Data? {
        let dimension = iconPixelDimension
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: dimension,
                pixelsHigh: dimension,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))

        let sourceSize = image.size
        let scale = min(CGFloat(dimension) / sourceSize.width, CGFloat(dimension) / sourceSize.height)
        let targetSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let target = NSRect(
            x: (CGFloat(dimension) - targetSize.width) / 2,
            y: (CGFloat(dimension) - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        image.draw(
            in: target,
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        context.flushGraphics()
        return bitmap.representation(using: .png, properties: [:])
    }
}
