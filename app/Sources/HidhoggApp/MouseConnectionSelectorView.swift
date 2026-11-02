import CryptoKit
import Foundation
import HidhoggDomain
import SwiftUI

struct MouseConnectionSelectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Associate an existing mouse")
                .font(.title2.weight(.semibold))
            Text("Choose an already-paired mouse for \(model.selectedMouseName). Its Hidhogg settings are retained. Only one Logitech mouse can be managed at a time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("IDs are stable Hidhogg selection fingerprints, not physical receiver slots.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.isMouseSelectorLoading {
                        ProgressView("Checking existing connections…")
                    }

                    ForEach(model.mouseConnectionChoices) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.model.family.title)
                                    .font(.headline)
                                Text("ID \(selectionFingerprint(for: candidate.identity))")
                                    .font(.system(.callout, design: .monospaced))
                                Text(candidate.connection == .bolt ? "Logi Bolt" : "Direct Bluetooth")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Associate and Connect") { model.associateMouse(candidateID: candidate.id) }
                                .disabled(model.isMouseSelectorLoading)
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let message = model.mouseSelectorMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { model.presentMouseSelector() }
                    .disabled(model.isMouseSelectorLoading)
                Spacer()
                Button("Close", role: .cancel) { model.dismissMouseSelector() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 520)
    }

    private func selectionFingerprint(for identity: LogitechIdentity) -> String {
        let data = Data("\(identity.unitID):\(identity.modelID)".utf8)
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
