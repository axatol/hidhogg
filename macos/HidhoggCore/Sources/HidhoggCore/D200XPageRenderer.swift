import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum D200XPageRenderError: Error, Equatable {
    case invalidPositionCount(Int)
    case invalidPositionOrder(index: Int, actual: String, expected: String)
    case invalidPositionID(index: Int)
    case duplicatePositionID(index: Int)
    case invalidLabel(index: Int)
    case invalidBackground(index: Int)
    case invalidLabelStyle(index: Int)
    case fontUnavailable
    case bitmapContextUnavailable
    case imageEncodingFailed
    case manifestEncodingFailed
}

struct D200XLivePageUpdate: Equatable, Sendable {
    let archive: D200XDisplayArchive
    let positions: [ConfiguredPosition]
}

enum D200XPageRenderer {
    private static let squareWidth = 196
    private static let wideWidth = 458
    private static let tileHeight = 196
    private static let borderThickness = 5
    private static let imagePrefix = "Images/"
    private static let fontName = "Source Han Sans SC"
    private static let maximumLabelRunes = 64

    static func render(profile: ConfiguredProfile) throws -> D200XLivePageUpdate {
        let positions = try canonicalPositions(profile.positions)
        var rendered = [RenderedPosition]()
        for (index, position) in positions.enumerated() {
            let wide = index == HidhoggConfiguration.supportedPositions.count - 1
            let background = try parseBackground(position.background, index: index)
            let image = try renderPNG(position: position, background: background, width: wide ? wideWidth : squareWidth, wide: wide)
            rendered.append(RenderedPosition(
                position: position,
                wide: wide,
                iconPath: imagePrefix + hexadecimalDigest(image) + ".png",
                pngData: image
            ))
        }

        let manifest = try encodeManifest(rendered)
        var files = [D200XArchiveFile(name: "manifest.json", data: manifest, method: 8)]
        var seen = Set<String>()
        for item in rendered where seen.insert(item.iconPath).inserted {
            files.append(D200XArchiveFile(name: item.iconPath, data: item.pngData, method: 8))
        }
        let archive = try D200XDisplayArchiveBuilder.makeFirmwareSafe(files: files)
        return D200XLivePageUpdate(archive: archive, positions: positions)
    }

    private static func canonicalPositions(_ positions: [ConfiguredPosition]) throws -> [ConfiguredPosition] {
        let coordinates = HidhoggConfiguration.supportedPositions
        guard positions.count == coordinates.count else {
            throw D200XPageRenderError.invalidPositionCount(positions.count)
        }

        var byCoordinate = [String: ConfiguredPosition]()
        var seenIDs = Set<String>()
        for (index, position) in positions.enumerated() {
            guard isStableID(position.id) else { throw D200XPageRenderError.invalidPositionID(index: index) }
            guard seenIDs.insert(position.id).inserted else { throw D200XPageRenderError.duplicatePositionID(index: index) }
            guard isValidLabel(position.label) else { throw D200XPageRenderError.invalidLabel(index: index) }
            guard (8...32).contains(position.labelSize), position.labelAlignment == "bottom" || position.labelAlignment == "center" else {
                throw D200XPageRenderError.invalidLabelStyle(index: index)
            }
            guard byCoordinate.updateValue(position, forKey: position.position) == nil else {
                throw D200XPageRenderError.invalidPositionOrder(index: index, actual: position.position, expected: "unique coordinate")
            }
        }

        return try coordinates.enumerated().map { index, spec in
            guard let position = byCoordinate.removeValue(forKey: spec.name) else {
                throw D200XPageRenderError.invalidPositionOrder(index: index, actual: "missing", expected: spec.name)
            }
            return position
        }
    }

    private static func isStableID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, bytes.count <= 64, isASCIIAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy { isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private static func isValidLabel(_ value: String) -> Bool {
        guard value.unicodeScalars.count <= maximumLabelRunes else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func parseBackground(_ value: String, index: Int) throws -> RGBAColor {
        let bytes = Array(value.utf8)
        guard bytes.count == 7 || bytes.count == 9, bytes.first == 35 else {
            throw D200XPageRenderError.invalidBackground(index: index)
        }
        func byte(_ offset: Int) -> UInt8? {
            guard let high = hexValue(bytes[offset]), let low = hexValue(bytes[offset + 1]) else { return nil }
            return high << 4 | low
        }
        guard let red = byte(1), let green = byte(3), let blue = byte(5) else {
            throw D200XPageRenderError.invalidBackground(index: index)
        }
        let alpha = bytes.count == 9 ? byte(7) : 255
        guard let alpha else { throw D200XPageRenderError.invalidBackground(index: index) }
        return RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 65 + 10
        case 97...102: return byte - 97 + 10
        default: return nil
        }
    }

    private static func renderPNG(position: ConfiguredPosition, background: RGBAColor, width: Int, wide: Bool) throws -> Data {
        let hasBorder = !position.label.isEmpty
        let text = wide ? position.label : ""
        let textColor = background.luminance >= 128_000 ? RGBAColor(red: 0, green: 0, blue: 0, alpha: 255) : RGBAColor(red: 255, green: 255, blue: 255, alpha: 255)
        let image = makeImage(width: width, background: background, hasBorder: hasBorder, text: text, textColor: textColor, alignment: position.labelAlignment, pointSize: position.labelSize)
        guard let image else { throw D200XPageRenderError.bitmapContextUnavailable }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw D200XPageRenderError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw D200XPageRenderError.imageEncodingFailed }
        return data as Data
    }

    private static func makeImage(
        width: Int,
        background: RGBAColor,
        hasBorder: Bool,
        text: String,
        textColor: RGBAColor,
        alignment: String,
        pointSize: Int
    ) -> CGImage? {
        let height = tileHeight
        var premultipliedPixels = [UInt16](repeating: 0, count: width * height * 4)
        let image = premultipliedPixels.withUnsafeMutableBytes { storage -> CGImage? in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 4 * MemoryLayout<UInt16>.stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            ) else { return nil }

            context.setBlendMode(.copy)
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if hasBorder {
                let accent = RGBAColor(
                    red: 255 - background.red / 3,
                    green: 255 - background.green / 3,
                    blue: 255 - background.blue / 3,
                    alpha: 255
                )
                context.setFillColor(accent.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: borderThickness))
                context.fill(CGRect(x: 0, y: height - borderThickness, width: width, height: borderThickness))
                context.fill(CGRect(x: 0, y: 0, width: borderThickness, height: height))
                context.fill(CGRect(x: width - borderThickness, y: 0, width: borderThickness, height: height))
            }
            if !text.isEmpty {
                guard let font = goFont(size: CGFloat(pointSize * 2)) else { return nil }
                context.setBlendMode(.normal)
                draw(text: text, font: font, foreground: textColor, alignment: alignment, in: context, width: width, height: height)
            }
            context.flush()
            let components = storage.bindMemory(to: UInt16.self)
            var straightPixels = [UInt8](repeating: 0, count: width * height * 4)
            for pixelOffset in stride(from: 0, to: components.count, by: 4) {
                let alpha = Int(components[pixelOffset + 3])
                guard alpha > 0 else { continue }
                straightPixels[pixelOffset] = straightChannel(components[pixelOffset], alpha: alpha)
                straightPixels[pixelOffset + 1] = straightChannel(components[pixelOffset + 1], alpha: alpha)
                straightPixels[pixelOffset + 2] = straightChannel(components[pixelOffset + 2], alpha: alpha)
                straightPixels[pixelOffset + 3] = UInt8((alpha + 128) / 257)
            }

            let providerData = Data(straightPixels) as CFData
            guard let provider = CGDataProvider(data: providerData) else { return nil }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
        return image
    }

    private static func straightChannel(_ component: UInt16, alpha: Int) -> UInt8 {
        let rounded = (Int(component) * 255 + alpha / 2) / alpha
        return UInt8(min(255, rounded))
    }

    private static func goFont(size: CGFloat) -> CTFont? {
        guard let url = Bundle.module.url(forResource: "Go-Regular", withExtension: "ttf"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func draw(text: String, font: CTFont, foreground: RGBAColor, alignment: String, in context: CGContext, width: Int, height: Int) {
        let innerWidth = width - borderThickness * 2
        let layout = wideLabelLayout(text, requestedSize: Int(CTFontGetSize(font) / 2), maxWidth: innerWidth, font: font)
        let selectedFont = layout.font
        let lines = layout.lines
        let ascent = Int(ceil(CTFontGetAscent(selectedFont)))
        let descent = Int(ceil(CTFontGetDescent(selectedFont)))
        let lineHeight = max(1, Int(ceil(CTFontGetAscent(selectedFont) + CTFontGetDescent(selectedFont) + CTFontGetLeading(selectedFont))))
        let blockHeight = lineHeight * lines.count
        var firstBaseline = height - borderThickness - descent - (lines.count - 1) * lineHeight
        if alignment == "center" {
            firstBaseline = borderThickness + ((height - borderThickness * 2) - blockHeight) / 2 + ascent
        }

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.setFillColor(foreground.cgColor)
        for (index, lineText) in lines.enumerated() {
            let line = makeLine(lineText, font: selectedFont, foreground: foreground)
            let width = Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))
            let x = borderThickness + (innerWidth - width) / 2
            context.textPosition = CGPoint(x: x, y: firstBaseline + index * lineHeight)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    private static func wideLabelLayout(_ label: String, requestedSize: Int, maxWidth: Int, font: CTFont) -> WideTextLayout {
        let sourceLines = label.components(separatedBy: "\n")
        if linesFit(sourceLines, font: font, maxWidth: maxWidth) {
            return WideTextLayout(font: font, lines: sourceLines)
        }

        for size in stride(from: requestedSize - 1, through: 8, by: -1) {
            guard let smaller = goFont(size: CGFloat(size * 2)) else { continue }
            if linesFit(sourceLines, font: smaller, maxWidth: maxWidth) {
                return WideTextLayout(font: smaller, lines: sourceLines)
            }
        }

        guard let minimum = goFont(size: 16) else { return WideTextLayout(font: font, lines: sourceLines) }
        return WideTextLayout(font: minimum, lines: wrap(label, font: minimum, maxWidth: maxWidth))
    }

    private static func linesFit(_ lines: [String], font: CTFont, maxWidth: Int) -> Bool {
        lines.allSatisfy { Int(ceil(CTLineGetTypographicBounds(makeLine($0, font: font), nil, nil, nil))) <= maxWidth }
    }

    private static func wrap(_ label: String, font: CTFont, maxWidth: Int) -> [String] {
        var wrapped = [String]()
        for sourceLine in label.components(separatedBy: "\n") {
            if sourceLine.isEmpty {
                wrapped.append("")
                continue
            }
            var current = ""
            for scalar in sourceLine.unicodeScalars {
                let candidate = current + String(scalar)
                if !current.isEmpty && Int(ceil(CTLineGetTypographicBounds(makeLine(candidate, font: font), nil, nil, nil))) > maxWidth {
                    wrapped.append(current)
                    current = String(scalar)
                } else {
                    current = candidate
                }
            }
            wrapped.append(current)
        }
        return wrapped
    }

    private static func makeLine(_ text: String, font: CTFont, foreground: RGBAColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let foreground {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = foreground.cgColor
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed)
    }

    private static func encodeManifest(_ rendered: [RenderedPosition]) throws -> Data {
        var manifest = "{"
        for (index, item) in rendered.enumerated() {
            if index > 0 { manifest += "," }
            let entry = try jsonQuoted(item.position.position) + ":" + manifestEntry(item)
            manifest += entry
        }
        manifest += "}"
        guard let data = manifest.data(using: .utf8) else { throw D200XPageRenderError.manifestEncodingFailed }
        return data
    }

    private static func manifestEntry(_ item: RenderedPosition) throws -> String {
        let position = item.position
        let font = "\"Align\":\(try jsonQuoted(position.labelAlignment))," +
            "\"Color\":16777215,\"FontName\":\(try jsonQuoted(fontName))," +
            "\"ShowTitle\":\(!item.wide && !position.label.isEmpty)," +
            "\"Size\":\(position.labelSize),\"Weight\":80"
        let view = "{\"Font\":{\(font)},\"Icon\":\(try jsonQuoted(item.iconPath)),\"Text\":\(try jsonQuoted(position.label))}"
        let smallViewMode = item.wide ? "\"SmallViewMode\":2," : ""
        return "{\(smallViewMode)\"State\":0,\"ViewParam\":[\(view)]}"
    }

    private static func jsonQuoted(_ value: String) throws -> String {
        let encoded = try JSONEncoder().encode(value)
        guard let result = String(data: encoded, encoding: .utf8) else { throw D200XPageRenderError.manifestEncodingFailed }
        return result
    }

    private static func hexadecimalDigest(_ data: Data) -> String {
        let bytes = SHA256.hash(data: data)
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0) >> 4], digits[Int($0) & 0x0f]] }, as: UTF8.self)
    }
}

private struct RenderedPosition {
    let position: ConfiguredPosition
    let wide: Bool
    let iconPath: String
    let pngData: Data
}

private struct WideTextLayout {
    let font: CTFont
    let lines: [String]
}

private struct RGBAColor {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var luminance: Int { 299 * Int(red) + 587 * Int(green) + 114 * Int(blue) }
    var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, CGFloat(alpha) / 255]
        )!
    }
}
