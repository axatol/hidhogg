import AppKit
import HidhoggDomain
import SwiftUI

struct D200XTilePreview: View {
    let appearance: D200XTileAppearance
    let wide: Bool
    let labelOverride: String?
    let assetDirectory: URL?

    @State private var renderedImage: NSImage?

    private var renderKey: RenderKey {
        RenderKey(
            appearance: appearance,
            wide: wide,
            labelOverride: labelOverride,
            assetDirectory: assetDirectory
        )
    }

    private var fallbackTitle: String {
        labelOverride.flatMap { $0.isEmpty ? nil : $0 } ?? appearance.label
    }

    var body: some View {
        Group {
            if let renderedImage {
                Image(nsImage: renderedImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if appearance.showTitle || labelOverride != nil || appearance.imageAsset != nil {
                Text(fallbackTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .foregroundStyle(fallbackTitleColor)
            } else {
                Color.clear
            }
        }
        .accessibilityHidden(true)
        .task(id: renderKey) {
            let key = renderKey
            await render(for: key)
        }
    }

    private var fallbackTitleColor: Color {
        if let hex = appearance.titleColorHex, Self.isValidHex(hex) {
            return Self.color(forHex: hex)
        }
        let (red, green, blue) = Self.rgb(forHex: appearance.backgroundHex)
        let linear: (Double) -> Double = {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance > 0.179 ? .black : .white
    }

    private func render(for key: RenderKey) async {
        renderedImage = nil
        let renderTask = Task.detached(priority: .utility) {
            try D200XPageRenderer.tilePNG(
                appearance: key.appearance,
                wide: key.wide,
                labelOverride: key.labelOverride,
                assetDirectory: key.assetDirectory,
                destination: .preview
            )
        }

        do {
            let data = try await withTaskCancellationHandler {
                try await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            try Task.checkCancellation()
            guard renderKey == key, let image = NSImage(data: data) else { return }
            renderedImage = image
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private static func isValidHex(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func rgb(forHex value: String) -> (Double, Double, Double) {
        guard isValidHex(value), let color = UInt32(value, radix: 16) else {
            return (0.19, 0.20, 0.22)
        }
        return (
            Double((color >> 16) & 255) / 255,
            Double((color >> 8) & 255) / 255,
            Double(color & 255) / 255
        )
    }

    private static func color(forHex value: String) -> Color {
        let (red, green, blue) = rgb(forHex: value)
        return Color(red: red, green: green, blue: blue)
    }

    private struct RenderKey: Equatable, Sendable {
        let appearance: D200XTileAppearance
        let wide: Bool
        let labelOverride: String?
        let assetDirectory: URL?
    }
}
