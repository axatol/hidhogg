import SwiftUI

struct PermissionSettingsRow<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    private let actions: Actions

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                description
                Spacer()
                actions
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading) {
                description
                actions
            }
        }
    }

    private var description: some View {
        Label {
            VStack(alignment: .leading) {
                Text(title)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
