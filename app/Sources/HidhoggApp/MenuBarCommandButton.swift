import SwiftUI

struct MenuBarCommandButton: View {
    let title: String
    let symbol: String
    let hint: String
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
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
        .accessibilityHint(hint)
    }
}
