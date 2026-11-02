import HidhoggDomain
import LogitechBolt
import SwiftUI

struct LogitechDevicesListView: View {
    @EnvironmentObject private var model: AppModel

    let candidates: [LogitechEndpointCandidate]
    let isLoading: Bool
    let isDisabled: Bool
    let isSelectionDisabled: Bool
    let message: String?
    let actionTitle: (LogitechEndpointCandidate) -> String
    let onRefresh: () -> Void
    let onSelect: (LogitechEndpointCandidate) -> Void
    let onSelectBoltCandidate: (UUID) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if isLoading {
                    ProgressView("Checking Logitech devices…")
                }

                if model.isBoltReceiverManagementBusy {
                    ProgressView("Inspecting Logi Bolt receivers…")
                }

                if let message {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message = model.boltReceiverManagementMessage {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if candidates.isEmpty,
                   rememberedRegistrations.isEmpty,
                   storedInventories.isEmpty,
                   pairingCandidates.isEmpty,
                   !isLoading,
                   !model.isBoltPairingLoading,
                   !model.isBoltPairingInProgress,
                   !model.isBoltReceiverManagementBusy,
                   message == nil,
                   model.boltReceiverManagementMessage == nil {
                    Text("No Logitech devices were found or remembered.")
                        .foregroundStyle(.secondary)
                }

                if !pairingCandidates.isEmpty {
                    sectionHeading("Ready to pair")
                    ForEach(pairingCandidates) { candidate in
                        boltPairingCandidateRow(candidate)
                    }
                }

                if !candidates.isEmpty {
                    if !pairingCandidates.isEmpty { Divider() }
                    sectionHeading("Available")
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

                if !rememberedRegistrations.isEmpty {
                    if !pairingCandidates.isEmpty || !candidates.isEmpty { Divider() }
                    sectionHeading("Remembered by Hidhogg")
                    ForEach(rememberedRegistrations) { registration in
                        rememberedRegistrationRow(registration)
                    }
                }

                if !storedInventories.isEmpty {
                    if !pairingCandidates.isEmpty || !candidates.isEmpty || !rememberedRegistrations.isEmpty {
                        Divider()
                    }
                    sectionHeading("Stored on Logi Bolt")
                    ForEach(storedInventories) { inventory in
                        if storedInventories.first?.id != inventory.id { Divider() }
                        storedInventorySection(inventory)
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardContentPadding()
        } label: {
            HStack {
                Label("Devices", systemImage: "computermouse")
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                    .disabled(isBusy)
            }
        }
    }

    private var isBusy: Bool {
        isDisabled || model.isBoltReceiverManagementBusy
    }

    private var storedInventories: [BoltReceiverInventory] {
        model.boltStoredInventories.filter { !$0.rows.isEmpty }
    }

    private var rememberedRegistrations: [RegisteredDevice] {
        let targetFamily = reassociatedRegistration?.family
        return model.registeredDevices.filter { registration in
            guard registration.family.isLogitechMouse,
                  targetFamily == nil || registration.family == targetFamily else { return false }
            guard let identity = registration.logitechAssociation?.identity else { return true }
            return !candidates.contains { $0.identity == identity }
        }
    }

    private var pairingCandidates: [BoltPairingCandidate] {
        guard model.boltPairingStatus?.phase == .awaitingSelection else { return [] }
        return model.boltPairingStatus?.candidates ?? []
    }

    private var expectedModel: LogitechMouseModel? {
        reassociatedRegistration?.mouseModel
    }

    private var reassociatedRegistration: RegisteredDevice? {
        guard let destination = model.logitechSetupDestination,
              case let .reassociate(id) = destination else { return nil }
        return model.registration(id: id)
    }

    private var reassociatedRegistrationID: UUID? {
        guard let destination = model.logitechSetupDestination,
              case let .reassociate(id) = destination else { return nil }
        return id
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func rememberedRegistrationRow(_ registration: RegisteredDevice) -> some View {
        HStack(spacing: 12) {
            Image("DeviceMouse")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(AppAppearance.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(registration.displayName)
                    .font(.headline)
                Text(rememberedConnectionLabel(for: registration))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Remembered by Hidhogg; no live endpoint was verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if registration.id == reassociatedRegistrationID {
                Text("Current Mouse")
                    .foregroundStyle(.secondary)
            } else {
                Button("Open Existing") {
                    model.openExistingLogitechSetupDevice(registration.id)
                }
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 5)
    }

    private func rememberedConnectionLabel(for registration: RegisteredDevice) -> String {
        switch registration.logitechAssociation?.preferredConnection {
        case .some(.bolt): "Saved connection: Logi Bolt"
        case .some(.bluetooth): "Saved connection: Bluetooth"
        case nil: "Saved Logitech mouse"
        }
    }

    private func storedInventorySection(_ inventory: BoltReceiverInventory) -> some View {
        let receiverLabel = model.boltStoredReceiverLabels[inventory.receiverID] ?? "Logi Bolt receiver"

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(receiverLabel)
                        .font(.headline)
                    Text("\(inventory.rows.count) of \(inventory.capacity) receiver slots used")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button("Inspect", systemImage: "arrow.clockwise") {
                    inspectReceiver(inventory.receiverID)
                }
                .disabled(isBusy)
            }

            ForEach(inventory.rows) { row in
                let canUnpair = model.canUnpairStoredRecord(inventoryID: inventory.id, recordID: row.id)
                if inventory.rows.first?.id != row.id { Divider() }
                LogitechStoredBoltDeviceRow(
                    row: row,
                    inventoryID: inventory.id,
                    receiverLabel: receiverLabel,
                    canUnpair: canUnpair,
                    isInventoryStale: model.isBoltManagedInventoryStale,
                    isDisabled: isBusy,
                    onUnpair: { recordID, inventoryID in
                        model.unpairBoltManagedRecord(recordID: recordID, inventoryID: inventoryID)
                    }
                )
            }
        }
    }

    private func inspectReceiver(_ receiverID: UUID) {
        let isKnownInActiveContext = !model.isBoltManagedInventoryStale &&
            model.boltManagedReceivers.contains { $0.id == receiverID }
        guard isKnownInActiveContext else {
            model.inspectBoltReceivers()
            return
        }
        model.selectBoltManagedReceiver(receiverID)
    }

    private func boltPairingCandidateRow(_ candidate: BoltPairingCandidate) -> some View {
        let isSupported = candidate.model != nil
        let matchesExpectedModel = expectedModel == nil || candidate.model == expectedModel

        return HStack(spacing: 12) {
            Image("DeviceMouse")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(AppAppearance.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name ?? candidate.model?.family.title ?? "Unsupported device")
                    .font(.headline)
                Text("New Logi Bolt pairing candidate")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !isSupported {
                    Text("This device cannot be added as a supported mouse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !matchesExpectedModel {
                    Text("This mouse does not match the registered model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button("Pair", systemImage: "checkmark.circle") {
                onSelectBoltCandidate(candidate.id)
            }
            .disabled(!isSupported || !matchesExpectedModel || model.isBoltPairingLoading || model.isBoltReceiverManagementBusy)
        }
        .padding(.vertical, 5)
    }
}
