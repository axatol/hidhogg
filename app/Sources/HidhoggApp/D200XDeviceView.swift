import SwiftUI
import HidhoggDomain

struct D200XDeviceView: View {
    @ObservedObject var model: D200XModel
    @Binding private var isInspectorPresented: Bool

    init(model: D200XModel, isInspectorPresented: Binding<Bool> = .constant(true)) {
        self._model = ObservedObject(wrappedValue: model)
        self._isInspectorPresented = isInspectorPresented
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                deviceHeader

                D200XApplicationSelectorView(model: model)
                deckCanvas
                deviceSettings

                if let firmware = model.firmware {
                    GroupBox("Firmware") {
                        LabeledContent("Version", value: firmware)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
        .navigationTitle("Ulanzi D200X")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(
                        isInspectorPresented ? "Hide Control Settings" : "Show Control Settings",
                        systemImage: "slider.horizontal.3"
                    )
                }
                .help(isInspectorPresented ? "Hide control settings" : "Show control settings")
            }
        }
    }

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image("DeviceDeck")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(AppAppearance.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ulanzi D200X")
                        .font(.title2.weight(.semibold))

                    Text(model.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                connectionAction
            }

            DeviceManagementControls(family: .d200x)

            HStack(spacing: 6) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.connectionTitle)
            }
            .font(.callout)

            if let configurationBlocker = model.configurationBlocker {
                Label(configurationBlocker, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.canEdit {
                Label("D200X configuration cannot be edited right now.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.isConfigured {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(
                        "Create a local configuration to edit this deck. You can save changes while disconnected.",
                        systemImage: "externaldrive"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button("Set Up Deck Configuration", systemImage: "plus.square") {
                        model.enableConfiguration()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canEdit)
                }
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastActionMessage = model.lastActionMessage {
                Text(lastActionMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var connectionAction: some View {
        if model.isConnected || model.isBusy {
            let actionTitle = model.connectionTitle == "Connecting" ? "Cancel" : "Disconnect"
            Button(actionTitle, systemImage: "xmark.circle") {
                model.disconnect()
            }
            .buttonStyle(.bordered)
            .disabled(model.connectionTitle == "Disconnecting")
        } else {
            Button("Connect", systemImage: "cable.connector") {
                model.connect()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppAppearance.sidebarSelection)
            .disabled(!model.canEdit || model.isBusy)
        }
    }

    private var deckCanvas: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Control deck")
                    .font(.headline)

                Text("Select a key, front button or dial to open its settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            D200XDeckView(model: model) {
                isInspectorPresented = true
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var deviceSettings: some View {
        GroupBox("Device settings") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Brightness")
                    .font(.headline)

                Toggle("Set brightness preference", isOn: Binding(
                    get: { model.configuration?.brightnessPercent != nil },
                    set: { enabled in
                        model.setBrightnessPercent(
                            enabled ? (model.configuration?.brightnessPercent ?? 100) : nil
                        )
                    }
                ))
                .disabled(!canEditBrightness)

                HStack {
                    Text("Level")
                    Spacer()
                    Text(brightnessValueDescription)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(
                    value: Binding(
                        get: { Double(model.configuration?.brightnessPercent ?? 100) },
                        set: { model.setBrightnessPercent(Int($0.rounded())) }
                    ),
                    in: 1...100,
                    step: 1
                )
                .disabled(!canEditBrightness || model.configuration?.brightnessPercent == nil)
                .accessibilityLabel("D200X brightness preference")

                Divider().padding(.vertical, 6)
                Text("Wide display").font(.headline)
                Picker("Display", selection: Binding(
                    get: { model.configuration?.wideDisplayMode ?? .custom },
                    set: { model.setWideDisplayMode($0) }
                )) {
                    ForEach(D200XWideDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!canEditBrightness)
                Picker("Clock format", selection: Binding(
                    get: { model.configuration?.clockFormat ?? .twentyFourHour },
                    set: { model.setClockFormat($0) }
                )) {
                    Text("24 hour").tag(D200XClockFormat.twentyFourHour)
                    Text("12 hour").tag(D200XClockFormat.twelveHour)
                }
                .disabled(!canEditBrightness)
                Text("Applies to the device across application profiles. Notifications temporarily show the custom wide tile. CPU uses host tick deltas; RAM is active, wired and compressed memory. GPU availability depends on the host.")
                    .font(.caption).foregroundStyle(.secondary)
                if let displayMessage = model.wideDisplayMessage {
                    Text(displayMessage).font(.callout).foregroundStyle(.secondary)
                }
                if model.configuration?.wideDisplayMode == .systemStatus {
                    HStack {
                        Text(metricDescription("CPU", model.displayMetrics.cpu))
                        Text(metricDescription("RAM", model.displayMetrics.memory))
                        Text(metricDescription("GPU", model.displayMetrics.gpu))
                    }
                    .font(.caption).monospacedDigit()
                }
                Divider().padding(.vertical, 6)
                D200XScreensaverEditorView(model: model)
                    .disabled(!canEditBrightness)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var canEditBrightness: Bool {
        model.canEdit && model.isConfigured
    }

    private func metricDescription(_ label: String, _ value: Double?) -> String {
        value.map { "\(label) \(Int($0.rounded()))%" } ?? "\(label) unavailable"
    }

    private var brightnessValueDescription: String {
        guard let brightnessPercent = model.configuration?.brightnessPercent else { return "Device default" }
        return "\(brightnessPercent)%"
    }
}
