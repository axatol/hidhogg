import HidhoggDomain
import LogitechBolt
import SwiftUI

struct LogitechBoltPairingSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pair a new mouse with a Logi Bolt receiver.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isBoltPairingLoading {
                    ProgressView("Checking Logi Bolt receivers…")
                }

                if isChoosingReceiver {
                    Text("Choose the receiver to use for pairing.")
                        .font(.callout)
                    ForEach(model.boltPairingReceivers) { receiver in
                        HStack {
                            Text(receiver.label)
                            Spacer()
                            Button("Use Receiver") {
                                model.pairLogitechSetup(receiverID: receiver.id)
                            }
                            .disabled(model.isLogitechSetupLoading || model.isBoltPairingLoading)
                        }
                    }
                } else if let status = model.boltPairingStatus, status.phase != .idle {
                    LogitechBoltPairingStatusView(
                        status: status,
                        expectedModel: expectedModel,
                        onSelectCandidate: model.selectBoltPairingCandidate,
                        showsCandidates: false
                    )
                }

                if let message = model.boltPairingMessage {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.shouldShowLogitechSetupRecoveryButton {
                    Button("Refresh Devices", systemImage: "arrow.clockwise") {
                        model.refreshLogitechSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRefreshLogitechSetup)
                }

                if !isChoosingReceiver {
                    Button(pairButtonTitle, systemImage: "cable.connector") {
                        model.pairLogitechSetup()
                    }
                        .disabled(model.isLogitechSetupLoading || model.isBoltPairingLoading || model.isBoltPairingInProgress || model.isLogitechSetupSelectionBlocked)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardContentPadding()
        } label: {
            Label("Logi Bolt", systemImage: "cable.connector")
        }
    }

    private var isChoosingReceiver: Bool {
        model.boltPairingReceivers.count > 1 &&
            (model.boltPairingStatus == nil || model.boltPairingStatus?.phase == .idle)
    }

    private var pairButtonTitle: String {
        "Pair Mouse"
    }

    private var expectedModel: LogitechMouseModel? {
        guard let destination = model.logitechSetupDestination,
              case let .reassociate(id) = destination else { return nil }
        return model.registration(id: id)?.mouseModel
    }
}
