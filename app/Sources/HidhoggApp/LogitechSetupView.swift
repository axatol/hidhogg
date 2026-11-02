import HidhoggDomain
import LogitechBolt
import SwiftUI

struct LogitechSetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reassociatedRegistration == nil ? "Add Logitech Mouse" : "Change Connection")
                        .font(.title2.weight(.semibold))
                    Text(description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                connectionLayout {
                    LogitechBoltPairingSection()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    bluetoothPairingUnavailable
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                LogitechDevicesListView(
                    candidates: displayedCandidates,
                    isLoading: isCheckingInventory,
                    isDisabled: isSetupBusy,
                    isSelectionDisabled: model.isLogitechSetupSelectionBlocked,
                    message: model.logitechSetupMessage,
                    actionTitle: endpointActionTitle,
                    onRefresh: model.refreshLogitechSetup,
                    onSelect: selectEndpoint,
                    onSelectBoltCandidate: model.selectBoltPairingCandidate
                )
            }
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            availableWidth = max(0, min(780, width - 48))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                if isInlinePairingActive {
                    Button("Cancel Pairing", systemImage: "xmark.circle", role: .cancel) {
                        model.cancelLogitechSetupPairing()
                    }
                }
                Spacer(minLength: 0)
                Button(reassociatedRegistration == nil ? "Cancel" : "Back to Device", role: .cancel) {
                    model.cancelLogitechSetup()
                }
                .keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .navigationTitle(reassociatedRegistration == nil ? "Add Logitech Mouse" : "Change Connection")
    }

    private var connectionLayout: AnyLayout {
        if availableWidth >= 680 {
            return AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        }
        return AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
    }

    private var bluetoothPairingUnavailable: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("New Bluetooth pairing is not available yet.")
                    .font(.headline)
                Text("Mice already paired through Bluetooth appear in Devices below.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardContentPadding()
        } label: {
            Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    private var description: String {
        guard let registration = reassociatedRegistration else {
            return "Choose a mouse that is already paired, or pair a new mouse with a Logi Bolt receiver."
        }
        return "Change how \(registration.displayName) connects. Its Hidhogg settings will be preserved."
    }

    private var reassociatedRegistration: RegisteredDevice? {
        guard let destination = model.logitechSetupDestination,
              case let .reassociate(id) = destination else { return nil }
        return model.registration(id: id)
    }

    private var displayedCandidates: [LogitechEndpointCandidate] {
        guard let registration = reassociatedRegistration else { return model.logitechSetupCandidates }
        return model.logitechSetupCandidates.filter { $0.model.family == registration.family }
    }

    private var isSetupBusy: Bool {
        model.isLogitechSetupLoading || model.isBoltPairingLoading || model.isBoltPairingInProgress
    }

    private var isCheckingInventory: Bool {
        model.isLogitechSetupLoading && !model.isSaving && !model.isBoltPairingInProgress
    }

    private var isInlinePairingActive: Bool {
        if model.isBoltPairingLoading || model.isBoltPairingInProgress { return true }
        if model.boltPairingReceivers.count > 1,
           model.boltPairingStatus == nil || model.boltPairingStatus?.phase == .idle {
            return true
        }
        guard let phase = model.boltPairingStatus?.phase else { return false }
        return [.discovering, .awaitingSelection, .authenticating, .verifying].contains(phase)
    }

    private func endpointActionTitle(_ candidate: LogitechEndpointCandidate) -> String {
        if let existingID = model.existingLogitechRegistrationID(for: candidate) {
            if case let .reassociate(targetID)? = model.logitechSetupDestination, existingID == targetID {
                return "Use This Mouse"
            }
            return "Open Existing"
        }
        return reassociatedRegistration == nil ? "Add" : "Use This Mouse"
    }

    private func selectEndpoint(_ candidate: LogitechEndpointCandidate) {
        if let existingID = model.existingLogitechRegistrationID(for: candidate) {
            if case let .reassociate(targetID)? = model.logitechSetupDestination, existingID == targetID {
                model.addLogitechSetupCandidate(candidate.id)
            } else {
                model.openExistingLogitechSetupDevice(existingID)
            }
            return
        }
        model.addLogitechSetupCandidate(candidate.id)
    }
}
