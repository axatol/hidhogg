import SwiftUI

struct BoltReceiverManagementView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup("Stored Pairings", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Devices paired with this receiver, including offline devices.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.inspectBoltReceivers()
                    }
                    .disabled(isBusy)
                }

                if model.isBoltReceiverManagementBusy {
                    ProgressView("Checking receiver…")
                }

                if model.boltManagedReceivers.count > 1 {
                    ForEach(model.boltManagedReceivers) { receiver in
                        HStack {
                            Text(receiver.label)
                            Spacer()
                            if model.boltManagedInventory?.receiverID == receiver.id {
                                Image(systemName: "checkmark")
                                    .accessibilityLabel("Selected receiver")
                            } else {
                                Button("Inspect") { model.selectBoltManagedReceiver(receiver.id) }
                                    .disabled(isBusy)
                            }
                        }
                    }
                }

                if let inventory = model.boltManagedInventory {
                    Text("\(inventory.rows.count) of \(inventory.capacity) slots used")
                        .font(.callout.weight(.medium))
                    if inventory.rows.isEmpty {
                        Text("No stored pairings.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(inventory.rows) { row in
                        BoltStoredPairingRowView(row: row, inventoryID: inventory.id,
                                                receiverLabel: model.boltManagedReceivers.first { $0.id == inventory.receiverID }?.label ?? "Logi Bolt receiver",
                                                isDisabled: isBusy) { selection in
                            model.unpairBoltManagedRecord(recordID: selection.recordID, inventoryID: selection.inventoryID)
                        }
                    }
                }

                if let message = model.boltReceiverManagementMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        }
    }

    private var isBusy: Bool {
        model.isBoltReceiverManagementBusy || model.isLogitechSetupLoading ||
            model.isBoltPairingLoading || model.isBoltPairingInProgress
    }
}
