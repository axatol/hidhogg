import AppKit
import HidhoggDomain
import SwiftUI

struct MenuBarDeviceRow: View {
    enum Status {
        case connected
        case transitioning
        case disconnected
        case disabled

        var color: Color {
            switch self {
            case .connected: .green
            case .transitioning: .orange
            case .disconnected, .disabled: .secondary
            }
        }
    }

    enum Symbol {
        case system(String)
        case bluetooth(BluetoothDeviceKind)
    }

    struct BatteryComponent: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    let title: String
    let symbol: Symbol
    let status: Status
    let primaryValue: String
    var components: [BatteryComponent] = []
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    DeviceIcon(symbol: symbol)
                        .frame(width: 18, height: 18)
                        .padding(2)

                    Circle()
                        .fill(status.color)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(primaryValue)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    if !components.isEmpty {
                        componentGroup
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.accentColor.opacity(0.14) : isHovered ? Color.primary.opacity(0.07) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var componentGroup: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(components) { component in
                    HStack(spacing: 4) {
                        Text(component.label)
                            .foregroundStyle(.secondary)
                        Text(component.value)
                            .monospacedDigit()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 1) {
                ForEach(components) { component in
                    GridRow {
                        Text(component.label)
                            .foregroundStyle(.secondary)
                        Text(component.value)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .font(.caption)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private struct DeviceIcon: View {
        let symbol: Symbol

        @ViewBuilder
        var body: some View {
            switch symbol {
            case .system(let name):
                Image(systemName: name)
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            case .bluetooth(let kind):
                BluetoothDeviceIcon(kind: kind)
                    .accessibilityHidden(true)
            }
        }
    }
}
