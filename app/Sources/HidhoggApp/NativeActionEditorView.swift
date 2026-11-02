import HidhoggDomain
import MacOSActions
import SwiftUI
import UniformTypeIdentifiers

struct NativeActionEditorView: View {
    @ObservedObject var model: D200XModel
    @Binding var selectedActionID: String?
    let initialAction: NativeAction
    let onSaved: (String) -> Void
    let onRemoved: (NativeAction) -> Void

    @State private var originalAction: NativeAction?
    @State private var identifier = ""
    @State private var action = NativeAction(kind: .bell)
    @State private var isFileImporterPresented = false
    @State private var isShortcutEditorPresented = false
    @State private var isRemovalConfirmationPresented = false
    @State private var errorMessage: String?

    private var actionIDs: [String] {
        model.configuration?.actionIDs ?? []
    }

    private var actionValidationMessage: String? {
        guard ConfiguredExecutable.isValidIdentifier(identifier) else {
            return "Use an action ID beginning with a letter or digit, up to 64 bytes."
        }
        if originalAction == nil, model.configuration?.actionDefinition(id: identifier) != nil {
            return "That action ID is already in use."
        }
        if originalAction == nil, actionIDs.count >= 64 {
            return "A device can store at most 64 actions."
        }
        guard (try? action.validated()) != nil else {
            return invalidActionMessage
        }
        return nil
    }

    private var invalidActionMessage: String {
        switch action.kind {
        case .media:
            "Choose a media operation."
        case .volume:
            action.volume == .set ? "Choose a volume from 0 to 100%." : "Choose a volume operation."
        case .bell:
            "Check the action fields."
        case .playSound:
            "Choose an absolute path to an audio file."
        case .openApplication:
            "Choose an absolute path to an application."
        case .openFile:
            "Choose an absolute file path."
        case .openURL:
            "Enter an HTTP or HTTPS URL with a host and no credentials."
        case .deckNotification:
            "Use a concrete topic and provide valid one-line text or an application bundle ID."
        case .shortcut:
            "Choose a valid keyboard shortcut."
        case .lockScreen:
            "Lock Screen does not accept parameters."
        }
    }

    private var fileImporterTypes: [UTType] {
        switch action.kind {
        case .playSound: [.audio]
        case .openApplication: [.applicationBundle]
        case .openFile: [.item]
        default: [.item]
        }
    }

    private var shortcut: HidhoggDomain.KeyboardShortcut? {
        action.shortcut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedActionID == nil ? "New native action" : "Edit native action")
                    .font(.title2.weight(.semibold))
                Text("Values are saved as static parameters. Actions do not run while you edit them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("Action") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Action ID", text: $identifier)
                        .textFieldStyle(.roundedBorder)
                        .disabled(originalAction != nil || !canEdit)
                    Text("\(identifier.isEmpty ? "New" : identifier) · \(kindTitle(action.kind))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            actionFields

            if let actionValidationMessage {
                Text(actionValidationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(selectedActionID == nil ? "Add Action" : "Save Action", systemImage: "square.and.arrow.down") {
                    saveAction()
                }
                .disabled(!canEdit || actionValidationMessage != nil)

                if originalAction != nil, let selectedActionID {
                    Button("Remove…", systemImage: "trash", role: .destructive) {
                        isRemovalConfirmationPresented = true
                    }
                    .disabled(!canEdit)
                }
            }
        }
        .onAppear(perform: loadDraft)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: fileImporterTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFileImporterResult
        )
        .sheet(isPresented: $isShortcutEditorPresented) {
            ShortcutEditorView(
                initialShortcut: shortcut,
                onCancel: { isShortcutEditorPresented = false },
                onCommit: { value in
                    action.shortcut = value
                    isShortcutEditorPresented = false
                }
            )
        }
        .confirmationDialog(
            "Remove native action?",
            isPresented: $isRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let selectedActionID {
                Button("Remove \(selectedActionID)", role: .destructive) {
                    model.removeAction(id: selectedActionID)
                    onRemoved(action)
                }
            }
            Button("Cancel", role: .cancel) { isRemovalConfirmationPresented = false }
        } message: {
            Text("Controls assigned to this action will no longer use it.")
        }
    }

    private var canEdit: Bool {
        model.canEdit && model.isConfigured
    }

    @ViewBuilder
    private var actionFields: some View {
        switch action.kind {
        case .media:
            GroupBox("Playback") {
                Picker("Operation", selection: Binding(
                    get: { action.media ?? .playPause },
                    set: { action.media = $0 }
                )) {
                    Text("Play/Pause").tag(NativeAction.Media.playPause)
                    Text("Next Track").tag(NativeAction.Media.nextTrack)
                    Text("Previous Track").tag(NativeAction.Media.previousTrack)
                }
                .disabled(!canEdit)
                .padding(.vertical, 4)
            }
        case .volume:
            GroupBox("Volume") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Operation", selection: Binding(
                        get: { action.volume ?? .up },
                        set: updateVolumeOperation
                    )) {
                        Text("Up").tag(NativeAction.Volume.up)
                        Text("Down").tag(NativeAction.Volume.down)
                        Text("Mute").tag(NativeAction.Volume.mute)
                        Text("Set level").tag(NativeAction.Volume.set)
                    }
                    .disabled(!canEdit)

                    if action.volume == .set {
                        HStack {
                            Text("Level")
                            Spacer()
                            Text("\(action.percent ?? 50)%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(action.percent ?? 50) },
                            set: { action.percent = Int($0.rounded()) }
                        ), in: 0...100, step: 1)
                        .disabled(!canEdit)
                    } else {
                        Text("Uses the standard system volume step.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        case .bell:
            GroupBox("Bell") {
                Text("Plays the system alert sound when this action is assigned and invoked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        case .lockScreen:
            GroupBox("Lock Screen") {
                Label("Locks this Mac with Control–Command–Q when invoked.", systemImage: "lock")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
        case .playSound, .openApplication, .openFile:
            GroupBox(targetFieldTitle) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(targetFieldTitle, text: targetBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEdit)
                    Button(filePickerTitle, systemImage: "folder") {
                        isFileImporterPresented = true
                    }
                    .disabled(!canEdit)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        case .openURL:
            GroupBox("Website") {
                TextField("https://example.com", text: targetBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canEdit)
                    .padding(.vertical, 4)
            }
        case .deckNotification:
            GroupBox("Deck notification") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Concrete topic", text: topicBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEdit)
                    TextField("Application bundle ID (optional)", text: appIDBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEdit)
                    TextField("Notification text (optional)", text: textBinding)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEdit)
                    Text("An installed app icon replaces the text on the deck. If the icon is unavailable, the deck shows your text or the bundle ID when text is omitted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Set expiry", isOn: Binding(
                        get: { action.ttlSeconds != nil },
                        set: { action.ttlSeconds = $0 ? (action.ttlSeconds ?? 10) : nil }
                    ))
                    .disabled(!canEdit)
                    if action.ttlSeconds != nil {
                        Stepper(value: expiryBinding, in: 1...86_400) {
                            Text("Expires after \(action.ttlSeconds ?? 10) seconds")
                                .monospacedDigit()
                        }
                        .disabled(!canEdit)
                    }
                }
                .padding(.vertical, 4)
            }
        case .shortcut:
            GroupBox("Keyboard shortcut") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(shortcut.map { ShortcutSender.label(for: $0) } ?? "No shortcut selected")
                        .foregroundStyle(shortcut == nil ? .secondary : .primary)
                    Button("Choose Manually…", systemImage: "keyboard") {
                        isShortcutEditorPresented = true
                    }
                    .disabled(!canEdit)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var targetFieldTitle: String {
        switch action.kind {
        case .playSound: "Audio file path"
        case .openApplication: "Application path"
        case .openFile: "File path"
        default: "Target"
        }
    }

    private var filePickerTitle: String {
        switch action.kind {
        case .playSound: "Choose Audio File…"
        case .openApplication: "Choose Application…"
        case .openFile: "Choose File…"
        default: "Choose…"
        }
    }

    private var targetBinding: Binding<String> {
        Binding(get: { action.target ?? "" }, set: { action.target = $0.isEmpty ? nil : $0 })
    }

    private var topicBinding: Binding<String> {
        Binding(get: { action.topic ?? "" }, set: { action.topic = $0.isEmpty ? nil : $0 })
    }

    private var textBinding: Binding<String> {
        Binding(get: { action.text ?? "" }, set: { action.text = $0.isEmpty ? nil : $0 })
    }

    private var appIDBinding: Binding<String> {
        Binding(get: { action.appID ?? "" }, set: { action.appID = $0.isEmpty ? nil : $0 })
    }

    private var expiryBinding: Binding<Int> {
        Binding(get: { action.ttlSeconds ?? 10 }, set: { action.ttlSeconds = $0 })
    }

    private func loadDraft() {
        errorMessage = nil
        guard let selectedActionID,
              let saved = model.configuration?.nativeActions[selectedActionID] else {
            originalAction = nil
            identifier = ""
            action = initialAction
            return
        }
        originalAction = saved
        identifier = selectedActionID
        action = saved
    }

    private func updateVolumeOperation(_ volume: NativeAction.Volume) {
        action.volume = volume
        if volume == .set {
            action.percent = action.percent ?? 50
        } else {
            action.percent = nil
        }
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            action.target = url.path
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func saveAction() {
        guard canEdit, actionValidationMessage == nil else { return }
        do {
            try model.saveNativeAction(id: identifier, action: action)
            originalAction = action
            errorMessage = nil
            selectedActionID = identifier
            onSaved(identifier)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func kindTitle(_ kind: NativeAction.Kind) -> String {
        switch kind {
        case .media: "Media"
        case .volume: "Volume"
        case .bell: "Bell"
        case .playSound: "Play Sound"
        case .openApplication: "Open Application"
        case .openFile: "Open File"
        case .openURL: "Open URL"
        case .deckNotification: "Deck Notification"
        case .shortcut: "Keyboard Shortcut"
        case .lockScreen: "Lock Screen"
        }
    }
}
