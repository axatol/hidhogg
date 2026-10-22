import SwiftUI
import HidhoggDomain

struct ControlBindingInspector: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShortcutEditorPresented = false
    @State private var manualEditorCaptureSessionID: UUID?
    @State private var manualEditorApplicationID: String?
    @State private var manualEditorPresentationID = UUID()

    let control: MouseControl

    private var availableModes: [BindingEditorMode] {
        model.selectedApplicationID == nil ? [.disabled, .shortcut] : BindingEditorMode.allCases
    }

    private var captureTarget: ShortcutRecordingTarget {
        ShortcutRecordingTarget(control: control, applicationID: model.selectedApplicationID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(control.title) button")
                        .font(.title3.weight(.semibold))
                    Text(model.selectedApplicationID ?? "All apps")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Assignment", selection: Binding(
                        get: { model.bindingMode(for: control) },
                        set: { model.setBindingMode($0, for: control) }
                    )) {
                        ForEach(availableModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .disabled(!model.canEditConfiguration)

                    Text(model.bindingDescription(for: control))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.selectedApplicationID != nil,
                       model.bindingMode(for: control) == .inherit {
                        Button("Override", systemImage: "pencil") {
                            model.setBindingMode(.shortcut, for: control)
                        }
                        .disabled(!model.canEditConfiguration)
                    }
                }

                if model.bindingMode(for: control) == .shortcut {
                    shortcutControls
                }

                Divider()

                Text("While Hidhogg is handling the buttons, Disabled also suppresses the mouse’s original Back or Forward action. Native behavior resumes when the button session is off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Navigation presets use Command+[ and Command+] at ANSI physical key positions. Labels follow the active keyboard layout, and applications may ignore or override these shortcuts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("\(control.title) button")
        .sheet(isPresented: $isShortcutEditorPresented, onDismiss: finishManualEditor) {
            if let sessionID = manualEditorCaptureSessionID {
                ShortcutEditorView(
                    initialShortcut: model.document.draft.mouse?.binding(
                        for: control,
                        application: manualEditorApplicationID
                    ).shortcut,
                    onCancel: { isShortcutEditorPresented = false },
                    onCommit: { shortcut in
                        model.completeRecording(shortcut, sessionID: sessionID)
                        isShortcutEditorPresented = false
                    }
                )
                .id(manualEditorPresentationID)
            }
        }
        .onChange(of: model.captureSessionID) { _, sessionID in
            guard isShortcutEditorPresented,
                  sessionID != manualEditorCaptureSessionID else { return }
            isShortcutEditorPresented = false
        }
    }

    @ViewBuilder
    private var shortcutControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                if let sessionID = model.captureSessionID,
                   model.recordingTarget == captureTarget,
                   !isShortcutEditorPresented {
                    ShortcutCaptureView(
                        onCapture: { shortcut in
                            model.completeRecording(shortcut, sessionID: sessionID)
                        },
                        onCancel: {
                            model.cancelRecording(sessionID: sessionID)
                        }
                    )
                    .frame(minWidth: 180, maxWidth: .infinity, minHeight: 34)
                    .id(sessionID)

                    Button("Cancel", systemImage: "xmark.circle") {
                        model.cancelRecording(sessionID: sessionID)
                    }
                } else {
                    Button("Record Shortcut", systemImage: "record.circle") {
                        model.beginRecording(for: control, applicationID: model.selectedApplicationID)
                    }
                    .disabled(!model.canEditConfiguration)
                }
            }

            HStack(spacing: 10) {
                Menu("Preset", systemImage: "keyboard") {
                    ForEach(NavigationPreset.allCases) { preset in
                        Button(preset.title) {
                            model.applyNavigationPreset(preset)
                        }
                    }
                }
                .disabled(!model.canEditConfiguration)

                Button("Choose Manually…", systemImage: "keyboard") {
                    guard manualEditorCaptureSessionID == nil else { return }
                    manualEditorApplicationID = model.selectedApplicationID
                    model.beginRecording(for: control, applicationID: manualEditorApplicationID)
                    guard let sessionID = model.captureSessionID else { return }
                    manualEditorCaptureSessionID = sessionID
                    manualEditorPresentationID = UUID()
                    isShortcutEditorPresented = true
                }
                .disabled(!model.canEditConfiguration || manualEditorCaptureSessionID != nil)
                .accessibilityHint("Choose a key and modifiers without pressing the shortcut")
            }
        }
    }

    private func finishManualEditor() {
        if let sessionID = manualEditorCaptureSessionID {
            model.cancelRecording(sessionID: sessionID)
        }
        manualEditorCaptureSessionID = nil
        manualEditorApplicationID = nil
    }
}
