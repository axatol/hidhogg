import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct D200XScreensaver: Equatable, Sendable {
    public let jpeg: Data

    public init(jpeg: Data) { self.jpeg = jpeg }

    public func archive() throws -> Data {
        guard jpeg.count >= 4, jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2) == Data([0xff, 0xd9]) else {
            throw D200XFailure.invalidPage
        }
        guard jpeg.count <= D200XCodec.maximumPayloadSize else { throw D200XFailure.oversized }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 1220,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 708 else {
            throw D200XFailure.invalidPage
        }
        return try D200XStoredZIP.build([("screensaver.jpg", jpeg)])
    }
}
