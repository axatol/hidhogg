import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI

struct D200XControlInspectorView: View {
    @ObservedObject var model: D200XModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isCapturingShortcut = false
    @State private var captureControl: D200XControl?
    @State private var captureApplicationID: String?
    @State private var captureSessionID = UUID()
    @State private var isActionChooserPresented = false
    @State private var actionChooserControl: D200XControl?
    @State private var actionChooserApplicationID: String?
    @State private var actionChooserSessionID = UUID()
    @State private var isManualEditorPresented = false
    @State private var manualEditorControl: D200XControl?
    @State private var manualEditorApplicationID: String?
    @State private var manualEditorInitialShortcut: HidhoggDomain.KeyboardShortcut?
    @State private var manualEditorPresentationID = UUID()
    @State private var presetChooserContext: D200XPresetAssignmentContext?
    @State private var topicDraft = ""
    @State private var topicError: String?

    private var selectedDialIndex: Int? {
        switch model.selectedControl {
        case .dial0Press, .dial0Left, .dial0Right, .dial0HeldLeft, .dial0HeldRight: 0
        case .dial1Press, .dial1Left, .dial1Right, .dial1HeldLeft, .dial1HeldRight: 1
        case .dial2Press, .dial2Left, .dial2Right, .dial2HeldLeft, .dial2HeldRight: 2
        default: nil
        }
    }

    private var actionIDs: [String] {
        model.configuration?.actionIDs ?? []
    }

    private var canEditControl: Bool {
        model.canEdit && model.isConfigured
    }

    private var canChoosePreset: Bool {
        let control = model.selectedControl
        return control.isTile || control == .side0 || control == .side1
            || control.gesture == .press || control.gesture == .left || control.gesture == .right
    }

    private var parsedTopicFilters: [String] {
        topicDraft
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var topicValidationMessage: String? {
        let filters = parsedTopicFilters
        guard !filters.isEmpty else { return nil }
        guard filters.count <= 16 else { return "A control can subscribe to at most 16 topic filters." }
        guard Set(filters).count == filters.count else { return "Topic filters must be unique." }
        guard filters.allSatisfy({ NotificationTopic.isValidFilter($0) }) else {
            return "Use 1–64 ASCII letters, digits, dots, underscores, hyphens, or *; begin with a letter, digit, or *."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            selectedControlHeader
            gesturePicker
            assignmentGroup

            if model.selectedControl.isTile {
                appearanceGroup
                topicSubscriptionsGroup
                if model.applicationID != nil {
                    Button("Use All Apps Appearance and Topics", systemImage: "arrow.uturn.backward") {
                        model.resetSelectedAppearanceAndTopics()
                    }
                    .disabled(!canEditControl)
                }
            }

            if !model.isConfigured {
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Set up a local configuration on Devices or Actions before editing this control. You can make configuration changes while disconnected.")
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
        .onAppear {
            normalizeLegacyHeldControl()
            syncTopicDraft()
        }
        .onChange(of: model.selectedControl) { _, _ in
            cancelInputSessions()
            normalizeLegacyHeldControl()
            syncTopicDraft()
        }
        .onChange(of: model.applicationID) { _, _ in
            cancelInputSessions()
            syncTopicDraft()
        }
        .onChange(of: model.notificationTopics) { _, _ in syncTopicDraft() }
        .onChange(of: isActionChooserPresented) { _, isPresented in
            if !isPresented { finishActionChooser() }
        }
        .onChange(of: model.canEdit) { _, canEdit in
            if !canEdit {
                cancelInputSessions()
                cancelPresetChooser()
            }
        }
        .onChange(of: model.isConfigured) { _, isConfigured in
            if !isConfigured {
                cancelInputSessions()
                cancelPresetChooser()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelInputSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelInputSessions()
        }
        .onDisappear {
            cancelInputSessions()
            cancelPresetChooser()
        }
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
                VStack(spacing: 8) {
                    gestureButton(.press, title: "Press", dialIndex: dialIndex)
                    HStack(spacing: 8) {
                        Text("Rotate")
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        gestureButton(
                            .left,
                            title: "Left",
                            accessibilityTitle: "Rotate Left",
                            dialIndex: dialIndex
                        )
                        gestureButton(
                            .right,
                            title: "Right",
                            accessibilityTitle: "Rotate Right",
                            dialIndex: dialIndex
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var selectedDialGesture: D200XGesture {
        switch model.selectedControl.gesture {
        case .some(.heldLeft): .left
        case .some(.heldRight): .right
        case .some(.press), .none: .press
        case .some(.left): .left
        case .some(.right): .right
        }
    }

    private func gestureButton(
        _ gesture: D200XGesture,
        title: String,
        accessibilityTitle: String? = nil,
        dialIndex: Int
    ) -> some View {
        let isSelected = selectedDialGesture == gesture
        let spokenTitle = accessibilityTitle ?? title
        let shape = RoundedRectangle(cornerRadius: 8)

        return Button {
            selectDialGesture(gesture, dialIndex: dialIndex)
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.bold))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                isSelected ? MXMasterMousePalette.selected.opacity(0.18) : MXMasterMousePalette.cardBackground,
                in: shape
            )
            .overlay {
                shape.stroke(
                    isSelected ? MXMasterMousePalette.selected : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 2 : 1
                )
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!canEditControl)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Selects the \(spokenTitle) dial gesture.")
        .help("Select the \(spokenTitle) dial gesture.")
        .accessibilityIdentifier("d200x-dial-gesture-\(gesture.rawValue)")
    }

    private var assignmentGroup: some View {
        GroupBox("Assignment") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current assignment")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(currentAssignmentSummary)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(currentAssignmentSummary)
                            .accessibilityLabel("Current assignment: \(currentAssignmentSummary)")
                    }
                    Spacer(minLength: 4)
                    if model.binding.kind != .disabled {
                        Button("Clear assignment", systemImage: "xmark") {
                            model.setBinding(.disabled)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Set the current app scope to Disabled.")
                        .disabled(!canEditControl || isCapturingShortcut)
                    }
                }

                if isCapturingShortcut {
                    VStack(alignment: .leading, spacing: 8) {
                        shortcutCaptureView
                            .frame(maxWidth: .infinity, minHeight: 34)

                        Button("Cancel Shortcut Capture", systemImage: "xmark.circle") {
                            cancelShortcutCapture()
                        }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            recordShortcutButton
                            chooseActionButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            recordShortcutButton
                                .frame(maxWidth: .infinity)
                            chooseActionButton
                                .frame(maxWidth: .infinity)
                        }
                    }

                    Button("Choose Manually…", systemImage: "keyboard") {
                        beginManualEditor()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Choose a key and modifiers without pressing the shortcut.")
                    .disabled(!canEditControl)

                    if canChoosePreset {
                        Button("Choose Preset…", systemImage: "square.grid.2x2") {
                            beginPresetChooser()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Preview a complete preset and apply it without running its action.")
                        .disabled(!canEditControl)
                    }
                }

                if model.applicationID != nil && !model.isInherited {
                    Button("Use All Apps Default", systemImage: "arrow.uturn.backward") {
                        model.setBinding(nil)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this app's override and use the All Apps assignment.")
                    .disabled(!canEditControl || isCapturingShortcut)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .popover(isPresented: $isActionChooserPresented, arrowEdge: .bottom) {
            actionChooserPopover
        }
        .sheet(item: $presetChooserContext, onDismiss: finishPresetChooser) { context in
            D200XPresetChooserView(model: model, context: context) {
                presetChooserContext = nil
            }
            .id(context)
        }
    }

    private var recordShortcutButton: some View {
        Button("Record Shortcut", systemImage: "record.circle") {
            beginShortcutCapture()
        }
        .buttonStyle(.borderedProminent)
        .tint(AppAppearance.accent)
        .help("Start keyboard shortcut capture for the selected control and app.")
        .accessibilityHint("The current assignment changes only after you press a shortcut.")
        .disabled(!canEditControl)
    }

    private var chooseActionButton: some View {
        Button("Choose Action", systemImage: "list.bullet") {
            beginActionChooser()
        }
        .buttonStyle(.bordered)
        .help("Choose an action to assign to the selected control.")
        .disabled(!canEditControl)
    }

    @ViewBuilder
    private var actionChooserPopover: some View {
        if let control = actionChooserControl {
            let applicationID = actionChooserApplicationID
            let sessionID = actionChooserSessionID
            D200XActionChooserView(model: model) { actionID in
                commitChosenAction(
                    actionID,
                    control: control,
                    applicationID: applicationID,
                    sessionID: sessionID
                )
            }
        } else {
            Text("Choose an action from the current control context.")
                .padding(16)
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
        D200XAppearanceEditorView(model: model)
    }

    private var topicSubscriptionsGroup: some View {
        GroupBox("Topic filters") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Exact filters match one topic. * matches any sequence, including dots. Leave empty to clear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("build.finished, build.*", text: $topicDraft, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canEditControl)
                    .accessibilityLabel("Notification topic filters")

                if let topicError {
                    Text(topicError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let topicValidationMessage {
                    Text(topicValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button("Save topic filters", systemImage: "square.and.arrow.down", action: saveTopicFilters)
                    .disabled(!canEditControl || topicValidationMessage != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private var currentAssignmentSummary: String {
        let scope: String
        if model.applicationID == nil {
            scope = "All apps"
        } else {
            scope = model.isInherited ? "All apps default" : "This app"
        }

        let assignment: String
        switch model.binding.kind {
        case .disabled:
            assignment = "Disabled"
        case .shortcut:
            assignment = model.binding.shortcut.map { "Keyboard shortcut · \(ShortcutSender.label(for: $0))" }
                ?? "Keyboard shortcut"
        case .action:
            assignment = model.binding.actionID.map { "Action · \($0)" } ?? "Action"
        }
        return "\(scope): \(assignment)"
    }

    private func beginShortcutCapture() {
        guard canEditControl else { return }
        cancelActionChooser()
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
        cancelShortcutCapture()
    }

    private func beginManualEditor() {
        guard canEditControl else { return }
        cancelActionChooser()
        cancelShortcutCapture()
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
        isManualEditorPresented = false
    }

    private func finishManualEditor() {
        manualEditorControl = nil
        manualEditorApplicationID = nil
        manualEditorInitialShortcut = nil
    }

    private func cancelShortcutCapture() {
        isCapturingShortcut = false
        captureControl = nil
        captureApplicationID = nil
        captureSessionID = UUID()
    }

    private func cancelInputSessions() {
        cancelShortcutCapture()
        cancelActionChooser()
        if isManualEditorPresented { isManualEditorPresented = false }
    }

    private func beginActionChooser() {
        guard canEditControl else { return }
        cancelShortcutCapture()
        actionChooserControl = model.selectedControl
        actionChooserApplicationID = model.applicationID
        actionChooserSessionID = UUID()
        isActionChooserPresented = true
    }

    private func beginPresetChooser() {
        guard canEditControl, canChoosePreset else { return }
        cancelActionChooser()
        cancelShortcutCapture()
        if isManualEditorPresented { isManualEditorPresented = false }
        presetChooserContext = D200XPresetAssignmentContext(
            control: model.selectedControl,
            applicationID: model.applicationID
        )
    }

    private func finishPresetChooser() {
        presetChooserContext = nil
    }

    private func cancelPresetChooser() {
        finishPresetChooser()
    }

    private func commitChosenAction(
        _ actionID: String,
        control: D200XControl,
        applicationID: String?,
        sessionID: UUID
    ) {
        guard actionChooserSessionID == sessionID,
              actionChooserControl == control,
              actionChooserApplicationID == applicationID else { return }
        guard isActionChooserPresented,
              model.selectedControl == control,
              model.applicationID == applicationID,
              canEditControl,
              model.configuration?.actionDefinition(id: actionID) != nil else {
            cancelActionChooser()
            return
        }

        model.setBinding(.action(actionID))
        cancelActionChooser()
    }

    private func cancelActionChooser() {
        isActionChooserPresented = false
        finishActionChooser()
    }

    private func finishActionChooser() {
        actionChooserControl = nil
        actionChooserApplicationID = nil
        actionChooserSessionID = UUID()
    }

    private func selectDialGesture(_ gesture: D200XGesture, dialIndex: Int) {
        guard let control = D200XControl.allCases.first(where: {
            $0.wireIndex == dialIndex + 17 && $0.gesture == gesture
        }) else { return }
        model.selectedControl = control
    }

    private func normalizeLegacyHeldControl() {
        guard let dialIndex = selectedDialIndex else { return }
        switch model.selectedControl.gesture {
        case .some(.heldLeft): selectDialGesture(.left, dialIndex: dialIndex)
        case .some(.heldRight): selectDialGesture(.right, dialIndex: dialIndex)
        case .some(.press), .some(.left), .some(.right), .none: return
        }
    }

    private func syncTopicDraft() {
        topicDraft = model.notificationTopics.joined(separator: ", ")
        topicError = nil
    }

    private func saveTopicFilters() {
        guard canEditControl, topicValidationMessage == nil else { return }
        do {
            try model.setNotificationTopics(parsedTopicFilters)
            topicError = nil
        } catch {
            topicError = error.localizedDescription
        }
    }

}
