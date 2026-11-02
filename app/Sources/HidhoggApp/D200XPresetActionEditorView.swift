import HidhoggDomain
import MacOSActions
import SwiftUI
import UniformTypeIdentifiers

struct D200XPresetActionEditorView: View {
    @Binding var draft: D200XPresetActionDraft
    let configuration: D200XConfiguration?
    var showsActionPicker = true

    @State private var isFileImporterPresented = false
    @State private var isShortcutEditorPresented = false
    @State private var importError: String?

    private enum ActionChoice: Hashable {
        case none
        case template(D200XActionTemplate)
        case existing(String)
        case current
    }

    private var selection: Binding<ActionChoice> {
        Binding(
            get: {
                if draft.kind == .none { return .none }
                guard let template = draft.template else { return .current }
                return .template(template)
            },
            set: select
        )
    }

    var body: some View {
        GroupBox("Action") {
            VStack(alignment: .leading, spacing: 10) {
                if showsActionPicker {
                    Picker("Action", selection: selection) {
                        Label("None", systemImage: "minus.circle")
                            .tag(ActionChoice.none)

                        if case .current = selection.wrappedValue {
                            Label(draft.summary, systemImage: draft.systemSymbol)
                                .tag(ActionChoice.current)
                        }

                        Section("Templates") {
                            ForEach(D200XActionTemplate.allCases) { template in
                                Label(template.title, systemImage: template.systemSymbol)
                                    .tag(ActionChoice.template(template))
                            }
                        }

                        if let actionIDs = configuration?.actionIDs, !actionIDs.isEmpty {
                            Section("Advanced copies") {
                                ForEach(actionIDs.indices, id: \.self) { index in
                                    let actionID = actionIDs[index]
                                    Label("Copy \(actionTitle(for: actionID)) · \(index + 1)", systemImage: "doc.on.doc")
                                        .tag(ActionChoice.existing(actionID))
                                }
                            }
                        }
                    }
                }

                Label(draft.summary, systemImage: draft.systemSymbol)
                    .font(.callout.weight(.medium))

                parameterFields

                if let validationMessage = draft.validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardContentPadding()
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: fileImporterTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFileImporterResult
        )
        .sheet(isPresented: $isShortcutEditorPresented) {
            ShortcutEditorView(
                initialShortcut: draft.nativeAction.shortcut,
                onCancel: { isShortcutEditorPresented = false },
                onCommit: { value in
                    updateNativeAction { $0.shortcut = value }
                    isShortcutEditorPresented = false
                }
            )
        }
    }

    @ViewBuilder
    private var parameterFields: some View {
        switch draft.kind {
        case .none:
            Text("This preset leaves the control unassigned.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .native:
            nativeFields
        case .executable:
            executableFields
        }
    }

    @ViewBuilder
    private var nativeFields: some View {
        switch draft.nativeAction.kind {
        case .media:
            GroupBox("Playback") {
                Picker("Operation", selection: nativeBinding(
                    get: { $0.media ?? .playPause },
                    set: { $0.media = $1 }
                )) {
                    Text("Play/Pause").tag(NativeAction.Media.playPause)
                    Text("Next Track").tag(NativeAction.Media.nextTrack)
                    Text("Previous Track").tag(NativeAction.Media.previousTrack)
                }
                .cardContentPadding()
            }
        case .volume:
            GroupBox("Volume") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Operation", selection: nativeBinding(
                        get: { $0.volume ?? .up },
                        set: {
                            $0.volume = $1
                            $0.percent = $1 == .set ? ($0.percent ?? 50) : nil
                        }
                    )) {
                        Text("Up").tag(NativeAction.Volume.up)
                        Text("Down").tag(NativeAction.Volume.down)
                        Text("Mute").tag(NativeAction.Volume.mute)
                        Text("Set level").tag(NativeAction.Volume.set)
                    }

                    if draft.nativeAction.volume == .set {
                        HStack {
                            Text("Level")
                            Spacer()
                            Text("\(draft.nativeAction.percent ?? 50)%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: nativeBinding(
                            get: { Double($0.percent ?? 50) },
                            set: { $0.percent = Int($1.rounded()) }
                        ), in: 0...100, step: 1)
                    } else {
                        Text("Uses the standard system volume step.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .cardContentPadding()
            }
        case .bell:
            GroupBox("Bell") {
                Text("Plays the system alert sound when this action is assigned and invoked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .cardContentPadding()
            }
        case .lockScreen:
            GroupBox("Lock Screen") {
                Label("Locks this Mac with Control–Command–Q when invoked.", systemImage: "lock")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .cardContentPadding()
            }
        case .playSound, .openApplication, .openFile:
            GroupBox(targetFieldTitle) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(targetFieldTitle, text: targetBinding)
                        .textFieldStyle(.roundedBorder)
                    Button(filePickerTitle, systemImage: "folder") {
                        isFileImporterPresented = true
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardContentPadding()
            }
        case .openURL:
            GroupBox("Website") {
                TextField("https://…", text: targetBinding)
                    .textFieldStyle(.roundedBorder)
                    .cardContentPadding()
            }
        case .deckNotification:
            GroupBox("Deck notification") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Concrete topic", text: topicBinding)
                        .textFieldStyle(.roundedBorder)
                    TextField("Application bundle ID (optional)", text: appIDBinding)
                        .textFieldStyle(.roundedBorder)
                    TextField("Notification text (optional)", text: textBinding)
                        .textFieldStyle(.roundedBorder)
                    Text("Provide valid one-line text or an application bundle ID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Set expiry", isOn: Binding(
                        get: { draft.nativeAction.ttlSeconds != nil },
                        set: { isEnabled in
                            updateNativeAction { $0.ttlSeconds = isEnabled ? ($0.ttlSeconds ?? 10) : nil }
                        }
                    ))
                    if draft.nativeAction.ttlSeconds != nil {
                        Stepper(value: expiryBinding, in: 1...86_400) {
                            Text("Expires after \(draft.nativeAction.ttlSeconds ?? 10) seconds")
                                .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardContentPadding()
            }
        case .shortcut:
            GroupBox("Keyboard shortcut") {
                HStack {
                    Text(draft.nativeAction.shortcut.map { ShortcutSender.label(for: $0) } ?? "No shortcut selected")
                        .foregroundStyle(draft.nativeAction.shortcut == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose Shortcut…", systemImage: "keyboard") {
                        isShortcutEditorPresented = true
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardContentPadding()
            }
        }
    }

    private var executableFields: some View {
        GroupBox("Custom executable") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Absolute executable path", text: executableStringBinding(
                    get: { $0.executable },
                    set: { $0.executable = $1 }
                ))
                .textFieldStyle(.roundedBorder)

                TextField("Working directory (optional)", text: workingDirectoryBinding)
                    .textFieldStyle(.roundedBorder)

                ForEach(Array(draft.executable.arguments.indices), id: \.self) { index in
                    HStack(spacing: 6) {
                        TextField("Argument \(index + 1)", text: argumentBinding(at: index))
                            .textFieldStyle(.roundedBorder)
                        Button("Remove argument \(index + 1)", systemImage: "minus.circle", role: .destructive) {
                            updateExecutable { $0.arguments.remove(at: index) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }

                Button("Add Argument", systemImage: "plus") {
                    updateExecutable { $0.arguments.append("") }
                }
                .disabled(draft.executable.arguments.count >= 64)

                Stepper(value: timeoutBinding, in: 1...60) {
                    Text("Timeout: \(draft.executable.timeoutSeconds) seconds")
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardContentPadding()
        }
    }

    private var fileImporterTypes: [UTType] {
        switch draft.nativeAction.kind {
        case .playSound: [.audio]
        case .openApplication: [.applicationBundle]
        case .openFile: [.item]
        default: [.item]
        }
    }

    private var targetFieldTitle: String {
        switch draft.nativeAction.kind {
        case .playSound: "Audio file path"
        case .openApplication: "Application path"
        case .openFile: "File path"
        default: "Target"
        }
    }

    private var filePickerTitle: String {
        switch draft.nativeAction.kind {
        case .playSound: "Choose Audio File…"
        case .openApplication: "Choose Application…"
        case .openFile: "Choose File…"
        default: "Choose…"
        }
    }

    private var targetBinding: Binding<String> {
        nativeBinding(
            get: { $0.target ?? "" },
            set: { $0.target = $1.isEmpty ? nil : $1 }
        )
    }

    private var topicBinding: Binding<String> {
        nativeBinding(
            get: { $0.topic ?? "" },
            set: { $0.topic = $1.isEmpty ? nil : $1 }
        )
    }

    private var textBinding: Binding<String> {
        nativeBinding(
            get: { $0.text ?? "" },
            set: { $0.text = $1.isEmpty ? nil : $1 }
        )
    }

    private var appIDBinding: Binding<String> {
        nativeBinding(
            get: { $0.appID ?? "" },
            set: { $0.appID = $1.isEmpty ? nil : $1 }
        )
    }

    private var expiryBinding: Binding<Int> {
        nativeBinding(
            get: { $0.ttlSeconds ?? 10 },
            set: { $0.ttlSeconds = $1 }
        )
    }

    private var workingDirectoryBinding: Binding<String> {
        executableStringBinding(
            get: { $0.workingDirectory ?? "" },
            set: { $0.workingDirectory = $1.isEmpty ? nil : $1 }
        )
    }

    private var timeoutBinding: Binding<Int> {
        Binding(
            get: { draft.executable.timeoutSeconds },
            set: { value in updateExecutable { $0.timeoutSeconds = value } }
        )
    }

    private func nativeBinding<Value>(
        get: @escaping (NativeAction) -> Value,
        set: @escaping (inout NativeAction, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { get(draft.nativeAction) },
            set: { value in
                updateNativeAction { action in set(&action, value) }
            }
        )
    }

    private func executableStringBinding(
        get: @escaping (ConfiguredExecutable) -> String,
        set: @escaping (inout ConfiguredExecutable, String) -> Void
    ) -> Binding<String> {
        Binding(
            get: { get(draft.executable) },
            set: { value in
                updateExecutable { executable in set(&executable, value) }
            }
        )
    }

    private func argumentBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                draft.executable.arguments.indices.contains(index) ? draft.executable.arguments[index] : ""
            },
            set: { value in
                updateExecutable { executable in
                    guard executable.arguments.indices.contains(index) else { return }
                    executable.arguments[index] = value
                }
            }
        )
    }

    private func updateNativeAction(_ update: (inout NativeAction) -> Void) {
        var action = draft.nativeAction
        update(&action)
        draft.nativeAction = action
    }

    private func updateExecutable(_ update: (inout ConfiguredExecutable) -> Void) {
        var executable = draft.executable
        update(&executable)
        draft.executable = executable
    }

    private func select(_ choice: ActionChoice) {
        importError = nil
        switch choice {
        case .none:
            draft = D200XPresetActionDraft()
        case .template(let template):
            draft = D200XPresetActionDraft(template: template)
        case .existing(let actionID):
            guard let definition = configuration?.actionDefinition(id: actionID) else {
                importError = "The selected configured action is no longer available."
                return
            }
            switch definition {
            case .executable(let action):
                draft = D200XPresetActionDraft(binding: .action(actionID), actions: [actionID: action], nativeActions: [:])
            case .native(let action):
                draft = D200XPresetActionDraft(binding: .action(actionID), actions: [:], nativeActions: [actionID: action])
            }
        case .current:
            break
        }
    }

    private func actionTitle(for actionID: String) -> String {
        guard let definition = configuration?.actionDefinition(id: actionID) else { return "Configured Action" }
        return switch definition {
        case .executable:
            "Custom Executable"
        case .native(let action):
            switch action.kind {
            case .media:
                switch action.media {
                case .some(.playPause): "Play/Pause"
                case .some(.nextTrack): "Next Track"
                case .some(.previousTrack): "Previous Track"
                case .none: "Playback"
                }
            case .volume:
                switch action.volume {
                case .some(.up): "Volume Up"
                case .some(.down): "Volume Down"
                case .some(.mute): "Mute"
                case .some(.set): "Set Volume"
                case .none: "Volume"
                }
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

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            updateNativeAction { $0.target = url.path }
            importError = nil
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            importError = error.localizedDescription
        }
    }
}
