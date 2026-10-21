import Darwin
import Foundation
import MacOSActions

@MainActor
enum PermissionProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--permission-diagnostics") else { return }
        let sender = ShortcutSender()
        _ = sender.refreshPermission()
        let identity = ApplicationIdentity.current
        let report: [String: Any] = [
            "processID": identity.processID,
            "buildID": String(identity.buildID.prefix(12)),
            "accessibilityTrusted": sender.permissionChecks.accessibilityTrusted,
            "eventPostingAllowed": sender.permissionChecks.eventPostingAllowed
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Permission diagnostics could not be encoded.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
