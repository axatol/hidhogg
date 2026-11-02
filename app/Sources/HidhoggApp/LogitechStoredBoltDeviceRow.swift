import LogitechBolt
import SwiftUI

struct LogitechStoredBoltDeviceRow: View {
    let row: BoltReceiverInventoryRow
    let inventoryID: UUID
    let receiverLabel: String
    let canUnpair: Bool
    let isInventoryStale: Bool
    let isDisabled: Bool
    let onUnpair: (UUID, UUID) -> Void
    @State private var isShowingConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            Text("Slot \(row.slot)")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 3) {
                Text(row.label)
                    .font(.headline)
                Text("\(row.isReachable ? "Reachable" : "Offline") · \(snapshotStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if canUnpair {
                Button("Unpair…", role: .destructive) {
                    isShowingConfirmation = true
                }
                .disabled(isDisabled)
                .confirmationDialog("Unpair device from receiver?", isPresented: $isShowingConfirmation,
                                    titleVisibility: .visible) {
                    Button("Unpair \(row.label)", role: .destructive) {
                        onUnpair(row.id, inventoryID)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Remove \(row.label) from slot \(row.slot) of \(receiverLabel)? It will stop connecting through this receiver until paired again. Hidhogg settings will be retained.")
                }
            } else {
                Text("Inspect to manage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .onChange(of: canUnpair) { _, permitted in
            if !permitted { isShowingConfirmation = false }
        }
    }

    private var snapshotStatus: String {
        if isInventoryStale { return "Last read · stale" }
        return canUnpair ? "Current inspection" : "Cached · inspect receiver"
    }
}
