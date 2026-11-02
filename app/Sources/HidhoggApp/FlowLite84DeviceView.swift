import SwiftUI
import LofreeFlowLite84
import HidhoggDomain

struct FlowLite84DeviceView: View {
    @ObservedObject var model: FlowLite84Model
    @State private var isDeviceInformationExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                deviceHeader
                deviceInformation
                keyboardAndSystemStatus
                lightingStatus
            }
            .padding(16)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Lofree Flow Lite84")
    }

    private var deviceHeader: some View {
        section("Lofree Flow Lite84") {
            VStack(alignment: .leading, spacing: 14) {
                deviceHeaderIdentity

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        LabeledContent("Connection", value: model.connectionTitle)
                            .fixedSize(horizontal: true, vertical: false)
                        LabeledContent("Battery", value: model.batteryText)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Connection", value: model.connectionTitle)
                        LabeledContent("Battery", value: model.batteryText)
                    }
                }

                connectionActions

                DeviceManagementControls(family: .flowLite84)

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Device error: \(errorMessage)")
                }
            }
        }
    }

    private var deviceHeaderIdentity: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 28))
                .foregroundStyle(AppAppearance.accent)
                .accessibilityHidden(true)

            Text("Receiver status and controls")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionActions: some View {
        Group {
            if model.isConnected {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        refreshButton
                        disconnectButton
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    VStack(alignment: .leading, spacing: 8) {
                        refreshButton
                        disconnectButton
                    }
                }
            } else if model.connectionTitle == "Connecting" || model.connectionTitle == "Disconnecting" {
                cancelConnectionButton
            } else {
                connectButton
            }
        }
    }

    private var refreshButton: some View {
        Button(model.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") {
            model.refresh()
        }
        .disabled(model.isBusy)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var disconnectButton: some View {
        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
            model.disconnect()
        }
        .disabled(model.connectionTitle == "Disconnecting")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var cancelConnectionButton: some View {
        Button(model.connectionTitle == "Connecting" ? "Cancel" : "Disconnect", systemImage: "xmark.circle") {
            model.disconnect()
        }
        .disabled(model.connectionTitle == "Disconnecting")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var connectButton: some View {
        Button("Connect", systemImage: "cable.connector") {
            model.connect()
        }
        .buttonStyle(.borderedProminent)
        .tint(AppAppearance.sidebarSelection)
        .disabled(model.isBusy)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var deviceInformation: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isDeviceInformationExpanded) {
                deviceInformationDetails
                    .padding(.top, 12)
            } label: {
                Label("Device information", systemImage: "info.circle")
            }
            .cardContentPadding()
        }
    }

    private var deviceInformationDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = model.snapshot {
                LabeledContent("Reported keyboard mode", value: systemModeText(snapshot.systemMode))
                LabeledContent("Voltage", value: voltageText(snapshot.battery?.voltageMillivolts))
                LabeledContent("Charging", value: chargingText(snapshot.battery?.charging))
                LabeledContent("Full status read", value: snapshot.readAt.formatted(date: .abbreviated, time: .shortened))
                if let batteryReadAt = snapshot.batteryReadAt {
                    LabeledContent("Battery received", value: batteryReadAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Keyboard firmware", value: snapshot.keyboardVersion ?? "Unavailable")
                LabeledContent("Receiver firmware", value: snapshot.receiverVersion ?? "Unavailable")

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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyboardAndSystemStatus: some View {
        section("Keyboard mode") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("Keyboard", value: keyboardStatus)

                systemModeChoices

                systemModeReadback

                Text("Changes are sent automatically after 200 ms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                systemModeActions
            }
        }
    }

    private var systemModeChoices: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                systemModeChoice(.windows, title: "Windows", systemImage: "pc")
                systemModeChoice(.mac, title: "Mac", systemImage: "apple.logo")
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 8) {
                systemModeChoice(.windows, title: "Windows", systemImage: "pc")
                systemModeChoice(.mac, title: "Mac", systemImage: "apple.logo")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard mode")
    }

    private func systemModeChoice(
        _ mode: FlowLite84SystemMode,
        title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        let isSelected = model.draftSystemMode == mode

        return Button {
            model.draftSystemMode = mode
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .accessibilityHidden(true)
                Label(title, systemImage: systemImage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? AppAppearance.sidebarSelection : nil)
        .disabled(!model.canEditSystemMode)
        .accessibilityLabel(Text(title))
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var systemModeReadback: some View {
        if let rawMode = model.snapshot?.systemMode,
           FlowLite84SystemMode(rawValue: rawMode) == nil {
            Label("Receiver reports \(systemModeText(rawMode)); it is not selectable here.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.snapshot?.systemMode == nil {
            Label("Receiver mode is unavailable.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var systemModeActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                retrySystemModeButton
                undoSystemModeButton
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 8) {
                retrySystemModeButton
                undoSystemModeButton
            }
        }
    }

    @ViewBuilder
    private var retrySystemModeButton: some View {
        if model.hasSystemModeWriteError {
            Button("Retry keyboard mode", systemImage: "arrow.clockwise") {
                model.retrySystemModeDraft()
            }
            .disabled(model.isBusy)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var undoSystemModeButton: some View {
        if model.snapshot?.canRestoreOriginalSystemMode == true {
            Button(model.isRestoringSystemMode ? "Undoing mode change…" : "Undo mode change", systemImage: "arrow.uturn.backward") {
                model.restoreOriginalSystemMode()
            }
            .disabled(!model.canRestoreOriginalSystemMode)
            .help("Restores the mode saved when it was first changed during this connection. This is not a step-by-step undo history.")
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var lightingStatus: some View {
        section("Lighting") {
            VStack(alignment: .leading, spacing: 14) {
                lightingReadbackExceptions
                lightingEditor
            }
        }
    }

    @ViewBuilder
    private var lightingReadbackExceptions: some View {
        if let lighting = model.snapshot?.lighting {
            VStack(alignment: .leading, spacing: 8) {
                if lighting.effect == nil {
                    LabeledContent("Effect readback", value: effectText(lighting))
                }
                if FlowLite84Lighting.displayedLevel(lighting.brightnessLevel) == nil {
                    LabeledContent("Brightness", value: brightnessText(lighting.brightnessLevel))
                }
                if FlowLite84Lighting.displayedLevel(lighting.speedLevel) == nil {
                    LabeledContent("Speed", value: brightnessText(lighting.speedLevel))
                }
                if lighting.idleOff == nil {
                    LabeledContent("Idle-off", value: idleOffText(lighting))
                }
            }
        } else {
            LabeledContent("Current readback", value: "Unavailable")
        }
    }

    private var lightingEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            lightingEffectChoices

            if model.draftLightingEnabled == nil {
                Label(model.lightingDraftEnabledPlaceholder, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            levelControl(
                title: "Brightness",
                selection: $model.draftLightingBrightnessLevel,
                placeholder: model.lightingDraftBrightnessPlaceholder
            )
            .disabled(!model.canEditLightingEffectDependentFields)

            levelControl(
                title: "Speed",
                selection: $model.draftLightingSpeedLevel,
                placeholder: model.lightingDraftSpeedPlaceholder
            )
            .disabled(!model.canEditLightingEffectDependentFields)

            Picker("Idle-off", selection: $model.draftLightingIdleOff) {
                if model.snapshot?.lighting?.idleOff == nil {
                    Text(model.lightingDraftIdleOffPlaceholder)
                        .tag(nil as FlowLite84LightingIdleOff?)
                }
                ForEach(FlowLite84LightingIdleOff.allCases, id: \.rawValue) { duration in
                    Text(duration.title).tag(Optional(duration))
                }
            }

            lightingActions

            Text("Changes are sent automatically after 200 ms.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.snapshot?.canRestoreOriginalLighting == true {
                Text("Undo restores lighting saved at its first change during this connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .disabled(!model.canEditLighting)
    }

    private var lightingEffectChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Effect")
                .font(.headline)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(FlowLite84LightingEffect.allCases, id: \.rawValue) { effect in
                    lightingChoice(
                        title: effect.title,
                        systemImage: effectSymbol(effect),
                        isSelected: model.draftLightingEnabled != false && model.draftLightingEffect == effect
                    ) {
                        model.draftLightingEffect = effect
                        model.draftLightingEnabled = true
                    }
                }

                lightingChoice(
                    title: "Off",
                    systemImage: "lightbulb.slash",
                    isSelected: model.draftLightingEnabled == false
                ) {
                    model.draftLightingEnabled = false
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Lighting effect")
        }
    }

    private func lightingChoice(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 2)
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? AppAppearance.sidebarSelection : nil)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var lightingActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                lightingApplyStatus
                retryLightingButton
                undoLightingButton
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 8) {
                lightingApplyStatus
                retryLightingButton
                undoLightingButton
            }
        }
    }

    @ViewBuilder
    private var lightingApplyStatus: some View {
        if model.isApplyingLighting {
            Label("Applying lighting changes…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var retryLightingButton: some View {
        if model.hasLightingWriteError {
            Button("Retry lighting update", systemImage: "arrow.clockwise") {
                model.retryLightingDraft()
            }
            .disabled(model.isBusy)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var undoLightingButton: some View {
        if model.snapshot?.canRestoreOriginalLighting == true {
            Button(model.isRestoringLighting ? "Undoing lighting changes…" : "Undo lighting changes", systemImage: "arrow.uturn.backward") {
                model.restorePreviousLighting()
            }
            .disabled(!model.canRestorePreviousLighting)
            .help("Restores lighting saved at its first change during this connection. This is not a step-by-step undo history.")
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func levelControl(title: String, selection: Binding<UInt8?>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let level = selection.wrappedValue {
                HStack {
                    Text(title)
                    Spacer()
                    Text("Level \(level)")
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(selection.wrappedValue ?? level) },
                        set: { selection.wrappedValue = UInt8($0.rounded()) }
                    ),
                    in: 1...5,
                    step: 1
                )
                .accessibilityLabel(title)
                .accessibilityValue("Level \(level)")
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Set \(title.lowercased()) level", selection: selection) {
                    Text("Choose a level").tag(nil as UInt8?)
                    ForEach(1...5, id: \.self) { level in
                        Text("Level \(level)").tag(Optional(UInt8(level)))
                    }
                }
                .pickerStyle(.menu)
            }
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
        case 0: "Windows"
        case 1: "Mac"
        case 2: "Android"
        case 3: "iOS"
        default: "Unknown (reported \(mode))"
        }
    }

    private func effectText(_ lighting: FlowLite84Lighting) -> String {
        lighting.effect?.title ?? "Unknown (reported mode \(lighting.mode))"
    }

    private func effectSymbol(_ effect: FlowLite84LightingEffect) -> String {
        switch effect {
        case .trailing: "arrow.right"
        case .breathing: "wind"
        case .wave: "water.waves"
        case .reactive: "bolt.fill"
        case .ripple: "circle.circle"
        case .snake: "point.topleft.down.to.point.bottomright.curvepath"
        case .steady: "sun.max"
        }
    }

    private func brightnessText(_ level: UInt8?) -> String {
        guard let level else { return "Unavailable" }
        guard let displayedLevel = FlowLite84Lighting.displayedLevel(level) else {
            return "Unknown (reported \(level))"
        }
        return "Level \(displayedLevel)"
    }

    private func idleOffText(_ lighting: FlowLite84Lighting) -> String {
        if let idleOff = lighting.idleOff { return idleOff.title }
        if lighting.idleOffUnits == 0 { return "Default / unknown (reported 0 units)" }
        return "Unknown (reported \(lighting.idleOffUnits) units)"
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

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox(title) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardContentPadding()
        }
    }
}
