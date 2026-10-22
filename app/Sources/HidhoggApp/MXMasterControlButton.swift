import SwiftUI

struct MXMasterControlButton: View {
    enum Presentation {
        case label
        case physicalRegion(shape: Path, width: CGFloat, height: CGFloat)
    }

    let target: DeviceEditorTarget
    let isSelected: Bool
    let presentation: Presentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch presentation {
            case .label:
                HStack(spacing: 10) {
                    Text(target.title)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.callout.weight(.bold))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    isSelected ? MXMasterMousePalette.selected.opacity(0.18) : MXMasterMousePalette.cardBackground,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(
                            isSelected ? MXMasterMousePalette.selected : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))

            case let .physicalRegion(shape, width, height):
                shape
                    .fill(isSelected ? MXMasterMousePalette.selected.opacity(0.18) : .clear)
                    .frame(width: width, height: height)
                    .contentShape(shape)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Selects this control and opens its settings.")
        .accessibilityIdentifier("mouse-control-\(identifierRole)-\(targetIdentifier)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var identifierRole: String {
        switch presentation {
        case .label: "label"
        case .physicalRegion: "region"
        }
    }

    private var accessibilityLabel: String {
        switch presentation {
        case .label: "\(target.title) label"
        case .physicalRegion: "\(target.title) physical region"
        }
    }

    private var targetIdentifier: String {
        switch target {
        case .back: "back"
        case .forward: "forward"
        case .verticalWheel: "vertical-wheel"
        case .thumbWheel: "thumb-wheel"
        }
    }
}
