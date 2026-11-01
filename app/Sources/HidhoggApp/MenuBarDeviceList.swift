import SwiftUI

struct MenuBarDeviceList<Content: View>: View {
    let rowCount: Int
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(.vertical, 1)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .frame(height: min(420, max(1, contentHeight ?? CGFloat(max(1, rowCount)) * 44)))
    }
}
