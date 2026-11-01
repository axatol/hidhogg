import SwiftUI

struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 10) {
            configuration.icon
                .frame(width: 20, height: 20, alignment: .center)
            configuration.title
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
