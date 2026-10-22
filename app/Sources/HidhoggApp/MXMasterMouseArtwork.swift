import SwiftUI

struct MXMasterMouseArtwork: View {
    let selectedTarget: DeviceEditorTarget
    let onSelect: (DeviceEditorTarget) -> Void

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / MXMasterMouseGeometry.canvasSize.width,
                geometry.size.height / MXMasterMouseGeometry.canvasSize.height
            )
            let artworkSize = CGSize(
                width: MXMasterMouseGeometry.canvasSize.width * scale,
                height: MXMasterMouseGeometry.canvasSize.height * scale
            )
            let artworkOrigin = CGPoint(
                x: (geometry.size.width - artworkSize.width) / 2,
                y: (geometry.size.height - artworkSize.height) / 2
            )

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var context = context
                    context.scaleBy(x: scale, y: scale)

                    context.fill(MXMasterMouseGeometry.outerShell, with: .color(MXMasterMousePalette.outerShell))
                    context.stroke(
                        MXMasterMouseGeometry.outerShell,
                        with: .color(MXMasterMousePalette.sideWall),
                        style: self.strokeStyle(lineWidth: 4)
                    )
                    context.fill(MXMasterMouseGeometry.lowerShell, with: .color(MXMasterMousePalette.lowerShell))
                    context.fill(MXMasterMouseGeometry.sideWall, with: .color(MXMasterMousePalette.sideWall))
                    context.fill(MXMasterMouseGeometry.topShell, with: .color(MXMasterMousePalette.topShell))
                    context.fill(MXMasterMouseGeometry.bandShadow, with: .color(MXMasterMousePalette.sideWall))
                    context.fill(MXMasterMouseGeometry.rightClickPanel, with: .color(MXMasterMousePalette.outerShell))
                    context.stroke(
                        MXMasterMouseGeometry.rightClickPanel,
                        with: .color(MXMasterMousePalette.darkDetail),
                        style: self.strokeStyle(lineWidth: 4)
                    )
                    context.stroke(
                        MXMasterMouseGeometry.panelSeams,
                        with: .color(MXMasterMousePalette.darkDetail),
                        style: self.strokeStyle(lineWidth: 4)
                    )
                    context.fill(MXMasterMouseGeometry.palmRest, with: .color(MXMasterMousePalette.sideWall))
                    context.fill(MXMasterMouseGeometry.modeButton, with: .color(MXMasterMousePalette.outerShell))
                    context.stroke(
                        MXMasterMouseGeometry.modeButton,
                        with: .color(MXMasterMousePalette.darkDetail),
                        style: self.strokeStyle(lineWidth: 5)
                    )
                    context.fill(MXMasterMouseGeometry.verticalWheelHousing, with: .color(MXMasterMousePalette.darkDetail))
                    context.fill(MXMasterMouseGeometry.verticalWheelFace, with: .color(MXMasterMousePalette.wheelFace))
                    context.fill(MXMasterMouseGeometry.verticalWheelShadow, with: .color(MXMasterMousePalette.wheelShadow))
                    context.fill(MXMasterMouseGeometry.thumbWheelCasing, with: .color(MXMasterMousePalette.darkDetail))
                    context.fill(MXMasterMouseGeometry.thumbWheelUpperFace, with: .color(MXMasterMousePalette.wheelShadow))
                    context.fill(MXMasterMouseGeometry.thumbWheelUpperHighlight, with: .color(MXMasterMousePalette.wheelFace))
                    context.fill(MXMasterMouseGeometry.thumbWheelLowerFace, with: .color(MXMasterMousePalette.wheelShadow))
                    context.fill(MXMasterMouseGeometry.thumbWheelLowerHighlight, with: .color(MXMasterMousePalette.wheelFace))
                    context.fill(MXMasterMouseGeometry.backButton, with: .color(MXMasterMousePalette.lowerShell))
                    context.stroke(
                        MXMasterMouseGeometry.backButton,
                        with: .color(MXMasterMousePalette.darkDetail),
                        style: self.strokeStyle(lineWidth: 8)
                    )
                    context.fill(MXMasterMouseGeometry.forwardButton, with: .color(MXMasterMousePalette.lowerShell))
                    context.stroke(
                        MXMasterMouseGeometry.forwardButton,
                        with: .color(MXMasterMousePalette.darkDetail),
                        style: self.strokeStyle(lineWidth: 8)
                    )
                    context.stroke(
                        MXMasterMouseGeometry.smoothBand,
                        with: .color(MXMasterMousePalette.sideWall),
                        style: self.strokeStyle(lineWidth: 28)
                    )

                    context.stroke(
                        MXMasterMouseGeometry.verticalWheelHousing,
                        with: .color(self.regionColor(for: .verticalWheel)),
                        style: self.regionStrokeStyle(for: .verticalWheel)
                    )
                    context.stroke(
                        MXMasterMouseGeometry.thumbWheelCasing,
                        with: .color(self.regionColor(for: .thumbWheel)),
                        style: self.regionStrokeStyle(for: .thumbWheel)
                    )
                    context.stroke(
                        MXMasterMouseGeometry.backButton,
                        with: .color(self.regionColor(for: .back)),
                        style: self.regionStrokeStyle(for: .back)
                    )
                    context.stroke(
                        MXMasterMouseGeometry.forwardButton,
                        with: .color(self.regionColor(for: .forward)),
                        style: self.regionStrokeStyle(for: .forward)
                    )
                }
                .frame(width: artworkSize.width, height: artworkSize.height)
                .position(
                    x: artworkOrigin.x + artworkSize.width / 2,
                    y: artworkOrigin.y + artworkSize.height / 2
                )
                .accessibilityHidden(true)

                physicalRegion(
                    .verticalWheel,
                    shape: MXMasterMouseGeometry.verticalWheelHitShape,
                    bounds: MXMasterMouseGeometry.verticalWheelHitBounds,
                    scale: scale,
                    artworkOrigin: artworkOrigin
                )
                physicalRegion(
                    .thumbWheel,
                    shape: MXMasterMouseGeometry.thumbWheelHitShape,
                    bounds: MXMasterMouseGeometry.thumbWheelHitBounds,
                    scale: scale,
                    artworkOrigin: artworkOrigin
                )
                physicalRegion(
                    .back,
                    shape: MXMasterMouseGeometry.backButtonHitShape,
                    bounds: MXMasterMouseGeometry.backButtonHitBounds,
                    scale: scale,
                    artworkOrigin: artworkOrigin
                )
                physicalRegion(
                    .forward,
                    shape: MXMasterMouseGeometry.forwardButtonHitShape,
                    bounds: MXMasterMouseGeometry.forwardButtonHitBounds,
                    scale: scale,
                    artworkOrigin: artworkOrigin
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MX Master 3S control diagram")
    }

    private func physicalRegion(
        _ target: DeviceEditorTarget,
        shape: Path,
        bounds: CGRect,
        scale: CGFloat,
        artworkOrigin: CGPoint
    ) -> some View {
        let scaledBounds = CGRect(
            x: bounds.minX * scale,
            y: bounds.minY * scale,
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        let scaledShape = shape.applying(CGAffineTransform(scaleX: scale, y: scale))

        return MXMasterControlButton(
            target: target,
            isSelected: selectedTarget == target,
            presentation: .physicalRegion(
                shape: scaledShape,
                width: scaledBounds.width,
                height: scaledBounds.height
            )
        ) {
            onSelect(target)
        }
        .position(
            x: artworkOrigin.x + scaledBounds.midX,
            y: artworkOrigin.y + scaledBounds.midY
        )
    }

    private func regionColor(for target: DeviceEditorTarget) -> Color {
        selectedTarget == target ? MXMasterMousePalette.selected : MXMasterMousePalette.neutralRegion
    }

    private func regionStrokeStyle(for target: DeviceEditorTarget) -> StrokeStyle {
        strokeStyle(lineWidth: selectedTarget == target ? 12 : 8)
    }

    private func strokeStyle(lineWidth: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }
}
