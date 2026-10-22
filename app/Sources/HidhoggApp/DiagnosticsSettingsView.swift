import SwiftUI

struct DiagnosticsSettingsView: View {
    @EnvironmentObject private var diagnostics: DiagnosticsStore

    var body: some View {
        Section("Diagnostics") {
            LabeledContent("Process", value: String(ApplicationIdentity.current.processID))
            LabeledContent("Build", value: String(ApplicationIdentity.current.buildID.prefix(12)))
            Text(ApplicationIdentity.current.bundleURL.path)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)

            DisclosureGroup("Recent activity (up to 100 entries)") {
                ForEach(diagnostics.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date, style: .time)
                                .foregroundStyle(.secondary)
                            Text(entry.code.rawValue)
                                .fontDesign(.monospaced)
                                .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                        }
                        Text(entry.message)
                            .foregroundStyle(entry.isError ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("Details") {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("ID  \(entry.id.uuidString)")
                                Text("Build  \(entry.buildID)")
                                Text("Source  \(entry.source.description)")
                            }
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
            }

            Button("Clear Recent Activity") { diagnostics.clear() }
                .disabled(diagnostics.entries.isEmpty)

            Text("Persistent diagnostics are available in Console under com.hidhogg.app. macOS manages log retention. Shortcut contents are not logged.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }

    }
}
