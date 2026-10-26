import AppKit
import Foundation
import HidhoggDomain
import MacOSActions
import SwiftUI
import UniformTypeIdentifiers

struct TilePresetEditorView: View {
    @ObservedObject var model: D200XModel
    @Binding var selectedID: String?
    @Binding var draftID: UUID
    let onSaved: (String) -> Void

    @State private var activeDraftID = UUID()
    @State private var originalPreset: D200XTilePreset?
    @State private var identifier = ""
    @State private var name = ""
    @State private var appearance = D200XTileAppearance()
    @State private var assignmentKind: AssignmentKind = .none
    @State private var shortcut: HidhoggDomain.KeyboardShortcut?
    @State private var actionChoice = ""
    @State private var selectedActionIdentifier: String?
    @State private var selectedActionSnapshot: ConfiguredActionDefinition?
    @State private var embeddedActionIdentifier: String?
    @State private var embeddedActionSnapshot: ConfiguredActionDefinition?
    @State private var isShortcutEditorPresented = false
    @State private var isImageImporterPresented = false
    @State private var isImportingImage = false
    @State private var errorMessage: String?

    private enum AssignmentKind: String, CaseIterable, Hashable, Identifiable {
        case none
        case shortcut
        case action

        var id: Self { self }

        var title: String {
            switch self {
            case .none: "None"
            case .shortcut: "Keyboard shortcut"
            case .action: "Configured action copy"
            }
        }
    }

    private var catalogActionIDs: [String] {
        model.configuration?.actionIDs ?? []
    }

    private var assignmentSelection: Binding<AssignmentKind> {
        Binding(get: { assignmentKind }, set: { assignmentKind = $0 })
    }

    private var actionChoiceSelection: Binding<String> {
        Binding(get: { actionChoice }, set: selectActionChoice)
    }

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { Self.color(forHex: appearance.backgroundHex) },
            set: { appearance.backgroundHex = Self.hex(for: $0) }
        )
    }

    private var titleColor: Binding<Color> {
        Binding(
            get: { Self.color(forHex: appearance.titleColorHex ?? "FFFFFF") },
            set: { appearance.titleColorHex = Self.hex(for: $0) }
        )
    }

    private var candidatePreset: D200XTilePreset? {
        let binding: D200XBinding?
        let actions: [String: ConfiguredExecutable]
        let nativeActions: [String: NativeAction]

        switch assignmentKind {
        case .none:
            binding = nil
            actions = [:]
            nativeActions = [:]
        case .shortcut:
            guard let shortcut else { return nil }
            binding = .key(shortcut)
            actions = [:]
            nativeActions = [:]
        case .action:
            guard let selectedActionIdentifier, let selectedActionSnapshot else { return nil }
            binding = .action(selectedActionIdentifier)
            switch selectedActionSnapshot {
            case .executable(let action):
                actions = [selectedActionIdentifier: action]
                nativeActions = [:]
            case .native(let action):
                actions = [:]
                nativeActions = [selectedActionIdentifier: action]
            }
        }

        return try? D200XTilePreset(
            name: name,
            appearance: appearance,
            binding: binding,
            actions: actions,
            nativeActions: nativeActions
        ).validated()
    }

    private var validationMessage: String? {
        guard ConfiguredExecutable.isValidIdentifier(identifier) else {
            return "Use a preset ID beginning with a letter or digit, up to 64 bytes."
        }
        if originalPreset == nil, model.configuration?.tilePresets[identifier] != nil {
            return "That preset ID is already in use."
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64 else {
            return "Enter a name of at most 64 characters."
        }
        guard appearance.isValid() else {
            return "Check the label, colors and title size."
        }
        if assignmentKind == .shortcut, shortcut == nil {
            return "Choose a keyboard shortcut for this preset."
        }
        if assignmentKind == .action, selectedActionSnapshot == nil {
            return "Choose a configured action to embed in this preset."
        }
        guard candidatePreset != nil else { return "Review the preset fields before saving." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedID == nil ? "New tile preset" : "Edit tile preset")
                    .font(.title2.weight(.semibold))
                Text("Changes stay in this draft until you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            previewPair

            GroupBox("Preset") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Preset ID", text: $identifier)
                        .textFieldStyle(.roundedBorder)
                        .disabled(originalPreset != nil || !model.canEdit)
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canEdit)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            appearanceEditor
            assignmentEditor

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Save Preset", systemImage: "square.and.arrow.down", action: savePreset)
                .disabled(!model.canEdit || !model.isConfigured || isImportingImage || validationMessage != nil)
        }
        .onAppear(perform: loadDraft)
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.png, .jpeg],
            allowsMultipleSelection: false,
            onCompletion: handleImageImporterResult
        )
        .sheet(isPresented: $isShortcutEditorPresented) {
            ShortcutEditorView(
                initialShortcut: shortcut,
                onCancel: { isShortcutEditorPresented = false },
                onCommit: { value in
                    shortcut = value
                    assignmentKind = .shortcut
                    isShortcutEditorPresented = false
                }
            )
        }
        .alert("Tile preset", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The preset could not be saved.")
        }
    }

    private var previewPair: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Text("Square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                D200XTilePreview(
                    appearance: appearance,
                    wide: false,
                    labelOverride: nil,
                    assetDirectory: model.assetDirectory
                )
                .frame(width: 92, height: 92)
            }
            VStack(spacing: 4) {
                Text("Wide")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                D200XTilePreview(
                    appearance: appearance,
                    wide: true,
                    labelOverride: nil,
                    assetDirectory: model.assetDirectory
                )
                .frame(width: 164, height: 92)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceEditor: some View {
        GroupBox("Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Tile text", text: $appearance.label)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canEdit)

                ColorPicker("Background color", selection: backgroundColor, supportsOpacity: false)
                    .disabled(!model.canEdit)
                TextField("Background hex", text: $appearance.backgroundHex)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Background color as six hexadecimal digits")
                    .disabled(!model.canEdit)

                Toggle("Show title", isOn: $appearance.showTitle)
                    .disabled(!model.canEdit)
                HStack {
                    Text("Title size")
                    Spacer()
                    Text("\(Int(appearance.titleSize)) pt")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $appearance.titleSize, in: 8...48, step: 1)
                    .disabled(!model.canEdit)

                Picker("Title placement", selection: $appearance.titlePlacement) {
                    Text("Top").tag(D200XTitlePlacement.top)
                    Text("Center").tag(D200XTitlePlacement.center)
                    Text("Bottom").tag(D200XTitlePlacement.bottom)
                }
                .disabled(!model.canEdit)
                Picker("Title alignment", selection: $appearance.titleAlignment) {
                    Text("Left").tag(D200XTitleAlignment.left)
                    Text("Center").tag(D200XTitleAlignment.center)
                    Text("Right").tag(D200XTitleAlignment.right)
                }
                .disabled(!model.canEdit)

                Toggle("Use custom title color", isOn: Binding(
                    get: { appearance.titleColorHex != nil },
                    set: { appearance.titleColorHex = $0 ? (appearance.titleColorHex ?? "FFFFFF") : nil }
                ))
                .disabled(!model.canEdit)
                if appearance.titleColorHex != nil {
                    ColorPicker("Title color", selection: titleColor, supportsOpacity: false)
                        .disabled(!model.canEdit)
                    TextField("Title color hex", text: Binding(
                        get: { appearance.titleColorHex ?? "FFFFFF" },
                        set: { appearance.titleColorHex = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Title color as six hexadecimal digits")
                    .disabled(!model.canEdit)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appearance.imageAsset == nil ? "No image" : "Image included")
                        Text("PNG or JPEG")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Image…", systemImage: "photo") {
                        isImageImporterPresented = true
                    }
                    .disabled(!model.canEdit || !model.isConfigured || isImportingImage)
                }
                if appearance.imageAsset != nil {
                    Button("Remove Image", systemImage: "trash") {
                        appearance.imageAsset = nil
                    }
                    .disabled(!model.canEdit || isImportingImage)
                }
                if isImportingImage {
                    ProgressView("Importing image…")
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var assignmentEditor: some View {
        GroupBox("Optional shortcut or action") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Assignment", selection: assignmentSelection) {
                    ForEach(AssignmentKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .disabled(!model.canEdit)

                if assignmentKind == .shortcut {
                    HStack {
                        Text(shortcut.map { ShortcutSender.label(for: $0) } ?? "No shortcut selected")
                            .font(.callout)
                            .foregroundStyle(shortcut == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose Manually…", systemImage: "keyboard") {
                            isShortcutEditorPresented = true
                        }
                        .disabled(!model.canEdit)
                    }
                }

                if assignmentKind == .action {
                    Picker("Configured action", selection: actionChoiceSelection) {
                        Text("Choose action…").tag("")
                        if let embeddedActionIdentifier {
                            Text("Saved embedded copy · \(embeddedActionIdentifier)").tag("embedded")
                        }
                        if let selectedActionIdentifier,
                           !catalogActionIDs.contains(selectedActionIdentifier),
                           actionChoice == "catalog:\(selectedActionIdentifier)" {
                            Text("Selected copy · \(selectedActionIdentifier)").tag(actionChoice)
                        }
                        ForEach(catalogActionIDs, id: \.self) { actionID in
                            Text("Catalog copy · \(actionID)").tag("catalog:\(actionID)")
                        }
                    }
                    .disabled(!model.canEdit)

                    if let selectedActionIdentifier, let selectedActionSnapshot {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Embedded immutable copy")
                                .font(.caption.weight(.semibold))
                            Text("ID: \(selectedActionIdentifier)")
                            Text(actionSnapshotLines(selectedActionSnapshot).joined(separator: "\n"))
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The preset keeps this action snapshot even if the catalog changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func loadDraft() {
        activeDraftID = draftID
        errorMessage = nil

        guard let selectedID, let preset = model.configuration?.tilePresets[selectedID] else {
            originalPreset = nil
            identifier = ""
            name = ""
            appearance = D200XTileAppearance()
            assignmentKind = .none
            shortcut = nil
            actionChoice = ""
            selectedActionIdentifier = nil
            selectedActionSnapshot = nil
            embeddedActionIdentifier = nil
            embeddedActionSnapshot = nil
            return
        }

        originalPreset = preset
        identifier = selectedID
        name = preset.name
        appearance = preset.appearance
        let binding = preset.binding ?? .disabled
        shortcut = binding.shortcut
        switch binding.kind {
        case .disabled:
            assignmentKind = .none
            actionChoice = ""
            selectedActionIdentifier = nil
            selectedActionSnapshot = nil
            embeddedActionIdentifier = nil
            embeddedActionSnapshot = nil
        case .shortcut:
            assignmentKind = .shortcut
            actionChoice = ""
            selectedActionIdentifier = nil
            selectedActionSnapshot = nil
            embeddedActionIdentifier = nil
            embeddedActionSnapshot = nil
        case .action:
            assignmentKind = .action
            embeddedActionIdentifier = binding.actionID
            embeddedActionSnapshot = binding.actionID.flatMap { actionID in
                if let action = preset.actions[actionID] { return .executable(action) }
                if let action = preset.nativeActions[actionID] { return .native(action) }
                return nil
            }
            selectedActionIdentifier = embeddedActionIdentifier
            selectedActionSnapshot = embeddedActionSnapshot
            actionChoice = embeddedActionSnapshot == nil ? "" : "embedded"
        }
    }

    private func selectActionChoice(_ choice: String) {
        guard !choice.isEmpty else {
            actionChoice = ""
            selectedActionIdentifier = nil
            selectedActionSnapshot = nil
            return
        }
        if choice == "embedded" {
            actionChoice = choice
            selectedActionIdentifier = embeddedActionIdentifier
            selectedActionSnapshot = embeddedActionSnapshot
            return
        }
        guard choice.hasPrefix("catalog:") else { return }
        let actionID = String(choice.dropFirst("catalog:".count))
        guard let action = model.configuration?.actionDefinition(id: actionID) else {
            errorMessage = "The selected catalog action is no longer available."
            return
        }
        actionChoice = choice
        selectedActionIdentifier = actionID
        selectedActionSnapshot = action
    }

    private func actionSnapshotLines(_ definition: ConfiguredActionDefinition) -> [String] {
        switch definition {
        case .executable(let action):
            return [
                "Custom executable: \(action.executable)",
                "Arguments: \(action.arguments.joined(separator: " · "))",
                "Working directory: \(action.workingDirectory ?? "None") · Timeout: \(action.timeoutSeconds)s"
            ]
        case .native(let action):
            switch action.kind {
            case .media:
                let operation: String
                switch action.media {
                case .some(.playPause): operation = "Play/Pause"
                case .some(.nextTrack): operation = "Next Track"
                case .some(.previousTrack): operation = "Previous Track"
                case .none: operation = "Unknown"
                }
                return ["Native media action: \(operation)"]
            case .volume:
                let operation: String
                switch action.volume {
                case .some(.up): operation = "Up"
                case .some(.down): operation = "Down"
                case .some(.mute): operation = "Mute"
                case .some(.set): operation = "Set to \(action.percent ?? 0)%"
                case .none: operation = "Unknown"
                }
                return ["Native volume action: \(operation)"]
            case .bell:
                return ["System alert sound"]
            case .playSound:
                return ["Audio file: \(action.target ?? "Unknown")"]
            case .openApplication:
                return ["Application: \(action.target ?? "Unknown")"]
            case .openFile:
                return ["File: \(action.target ?? "Unknown")"]
            case .openURL:
                return ["URL: \(action.target ?? "Unknown")"]
            case .deckNotification:
                return [
                    "Deck notification topic: \(action.topic ?? "Unknown")",
                    "Text: \(action.text ?? "Unknown")",
                    "Expiry: \(action.ttlSeconds.map { "\($0) seconds" } ?? "None")"
                ]
            case .shortcut:
                return ["Keyboard shortcut: \(action.shortcut.map { ShortcutSender.label(for: $0) } ?? "Unknown")"]
            }
        }
    }

    private func handleImageImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importImage(from: url)
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func importImage(from url: URL) {
        let expectedDraftID = activeDraftID
        let expectedSelectedID = selectedID
        guard isCurrentDraft(expectedDraftID, selectedID: expectedSelectedID) else { return }
        isImportingImage = true

        Task { @MainActor in
            do {
                let reference = try await model.importPresetImage(from: url)
                guard isCurrentDraft(expectedDraftID, selectedID: expectedSelectedID) else { return }
                appearance.imageAsset = reference
                errorMessage = nil
            } catch is CancellationError {
                if isCurrentDraft(expectedDraftID, selectedID: expectedSelectedID) { isImportingImage = false }
                return
            } catch {
                guard isCurrentDraft(expectedDraftID, selectedID: expectedSelectedID) else { return }
                errorMessage = error.localizedDescription
            }
            if isCurrentDraft(expectedDraftID, selectedID: expectedSelectedID) { isImportingImage = false }
        }
    }

    private func isCurrentDraft(_ expectedDraftID: UUID, selectedID expectedSelectedID: String?) -> Bool {
        activeDraftID == expectedDraftID && draftID == expectedDraftID && selectedID == expectedSelectedID
    }

    private func savePreset() {
        guard model.canEdit, model.isConfigured, let preset = candidatePreset else { return }
        do {
            try model.saveTilePreset(id: identifier, preset: preset, replacing: originalPreset)
            originalPreset = preset
            errorMessage = nil
            onSaved(identifier)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func color(forHex hex: String) -> Color {
        guard hex.utf8.count == 6, let value = UInt32(hex, radix: 16) else { return .gray }
        return Color(
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255
        )
    }

    private static func hex(for color: Color) -> String {
        let rgb = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
