import CoreText
import Foundation

enum D200XNotificationTextLayout {
    struct Layout: Equatable {
        let text: String
        let fontSize: CGFloat
    }

    static func fit(_ text: String, preferredSize: CGFloat, bounds: CGSize) -> Layout {
        let maximum = Int(min(48, max(8, preferredSize.isFinite ? preferredSize : 22)))
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for size in stride(from: maximum, through: 8, by: -1) {
            let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
            guard words.allSatisfy({ width($0, font: font) <= bounds.width }) else { continue }
            let lines = wrap(words, font: font, width: bounds.width)
            if CGFloat(lines.count) * lineHeight(font) + 4 <= bounds.height {
                return Layout(text: lines.joined(separator: "\n"), fontSize: CGFloat(size))
            }
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 8, nil)
        let shortened = words.map { word in
            width(word, font: font) <= bounds.width ? word : ellipsize(word, font: font, maximumWidth: bounds.width)
        }
        let lines = wrap(shortened, font: font, width: bounds.width)
        let count = max(1, Int((bounds.height - 4) / lineHeight(font)))
        guard lines.count > count else { return Layout(text: lines.joined(separator: "\n"), fontSize: 8) }
        var visible = Array(lines.prefix(count))
        var lastWords = visible[count - 1].split(separator: " ").map(String.init)
        while lastWords.count > 1 && width(lastWords.joined(separator: " ") + "…", font: font) > bounds.width {
            lastWords.removeLast()
        }
        visible[count - 1] = ellipsize(lastWords.joined(separator: " "), font: font, maximumWidth: bounds.width)
        return Layout(text: visible.joined(separator: "\n"), fontSize: 8)
    }

    static func width(_ text: String, font: CTFont) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil))
    }

    private static func lineHeight(_ font: CTFont) -> CGFloat {
        ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    private static func wrap(_ words: [String], font: CTFont, width maximumWidth: CGFloat) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if !current.isEmpty, width(candidate, font: font) > maximumWidth {
                lines.append(current)
                current = word
            } else { current = candidate }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func ellipsize(_ text: String, font: CTFont, maximumWidth: CGFloat) -> String {
        var result = text
        while !result.isEmpty && width(result + "…", font: font) > maximumWidth { result.removeLast() }
        return result + "…"
    }
}
