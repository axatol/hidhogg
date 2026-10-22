import SwiftUI

struct DeviceInformationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let presentation = DeviceInformationPresentation(status: model.boltStatus)
        GroupBox("Device information") {
            let firmwareRows = presentation.firmwareRows
            let mainFirmwareRows = firmwareRows.filter(\.isPrimary)
            let additionalFirmwareRows = firmwareRows.filter { !$0.isPrimary }
            VStack(alignment: .leading, spacing: 12) {
                if presentation.isConnected, model.boltStatus.deviceInformation.firmwareState == .available {
                    if firmwareRows.isEmpty {
                        LabeledContent("MX Master 3S firmware", value: "No firmware components reported")
                    }
                    ForEach(mainFirmwareRows) { row in
                        firmwareRow(row)
                    }
                    if !additionalFirmwareRows.isEmpty {
                        DisclosureGroup("Additional version information") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(additionalFirmwareRows) { row in
                                    firmwareRow(row)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                } else {
                    LabeledContent("MX Master 3S firmware", value: presentation.firmwareStateText)
                }

                Button("Refresh Device Information", systemImage: "arrow.clockwise") {
                    model.refreshDeviceInformation()
                }
                .disabled(!model.canRefreshDeviceInformation)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func firmwareRow(_ row: DeviceInformationPresentation.FirmwareRow) -> some View {
        LabeledContent(row.label) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.value)
                    if row.isActive {
                        Text("Active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let caption = row.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
    }
}
