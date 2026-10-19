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
                    } else if model.boltStatus.phase == .enabled || model.boltStatus.phase == .stopping {
                        Button("Stop", systemImage: "stop.fill", role: .destructive) { model.disconnect() }
                            .disabled(model.boltStatus.phase == .stopping)
                    } else {
                        Button(model.boltStatus.phase == .ready ? "Reconnect" : "Connect", systemImage: "cable.connector") {
                            model.connect()
                        }
                        .disabled(!model.canDiscover)
                    }
                }

                if model.boltStatus.phase == .ready {
                    Button("Enable Back and Forward", systemImage: "arrow.left.arrow.right") {
                        model.requestEnableConfirmation()
                    }
                    .disabled(!model.canEnableBindings)
                }

                if model.boltStatus.cleanupUncertain {
                    Label("Cleanup is unverified. Hidhogg will not reconnect automatically.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Configuration") {
                LabeledContent("Saved state", value: model.configurationStatus)
                Text("Changes apply after saving. Enabling bindings suppresses the mouse’s native Back and Forward behavior.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save", systemImage: "square.and.arrow.down") { Task { await model.save() } }
                        .disabled(!model.canSaveConfiguration)
                    Button("Reload", systemImage: "arrow.clockwise") { model.requestReload() }
                        .disabled(model.isLoading || model.isSaving)
                }
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
                                .background(
                                    isSelected ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(
                                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
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
                Text("Shortcuts use physical macOS key codes and current keyboard-layout labels. Recording stops the active binding session. Save changes, then reconnect and enable bindings explicitly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices")
        .disabled(model.isLoading || model.isSaving)
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
        .confirmationDialog(
            "Enable Back and Forward bindings?",
            isPresented: $model.isEnableConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Enable Bindings", role: .destructive) { model.confirmEnableBindings() }
            Button("Cancel", role: .cancel) { model.isEnableConfirmationPresented = false }
        } message: {
            Text("Confirm that this is the intended mouse and that competing mouse software is closed. Enabling diverts both buttons and suppresses their native behavior until you stop the session.")
        }
    }
}

private struct ControlBindingRow: View {
    @EnvironmentObject private var model: AppModel
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
                if model.bindingMode(for: control) == .shortcut {
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
        }
        .padding(.vertical, 3)
    }
}
