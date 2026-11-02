import LogitechBolt
import SwiftUI

struct BoltStoredPairingRowView: View {
    let row: BoltReceiverInventoryRow
    let inventoryID: UUID
    let receiverLabel: String
    let isDisabled: Bool
    let onUnpair: (BoltUnpairSelection) -> Void
    @State private var selection: BoltUnpairSelection?
    @State private var isShowingConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            Text("Slot \(row.slot)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label)
                Text(row.isReachable ? "Connected" : "Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unpair…", role: .destructive) {
                selection = BoltUnpairSelection(inventoryID: inventoryID, recordID: row.id,
                                               label: row.label, receiverLabel: receiverLabel, slot: row.slot)
                isShowingConfirmation = true
            }
            .disabled(isDisabled)
            .confirmationDialog("Unpair device from receiver?", isPresented: $isShowingConfirmation,
                                titleVisibility: .visible, presenting: selection) { selected in
                Button("Unpair \(selected.label)", role: .destructive) {
                    onUnpair(selected)
                    selection = nil
                }
                Button("Cancel", role: .cancel) { selection = nil }
            } message: { selected in
                Text("Remove \(selected.label) from slot \(selected.slot) of \(selected.receiverLabel)? It will stop connecting through this receiver until paired again. Hidhogg settings will be retained.")
            }
        }
        .onChange(of: isDisabled) { _, disabled in
            guard disabled else { return }
            isShowingConfirmation = false
            selection = nil
        }
    }
}
