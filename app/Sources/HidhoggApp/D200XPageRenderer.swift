import CoreGraphics
import CoreText
import Foundation
import ImageIO
import HidhoggDomain
import UlanziD200X
import UniformTypeIdentifiers

enum D200XPageRenderer {
    enum Destination: Equatable {
        case device
        case preview
    }

    enum Failure: Error { case renderFailed }

    static func page(
        configuration: D200XConfiguration,
        labelOverrides: [String: String] = [:],
        assetDirectory: URL? = nil,
        notificationIcons: [String: Data] = [:]
    ) throws -> D200XPage {
        var slots: [String: D200XSlot] = [:]
        for (index, control) in D200XControl.allCases.filter(\.isTile).enumerated() {
            let appearance = configuration.appearance(for: control)
            slots["\(index % 5)_\(index / 5)"] = D200XSlot(
                image: try tilePNG(
                    appearance: appearance,
                    wide: index == 13,
                    labelOverride: labelOverrides[control.rawValue],
                    assetDirectory: assetDirectory,
                    notificationIcon: notificationIcons[control.rawValue]
                )
            )
        }
        return D200XPage(slots: slots)
    }

    static func tilePNG(
        appearance: D200XTileAppearance,
        wide: Bool,
        labelOverride: String? = nil,
        assetDirectory: URL? = nil,
        destination: Destination = .device,
        notificationIcon: Data? = nil,
        presetIcon: Data? = nil
    ) throws -> Data {
        try Task.checkCancellation()
        let icon = loadNotificationIcon(notificationIcon)
        let presetImage = appearance.imageAsset == nil
            ? loadNotificationIcon(
                presetIcon,
                maximumPNGBytes: D200XPresetIconRenderer.maximumPNGBytes,
                maximumPixelDimension: D200XPresetIconRenderer.pixelSize
            )
            : nil
        let image: CGImage?
        if icon != nil {
            image = nil
        } else {
            image = presetImage ?? loadAsset(appearance.imageAsset, directory: assetDirectory)
        }
        try Task.checkCancellation()
        let title = labelOverride.flatMap { $0.isEmpty ? nil : $0 } ?? appearance.label
        let showTitle = icon == nil && (appearance.showTitle || labelOverride != nil ||
            (appearance.imageAsset != nil && image == nil)
        )
        let result = try png(
            appearance: appearance,
            title: title,
            showTitle: showTitle,
            image: image,
            notificationIcon: icon,
            wide: wide,
            destination: destination,
            notification: labelOverride != nil || icon != nil
        )
        try Task.checkCancellation()
        return result
    }

    private static func loadNotificationIcon(
        _ data: Data?,
        maximumPNGBytes: Int = D200XApplicationIconResolver.maximumPNGBytes,
        maximumPixelDimension: Int = D200XApplicationIconResolver.iconPixelDimension
    ) -> CGImage? {
        guard let data, data.count <= maximumPNGBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: true] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumPixelDimension).contains(width),
              (1...maximumPixelDimension).contains(height) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func loadAsset(_ reference: String?, directory: URL?) -> CGImage? {
        guard let reference, let directory,
              let data = try? D200XAssetStore(directory: directory).imageData(for: reference),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: true] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func png(
        appearance: D200XTileAppearance,
        title: String,
        showTitle: Bool,
        image: CGImage?,
        notificationIcon: CGImage?,
        wide: Bool,
        destination: Destination,
        notification: Bool
    ) throws -> Data {
        let width = 196
        let height = wide ? 98 : 196
        let usesWideDeviceRaster = wide && destination == .device
        let rasterScaleX: CGFloat = usesWideDeviceRaster ? 458 / CGFloat(width) : 1
        let rasterScaleY: CGFloat = usesWideDeviceRaster ? 196 / CGFloat(height) : 1
        let rasterWidth = usesWideDeviceRaster ? 458 : width
        let rasterHeight = usesWideDeviceRaster ? 196 : height
        guard let context = CGContext(
            data: nil, width: rasterWidth, height: rasterHeight, bitsPerComponent: 8, bytesPerRow: rasterWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.renderFailed }
        context.scaleBy(x: rasterScaleX, y: rasterScaleY)

        let background = rgb(for: appearance.backgroundHex) ?? (
            red: CGFloat(0x30) / 255,
            green: CGFloat(0x34) / 255,
            blue: CGFloat(0x3B) / 255
        )
        context.setFillColor(CGColor(red: background.red, green: background.green, blue: background.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        if let notificationIcon {
            let iconSize = min(CGFloat(width), CGFloat(height)) * 0.62
            drawAspectContained(
                notificationIcon,
                in: context,
                bounds: CGRect(
                    x: (CGFloat(width) - iconSize) / 2,
                    y: (CGFloat(height) - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                )
            )
        } else if let image {
            drawAspectContained(
                image,
                in: context,
                bounds: CGRect(x: 8, y: 8, width: CGFloat(width - 16), height: CGFloat(height - 16))
            )
        }

        if showTitle, !title.isEmpty {
            let titleScale = CGFloat(height) / 196
            context.saveGState()
            context.scaleBy(x: titleScale, y: titleScale)
            if wide, destination == .device {
                let horizontalScale: CGFloat = 0.8
                let logicalWidth = CGFloat(width) / titleScale
                let alignmentAnchor: CGFloat = switch appearance.titleAlignment {
                case .left: 10
                case .center: logicalWidth / 2
                case .right: logicalWidth - 10
                }
                context.translateBy(x: alignmentAnchor * (1 - horizontalScale), y: 0)
                context.scaleBy(x: horizontalScale, y: 1)
            }
            drawTitle(
                title,
                appearance: appearance,
                background: background,
                in: context,
                width: Int(CGFloat(width) / titleScale),
                height: Int(CGFloat(height) / titleScale),
                notification: notification
            )
            context.restoreGState()
        }

        guard let rendered = context.makeImage() else { throw Failure.renderFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.renderFailed
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.renderFailed }
        return data as Data
    }

    private static func drawAspectContained(_ image: CGImage, in context: CGContext, bounds: CGRect) {
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }

    private static func drawTitle(
        _ title: String,
        appearance: D200XTileAppearance,
        background: (red: CGFloat, green: CGFloat, blue: CGFloat),
        in context: CGContext,
        width: Int,
        height: Int,
        notification: Bool
    ) {
        let titleColor = rgb(for: appearance.titleColorHex ?? "") ?? contrastingColor(for: background)
        let proposedTitleSize = CGFloat(appearance.titleSize.isFinite ? appearance.titleSize : 22)
        let fitted = notification ? D200XNotificationTextLayout.fit(title, preferredSize: proposedTitleSize,
            bounds: CGSize(width: width - 20, height: height - 20)) : nil
        let titleSize = fitted?.fontSize ?? min(max(proposedTitleSize, 8), 48)
        var alignment: CTTextAlignment = switch appearance.titleAlignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                "Helvetica" as CFString, titleSize, nil
            ),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: titleColor.red, green: titleColor.green, blue: titleColor.blue, alpha: 1
            )
        ]
        let text = NSAttributedString(string: fitted?.text ?? title, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let inset: CGFloat = 10
        let bounds = CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, bounds.size, nil
        )
        let textHeight = min(max(suggested.height + 4, titleSize), bounds.height)
        let originY: CGFloat
        switch appearance.titlePlacement {
        case .top:
            originY = bounds.maxY - textHeight
        case .center:
            originY = bounds.minY + (bounds.height - textHeight) / 2
        case .bottom:
            originY = bounds.minY
        }
        let textBounds = CGRect(x: bounds.minX, y: originY, width: bounds.width, height: textHeight)
        let path = CGPath(rect: textBounds, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    private static func rgb(for hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard hex.utf8.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (
            CGFloat((value >> 16) & 255) / 255,
            CGFloat((value >> 8) & 255) / 255,
            CGFloat(value & 255) / 255
        )
    }

    private static func contrastingColor(
        for background: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let linear: (CGFloat) -> CGFloat = {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(background.red) + 0.7152 * linear(background.green) + 0.0722 * linear(background.blue)
        let value: CGFloat = luminance > 0.179 ? 0 : 1
        return (value, value, value)
    }
}
