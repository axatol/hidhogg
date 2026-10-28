import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum D200XScreensaverImage {
    static func readSelectedImage(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw D200XAssetStore.Failure.fileAccess }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw D200XAssetStore.Failure.unsafePath
        }
        guard info.st_size > 0, info.st_size <= D200XAssetStore.maximumInputBytes else {
            throw D200XAssetStore.Failure.oversizedInput
        }
        let data = try handle.read(upToCount: D200XAssetStore.maximumInputBytes + 1) ?? Data()
        guard data.count <= D200XAssetStore.maximumInputBytes else { throw D200XAssetStore.Failure.oversizedInput }
        _ = try validatedSource(data)
        try Task.checkCancellation()
        return data
    }

    static func crop(_ data: Data, zoom: Double = 1, horizontal: Double = 0, vertical: Double = 0) throws -> Data {
        try Task.checkCancellation()
        guard zoom.isFinite, (1...3).contains(zoom), horizontal.isFinite, (-1...1).contains(horizontal),
              vertical.isFinite, (-1...1).contains(vertical) else { throw D200XAssetStore.Failure.invalidImage }
        let image = try decoded(data)
        try Task.checkCancellation()
        let width = 1220
        let height = 708
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw D200XAssetStore.Failure.invalidImage
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height)) * zoom
        let drawnWidth = Double(image.width) * scale
        let drawnHeight = Double(image.height) * scale
        let x = (Double(width) - drawnWidth) * (horizontal + 1) / 2
        let y = (Double(height) - drawnHeight) * (vertical + 1) / 2
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: x, y: y, width: drawnWidth, height: drawnHeight))
        try Task.checkCancellation()
        guard let output = context.makeImage() else { throw D200XAssetStore.Failure.invalidImage }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw D200XAssetStore.Failure.invalidImage
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw D200XAssetStore.Failure.invalidImage }
        try Task.checkCancellation()
        return bytes as Data
    }

    private static func validatedSource(_ data: Data) throws -> CGImageSource {
        guard data.count <= D200XAssetStore.maximumInputBytes else { throw D200XAssetStore.Failure.oversizedInput }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value,
              width > 0, height > 0 else { throw D200XAssetStore.Failure.invalidImage }
        guard width <= D200XAssetStore.maximumPixels / height else { throw D200XAssetStore.Failure.oversizedInput }
        return source
    }

    private static func decoded(_ data: Data) throws -> CGImage {
        let source = try validatedSource(data)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw D200XAssetStore.Failure.invalidImage
        }
        return image
    }
}
