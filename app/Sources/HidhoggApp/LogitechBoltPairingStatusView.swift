import HidhoggDomain
import LogitechBolt
import SwiftUI

struct LogitechBoltPairingStatusView: View {
    let status: BoltPairingStatus
    let expectedModel: LogitechMouseModel?
    let onSelectCandidate: (UUID) -> Void
    let showsCandidates: Bool

    init(status: BoltPairingStatus,
         expectedModel: LogitechMouseModel?,
         onSelectCandidate: @escaping (UUID) -> Void,
         showsCandidates: Bool = true) {
        self.status = status
        self.expectedModel = expectedModel
        self.onSelectCandidate = onSelectCandidate
        self.showsCandidates = showsCandidates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if status.phase == .discovering {
                ProgressView(status.message)
                Text("Select a free Easy-Switch channel on the mouse, then hold its button until the channel light blinks quickly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.phase == .failed || status.phase == .pairedButNotAdded {
                Label(status.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(status.message)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsCandidates && status.phase == .awaitingSelection {
                ForEach(status.candidates) { candidate in
                    let matchesExpectedModel = expectedModel == nil || candidate.model == expectedModel
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.model?.family.title ?? "Unsupported device")
                                .font(.headline)
                            if candidate.model == nil {
                                Text("This device cannot be added as a supported mouse.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else if !matchesExpectedModel {
                                Text("This mouse does not match the registered model.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Pair", systemImage: "checkmark.circle") {
                            onSelectCandidate(candidate.id)
                        }
                        .disabled(candidate.model == nil || !matchesExpectedModel)
                    }
                }
            }

            if let challenge = status.challenge {
                BoltPairingChallengeView(challenge: challenge)
            }

            BoltDiscoveryDiagnosticsView(diagnostics: status.discoveryDiagnostics,
                                         nativeDiagnostics: status.nativeInputDiagnostics,
                                         notificationSetupMessage: status.notificationSetupMessage,
                                         notificationCleanupMessage: status.notificationCleanupMessage)
        }
    }
}
