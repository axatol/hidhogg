import HidhoggDomain
import SwiftUI

struct ActionsView: View {
    @ObservedObject var model: D200XModel
    let onOpenTile: (String?, String) -> Void
    @State private var selectedActionID: String?
    @State private var draftNativeAction: NativeAction?
    @State private var isCreatingNewAction = false
    @State private var newDraftID = UUID()

    private enum EditorIdentity: Hashable {
        case executable(String)
        case native(String)
        case executableDraft(UUID)
        case nativeDraft(UUID)
    }

    private enum ActionTemplate: String, CaseIterable, Identifiable {
        case playPause, nextTrack, previousTrack
        case volumeUp, volumeDown, volumeMute, volumeSet50
        case bell, playSound
        case openApplication, openFile, openURL
        case deckNotification, shortcut, customExecutable

        var id: Self { self }

        var title: String {
            switch self {
            case .playPause: "Play/Pause"
            case .nextTrack: "Next Track"
            case .previousTrack: "Previous Track"
            case .volumeUp: "Volume Up"
            case .volumeDown: "Volume Down"
            case .volumeMute: "Mute"
            case .volumeSet50: "Set Volume to 50%"
            case .bell: "Bell"
            case .playSound: "Play Sound…"
            case .openApplication: "Open Application…"
            case .openFile: "Open File…"
            case .openURL: "Open URL"
            case .deckNotification: "Deck Notification"
            case .shortcut: "Keyboard Shortcut"
            case .customExecutable: "Custom Executable"
            }
        }

        var symbol: String {
            switch self {
            case .playPause: "playpause.fill"
            case .nextTrack: "forward.end.fill"
            case .previousTrack: "backward.end.fill"
            case .volumeUp, .volumeSet50: "speaker.wave.2.fill"
            case .volumeDown: "speaker.wave.1.fill"
            case .volumeMute: "speaker.slash.fill"
            case .bell: "bell.fill"
            case .playSound: "waveform"
            case .openApplication: "app.badge"
            case .openFile: "doc"
            case .openURL: "link"
            case .deckNotification: "bell.badge"
            case .shortcut: "keyboard"
            case .customExecutable: "terminal"
            }
        }

        var nativeAction: NativeAction? {
            switch self {
            case .playPause: .init(kind: .media, media: .playPause)
            case .nextTrack: .init(kind: .media, media: .nextTrack)
            case .previousTrack: .init(kind: .media, media: .previousTrack)
            case .volumeUp: .init(kind: .volume, volume: .up)
            case .volumeDown: .init(kind: .volume, volume: .down)
            case .volumeMute: .init(kind: .volume, volume: .mute)
            case .volumeSet50: .init(kind: .volume, volume: .set, percent: 50)
            case .bell: .init(kind: .bell)
            case .playSound: .init(kind: .playSound, target: "/System/Library/Sounds/Glass.aiff")
            case .openApplication: .init(kind: .openApplication, target: "/System/Applications/Calculator.app")
            case .openFile: .init(kind: .openFile, target: "/System/Library/CoreServices/SystemVersion.plist")
            case .openURL: .init(kind: .openURL, target: "https://example.com")
            case .deckNotification: .init(kind: .deckNotification, topic: "hidhogg.test", text: "Notification", ttlSeconds: 10)
            case .shortcut: .init(
                kind: .shortcut,
                shortcut: KeyboardShortcut(keyCode: 0, modifiers: [.command, .option, .shift])
            )
            case .customExecutable: nil
            }
        }
    }

    private var actionIDs: [String] {
        model.configuration?.actionIDs ?? []
    }

    private var selection: Binding<String?> {
        Binding(
            get: { selectedActionID },
            set: {
                guard $0 != selectedActionID else { return }
                selectedActionID = $0
                draftNativeAction = nil
                newDraftID = UUID()
                isCreatingNewAction = $0 == nil
            }
        )
    }

    private var editorIdentity: EditorIdentity {
        if let selectedActionID,
           case .some(.native(_)) = model.configuration?.actionDefinition(id: selectedActionID) {
            return .native(selectedActionID)
        }
        if let selectedActionID { return .executable(selectedActionID) }
        return draftNativeAction == nil ? .executableDraft(newDraftID) : .nativeDraft(newDraftID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Actions")
                        .font(.title2.weight(.semibold))
                    Text("Create reusable actions here, then assign them to controls in the D200X inspector.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.isConfigured {
                    GroupBox("Deck configuration") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Create a local configuration before adding actions. You can edit it while disconnected.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Set Up Deck Configuration", systemImage: "plus.square") {
                                model.enableConfiguration()
                            }
                            .disabled(!model.canEdit)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }

                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Actions")
                                .font(.headline)
                            Spacer()
                            Menu("New Action", systemImage: "plus") {
                                Section("Playback") {
                                    templateButton(.playPause)
                                    templateButton(.nextTrack)
                                    templateButton(.previousTrack)
                                }
                                Section("Volume") {
                                    templateButton(.volumeUp)
                                    templateButton(.volumeDown)
                                    templateButton(.volumeMute)
                                    templateButton(.volumeSet50)
                                }
                                Section("Sound") {
                                    templateButton(.bell)
                                    templateButton(.playSound)
                                }
                                Section("Open") {
                                    templateButton(.openApplication)
                                    templateButton(.openFile)
                                    templateButton(.openURL)
                                }
                                Section("Other") {
                                    templateButton(.deckNotification)
                                    templateButton(.shortcut)
                                    templateButton(.customExecutable)
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .disabled(!model.canEdit || !model.isConfigured)
                        }
                        .padding(.horizontal, 8)

                        List(selection: selection) {
                            ForEach(actionIDs, id: \.self) { actionID in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(actionID)
                                    Text(actionTypeTitle(actionID))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(actionID)
                            }
                        }
                        .listStyle(.inset)
                    }
                    .frame(minWidth: 150, idealWidth: 190, maxWidth: 260, maxHeight: .infinity)

                    ScrollView {
                        actionEditor
                            .id(editorIdentity)
                            .padding(18)
                    }
                    .frame(minWidth: 320, minHeight: 400, maxHeight: .infinity)
                }
                .frame(minHeight: 420)

                D200XAutomationHistoryView(
                    model: model,
                    showNotifications: false,
                    onOpenTile: onOpenTile
                )
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
        .navigationTitle("Actions")
        .onAppear(perform: selectInitialAction)
        .onChange(of: selectedActionID) { oldValue, value in
            if value != nil {
                isCreatingNewAction = false
                draftNativeAction = nil
            } else if oldValue != nil {
                isCreatingNewAction = true
            }
        }
        .onChange(of: actionIDs) { _, ids in
            if let selectedActionID, !ids.contains(selectedActionID) {
                self.selectedActionID = nil
                isCreatingNewAction = true
                draftNativeAction = nil
                newDraftID = UUID()
            } else if selectedActionID == nil, !isCreatingNewAction, let firstActionID = ids.first {
                selectedActionID = firstActionID
            }
        }
    }

    @ViewBuilder
    private var actionEditor: some View {
        if let selectedActionID,
           case .some(.native(let action)) = model.configuration?.actionDefinition(id: selectedActionID) {
            NativeActionEditorView(
                model: model,
                selectedActionID: $selectedActionID,
                initialAction: action,
                onSaved: selectSavedAction,
                onRemoved: beginDraftFromRemovedAction
            )
        } else if selectedActionID != nil {
            D200XAutomationEditorView(model: model, selectedActionID: $selectedActionID)
        } else if let draftNativeAction {
            NativeActionEditorView(
                model: model,
                selectedActionID: $selectedActionID,
                initialAction: draftNativeAction,
                onSaved: selectSavedAction,
                onRemoved: beginDraftFromRemovedAction
            )
        } else {
            D200XAutomationEditorView(model: model, selectedActionID: $selectedActionID)
        }
    }

    private func templateButton(_ template: ActionTemplate) -> some View {
        Button(template.title, systemImage: template.symbol) {
            newDraftID = UUID()
            selectedActionID = nil
            draftNativeAction = template.nativeAction
            isCreatingNewAction = true
        }
    }

    private func actionTypeTitle(_ id: String) -> String {
        switch model.configuration?.actionDefinition(id: id) {
        case .some(.executable(_)): "Custom executable"
        case .some(.native(let action)): nativeActionTitle(action.kind)
        case nil: "Action"
        }
    }

    private func nativeActionTitle(_ kind: NativeAction.Kind) -> String {
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
        }
    }

    private func selectInitialAction() {
        guard selectedActionID == nil, !isCreatingNewAction else { return }
        selectedActionID = actionIDs.first
    }

    private func selectSavedAction(_ id: String) {
        selectedActionID = id
        draftNativeAction = nil
        isCreatingNewAction = false
    }

    private func beginDraftFromRemovedAction(_ action: NativeAction) {
        selectedActionID = nil
        newDraftID = UUID()
        draftNativeAction = action
        isCreatingNewAction = true
    }
}
