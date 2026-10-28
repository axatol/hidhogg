import SwiftUI

struct FlowLite84DeviceView: View {
    @ObservedObject var model: FlowLite84Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                deviceHeader
                keyboardAndSystemStatus
                lightingStatus
                versions
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
        .navigationTitle("Lofree Flow Lite84")
    }

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 28))
                    .foregroundStyle(AppAppearance.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Lofree Flow Lite84")
                        .font(.title2.weight(.semibold))
                    Text("Read-only receiver status")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
                connectionActions
            }

            LabeledContent("Connection", value: model.connectionTitle)
            LabeledContent("Battery", value: model.batteryText)

            if let snapshot = model.snapshot {
                LabeledContent(
                    "Full status read",
                    value: snapshot.readAt.formatted(date: .abbreviated, time: .shortened)
                )
                if let batteryReadAt = snapshot.batteryReadAt {
                    LabeledContent(
                        "Battery received",
                        value: batteryReadAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                LabeledContent("Voltage", value: voltageText(snapshot.battery?.voltageMillivolts))
                LabeledContent("Charging", value: chargingText(snapshot.battery?.charging))

                if !model.isConnected {
                    Label("Showing the last snapshot; the receiver is disconnected.", systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            } else {
                Text("No receiver snapshot has been read.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var connectionActions: some View {
        if model.isConnected {
            HStack(spacing: 8) {
                Button(model.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") {
                    model.refresh()
                }
                .disabled(model.isBusy)

                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                    model.disconnect()
                }
                .disabled(model.connectionTitle == "Disconnecting")
            }
        } else if model.connectionTitle == "Connecting" || model.connectionTitle == "Disconnecting" {
            Button(model.connectionTitle == "Connecting" ? "Cancel" : "Disconnect", systemImage: "xmark.circle") {
                model.disconnect()
            }
            .disabled(model.connectionTitle == "Disconnecting")
        } else {
            Button("Connect", systemImage: "cable.connector") {
                model.connect()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppAppearance.sidebarSelection)
            .disabled(model.isBusy)
        }
    }

    private var keyboardAndSystemStatus: some View {
        GroupBox("Keyboard and system") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Keyboard", value: keyboardStatus)
                LabeledContent("Reported system selector", value: systemModeText(model.snapshot?.systemMode))
                Text("This is the selector reported by the receiver; physical OS behavior has not been verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var lightingStatus: some View {
        GroupBox("Lighting status") {
            VStack(alignment: .leading, spacing: 10) {
                if let lighting = model.snapshot?.lighting {
                    LabeledContent("Mode", value: "Mode \(lighting.mode)")
                    LabeledContent("Backlight", value: lighting.enabled ? "Enabled" : "Disabled")
                    LabeledContent("Brightness", value: brightnessText(lighting.brightnessLevel))
                    LabeledContent("Speed", value: rawLevelText(lighting.speedLevel))
                    LabeledContent("Idle-off value", value: "Reported units \(lighting.idleOffUnits)")
                    Text("Mode IDs and levels are reported labels; the physical effect and level mapping are unverified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Lighting status unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var versions: some View {
        GroupBox("Versions") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Keyboard", value: model.snapshot?.keyboardVersion ?? "Unavailable")
                LabeledContent("Receiver", value: model.snapshot?.receiverVersion ?? "Unavailable")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var keyboardStatus: String {
        guard let snapshot = model.snapshot else { return "Unavailable" }
        if !model.isConnected { return snapshot.online ? "Last reported online" : "Last reported offline" }
        if model.isKeyboardOnline { return "Online" }
        return "Offline"
    }

    private func systemModeText(_ mode: UInt8?) -> String {
        guard let mode else { return "Unavailable" }
        return switch mode {
        case 0: "Win"
        case 1: "Mac"
        case 2: "Android"
        case 3: "iOS"
        default: "Unknown (reported \(mode))"
        }
    }

    private func brightnessText(_ level: UInt8?) -> String {
        guard let level else { return "Unavailable" }
        guard level <= 4 else { return "Unknown (reported \(level))" }
        return "Level \(Int(level) + 1) (reported \(level))"
    }

    private func rawLevelText(_ level: UInt8?) -> String {
        level.map { "Reported \($0)" } ?? "Unavailable"
    }

    private func voltageText(_ voltage: UInt16?) -> String {
        voltage.map { "\($0) mV" } ?? "Unavailable"
    }

    private func chargingText(_ charging: Bool?) -> String {
        switch charging {
        case .some(true): "Charging"
        case .some(false): "Not charging"
        case .none: "Unavailable"
        }
    }
}
