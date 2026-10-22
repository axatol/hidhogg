import SwiftUI

struct MXMasterMousePresentation: View {
    let selectedTarget: DeviceEditorTarget
    let onSelect: (DeviceEditorTarget) -> Void

    private let labelWidth: CGFloat = 180
    private let wideSpacing: CGFloat = 14
    private let labelSpacing: CGFloat = 8
    private let labelHeight: CGFloat = 48
    private let canvasAspectRatio = MXMasterMouseGeometry.canvasSize.width / MXMasterMouseGeometry.canvasSize.height
    private let wideTargetOrder: [DeviceEditorTarget] = [.thumbWheel, .back, .verticalWheel, .forward]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout(artworkWidth: 500)
            wideLayout(artworkWidth: 420)
            wideLayout(artworkWidth: 360)
            compactLayout
        }
        .frame(maxWidth: .infinity)
    }

    private func wideLayout(artworkWidth: CGFloat) -> some View {
        let artworkHeight = artworkWidth / canvasAspectRatio
        let labelsHeight = CGFloat(wideTargetOrder.count) * labelHeight
            + CGFloat(wideTargetOrder.count - 1) * labelSpacing
        let contentHeight = max(artworkHeight, labelsHeight)
        let artworkOriginX = labelWidth + wideSpacing
        let artworkOriginY = (contentHeight - artworkHeight) / 2
        let contentWidth = artworkOriginX + artworkWidth

        return ZStack(alignment: .topLeading) {
            MXMasterMouseArtwork(
                selectedTarget: selectedTarget,
                onSelect: onSelect
            )
            .frame(width: artworkWidth, height: artworkHeight)
            .offset(x: artworkOriginX, y: artworkOriginY)

            wideConnectors(
                artworkWidth: artworkWidth,
                artworkOriginX: artworkOriginX,
                artworkOriginY: artworkOriginY,
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                labelsHeight: labelsHeight
            )

            VStack(spacing: labelSpacing) {
                ForEach(wideTargetOrder, id: \.self) { target in
                    controlLabel(target)
                        .frame(width: labelWidth, height: labelHeight)
                }
            }
            .frame(width: labelWidth, height: contentHeight, alignment: .center)
            .zIndex(1)
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
    }

    private func wideConnectors(
        artworkWidth: CGFloat,
        artworkOriginX: CGFloat,
        artworkOriginY: CGFloat,
        contentWidth: CGFloat,
        contentHeight: CGFloat,
        labelsHeight: CGFloat
    ) -> some View {
        Canvas { context, _ in
            let scale = artworkWidth / MXMasterMouseGeometry.canvasSize.width
            let labelsTop = (contentHeight - labelsHeight) / 2

            for (index, target) in self.wideTargetOrder.enumerated() {
                let bounds = self.hitBounds(for: target)
                let targetCenter = CGPoint(
                    x: artworkOriginX + bounds.midX * scale,
                    y: artworkOriginY + bounds.midY * scale
                )
                let labelCenter = CGPoint(
                    x: self.labelWidth,
                    y: labelsTop + CGFloat(index) * (self.labelHeight + self.labelSpacing) + self.labelHeight / 2
                )
                let color = self.selectedTarget == target
                    ? MXMasterMousePalette.selected
                    : MXMasterMousePalette.neutralRegion
                var connector = Path()
                connector.move(to: labelCenter)
                connector.addLine(to: targetCenter)

                context.stroke(
                    connector,
                    with: .color(color),
                    style: StrokeStyle(
                        lineWidth: self.selectedTarget == target ? 1.5 : 1,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

                let endpoint = Path(
                    ellipseIn: CGRect(
                        x: targetCenter.x - 3.5,
                        y: targetCenter.y - 3.5,
                        width: 7,
                        height: 7
                    )
                )
                context.fill(endpoint, with: .color(color))
                context.stroke(endpoint, with: .color(MXMasterMousePalette.darkDetail), lineWidth: 1)
            }
        }
        .frame(width: contentWidth, height: contentHeight)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var compactLayout: some View {
        VStack(spacing: 14) {
            MXMasterMouseArtwork(
                selectedTarget: selectedTarget,
                onSelect: onSelect
            )
            .aspectRatio(canvasAspectRatio, contentMode: .fit)
            .frame(maxWidth: 260)

            VStack(spacing: labelSpacing) {
                controlLabel(.verticalWheel)
                    .frame(maxWidth: .infinity)
                controlLabel(.thumbWheel)
                    .frame(maxWidth: .infinity)
                controlLabel(.back)
                    .frame(maxWidth: .infinity)
                controlLabel(.forward)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity)
    }

    private func controlLabel(_ target: DeviceEditorTarget) -> some View {
        MXMasterControlButton(
            target: target,
            isSelected: selectedTarget == target,
            presentation: .label
        ) {
            onSelect(target)
        }
    }

    private func hitBounds(for target: DeviceEditorTarget) -> CGRect {
        switch target {
        case .back: MXMasterMouseGeometry.backButtonHitBounds
        case .forward: MXMasterMouseGeometry.forwardButtonHitBounds
        case .verticalWheel: MXMasterMouseGeometry.verticalWheelHitBounds
        case .thumbWheel: MXMasterMouseGeometry.thumbWheelHitBounds
        }
    }
}
