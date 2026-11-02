import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI
import UniformTypeIdentifiers

struct TilePresetsView: View {
    @ObservedObject var model: D200XModel
    @State private var category: Category = .tiles
    @State private var tileSelection: TileSelection = .blank
    @State private var rotationSelection: RotationSelection = .blank
    @State private var selectedTileID: String?
    @State private var selectedRotationID: String?
    @State private var tileDraftID = UUID()
    @State private var rotationDraftID = UUID()
    @State private var rotationStarterPreset: D200XDialRotationPreset?
    @State private var hasInitializedSelection = false
    @State private var searchText = ""
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var document = TilePresetDocument(data: Data())
    @State private var exportFilename = "preset.json"
    @State private var pendingImport: D200XPresetImportPackage?
    @State private var pendingImportName = ""
    @State private var pendingImportID = ""
    @State private var errorMessage: String?

    private enum Category: String, CaseIterable, Identifiable {
        case tiles
        case dialRotation

        var id: Self { self }

        var title: String {
            switch self {
            case .tiles: "Tiles & Press"
            case .dialRotation: "Dial Rotation"
            }
        }
    }

    private enum TileSelection: Hashable {
        case blank
        case template(D200XActionTemplate)
        case saved(String)
    }

    private enum RotationSelection: Hashable {
        case blank
        case starter(D200XPresetRotationStarter)
        case saved(String)
    }

    private var tilePresets: [String: D200XTilePreset] {
        model.configuration?.tilePresets ?? [:]
    }

    private var rotationPresets: [String: D200XDialRotationPreset] {
        model.configuration?.dialRotationPresets ?? [:]
    }

    private var tilePresetIDs: [String] {
        tilePresets.keys.sorted { firstID, secondID in
            let firstName = tilePresets[firstID]?.name ?? firstID
            let secondName = tilePresets[secondID]?.name ?? secondID
            let order = firstName.localizedStandardCompare(secondName)
            return order == .orderedSame
                ? firstID.localizedStandardCompare(secondID) == .orderedAscending
                : order == .orderedAscending
        }
    }

    private var rotationPresetIDs: [String] {
        rotationPresets.keys.sorted { firstID, secondID in
            let firstName = rotationPresets[firstID]?.name ?? firstID
            let secondName = rotationPresets[secondID]?.name ?? secondID
            let order = firstName.localizedStandardCompare(secondName)
            return order == .orderedSame
                ? firstID.localizedStandardCompare(secondID) == .orderedAscending
                : order == .orderedAscending
        }
    }

    private var filteredTilePresetIDs: [String] {
        filter(tilePresetIDs) { tilePresets[$0]?.name ?? $0 }
    }

    private var filteredRotationPresetIDs: [String] {
        filter(rotationPresetIDs) { rotationPresets[$0]?.name ?? $0 }
    }

    private var filteredActionTemplates: [D200XActionTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return D200XActionTemplate.allCases }
        return D200XActionTemplate.allCases.filter { $0.title.localizedStandardContains(query) }
    }

    private var selectedDialIndex: Int? {
        let control = model.selectedControl
        guard control.gesture != nil, (17...19).contains(control.wireIndex) else { return nil }
        return control.wireIndex - 17
    }

    private var canApplyTilePreset: Bool {
        let control = model.selectedControl
        return control.isTile || control == .side0 || control == .side1 || control.gesture == .press
    }

    private var editorIdentity: UUID {
        category == .tiles ? tileDraftID : rotationDraftID
    }

    private var pendingImportNameIsValid: Bool {
        let value = pendingImportName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 64
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Tile Presets")
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

            Picker("Preset group", selection: $category) {
                ForEach(Category.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)

            HSplitView {
                libraryList
                    .frame(minWidth: 190, idealWidth: 250, maxWidth: 320, maxHeight: .infinity)

                VStack(spacing: 0) {
                    ScrollView {
                        libraryEditor
                            .id(editorIdentity)
                            .padding(16)
                    }
                    .frame(maxHeight: .infinity)

                    if case .saved(let id) = tileSelection, category == .tiles,
                       let preset = tilePresets[id] {
                        Divider()
                        selectedTileActions(id: id, preset: preset)
                    } else if case .saved(let id) = rotationSelection, category == .dialRotation,
                              let preset = rotationPresets[id] {
                        Divider()
                        selectedRotationActions(id: id, preset: preset)
                    }
                }
                .frame(minWidth: 360, minHeight: 400, maxHeight: .infinity)
            }
            .frame(minHeight: 420)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Tile Presets")
        .onAppear(perform: selectInitialPreset)
        .onChange(of: tilePresetIDs) { _, ids in
            if case .saved(let id) = tileSelection, !ids.contains(id) {
                selectTile(.blank)
            } else if !hasInitializedSelection, let firstID = ids.first {
                selectTile(.saved(firstID))
                hasInitializedSelection = true
            }
        }
        .onChange(of: rotationPresetIDs) { _, ids in
            if case .saved(let id) = rotationSelection, !ids.contains(id) {
                selectRotation(.blank)
            } else if category == .dialRotation, rotationSelection == .blank,
                      !hasInitializedSelection, let firstID = ids.first {
                selectRotation(.saved(firstID))
                hasInitializedSelection = true
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result, let directory = model.assetDirectory else { return }
            Task { @MainActor in
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let imported = try await Task.detached(priority: .utility) {
                        try D200XPresetImportPackage.read(from: url, assetDirectory: directory)
                    }.value
                    prepareImport(imported)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            importReview
        }
        .alert("Tile Presets", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Library")
                    .font(.headline)
                Spacer()
                Button {
                    if category == .tiles { selectTile(.blank) }
                    else { selectRotation(.blank) }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(category == .tiles ? "New Tile Preset" : "New Dial Rotation Preset")
                .accessibilityLabel(category == .tiles ? "New Tile Preset" : "New Dial Rotation Preset")
                .disabled(!model.canEdit || !model.isConfigured)
            }
            .padding(.horizontal, 8)

            TextField("Search library", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)

            List {
                if category == .tiles {
                    Section("Tiles & Press") {
                        if filteredTilePresetIDs.isEmpty {
                            Text("No saved tile presets")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredTilePresetIDs, id: \.self) { id in
                                if let preset = tilePresets[id] {
                                    tileRow(.saved(id), title: preset.name, symbol: actionPresentation(preset).systemSymbol,
                                            subtitle: actionPresentation(preset).summary)
                                }
                            }
                        }
                    }

                    Section("Built-in defaults") {
                        tileRow(.blank, title: "Blank", symbol: "square", subtitle: "No action")
                        ForEach(filteredActionTemplates, id: \.id) { template in
                            tileRow(.template(template), title: template.title, symbol: template.systemSymbol,
                                    subtitle: template.requiresConfiguration ? "Configure before saving" : template.title)
                        }
                    }
                } else {
                    Section("Dial Rotation") {
                        if filteredRotationPresetIDs.isEmpty {
                            Text("No saved rotation presets")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filteredRotationPresetIDs, id: \.self) { id in
                                if let preset = rotationPresets[id] {
                                    rotationRow(.saved(id), title: preset.name, subtitle: rotationSummary(preset))
                                }
                            }
                        }
                    }

                    Section("Built-in starters") {
                        ForEach(D200XPresetRotationStarter.allCases.filter(matchesSearch), id: \.id) { starter in
                            rotationRow(.starter(starter), title: starter.title, subtitle: starter.subtitle)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var libraryEditor: some View {
        if category == .tiles {
            TilePresetEditorView(
                model: model,
                selectedID: $selectedTileID,
                draftID: $tileDraftID,
                onSaved: { selectTile(.saved($0)) },
                initialTemplate: selectedTileTemplate
            )
        } else {
            DialRotationPresetEditorView(
                model: model,
                selectedID: $selectedRotationID,
                draftID: $rotationDraftID,
                onSaved: { selectRotation(.saved($0)) },
                initialPreset: selectedRotationInitialPreset
            )
        }
    }

    private var selectedTileTemplate: D200XActionTemplate? {
        guard case .template(let template) = tileSelection else { return nil }
        return template
    }

    private var selectedRotationInitialPreset: D200XDialRotationPreset? {
        rotationStarterPreset
    }

    @ViewBuilder
    private func tileRow(_ selection: TileSelection, title: String, symbol: String, subtitle: String) -> some View {
        Button { selectTile(selection) } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: symbol)
                    .frame(width: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(selection == tileSelection ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    @ViewBuilder
    private func rotationRow(_ selection: RotationSelection, title: String, subtitle: String) -> some View {
        let symbols = rotationSymbols(selection)
        Button { selectRotation(selection) } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } icon: {
                HStack(spacing: 1) {
                    Image(systemName: symbols.0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                    Image(systemName: symbols.1)
                }
                .frame(width: 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(selection == rotationSelection ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    private func selectedTileActions(id: String, preset: D200XTilePreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(preset.name) · apply copy to \(model.selectedControl.title) · \(model.applicationID ?? "All Apps")")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Apply Copy") {
                    perform { try model.applyTilePreset(id: id) }
                }
                .disabled(!model.canEdit || !model.isConfigured || !canApplyTilePreset)
                Spacer()
                Menu("More", systemImage: "ellipsis") {
                    Button("Copy", systemImage: "doc.on.doc") { copyTilePackage(id: id) }
                    Button("Duplicate Preset", systemImage: "plus.square.on.square") { copyTilePreset(id: id) }
                        .disabled(!model.canEdit || !model.isConfigured)
                    Button("Export…", systemImage: "square.and.arrow.up") { exportTilePreset(id: id) }
                    Divider()
                    Button("Remove Preset", systemImage: "trash", role: .destructive) {
                        model.removeTilePreset(id: id)
                        selectTile(.blank)
                    }
                    .disabled(!model.canEdit)
                }
            }
        }
        .padding(10)
    }

    private func selectedRotationActions(id: String, preset: D200XDialRotationPreset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(preset.name) · apply both directions to Dial \((selectedDialIndex ?? 0) + 1) · \(model.applicationID ?? "All Apps")")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Apply Copy") {
                    guard let dialIndex = selectedDialIndex else { return }
                    perform { try model.applyDialRotationPreset(id: id, dialIndex: dialIndex) }
                }
                .disabled(!model.canEdit || !model.isConfigured || selectedDialIndex == nil)
                Spacer()
                Menu("More", systemImage: "ellipsis") {
                    Button("Copy", systemImage: "doc.on.doc") { copyRotationPackage(id: id) }
                    Button("Duplicate Preset", systemImage: "plus.square.on.square") { copyRotationPreset(id: id) }
                        .disabled(!model.canEdit || !model.isConfigured)
                    Button("Export…", systemImage: "square.and.arrow.up") { exportRotationPreset(id: id) }
                    Divider()
                    Button("Remove Preset", systemImage: "trash", role: .destructive) {
                        model.removeDialRotationPreset(id: id)
                        selectRotation(.blank)
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

            TextField("Preset name", text: $pendingImportName)
                .textFieldStyle(.roundedBorder)

            if let pendingImport {
                GroupBox("Included assignments") {
                    Text(importSummary(pendingImport))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                Text("The action definitions stay inside the imported preset. Importing does not run them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) { pendingImport = nil }
                Spacer()
                Button("Import Copy") { importReviewedPreset() }
                    .disabled(!model.canEdit || !model.isConfigured || !pendingImportNameIsValid || pendingImport == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func actionPresentation(_ preset: D200XTilePreset) -> D200XPresetActionPresentation {
        D200XPresetActionPresentation(binding: preset.binding, actions: preset.actions, nativeActions: preset.nativeActions)
    }

    private func rotationSummary(_ preset: D200XDialRotationPreset) -> String {
        let left = D200XPresetActionPresentation(binding: preset.left, actions: preset.actions, nativeActions: preset.nativeActions)
        let right = D200XPresetActionPresentation(binding: preset.right, actions: preset.actions, nativeActions: preset.nativeActions)
        return "Left: \(left.summary) · Right: \(right.summary)"
    }

    private func rotationSymbols(_ selection: RotationSelection) -> (String, String) {
        switch selection {
        case .blank:
            return ("minus.circle", "minus.circle")
        case .starter(.volume):
            return ("speaker.wave.1.fill", "speaker.wave.2.fill")
        case .starter(.previousNext):
            return ("backward.end.fill", "forward.end.fill")
        case .saved(let id):
            guard let preset = rotationPresets[id] else { return ("minus.circle", "minus.circle") }
            let left = D200XPresetActionPresentation(binding: preset.left, actions: preset.actions, nativeActions: preset.nativeActions)
            let right = D200XPresetActionPresentation(binding: preset.right, actions: preset.actions, nativeActions: preset.nativeActions)
            return (left.systemSymbol, right.systemSymbol)
        }
    }

    private func importSummary(_ imported: D200XPresetImportPackage) -> String {
        switch imported.package {
        case .tile(let package):
            let assignment = importAssignmentSummary(
                package.preset.binding,
                actions: package.preset.actions,
                nativeActions: package.preset.nativeActions
            )
            return "Tiles & Press · \(package.preset.appearance.label)\n\(assignment)"
        case .dialRotation(let package):
            let preset = package.preset
            let left = importAssignmentSummary(preset.left, actions: preset.actions, nativeActions: preset.nativeActions)
            let right = importAssignmentSummary(preset.right, actions: preset.actions, nativeActions: preset.nativeActions)
            return "Dial Rotation\nLeft: \(left)\nRight: \(right)"
        }
    }

    private func importAssignmentSummary(
        _ binding: D200XBinding?,
        actions: [String: ConfiguredExecutable],
        nativeActions: [String: NativeAction]
    ) -> String {
        guard let binding else { return "No action" }
        switch binding.kind {
        case .disabled:
            return "No action"
        case .shortcut:
            return "Keyboard shortcut · \(binding.shortcut.map { ShortcutSender.label(for: $0) } ?? "Unavailable")"
        case .action:
            guard let id = binding.actionID else { return "Unavailable action" }
            if let action = actions[id] {
                return [
                    "Custom Executable · \(action.executable)",
                    "Arguments: \(action.arguments.joined(separator: " "))",
                    "Working directory: \(action.workingDirectory ?? "None")",
                    "Timeout: \(action.timeoutSeconds) seconds"
                ].joined(separator: "\n")
            }
            if let action = nativeActions[id] { return nativeActionSummary(action) }
            return "Unavailable action"
        }
    }

    private func nativeActionSummary(_ action: NativeAction) -> String {
        switch action.kind {
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
            "Play sound · \(action.target ?? "No file selected")"
        case .openApplication:
            "Open application · \(action.target ?? "No application selected")"
        case .openFile:
            "Open file · \(action.target ?? "No file selected")"
        case .openURL:
            "Open URL · \(action.target ?? "No URL entered")"
        case .deckNotification:
            [
                "Deck notification",
                action.topic.map { "topic \($0)" },
                action.appID.map { "bundle ID \($0)" },
                action.text.map { "text \($0)" },
                "expiry \(action.ttlSeconds.map { "\($0)s" } ?? "none")"
            ].compactMap { $0 }.joined(separator: " · ")
        case .shortcut:
            "Keyboard shortcut · \(action.shortcut.map { ShortcutSender.label(for: $0) } ?? "Unavailable")"
        case .lockScreen:
            "Lock Screen"
        }
    }

    private func selectInitialPreset() {
        guard !hasInitializedSelection else { return }
        hasInitializedSelection = true
        if let firstID = tilePresetIDs.first {
            selectTile(.saved(firstID))
        } else {
            selectTile(.blank)
        }
        if let firstID = rotationPresetIDs.first {
            selectRotation(.saved(firstID))
        } else {
            selectRotation(.starter(.volume))
        }
    }

    private func selectTile(_ selection: TileSelection) {
        tileSelection = selection
        selectedTileID = if case .saved(let id) = selection { id } else { nil }
        tileDraftID = UUID()
    }

    private func selectRotation(_ selection: RotationSelection) {
        rotationSelection = selection
        selectedRotationID = if case .saved(let id) = selection { id } else { nil }
        if case .starter(let starter) = selection {
            rotationStarterPreset = try? starter.makePreset()
        } else {
            rotationStarterPreset = nil
        }
        rotationDraftID = UUID()
    }

    private func copyTilePreset(id: String) {
        perform {
            guard var preset = tilePresets[id] else { throw CancellationError() }
            preset.name = copyName(preset.name)
            let copiedID = D200XPresetIdentifier.generated()
            try model.saveTilePreset(id: copiedID, preset: preset)
            selectTile(.saved(copiedID))
        }
    }

    private func copyRotationPreset(id: String) {
        perform {
            guard var preset = rotationPresets[id] else { throw CancellationError() }
            preset.name = copyName(preset.name)
            let copiedID = D200XPresetIdentifier.generated()
            try model.saveDialRotationPreset(id: copiedID, preset: preset)
            selectRotation(.saved(copiedID))
        }
    }

    private func exportTilePreset(id: String) {
        perform {
            let preset = try model.tilePresetPackage(id: id)
            document = TilePresetDocument(data: try preset.encoded())
            exportFilename = makeExportFilename(for: preset.preset.name, suffix: "hidhogg-tile")
            isExporting = true
        }
    }

    private func exportRotationPreset(id: String) {
        perform {
            let preset = try model.dialRotationPresetPackage(id: id)
            document = TilePresetDocument(data: try preset.encoded())
            exportFilename = makeExportFilename(for: preset.preset.name, suffix: "hidhogg-dial-rotation")
            isExporting = true
        }
    }

    private func copyPackage(_ data: Data, type: NSPasteboard.PasteboardType) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: type)
    }

    private func copyTilePackage(id: String) {
        perform {
            copyPackage(try model.tilePresetPackage(id: id).encoded(), type: .tilePreset)
        }
    }

    private func copyRotationPackage(id: String) {
        perform {
            copyPackage(try model.dialRotationPresetPackage(id: id).encoded(), type: .dialRotationPreset)
        }
    }

    private func importReviewedPreset() {
        guard let imported = pendingImport, pendingImportNameIsValid else { return }
        do {
            let name = pendingImportName.trimmingCharacters(in: .whitespacesAndNewlines)
            switch imported.package {
            case .tile(var package):
                package.preset.name = name
                try model.importTilePreset(package, id: pendingImportID, includeAction: true)
                selectTile(.saved(pendingImportID))
                category = .tiles
            case .dialRotation(var package):
                package.preset.name = name
                try model.importDialRotationPreset(package, id: pendingImportID)
                selectRotation(.saved(pendingImportID))
                category = .dialRotation
            }
            pendingImport = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareImport(_ imported: D200XPresetImportPackage) {
        pendingImportName = imported.name
        pendingImportID = D200XPresetIdentifier.generated()
        pendingImport = imported
        switch imported.package {
        case .tile:
            category = .tiles
        case .dialRotation:
            category = .dialRotation
        }
    }

    private func pastePreset() {
        perform {
            guard let directory = model.assetDirectory else {
                throw D200XPresetImportPackage.Failure.invalidPackage
            }
            let pasteboard = NSPasteboard.general
            let data: Data
            if let tileData = pasteboard.data(forType: .tilePreset) {
                data = tileData
            } else if let rotationData = pasteboard.data(forType: .dialRotationPreset) {
                data = rotationData
            } else {
                throw D200XPresetImportPackage.Failure.invalidPackage
            }
            prepareImport(try D200XPresetImportPackage.decode(data, assetDirectory: directory))
        }
    }

    private func matchesSearch(_ starter: D200XPresetRotationStarter) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || starter.title.localizedStandardContains(query)
    }

    private func filter(_ values: [String], title: (String) -> String) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return values }
        return values.filter { title($0).localizedStandardContains(query) }
    }

    private func copyName(_ name: String) -> String {
        let suffix = " Copy"
        return String(name.prefix(64 - suffix.count)) + suffix
    }

    private func makeExportFilename(for name: String, suffix: String) -> String {
        let stem = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "\(stem.isEmpty ? "preset" : stem).\(suffix).json"
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { errorMessage = error.localizedDescription }
    }
}

private extension NSPasteboard.PasteboardType {
    static let tilePreset = NSPasteboard.PasteboardType("app.hidhogg.tile-preset")
    static let dialRotationPreset = NSPasteboard.PasteboardType("app.hidhogg.dial-rotation-preset")
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
