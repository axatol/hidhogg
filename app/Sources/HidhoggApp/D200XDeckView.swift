import HidhoggDomain
import SwiftUI

struct D200XDeckView: View {
    @ObservedObject var model: D200XModel
    var onSelect: () -> Void = {}

    private var tileControls: [D200XControl] {
        D200XControl.allCases.filter(\.isTile)
    }

    var body: some View {
        VStack(spacing: 0) {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    ForEach(tileControls.prefix(5), id: \.self) { control in
                        tileButton(control)
                    }
                }

                GridRow {
                    ForEach(tileControls[5..<10], id: \.self) { control in
                        tileButton(control)
                    }
                }

                GridRow {
                    ForEach(tileControls[10..<13], id: \.self) { control in
                        tileButton(control)
                    }
                    tileButton(.key13, isWide: true)
                        .gridCellColumns(2)
                }
            }
            .padding(12)
            .background(MXMasterMousePalette.sideWall, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(MXMasterMousePalette.darkDetail, lineWidth: 1)
            }

            Rectangle()
                .fill(MXMasterMousePalette.darkDetail)
                .frame(height: 2)
                .padding(.top, 10)
                .accessibilityHidden(true)

            frontControls
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
        }
        .padding(12)
        .background(MXMasterMousePalette.outerShell, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(MXMasterMousePalette.darkDetail, lineWidth: 1.5)
        }
        .frame(maxWidth: 630)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("D200X control deck")
    }

    private var frontControls: some View {
        HStack(alignment: .center, spacing: 12) {
            sideButton(.side0)
            sideButton(.side1)

            ForEach(0..<3, id: \.self) { index in
                dialButton(index)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tileButton(_ control: D200XControl, isWide: Bool = false) -> some View {
        let appearance = model.configuration?.appearance(for: control, application: model.applicationID) ??
            D200XConfiguration.defaultAppearance(for: control)
        let notificationLabel = model.notificationLabels[control.rawValue]
        let spokenLabel = notificationLabel.flatMap { $0.isEmpty ? nil : $0 } ?? appearance.label
        let isSelected = model.selectedControl == control
        let shape = RoundedRectangle(cornerRadius: 5)

        return Button {
            select(control)
        } label: {
            Rectangle()
                .fill(tileColor(for: appearance.backgroundHex))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(isWide ? 2.05 : 1, contentMode: .fit)
                .overlay {
                    D200XTilePreview(
                        appearance: appearance,
                        wide: isWide,
                        labelOverride: notificationLabel,
                        assetDirectory: model.assetDirectory,
                        notificationIcon: model.notificationIcons[control.rawValue]
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(shape)
                .overlay {
                    shape.stroke(
                        isSelected ? MXMasterMousePalette.selected : MXMasterMousePalette.neutralRegion.opacity(0.72),
                        lineWidth: isSelected ? 2.5 : 1
                    )
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(control.title), \(spokenLabel)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sideButton(_ control: D200XControl) -> some View {
        let isSelected = model.selectedControl == control
        let outline = isSelected ? MXMasterMousePalette.selected : MXMasterMousePalette.neutralRegion.opacity(0.72)

        return Button {
            select(control)
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(MXMasterMousePalette.lowerShell)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Circle().stroke(outline, lineWidth: isSelected ? 2 : 1)
                    }
                    .frame(height: 32)

                Text(control.title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(MXMasterMousePalette.neutralRegion)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func dialButton(_ index: Int) -> some View {
        let wireIndex = index + 17
        let isSelected = model.selectedControl.wireIndex == wireIndex
        let outline = isSelected ? MXMasterMousePalette.selected : MXMasterMousePalette.neutralRegion.opacity(0.72)

        return Button {
            selectDial(index)
            onSelect()
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(MXMasterMousePalette.lowerShell)
                        .frame(width: 39, height: 39)
                        .overlay {
                            Circle()
                                .stroke(outline, lineWidth: isSelected ? 2 : 1)
                        }
                        .offset(y: -1)

                    Circle()
                        .stroke(MXMasterMousePalette.neutralRegion.opacity(0.22), lineWidth: 1)
                        .frame(width: 25, height: 25)
                        .offset(y: -1)
                        .accessibilityHidden(true)
                }
                .frame(height: 42)

                Text("Dial \(index + 1)")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(MXMasterMousePalette.neutralRegion)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dial \(index + 1)")
        .accessibilityValue(isSelected ? "Selected, \(model.selectedControl.gesture?.title ?? D200XGesture.press.title)" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectDial(_ index: Int) {
        let wireIndex = index + 17
        guard model.selectedControl.wireIndex != wireIndex,
              let pressControl = D200XControl.allCases.first(where: {
                  $0.wireIndex == wireIndex && $0.gesture == .press
              }) else { return }

        model.selectedControl = pressControl
    }

    private func select(_ control: D200XControl) {
        model.selectedControl = control
        onSelect()
    }

    private func tileColor(for hex: String) -> Color {
        let (red, green, blue) = rgbComponents(for: hex)
        return Color(red: red, green: green, blue: blue)
    }

    private func rgbComponents(for hex: String) -> (Double, Double, Double) {
        guard let value = UInt32(hex, radix: 16) else { return (0.19, 0.20, 0.22) }
        return (
            Double((value >> 16) & 0xff) / 255,
            Double((value >> 8) & 0xff) / 255,
            Double(value & 0xff) / 255
        )
    }
}
