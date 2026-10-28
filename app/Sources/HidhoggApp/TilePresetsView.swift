import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI
import UniformTypeIdentifiers

struct TilePresetsView: View {
    @ObservedObject var model: D200XModel
    @State private var selectedID: String?
    @State private var draftID = UUID()
    @State private var hasInitializedSelection = false
    @State private var includesAction = false
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var document = TilePresetDocument(data: Data())
    @State private var pendingPackage: D200XTilePresetPackage?
    @State private var importID = ""
    @State private var importAssignment = false
    @State private var errorMessage: String?

    private enum EditorIdentity: Hashable {
        case saved(String)
        case draft(UUID)
    }

    private var presets: [String: D200XTilePreset] {
        model.configuration?.tilePresets ?? [:]
    }

    private var presetIDs: [String] {
        presets.keys.sorted()
    }

    private var editorIdentity: EditorIdentity {
        selectedID.map { EditorIdentity.saved($0) } ?? .draft(draftID)
    }

    private var presetSelection: Binding<String?> {
        Binding(
            get: { selectedID },
            set: {
                guard $0 != selectedID else { return }
                hasInitializedSelection = true
                draftID = UUID()
                selectedID = $0
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tile presets")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Import…", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                .disabled(!model.canEdit || !model.isConfigured)
                Button("Paste", systemImage: "doc.on.clipboard") {
                    pastePreset()
                }
                .disabled(!model.canEdit || !model.isConfigured)
            }

            if !model.isConfigured {
                HStack {
                    Text("Create a local configuration before saving presets.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Set Up Deck Configuration", systemImage: "plus.square") {
                        model.enableConfiguration()
                    }
                    .disabled(!model.canEdit)
                }
            }

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Library")
                            .font(.headline)
                        Spacer()
                        Button {
                            hasInitializedSelection = true
                            draftID = UUID()
                            selectedID = nil
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New Preset")
                        .accessibilityLabel("New Preset")
                        .disabled(!model.canEdit || !model.isConfigured)
                    }
                    .padding(.horizontal, 8)

                    List(selection: presetSelection) {
                        if presetIDs.isEmpty {
                            ContentUnavailableView("No presets", systemImage: "square.grid.2x2")
                        } else {
                            ForEach(presetIDs, id: \.self) { id in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(presets[id]?.name ?? id)
                                    Text(id)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .tag(id)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 250, maxHeight: .infinity)

                VStack(spacing: 0) {
                    ScrollView {
                        TilePresetEditorView(
                            model: model,
                            selectedID: $selectedID,
                            draftID: $draftID,
                            onSaved: selectSavedPreset
                        )
                        .id(editorIdentity)
                        .padding(16)
                    }
                    .frame(maxHeight: .infinity)

                    if let id = selectedID, let preset = presets[id] {
                        Divider()
                        selectedPresetActions(id: id, preset: preset)
                    }
                }
                .frame(minWidth: 320, minHeight: 400, maxHeight: .infinity)
            }
            .frame(minHeight: 420)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Tile presets")
        .onAppear(perform: selectInitialPreset)
        .onChange(of: presetIDs) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
                draftID = UUID()
            } else if !hasInitializedSelection, let firstID = ids.first {
                hasInitializedSelection = true
                selectedID = firstID
            }
        }
        .onChange(of: selectedID) { _, _ in includesAction = false }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result, let directory = model.assetDirectory else { return }
            Task { @MainActor in
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let package = try await Task.detached(priority: .utility) {
                        try D200XTilePresetPackage.read(from: url, assetDirectory: directory)
                    }.value
                    prepareImport(package)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .json,
            defaultFilename: "\(selectedID ?? "tile").hidhogg-tile"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { pendingPackage != nil }, set: { if !$0 { pendingPackage = nil } })) {
            importReview
        }
        .alert("Tile presets", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func selectedPresetActions(id: String, preset: D200XTilePreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apply copy to \(model.selectedControl.title) · \(model.applicationID ?? "Default")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Include optional shortcut or action", isOn: $includesAction)
                .disabled(preset.binding == nil || !model.canEdit)
            HStack {
                Button("Apply Copy") {
                    perform { try model.applyTilePreset(id: id, includeAction: includesAction) }
                }
                .disabled(!model.canEdit || !model.isConfigured || !model.selectedControl.isTile)
                Spacer()
                Menu("More", systemImage: "ellipsis") {
                    Button("Copy", systemImage: "doc.on.doc") { copyPreset(id: id) }
                    Button("Export…", systemImage: "square.and.arrow.up") { exportPreset(id: id) }
                    Divider()
                    Button("Remove Preset", systemImage: "trash", role: .destructive) {
                        model.removeTilePreset(id: id)
                        selectedID = nil
                        draftID = UUID()
                    }
                    .disabled(!model.canEdit)
                }
            }
        }
        .padding(10)
    }

    private var importReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review preset import")
                .font(.title2.bold())
            Text(pendingPackage?.preset.name ?? "")
            TextField("New preset ID", text: $importID)
                .textFieldStyle(.roundedBorder)
            if let package = pendingPackage, package.preset.binding != nil {
                Toggle("Include optional shortcut or action", isOn: $importAssignment)
                ForEach(package.preset.actions.keys.sorted(), id: \.self) { id in
                    if let action = package.preset.actions[id] {
                        Text("\(id): Custom executable\nPath: \(action.executable)\nArguments: \(action.arguments.joined(separator: "\n"))\nWorking directory: \(action.workingDirectory ?? "None")\nTimeout: \(action.timeoutSeconds) seconds")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                ForEach(package.preset.nativeActions.keys.sorted(), id: \.self) { id in
                    if let action = package.preset.nativeActions[id] {
                        Text("\(id): \(nativeActionSummary(action))")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if package.preset.binding?.kind == .shortcut, let shortcut = package.preset.binding?.shortcut {
                    Text("Keyboard shortcut · key code \(shortcut.keyCode) · modifiers \(shortcut.modifiers.map(\.rawValue).joined(separator: ", "))")
                        .font(.caption.monospaced())
                }
                Text("Import saves a copy. Included actions run only when explicitly invoked or assigned and pressed.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { pendingPackage = nil }
                Button("Import Copy") { importReviewedPreset() }
                    .disabled(!model.canEdit || !ConfiguredExecutable.isValidIdentifier(importID) || presets[importID] != nil)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func selectInitialPreset() {
        guard !hasInitializedSelection, let firstID = presetIDs.first else { return }
        hasInitializedSelection = true
        selectedID = firstID
    }

    private func selectSavedPreset(_ id: String) {
        hasInitializedSelection = true
        selectedID = id
    }

    private func importReviewedPreset() {
        guard let package = pendingPackage else { return }
        do {
            try model.importTilePreset(package, id: importID, includeAction: importAssignment)
            selectSavedPreset(importID)
            pendingPackage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func nativeActionSummary(_ action: NativeAction) -> String {
        return switch action.kind {
        case .media:
            switch action.media {
            case .some(.playPause): "Media · Play/Pause"
            case .some(.nextTrack): "Media · Next Track"
            case .some(.previousTrack): "Media · Previous Track"
            case .none: "Media · Unknown operation"
            }
        case .volume:
            switch action.volume {
            case .some(.up): "Volume · Up"
            case .some(.down): "Volume · Down"
            case .some(.mute): "Volume · Mute"
            case .some(.set): "Volume · Set to \(action.percent ?? 0)%"
            case .none: "Volume · Unknown operation"
            }
        case .bell:
            "System alert sound"
        case .playSound:
            "Play sound · \(action.target ?? "Unknown audio file")"
        case .openApplication:
            "Open application · \(action.target ?? "Unknown application")"
        case .openFile:
            "Open file · \(action.target ?? "Unknown file")"
        case .openURL:
            "Open URL · \(action.target ?? "Unknown URL")"
        case .deckNotification:
            [
                "Deck notification",
                "topic \(action.topic ?? "Unknown")",
                action.appID.map { "bundle ID \($0)" },
                action.text.map { "text \($0)" },
                "expiry \(action.ttlSeconds.map { "\($0)s" } ?? "none")"
            ].compactMap { $0 }.joined(separator: " · ")
        case .shortcut:
            "Keyboard shortcut · \(action.shortcut.map { ShortcutSender.label(for: $0) } ?? "Unknown")"
        }
    }

    private func copyPreset(id: String) {
        perform {
            let data = try model.tilePresetPackage(id: id).encoded()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .init("app.hidhogg.tile-preset"))
        }
    }

    private func exportPreset(id: String) {
        perform {
            document = TilePresetDocument(data: try model.tilePresetPackage(id: id).encoded())
            isExporting = true
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { errorMessage = error.localizedDescription }
    }

    private func prepareImport(_ package: D200XTilePresetPackage) {
        importID = ""
        importAssignment = false
        pendingPackage = package
    }

    private func pastePreset() {
        perform {
            guard let data = NSPasteboard.general.data(forType: .init("app.hidhogg.tile-preset")),
                  let directory = model.assetDirectory else {
                throw D200XTilePresetPackage.Failure.invalidPackage
            }
            prepareImport(try D200XTilePresetPackage.decode(data, assetDirectory: directory))
        }
    }
}

private struct TilePresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
