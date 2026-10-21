import SwiftUI
import HidhoggDomain
import UniformTypeIdentifiers

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isApplicationPickerPresented = false

    var body: some View {
        Form {
            Section("Device") {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color(nsColor: model.connectionColor))
                        .frame(width: 9, height: 9)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.connectionTitle)
                            .font(.headline)
                        Text(model.boltStatus.message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.boltStatus.phase == .discovering || model.boltStatus.phase == .enabling {
                        Button("Cancel", systemImage: "xmark.circle") { model.disconnect() }
                    } else if [.ready, .enabled, .stopping].contains(model.boltStatus.phase) {
                        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                            model.disconnect()
                        }
                        .disabled(model.boltStatus.phase == .stopping)
                    } else {
                        Button("Connect", systemImage: "cable.connector") {
                            model.connect()
                        }
                        .disabled(!model.canDiscover)
                    }
                }

                if model.boltStatus.cleanupUncertain {
                    Label("Cleanup is unverified. Hidhogg will not reconnect automatically.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if model.permission != .granted {
                Section("Input Permission") {
                    Label("Input posting permission is required for shortcuts and custom scroll amount.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Open Settings", systemImage: "gearshape") {
                        model.navigate(to: .settings)
                    }
                }
            }

            Section("Scroll") {
                Picker("Direction", selection: Binding(
                    get: { model.wheelPreferenceDraft },
                    set: { model.setWheelPreference($0) }
                )) {
                    Text("Leave unchanged").tag(Optional<Bool>.none)
                    Text("Standard").tag(Optional<Bool>.some(false))
                    Text("Natural").tag(Optional<Bool>.some(true))
                }

                LabeledContent("Observed device direction", value: model.observedWheelDirection)
                if model.boltStatus.wheel.captureActive {
                    LabeledContent("Effective direction", value: model.effectiveWheelDirection)
                }

                Picker("Input resolution", selection: Binding(
                    get: { model.wheelHighResolutionDraft },
                    set: { model.setWheelHighResolution($0) }
                )) {
                    Text("Leave unchanged").tag(Optional<Bool>.none)
                    Text("Low").tag(Optional<Bool>.some(false))
                    Text("High").tag(Optional<Bool>.some(true))
                }

                LabeledContent("Observed resolution", value: model.observedWheelResolution)
                LabeledContent("Hidhogg change", value: model.wheelSessionChange)

                Toggle("Custom scroll amount", isOn: Binding(
                    get: { model.wheelScrollAmountDraft != nil },
                    set: { model.setWheelScrollAmount($0 ? WheelScrollAmount.defaultSelection : nil) }
                ))
                if let amount = model.wheelScrollAmountDraft {
                    Slider(value: Binding(
                        get: { model.wheelScrollAmountDraft ?? WheelScrollAmount.defaultSelection },
                        set: { model.setWheelScrollAmount($0) }
                    ), in: WheelScrollAmount.range, step: 0.25)
                    LabeledContent("Vertical amount", value: String(format: "%.2f×", amount))
                }
                LabeledContent("Scroll amount state", value: model.scrollAmountStatus)
                Text("Custom amount captures this mouse’s wheel and posts fixed line events. Amount scales vertical movement; application handling and physical direction still need comparison. Temporary capture is always released on disconnect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Restore previous device settings on disconnect", isOn: Binding(
                    get: { model.restorePreviousSettingsOnDisconnect },
                    set: { model.setRestorePreviousSettingsOnDisconnect($0) }
                ))

                if let message = model.boltStatus.wheel.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(model.boltStatus.cleanupUncertain ? .orange : .secondary)
                }

                Text("Changes apply while connected and are saved automatically. The device keeps its scroll settings after disconnecting unless restoration is enabled. Temporary input interception is always released.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Input resolution controls device reporting granularity. Low resolution does not guarantee whole-line movement or disable animation in applications.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Leave unchanged keeps the current value, or restores the previous value when restoration is enabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Thumb wheel") {
                Picker("Direction", selection: Binding(
                    get: { model.thumbwheelPreferenceDraft },
                    set: { model.setThumbwheelPreference($0) }
                )) {
                    Text("Leave unchanged").tag(Optional<Bool>.none)
                    Text("Standard").tag(Optional<Bool>.some(false))
                    Text("Natural").tag(Optional<Bool>.some(true))
                }

                LabeledContent("Observed direction", value: model.observedThumbwheelDirection)
                LabeledContent("Effective direction", value: model.effectiveThumbwheelDirection)
                LabeledContent("Hidhogg change", value: model.thumbwheelSessionChange)

                Toggle("Custom thumb-wheel amount", isOn: Binding(
                    get: { model.thumbwheelScrollAmountDraft != nil },
                    set: { model.setThumbwheelScrollAmount($0 ? WheelScrollAmount.defaultSelection : nil) }
                ))
                if let amount = model.thumbwheelScrollAmountDraft {
                    Slider(value: Binding(
                        get: { model.thumbwheelScrollAmountDraft ?? WheelScrollAmount.defaultSelection },
                        set: { model.setThumbwheelScrollAmount($0) }
                    ), in: WheelScrollAmount.range, step: 0.25)
                    LabeledContent("Thumb-wheel amount", value: String(format: "%.2f×", amount))
                }
                LabeledContent("Thumb-wheel amount state", value: model.thumbwheelScrollAmountStatus)
                if let message = model.boltStatus.thumbwheel.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(model.boltStatus.cleanupUncertain ? .orange : .secondary)
                }
                Text("The thumb wheel has its own Standard or Natural direction and fixed line amount. At 1×, each reported rotation count posts one line; applications decide how far that line moves. Changes apply while connected and save automatically; physical settings remain in place after disconnect unless the restore option above is enabled. Temporary input interception is always released.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Configuration") {
                LabeledContent("Saved state", value: model.configurationStatus)
                if let error = model.configurationSaveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry Saving", systemImage: "arrow.clockwise") {
                        Task { await model.flushPendingSave() }
                    }
                    .disabled(model.isSaving || model.configurationLoadFailed)
                }
                Text("Changes apply immediately and save one second after your last edit. Connect to apply settings saved while disconnected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Reload from File…", systemImage: "arrow.clockwise") { model.requestReload() }
                    .disabled(!model.canReloadConfiguration)
                if let lastActionMessage = model.lastActionMessage {
                    Text(lastActionMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Application") {
                HStack {
                    Picker("App context", selection: Binding(
                        get: { model.selectedApplicationID },
                        set: { model.selectApplication($0) }
                    )) {
                        Text("All apps").tag(String?.none)
                        ForEach(model.applicationIDs, id: \.self) { applicationID in
                            Text(applicationID).tag(Optional(applicationID))
                        }
                    }
                    .disabled(model.isLoading)

                    Button("Add App…", systemImage: "plus") { isApplicationPickerPresented = true }
                        .disabled(model.isLoading)

                    if model.selectedApplicationID != nil {
                        Button("Remove", systemImage: "minus", role: .destructive) {
                            model.removeSelectedApplication()
                        }
                    }
                }
            }

            Section("Control") {
                HStack(spacing: 10) {
                    ForEach(MouseControl.allCases, id: \.self) { control in
                        let isSelected = model.selectedControl == control
                        Button {
                            model.selectControl(control)
                        } label: {
                            Label(control.title, systemImage: control == .back ? "arrow.left" : "arrow.right")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                                .background(
                                    isSelected ? AppAppearance.accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(
                                            isSelected ? AppAppearance.accent : Color(nsColor: .separatorColor),
                                            lineWidth: isSelected ? 2 : 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }

            Section("\(model.selectedControl.title) binding") {
                ControlBindingRow(control: model.selectedControl)
                Text("Shortcuts use physical macOS key codes and current keyboard-layout labels. Recording pauses shortcut delivery. Configured shortcuts apply immediately; active bindings suppress native Back and Forward behavior.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Navigation presets use Command+[ and Command+] at ANSI physical key positions. Labels depend on the active keyboard layout, and applications may override or ignore these shortcuts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
        .disabled(model.isLoading)
        .fileImporter(
            isPresented: $isApplicationPickerPresented,
            allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.addApplication(at: url) }
            case .failure(let error):
                model.reportError(error.localizedDescription)
            }
        }
    }
}

private struct ControlBindingRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShortcutEditorPresented = false
    @State private var shortcutEditorSessionID = UUID()
    let control: MouseControl

    private var availableModes: [BindingEditorMode] {
        model.selectedApplicationID == nil ? [.disabled, .shortcut] : BindingEditorMode.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(control.title, selection: Binding(
                get: { model.bindingMode(for: control) },
                set: { model.setBindingMode($0, for: control) }
            )) {
                ForEach(availableModes) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            HStack(spacing: 10) {
                Text(model.bindingDescription(for: control))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Preset", systemImage: "keyboard") {
                    ForEach(NavigationPreset.allCases) { preset in
                        Button(preset.title) {
                            model.applyNavigationPreset(preset)
                        }
                    }
                }
                if model.bindingMode(for: control) == .shortcut, !isShortcutEditorPresented {
                    if model.recordingTarget == ShortcutRecordingTarget(
                        control: control,
                        applicationID: model.selectedApplicationID
                    ) {
                        ShortcutCaptureView(
                            onCapture: { model.completeRecording($0) },
                            onCancel: { model.cancelRecording() }
                        )
                        .frame(width: 252, height: 32)
                        Button("Cancel") { model.cancelRecording() }
                    } else {
                        Button("Record Shortcut", systemImage: "record.circle") {
                            model.beginRecording(for: control, applicationID: model.selectedApplicationID)
                        }
                    }
                }
            }

            Button("Choose Manually…", systemImage: "keyboard") {
                shortcutEditorSessionID = UUID()
                model.beginRecording(for: control, applicationID: model.selectedApplicationID)
                isShortcutEditorPresented = true
            }
            .accessibilityHint("Choose a key and modifiers without pressing the shortcut")
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $isShortcutEditorPresented, onDismiss: { model.cancelRecording() }) {
            ShortcutEditorView(
                initialShortcut: model.document.draft.mouse?.binding(
                    for: control,
                    application: model.selectedApplicationID
                ).shortcut,
                onCancel: { isShortcutEditorPresented = false },
                onCommit: {
                    model.completeRecording($0)
                    isShortcutEditorPresented = false
                }
            )
            .id(shortcutEditorSessionID)
        }
    }
}
