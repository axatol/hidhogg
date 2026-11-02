import HidhoggDomain
import LogitechBolt
import SwiftUI

struct BoltPairingView: View {
    @EnvironmentObject private var model: AppModel
    private var selectedModel: LogitechMouseModel? {
        model.selectedMouseID.flatMap { model.registration(id: $0)?.mouseModel }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pair a new mouse")
                .font(.title2.weight(.semibold))
            Text("Pair a \(model.selectedMouseName) with a Logi Bolt receiver. The registration’s Hidhogg settings are retained.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isBoltPairingLoading {
                        ProgressView("Checking pairing progress…")
                    }
                    if model.boltPairingStatus == nil || model.boltPairingStatus?.phase == .idle {
                        receiverChoices
                    }
                    if let status = model.boltPairingStatus {
                        Text(status.message)
                            .fixedSize(horizontal: false, vertical: true)
                        if status.phase == .discovering {
                            Text("Choose a free Easy-Switch channel on the mouse, then hold its channel button until the light blinks rapidly. Discovery ends automatically.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if status.phase == .awaitingSelection {
                            candidateChoices(status.candidates)
                        }
                        if let challenge = status.challenge {
                            authenticationInstructions(challenge)
                        }
                    }
                    if let message = model.boltPairingMessage {
                        Label(message, systemImage: "info.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Existing receiver pairings are retained. If pairing completes after cancellation or saving fails, use Choose Existing Mouse to add the mouse to Hidhogg.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(model.isBoltPairingInProgress ? "Cancel Pairing" : "Close", role: .cancel) { model.dismissBoltPairing() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 560)
        .interactiveDismissDisabled(model.isBoltPairingLoading)
    }

    private var receiverChoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a receiver").font(.headline)
            Text("If receiver labels are identical, leave only the intended receiver connected before opening this sheet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.boltPairingReceivers) { receiver in
                HStack {
                    Text(receiver.label)
                    Spacer()
                    Button("Use Receiver") { model.selectBoltPairingReceiver(receiver.id) }
                        .disabled(model.isBoltPairingLoading)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func candidateChoices(_ candidates: [BoltPairingCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a mouse").font(.headline)
            ForEach(candidates) { candidate in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidateTitle(candidate)).font(.headline)
                        Text(candidate.model?.family.title ?? "Unsupported mouse")
                            .foregroundStyle(.secondary)
                        if candidate.model != selectedModel {
                            Text("This mouse does not match the selected registration.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Pair Mouse") { model.selectBoltPairingCandidate(candidate.id) }
                        .disabled(model.isBoltPairingLoading || candidate.model == nil ||
                                  candidate.model != selectedModel)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func authenticationInstructions(_ challenge: BoltPairingChallenge) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm on the mouse").font(.headline)
            Text("Click the mouse buttons in this order:")
            Text(challenge.directions.enumerated().map { "\($0.offset + 1). \(directionTitle($0.element))" }.joined(separator: "\n"))
                .font(.body.monospaced())
                .textSelection(.disabled)
            Text("Then click \(directionTitle(challenge.confirmationDirection).lowercased()) to confirm.")
                .fixedSize(horizontal: false, vertical: true)
            if challenge.completedClicks > 0 {
                ProgressView(value: Double(challenge.completedClicks), total: Double(max(1, challenge.requiredClicks))) {
                    Text("\(challenge.completedClicks) of \(challenge.requiredClicks) clicks confirmed")
                }
            } else {
                ProgressView("Waiting for receiver confirmation…")
            }
        }
    }

    private func candidateTitle(_ candidate: BoltPairingCandidate) -> String {
        let scalars = (candidate.name ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let bounded = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)
        return bounded.isEmpty ? "Discovered mouse" : String(bounded)
    }

    private func directionTitle(_ direction: BoltPairingClickDirection) -> String {
        switch direction {
        case .left: "Left button"
        case .right: "Right button"
        case .both: "Both buttons together"
        }
    }
}
