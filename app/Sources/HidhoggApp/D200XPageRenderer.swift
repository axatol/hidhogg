import CoreGraphics
import CoreText
import Foundation
import ImageIO
import HidhoggDomain
import UlanziD200X
import UniformTypeIdentifiers

enum D200XPageRenderer {
    enum Failure: Error { case renderFailed }

    static func page(configuration: D200XConfiguration) throws -> D200XPage {
        var slots: [String: D200XSlot] = [:]
        for index in 0..<14 {
            let control = D200XControl(rawValue: "key\(index)")!
            let appearance = configuration.tiles[control.rawValue] ?? D200XTileAppearance(
                label: control.title, backgroundHex: "30343B"
            )
            slots["\(index % 5)_\(index / 5)"] = D200XSlot(
                image: try png(appearance: appearance, wide: index == 13)
            )
        }
        return D200XPage(slots: slots)
    }

    private static func png(appearance: D200XTileAppearance, wide: Bool) throws -> Data {
        let width = 196
        let height = wide ? 98 : 196
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.renderFailed }
        let value = UInt32(appearance.backgroundHex, radix: 16) ?? 0x30343B
        let red = CGFloat((value >> 16) & 255) / 255
        let green = CGFloat((value >> 8) & 255) / 255
        let blue = CGFloat(value & 255) / 255
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let linear: (CGFloat) -> CGFloat = { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let foreground = CGColor(gray: luminance > 0.179 ? 0 : 1, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 22, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground
        ]
        let text = NSAttributedString(string: appearance.label, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let bounds = CGRect(x: 12, y: 12, width: width - 24, height: height - 24)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, bounds.size, nil
        )
        let textBounds = CGRect(x: bounds.minX, y: max(bounds.minY, (CGFloat(height) - suggested.height) / 2),
                                width: bounds.width, height: min(suggested.height + 4, bounds.height))
        let path = CGPath(rect: textBounds, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { throw Failure.renderFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.renderFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.renderFailed }
        return data as Data
    }
}
