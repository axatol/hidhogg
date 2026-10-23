import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI

struct D200XControlInspectorView: View {
    @ObservedObject var model: D200XModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isChoosingShortcut = false
    @State private var isCapturingShortcut = false
    @State private var captureControl: D200XControl?
    @State private var captureApplicationID: String?
    @State private var captureSessionID = UUID()
    @State private var isManualEditorPresented = false
    @State private var manualEditorControl: D200XControl?
    @State private var manualEditorApplicationID: String?
    @State private var manualEditorInitialShortcut: HidhoggDomain.KeyboardShortcut?
    @State private var manualEditorPresentationID = UUID()
    @State private var appearanceLabel = ""
    @State private var appearanceHex = ""
    @State private var loadedAppearanceControl: D200XControl?

    private var selectedDialIndex: Int? {
        switch model.selectedControl {
        case .dial0Press, .dial0Left, .dial0Right, .dial0HeldLeft, .dial0HeldRight: 0
        case .dial1Press, .dial1Left, .dial1Right, .dial1HeldLeft, .dial1HeldRight: 1
        case .dial2Press, .dial2Left, .dial2Right, .dial2HeldLeft, .dial2HeldRight: 2
        default: nil
        }
    }

    private var assignmentSelection: Binding<String> {
        Binding(
            get: {
                if isChoosingShortcut { return "shortcut" }
                if model.applicationID != nil && model.isInherited { return "inherit" }
                return model.binding.kind == .disabled ? "disabled" : "shortcut"
            },
            set: setAssignment
        )
    }

    private var isValidAppearanceHex: Bool {
        let value = appearanceHex.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.utf8.count == 6 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private var normalizedAppearanceHex: String {
        appearanceHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private var canEditControl: Bool {
        model.canEdit && model.isConfigured
    }

    private var requiresShortcutSelection: Bool {
        (model.applicationID != nil && model.isInherited) || model.binding.kind != .shortcut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            selectedControlHeader
            gesturePicker
            assignmentGroup

            if model.binding.kind == .shortcut || isChoosingShortcut {
                shortcutGroup
            }

            if model.selectedControl.isTile {
                appearanceGroup
            }

            if !model.isConfigured {
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connect once to add this deck to your saved devices. You can then edit its bindings while disconnected.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: loadAppearanceDraft)
        .onChange(of: model.selectedControl) { _, _ in
            loadAppearanceDraft()
            cancelInputSessions()
        }
        .onChange(of: model.applicationID) { _, _ in
            cancelInputSessions()
        }
        .onChange(of: model.canEdit) { _, canEdit in
            if !canEdit { cancelInputSessions() }
        }
        .onChange(of: model.isConfigured) { _, isConfigured in
            if !isConfigured { cancelInputSessions() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelInputSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelInputSessions()
        }
        .onDisappear(perform: cancelInputSessions)
        .sheet(isPresented: $isManualEditorPresented, onDismiss: finishManualEditor) {
            if let control = manualEditorControl {
                ShortcutEditorView(
                    initialShortcut: manualEditorInitialShortcut,
                    onCancel: { isManualEditorPresented = false },
                    onCommit: { shortcut in
                        commitManualShortcut(
                            shortcut,
                            control: control,
                            applicationID: manualEditorApplicationID
                        )
                    }
                )
                .id(manualEditorPresentationID)
            }
        }
    }

    private var selectedControlHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.selectedControl.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(model.applicationID ?? "All apps")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var gesturePicker: some View {
        if let dialIndex = selectedDialIndex {
            GroupBox("Dial gesture") {
                Picker("Gesture", selection: Binding(
                    get: { model.selectedControl.gesture ?? .press },
                    set: { selectDialGesture($0, dialIndex: dialIndex) }
                )) {
                    ForEach(D200XGesture.allCases, id: \.self) { gesture in
                        Text(gesture.title).tag(gesture)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!canEditControl)
                .padding(.vertical, 4)
            }
        }
    }

    private var assignmentGroup: some View {
        GroupBox("Assignment") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Action", selection: assignmentSelection) {
                    if model.applicationID != nil {
                        Text("Inherit from All apps").tag("inherit")
                    }
                    Text("Disabled").tag("disabled")
                    Text("Keyboard shortcut").tag("shortcut")
                }
                .pickerStyle(.menu)
                .disabled(!canEditControl)

                Text(assignmentDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var shortcutGroup: some View {
        GroupBox("Keyboard shortcut") {
            VStack(alignment: .leading, spacing: 10) {
                if model.binding.kind == .shortcut, let shortcut = model.binding.shortcut {
                    LabeledContent("Current shortcut", value: ShortcutSender.label(for: shortcut))
                }

                if isCapturingShortcut {
                    VStack(alignment: .leading, spacing: 8) {
                        shortcutCaptureView
                            .frame(maxWidth: .infinity, minHeight: 34)

                        Button("Cancel", systemImage: "xmark.circle") {
                            cancelShortcutCapture()
                        }
                    }
                } else {
                    Button("Record Shortcut", systemImage: "record.circle") {
                        beginShortcutCapture()
                    }
                    .disabled(!canEditControl)
                }

                Button("Choose Manually…", systemImage: "keyboard") {
                    beginManualEditor()
                }
                .disabled(!canEditControl)
                .accessibilityHint("Choose a key and modifiers without pressing the shortcut")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var shortcutCaptureView: some View {
        Group {
            if let control = captureControl, isCapturingShortcut {
                let applicationID = captureApplicationID
                ShortcutCaptureView(
                    onCapture: { shortcut in
                        commitCapturedShortcut(
                            shortcut,
                            control: control,
                            applicationID: applicationID
                        )
                    },
                    onCancel: cancelShortcutCapture
                )
                .id(captureSessionID)
            }
        }
    }

    private var appearanceGroup: some View {
        GroupBox("Key appearance") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Label", text: $appearanceLabel)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canEditControl)
                    .onChange(of: appearanceLabel) { _, _ in
                        applyAppearanceDraft()
                    }

                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color(forHex: normalizedAppearanceHex))
                        .frame(width: 26, height: 26)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                        .accessibilityLabel("Key background preview")

                    TextField("Six-digit hex color", text: $appearanceHex)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Key background color as six hexadecimal digits")
                        .disabled(!canEditControl)
                        .onChange(of: appearanceHex) { _, _ in
                            applyAppearanceDraft()
                        }
                }

                if appearanceLabel.count > 64 {
                    Text("Key labels can contain at most 64 characters.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !isValidAppearanceHex {
                    Text("Enter six hexadecimal digits without a # prefix. The color saves when valid.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Appearance changes save automatically on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var assignmentDescription: String {
        if model.applicationID != nil && model.isInherited {
            return "This control uses its All apps assignment. Choose an action to create an app-specific override."
        }
        if model.binding.kind == .disabled {
            return "No keyboard shortcut is assigned to this control."
        }
        guard let shortcut = model.binding.shortcut else {
            return "Choose or record a keyboard shortcut for this control."
        }
        return "Sends \(ShortcutSender.label(for: shortcut)) when this control is used."
    }

    private func setAssignment(_ value: String) {
        guard canEditControl else { return }

        switch value {
        case "inherit":
            isChoosingShortcut = false
            cancelShortcutCapture()
            model.setBinding(nil)
        case "disabled":
            isChoosingShortcut = false
            cancelShortcutCapture()
            model.setBinding(.disabled)
        case "shortcut":
            guard requiresShortcutSelection || model.binding.shortcut == nil else { return }
            isChoosingShortcut = true
            beginShortcutCapture()
        default:
            break
        }
    }

    private func beginShortcutCapture() {
        guard canEditControl else { return }
        isChoosingShortcut = requiresShortcutSelection
        captureControl = model.selectedControl
        captureApplicationID = model.applicationID
        captureSessionID = UUID()
        isCapturingShortcut = true
    }

    private func commitCapturedShortcut(
        _ shortcut: HidhoggDomain.KeyboardShortcut,
        control: D200XControl,
        applicationID: String?
    ) {
        guard isCapturingShortcut,
              captureControl == control,
              captureApplicationID == applicationID,
              model.selectedControl == control,
              model.applicationID == applicationID,
              canEditControl else {
            cancelInputSessions()
            return
        }

        model.setBinding(.key(shortcut))
        isChoosingShortcut = false
        cancelShortcutCapture()
    }

    private func beginManualEditor() {
        guard canEditControl else { return }
        cancelShortcutCapture()
        isChoosingShortcut = requiresShortcutSelection
        manualEditorControl = model.selectedControl
        manualEditorApplicationID = model.applicationID
        manualEditorInitialShortcut = model.binding.shortcut
        manualEditorPresentationID = UUID()
        isManualEditorPresented = true
    }

    private func commitManualShortcut(
        _ shortcut: HidhoggDomain.KeyboardShortcut,
        control: D200XControl,
        applicationID: String?
    ) {
        guard isManualEditorPresented,
              manualEditorControl == control,
              manualEditorApplicationID == applicationID,
              model.selectedControl == control,
              model.applicationID == applicationID,
              canEditControl else {
            cancelInputSessions()
            return
        }

        model.setBinding(.key(shortcut))
        isChoosingShortcut = false
        isManualEditorPresented = false
    }

    private func finishManualEditor() {
        manualEditorControl = nil
        manualEditorApplicationID = nil
        manualEditorInitialShortcut = nil
        isChoosingShortcut = false
    }

    private func cancelShortcutCapture() {
        isCapturingShortcut = false
        captureControl = nil
        captureApplicationID = nil
        captureSessionID = UUID()
        isChoosingShortcut = false
    }

    private func cancelInputSessions() {
        cancelShortcutCapture()
        if isManualEditorPresented { isManualEditorPresented = false }
        isChoosingShortcut = false
    }

    private func selectDialGesture(_ gesture: D200XGesture, dialIndex: Int) {
        guard let control = D200XControl.allCases.first(where: {
            $0.wireIndex == dialIndex + 17 && $0.gesture == gesture
        }) else { return }
        model.selectedControl = control
    }

    private func loadAppearanceDraft() {
        loadedAppearanceControl = model.selectedControl
        appearanceLabel = model.appearance.label
        appearanceHex = model.appearance.backgroundHex
    }

    private func applyAppearanceDraft() {
        guard let loadedAppearanceControl,
              model.selectedControl == loadedAppearanceControl,
              loadedAppearanceControl.isTile,
              canEditControl,
              appearanceLabel.count <= 64,
              isValidAppearanceHex else { return }

        let backgroundHex = normalizedAppearanceHex
        guard model.appearance.label != appearanceLabel ||
                model.appearance.backgroundHex != backgroundHex else { return }

        model.setAppearance(label: appearanceLabel, backgroundHex: backgroundHex)
    }

    private func color(forHex hex: String) -> Color {
        guard let value = UInt32(hex, radix: 16) else { return .gray }
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
