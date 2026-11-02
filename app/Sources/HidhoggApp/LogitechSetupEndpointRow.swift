import CryptoKit
import Foundation
import HidhoggDomain
import LogitechBolt
import SwiftUI

struct LogitechSetupEndpointRow: View {
    let candidate: LogitechEndpointCandidate
    let actionTitle: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image("DeviceMouse")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(AppAppearance.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.model.family.title)
                    .font(.headline)
                Text(candidate.connection == .bolt ? "Logi Bolt" : "Bluetooth")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Fingerprint \(selectionFingerprint(for: candidate.identity))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(actionTitle, action: action)
                .disabled(isDisabled)
        }
        .padding(.vertical, 5)
    }

    private func selectionFingerprint(for identity: LogitechIdentity) -> String {
        let data = Data("\(identity.unitID):\(identity.modelID)".utf8)
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
