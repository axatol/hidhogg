import AppKit
import Foundation

private enum PlaybackState {
    case playing
    case paused
}

private struct CardContent {
    let title: String
    let artist: String
    let elapsedSeconds: Int
    let durationSeconds: Int
    let playbackState: PlaybackState
    let outputMuted: Bool
    let accent: UInt32
    let artworkBase: UInt32
    let artworkHighlight: UInt32
}

@main
private enum NowPlayingCardRenderer {
    private static let cardWidth = 458
    private static let cardHeight = 196
    private static let artSize: CGFloat = 144
    private static let cornerRadius: CGFloat = 16

    static func main() throws {
        let outputPath = CommandLine.arguments.dropFirst().first ?? "/Volumes/Data/tmp/d200x-now-playing"
        let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let playing = CardContent(
            title: "Synthetic Horizon",
            artist: "Example Duo",
            elapsedSeconds: 157,
            durationSeconds: 263,
            playbackState: .playing,
            outputMuted: true,
            accent: 0xF2B66D,
            artworkBase: 0x233D54,
            artworkHighlight: 0x78B8B1
        )
        let paused = CardContent(
            title: "Quiet Circuit",
            artist: "Placeholder Artist",
            elapsedSeconds: 91,
            durationSeconds: 244,
            playbackState: .paused,
            outputMuted: false,
            accent: 0xB89CFF,
            artworkBase: 0x49365C,
            artworkHighlight: 0xE39A7A
        )

        let playingImage = try render(playing)
        let pausedImage = try render(paused)
        try write(playingImage, named: "playing.png", to: outputDirectory)
        try write(pausedImage, named: "paused.png", to: outputDirectory)
        try write(try contactSheet(playing: playingImage, paused: pausedImage), named: "contact-sheet.png", to: outputDirectory)

        print("Rendered synthetic cards at \(cardWidth)×\(cardHeight): \(outputDirectory.path)")
    }

    private static func render(_ content: CardContent) throws -> Data {
        let bitmap = try bitmap(width: cardWidth, height: cardHeight)
        try withDrawingContext(for: bitmap) {
            let background = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
            fillRoundedRectangle(background, radius: cornerRadius, color: color(0x171B22))
            drawArtwork(for: content)
            drawMetadata(for: content)
            drawPlaybackState(for: content)
            drawProgress(for: content)
            drawOutputMute(for: content)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RendererError.pngEncodingFailed
        }
        return png
    }

    private static func drawArtwork(for content: CardContent) {
        let art = NSRect(x: 18, y: 26, width: artSize, height: artSize)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: art, xRadius: 14, yRadius: 14).addClip()

        color(content.artworkBase).setFill()
        art.fill()

        color(content.artworkHighlight, alpha: 0.86).setFill()
        NSBezierPath(ovalIn: NSRect(x: 57, y: 76, width: 90, height: 90)).fill()

        color(0x101821, alpha: 0.78).setFill()
        let lowerRidge = NSBezierPath()
        lowerRidge.move(to: NSPoint(x: 18, y: 26))
        lowerRidge.line(to: NSPoint(x: 18, y: 80))
        lowerRidge.line(to: NSPoint(x: 72, y: 116))
        lowerRidge.line(to: NSPoint(x: 124, y: 82))
        lowerRidge.line(to: NSPoint(x: 162, y: 108))
        lowerRidge.line(to: NSPoint(x: 162, y: 26))
        lowerRidge.close()
        lowerRidge.fill()

        color(0xFFFFFF, alpha: 0.75).setFill()
        [
            NSRect(x: 39, y: 137, width: 3, height: 3),
            NSRect(x: 119, y: 150, width: 2, height: 2),
            NSRect(x: 139, y: 118, width: 2, height: 2),
            NSRect(x: 84, y: 151, width: 2, height: 2),
        ].forEach { NSBezierPath(ovalIn: $0).fill() }

        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawMetadata(for content: CardContent) {
        drawText("SYNTHETIC PLAYER · PREVIEW", at: NSPoint(x: 180, y: 162), size: 9, weight: .medium, color: color(0x8F9AAA))
        drawText(content.title, at: NSPoint(x: 178, y: 127), size: 22, weight: .semibold, color: color(0xF5F6F8), maximumWidth: 260)
        drawText(content.artist, at: NSPoint(x: 180, y: 105), size: 13, weight: .regular, color: color(0xAAB2BE), maximumWidth: 255)
    }

    private static func drawPlaybackState(for content: CardContent) {
        let isPlaying = content.playbackState == .playing
        let pill = NSRect(x: 180, y: 72, width: 90, height: 20)
        fillRoundedRectangle(pill, radius: 10, color: color(isPlaying ? 0x28372F : 0x30323B))

        if isPlaying {
            color(0x83D6A1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 189, y: 79, width: 6, height: 6)).fill()
        } else {
            color(0xC7CBD3).setFill()
            NSBezierPath(rect: NSRect(x: 189, y: 78, width: 2, height: 8)).fill()
            NSBezierPath(rect: NSRect(x: 194, y: 78, width: 2, height: 8)).fill()
        }

        drawText(isPlaying ? "PLAYING" : "PAUSED", at: NSPoint(x: 202, y: 78), size: 9, weight: .semibold, color: color(isPlaying ? 0xA7E2B8 : 0xD2D4DA))
    }

    private static func drawProgress(for content: CardContent) {
        let track = NSRect(x: 180, y: 54, width: 258, height: 4)
        fillRoundedRectangle(track, radius: 2, color: color(0x373D47))

        let fraction = min(max(CGFloat(content.elapsedSeconds) / CGFloat(content.durationSeconds), 0), 1)
        let progress = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        fillRoundedRectangle(progress, radius: 2, color: color(content.accent))

        drawText(formatTime(content.elapsedSeconds), at: NSPoint(x: 180, y: 34), size: 9, weight: .medium, color: color(0x9AA3B0))
        drawText(formatTime(content.durationSeconds), at: NSPoint(x: 406, y: 34), size: 9, weight: .medium, color: color(0x9AA3B0))
    }

    private static func drawOutputMute(for content: CardContent) {
        let pill = NSRect(x: 180, y: 10, width: 132, height: 20)
        fillRoundedRectangle(pill, radius: 10, color: color(content.outputMuted ? 0x49302E : 0x29343A))

        color(content.outputMuted ? 0xFF9C8E : 0xA9D8C1).setStroke()
        color(content.outputMuted ? 0xFF9C8E : 0xA9D8C1).setFill()

        let speaker = NSBezierPath()
        speaker.move(to: NSPoint(x: 189, y: 16))
        speaker.line(to: NSPoint(x: 192, y: 16))
        speaker.line(to: NSPoint(x: 196, y: 13))
        speaker.line(to: NSPoint(x: 196, y: 27))
        speaker.line(to: NSPoint(x: 192, y: 24))
        speaker.line(to: NSPoint(x: 189, y: 24))
        speaker.close()
        speaker.fill()

        if content.outputMuted {
            let slash = NSBezierPath()
            slash.lineWidth = 1.4
            slash.move(to: NSPoint(x: 198, y: 15))
            slash.line(to: NSPoint(x: 204, y: 25))
            slash.stroke()
        } else {
            let wave = NSBezierPath()
            wave.lineWidth = 1.2
            wave.appendArc(withCenter: NSPoint(x: 195, y: 20), radius: 7, startAngle: -42, endAngle: 42)
            wave.stroke()
        }

        drawText(content.outputMuted ? "OUTPUT MUTED" : "OUTPUT ON", at: NSPoint(x: 209, y: 16), size: 9, weight: .semibold, color: color(content.outputMuted ? 0xFFB6AA : 0xB9E3CE))
    }

    private static func contactSheet(playing: Data, paused: Data) throws -> Data {
        let gutter = 26
        let bitmap = try bitmap(width: cardWidth * 2 + gutter, height: cardHeight)
        guard let playingImage = NSImage(data: playing), let pausedImage = NSImage(data: paused) else {
            throw RendererError.pngDecodingFailed
        }
        try withDrawingContext(for: bitmap) {
            color(0x0C0F14).setFill()
            NSRect(x: 0, y: 0, width: cardWidth * 2 + gutter, height: cardHeight).fill()
            playingImage.draw(in: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight))
            pausedImage.draw(in: NSRect(x: cardWidth + gutter, y: 0, width: cardWidth, height: cardHeight))
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RendererError.pngEncodingFailed
        }
        return png
    }

    private static func bitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RendererError.bitmapCreationFailed
        }
        return bitmap
    }

    private static func withDrawingContext(for bitmap: NSBitmapImageRep, draw: () -> Void) throws {
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RendererError.graphicsContextCreationFailed
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        draw()
        context.flushGraphics()
    }

    private static func write(_ data: Data, named name: String, to directory: URL) throws {
        try data.write(to: directory.appendingPathComponent(name))
    }

    private static func fillRoundedRectangle(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private static func drawText(
        _ value: String,
        at point: NSPoint,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        maximumWidth: CGFloat = .greatestFiniteMagnitude
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = truncated(value, to: maximumWidth, attributes: attributes)
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    private static func truncated(_ value: String, to maximumWidth: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        guard maximumWidth.isFinite else { return value }
        var candidate = value
        while candidate.count > 1 && (candidate as NSString).size(withAttributes: attributes).width > maximumWidth {
            candidate.removeLast()
        }
        if candidate != value {
            while candidate.count > 1 && ((candidate + "…") as NSString).size(withAttributes: attributes).width > maximumWidth {
                candidate.removeLast()
            }
            return candidate + "…"
        }
        return candidate
    }

    private static func formatTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):\(String(format: "%02d", remainder))"
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private enum RendererError: Error {
        case bitmapCreationFailed
        case graphicsContextCreationFailed
        case pngDecodingFailed
        case pngEncodingFailed
    }
}
