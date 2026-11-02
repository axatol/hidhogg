import LogitechBolt
import SwiftUI

struct LogitechSetupInventorySection: View {
    let candidates: [LogitechEndpointCandidate]
    let isLoading: Bool
    let isDisabled: Bool
    let isSelectionDisabled: Bool
    let message: String?
    let actionTitle: (LogitechEndpointCandidate) -> String
    let onRefresh: () -> Void
    let onSelect: (LogitechEndpointCandidate) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if isLoading {
                    ProgressView("Checking existing mice…")
                }

                if let message {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if candidates.isEmpty && !isLoading && message == nil {
                    Text("No paired Logitech mice were found.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }

                ForEach(candidates) { candidate in
                    if candidates.first?.id != candidate.id { Divider() }
                    LogitechSetupEndpointRow(
                        candidate: candidate,
                        actionTitle: actionTitle(candidate),
                        isDisabled: isDisabled || isSelectionDisabled,
                        action: { onSelect(candidate) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Label("Existing Mice", systemImage: "computermouse")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                    .disabled(isDisabled)
            }
        }
    }
}
