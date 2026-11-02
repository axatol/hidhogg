import LogitechBolt
import SwiftUI

struct BoltDiscoveryDiagnosticsView: View {
    let diagnostics: BoltDiscoveryDiagnostics
    let nativeDiagnostics: BoltNativeInputDiagnostics
    let notificationSetupMessage: String?
    let notificationCleanupMessage: String?

    var body: some View {
        DisclosureGroup("Discovery details") {
            VStack(alignment: .leading, spacing: 6) {
                if let notificationSetupMessage {
                    Text(notificationSetupMessage)
                        .foregroundStyle(.secondary)
                }
                if let notificationCleanupMessage {
                    Text(notificationCleanupMessage)
                        .foregroundStyle(.secondary)
                }
                Text("Advertisement events: \(diagnostics.advertisementEvents)")
                Text("Decoded: \(diagnostics.decodedAdvertisements) · Rejected: \(diagnostics.rejectedAdvertisements) · Unsupported model: \(diagnostics.unsupportedModelAdvertisements)")
                Text("Discovery status events: \(diagnostics.discoveryStatusEvents) · Recovery events: \(diagnostics.recoveryEvents) · Transport failures: \(diagnostics.transportFailures)")
                Divider()
                if nativeDiagnostics.available {
                    Text("Native callbacks: \(nativeDiagnostics.callbacks) · Callback errors: \(nativeDiagnostics.callbackErrors)")
                    Text("Metadata rejected: \(nativeDiagnostics.metadataRejected) · Report ID mismatches: \(nativeDiagnostics.reportIDMismatch)")
                    Text("Register replies: \(nativeDiagnostics.registerReplies) · Feature replies: \(nativeDiagnostics.featureReplies)")
                    Text("Receiver notifications: \(nativeDiagnostics.receiverNotifications) · Unmatched reports: \(nativeDiagnostics.unmatchedReports)")
                } else {
                    Text("Native callback counts unavailable.")
                        .foregroundStyle(.secondary)
                }
                Text("Typed counts cover events forwarded to pairing. Native counts cover this session's callback and filter boundary. No device identifiers or message contents are included.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .monospacedDigit()
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
    }
}
