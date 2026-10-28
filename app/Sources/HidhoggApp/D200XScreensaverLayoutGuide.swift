import AppKit
import SwiftUI

struct D200XScreensaverLayoutGuide: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 260)
            .overlay {
                Canvas { context, size in
                    drawGuide(in: context, size: size)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
    }

    static let canvasSize = CGSize(width: 1_220, height: 708)

    static func fittedCanvasRect(in size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return .zero
        }

        let scale = min(size.width / canvasSize.width, size.height / canvasSize.height)
        let width = canvasSize.width * scale
        let height = canvasSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func screenRects(in canvasRect: CGRect) -> [CGRect] {
        guard canvasRect.minX.isFinite, canvasRect.minY.isFinite,
              canvasRect.width.isFinite, canvasRect.height.isFinite,
              canvasRect.width > 0, canvasRect.height > 0 else {
            return []
        }

        let scaleX = canvasRect.width / canvasSize.width
        let scaleY = canvasRect.height / canvasSize.height
        let cellSize: CGFloat = 196
        let gapSize: CGFloat = 60
        let pitch = cellSize + gapSize

        let individualScreens = (0..<3).flatMap { row in
            (0..<5).compactMap { column -> CGRect? in
                guard !(row == 2 && (column == 3 || column == 4)) else { return nil }
                return CGRect(
                    x: canvasRect.minX + CGFloat(column) * pitch * scaleX,
                    y: canvasRect.minY + CGFloat(row) * pitch * scaleY,
                    width: cellSize * scaleX,
                    height: cellSize * scaleY
                )
            }
        }
        let bottomRightWideScreen = CGRect(
            x: canvasRect.minX + 3 * pitch * scaleX,
            y: canvasRect.minY + 2 * pitch * scaleY,
            width: (2 * cellSize + gapSize) * scaleX,
            height: cellSize * scaleY
        )
        return individualScreens + [bottomRightWideScreen]
    }

    private func drawGuide(in context: GraphicsContext, size: CGSize) {
        let canvasRect = Self.fittedCanvasRect(in: size)
        let screens = Self.screenRects(in: canvasRect)
        guard !screens.isEmpty else { return }

        var gaps = Path()
        gaps.addRect(canvasRect)
        screens.forEach { gaps.addRect($0) }
        context.fill(gaps, with: .color(.black.opacity(0.56)), style: FillStyle(eoFill: true))

        for screen in screens {
            let lineWidth: CGFloat = 1
            let outlineRect = screen.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let cornerRadius = min(outlineRect.width, outlineRect.height) * 0.04
            let outline = Path(
                roundedRect: outlineRect,
                cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
            )
            context.stroke(outline, with: .color(.white.opacity(0.84)), lineWidth: lineWidth)
        }
    }
}
