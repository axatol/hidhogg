import HidhoggDomain
import MacOSActions
import SwiftUI

struct D200XPresetChooserView: View {
    @ObservedObject var model: D200XModel
    let context: D200XPresetAssignmentContext
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Selection?
    @State private var searchText = ""
    @State private var actionDraft = D200XPresetActionDraft()
    @State private var tileAppearance = D200XTileAppearance()
    @State private var presetIconPreview: Data?
    @State private var selectedActionID = D200XPresetIdentifier.generated()
    @State private var rotationPreset: D200XDialRotationPreset?
    @State private var isApplying = false
    @State private var errorMessage: String?

    private enum Selection: Hashable {
        case blank
        case action(String)
        case savedTile(String)
        case rotationStarter(String)
        case savedRotation(String)
    }

    private var isConfigured: Bool {
        model.canEdit && model.isConfigured
    }

    private var actionTemplates: [D200XActionTemplate] {
        D200XActionTemplate.allCases
    }

    private var tilePresetIDs: [String] {
        let presets = model.configuration?.tilePresets ?? [:]
        return presets.keys.sorted { firstID, secondID in
            let order = (presets[firstID]?.name ?? firstID).localizedStandardCompare(presets[secondID]?.name ?? secondID)
            return order == .orderedSame
                ? firstID.localizedStandardCompare(secondID) == .orderedAscending
                : order == .orderedAscending
        }
    }

    private var rotationPresetIDs: [String] {
        let presets = model.configuration?.dialRotationPresets ?? [:]
        return presets.keys.sorted { firstID, secondID in
            let order = (presets[firstID]?.name ?? firstID).localizedStandardCompare(presets[secondID]?.name ?? secondID)
            return order == .orderedSame
                ? firstID.localizedStandardCompare(secondID) == .orderedAscending
                : order == .orderedAscending
        }
    }

    private var selectedTemplate: D200XActionTemplate? {
        guard case .some(.action(let title)) = selection else { return nil }
        return actionTemplates.first { $0.title == title }
    }

    private var selectedTilePreset: D200XTilePreset? {
        switch selection {
        case .some(.blank):
            return try? D200XTilePreset(name: "Blank", appearance: tileAppearance).validated()
        case .some(.action):
            guard let template = selectedTemplate,
                  let snapshot = try? actionDraft.snapshot(actionID: selectedActionID) else { return nil }
            return try? D200XTilePreset(
                name: template.title,
                appearance: tileAppearance,
                binding: snapshot.binding,
                actions: snapshot.actions,
                nativeActions: snapshot.nativeActions
            ).validated()
        case .some(.savedTile(let id)):
            return model.configuration?.tilePresets[id]
        case .some(.rotationStarter), .some(.savedRotation), .none:
            return nil
        }
    }

    private var selectedRotationPreset: D200XDialRotationPreset? {
        switch selection {
        case .some(.rotationStarter):
            return rotationPreset
        case .some(.savedRotation(let id)):
            return model.configuration?.dialRotationPresets[id]
        case .some(.blank), .some(.action), .some(.savedTile), .none:
            return nil
        }
    }

    private var selectedTitle: String {
        switch selection {
        case .some(.blank): "Blank"
        case .some(.action): selectedTemplate?.title ?? "Action preset"
        case .some(.savedTile(let id)): model.configuration?.tilePresets[id]?.name ?? "Unavailable preset"
        case .some(.rotationStarter(let rawValue)):
            D200XPresetRotationStarter(rawValue: rawValue)?.title ?? "Dial rotation preset"
        case .some(.savedRotation(let id)): model.configuration?.dialRotationPresets[id]?.name ?? "Unavailable preset"
        case .none: "Choose a preset"
        }
    }

    private var selectedActionPresentation: D200XPresetActionPresentation? {
        guard let preset = selectedTilePreset else { return nil }
        return D200XPresetActionPresentation(
            binding: preset.binding,
            actions: preset.actions,
            nativeActions: preset.nativeActions
        )
    }

    private var selectedRotationPresentations: (D200XPresetActionPresentation, D200XPresetActionPresentation)? {
        guard let preset = selectedRotationPreset else { return nil }
        return (
            D200XPresetActionPresentation(binding: preset.left, actions: preset.actions, nativeActions: preset.nativeActions),
            D200XPresetActionPresentation(binding: preset.right, actions: preset.actions, nativeActions: preset.nativeActions)
        )
    }

    private var filteredTemplates: [D200XActionTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return actionTemplates }
        return actionTemplates.filter { $0.title.localizedStandardContains(query) }
    }

    private var filteredTilePresetIDs: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tilePresetIDs }
        return tilePresetIDs.filter { model.configuration?.tilePresets[$0]?.name.localizedStandardContains(query) == true }
    }

    private var filteredRotationPresetIDs: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rotationPresetIDs }
        return rotationPresetIDs.filter { model.configuration?.dialRotationPresets[$0]?.name.localizedStandardContains(query) == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose Preset")
                    .font(.title2.weight(.semibold))
                Text(context.isDialRotation ? "Apply a paired left and right assignment to Dial \((context.dialIndex ?? 0) + 1)." : "Apply a complete preset to \(context.control?.title ?? "the selected control").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Search presets", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search presets")

            HSplitView {
                presetList
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                ScrollView {
                    presetDetails
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 390)
            .disabled(isApplying)

            if !context.matches(control: model.selectedControl, applicationID: model.applicationID) {
                Text("The selected control or app profile changed. Close this chooser and open it again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isApplying)
                Button("Apply Preset", systemImage: "checkmark") {
                    applySelectedPreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApplySelection || isApplying)
            }
        }
        .padding(18)
        .frame(width: 760, height: 580)
        .onAppear(perform: selectInitialPreset)
        .onChange(of: selection) { _, value in configureSelection(value) }
        .alert("Preset", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var presetList: some View {
        List(selection: $selection) {
            if context.isDialRotation {
                Section("Dial Rotation") {
                    ForEach(filteredRotationPresetIDs, id: \.self) { id in
                        if let preset = model.configuration?.dialRotationPresets[id] {
                            let symbols = rotationSymbols(preset)
                            rotationPresetRow(title: preset.name, symbols: symbols, subtitle: rotationSummary(preset))
                                .tag(Selection.savedRotation(id))
                        }
                    }
                }
                Section("Built-in starters") {
                    ForEach(D200XPresetRotationStarter.allCases.filter(matchesSearch), id: \.rawValue) { starter in
                        rotationPresetRow(title: starter.title, symbols: rotationSymbols(starter), subtitle: starter.subtitle)
                            .tag(Selection.rotationStarter(starter.rawValue))
                    }
                }
            } else {
                Section("Tiles & Press") {
                    ForEach(filteredTilePresetIDs, id: \.self) { id in
                        if let preset = model.configuration?.tilePresets[id] {
                            presetRow(
                                title: preset.name,
                                symbol: D200XPresetActionPresentation(binding: preset.binding, actions: preset.actions, nativeActions: preset.nativeActions).systemSymbol,
                                subtitle: D200XPresetActionPresentation(binding: preset.binding, actions: preset.actions, nativeActions: preset.nativeActions).summary
                            )
                            .tag(Selection.savedTile(id))
                        }
                    }
                }
                Section("Built-in defaults") {
                    presetRow(title: "Blank", symbol: "square", subtitle: "No action")
                        .tag(Selection.blank)
                    ForEach(filteredTemplates, id: \.title) { template in
                        presetRow(title: template.title, symbol: template.systemSymbol,
                                  subtitle: template.requiresConfiguration ? "Configure before applying" : template.title)
                            .tag(Selection.action(template.title))
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var presetDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                selectionIcon
                    .font(.title2)
                    .frame(width: 42, height: 42)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTitle)
                        .font(.headline)
                    Text(context.isDialRotation ? "Dial rotation preset" : "Tile and action preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if context.isDialRotation {
                if let pair = selectedRotationPresentations {
                    GroupBox("Rotation assignments") {
                        VStack(alignment: .leading, spacing: 12) {
                            assignmentLine(title: "Left", presentation: pair.0)
                            assignmentLine(title: "Right", presentation: pair.1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardContentPadding()
                    }
                    Text("Applying this preset changes both rotation assignments together. Press and appearance stay as they are.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ContentUnavailableView("Choose a rotation preset", systemImage: "arrow.left.arrow.right")
                }
            } else if selectedTemplate != nil {
                if let preset = selectedTilePreset {
                    tileDisplayPreview(preset.appearance)
                } else {
                    tileDisplayPreview(tileAppearance)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: actionDraft.systemSymbol)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Action")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(actionDraft.summary)
                            .font(.callout)
                    }
                }
                D200XPresetActionEditorView(draft: $actionDraft, configuration: model.configuration, showsActionPicker: false)
                if let validationMessage = actionDraft.validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if presetIconPreview == nil {
                    Text("The action icon could not be rendered.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if let preset = selectedTilePreset {
                if let control = context.control, control.isTile {
                    tileDisplayPreview(preset.appearance)
                }

                if let presentation = selectedActionPresentation {
                    assignmentLine(title: "Action", presentation: presentation)
                }

                Text("Applying copies the preset appearance and assignment. A disabled assignment clears the current action.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ContentUnavailableView("Choose a preset", systemImage: "square.grid.2x2")
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var selectionIcon: some View {
        Group {
            if context.isDialRotation {
                Image(systemName: "arrow.left.arrow.right")
            } else if selection == .blank {
                Image(systemName: "square")
            } else if let presentation = selectedActionPresentation {
                Image(systemName: presentation.systemSymbol)
            } else if let template = selectedTemplate {
                Image(systemName: template.systemSymbol)
            } else {
                Image(systemName: "square")
            }
        }
        .accessibilityHidden(true)
    }

    private var canApplySelection: Bool {
        guard isConfigured, let selection else { return false }
        guard context.matches(control: model.selectedControl, applicationID: model.applicationID) else { return false }
        switch selection {
        case .blank, .action, .savedTile:
            return !context.isDialRotation && selectedTilePreset != nil
                && (selectedTemplate == nil || (actionDraft.validationMessage == nil && presetIconPreview != nil))
        case .rotationStarter, .savedRotation:
            return context.isDialRotation && selectedRotationPreset != nil
        }
    }

    @ViewBuilder
    private func presetRow(title: String, symbol: String, subtitle: String) -> some View {
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
        .padding(.vertical, 2)
    }

    private func rotationPresetRow(title: String, symbols: (String, String), subtitle: String) -> some View {
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
            HStack(spacing: 1) {
                Image(systemName: symbols.0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                Image(systemName: symbols.1)
            }
            .frame(width: 40)
        }
        .padding(.vertical, 2)
    }

    private func assignmentLine(title: String, presentation: D200XPresetActionPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: presentation.systemSymbol)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(presentation.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func tileDisplayPreview(_ appearance: D200XTileAppearance) -> some View {
        if let control = context.control, control.isTile {
            GroupBox("Display preview") {
                D200XTilePreview(
                    appearance: appearance,
                    wide: control == .key13,
                    labelOverride: nil,
                    assetDirectory: model.assetDirectory,
                    presetIcon: presetIconPreview
                )
                .frame(width: control == .key13 ? 220 : 110, height: 110)
                .frame(maxWidth: .infinity)
                .cardContentPadding()
            }
        }
    }

    private func selectInitialPreset() {
        configureSelection(nil)
    }

    private func configureSelection(_ selection: Selection?) {
        selectedActionID = D200XPresetIdentifier.generated()
        switch selection {
        case .some(.blank):
            tileAppearance = D200XTileAppearance(label: "Blank")
            actionDraft = D200XPresetActionDraft()
            presetIconPreview = nil
            rotationPreset = nil
        case .some(.action(let title)):
            guard let template = actionTemplates.first(where: { $0.title == title }) else { return }
            tileAppearance = D200XTileAppearance(label: template.title)
            tileAppearance.backgroundHex = "000000"
            tileAppearance.showTitle = false
            actionDraft = D200XPresetActionDraft(template: template)
            presetIconPreview = try? D200XPresetIconRenderer.pngData(systemSymbol: template.systemSymbol)
            rotationPreset = nil
        case .some(.savedTile(let id)):
            guard let preset = model.configuration?.tilePresets[id] else { return }
            tileAppearance = preset.appearance
            actionDraft = D200XPresetActionDraft(binding: preset.binding, actions: preset.actions, nativeActions: preset.nativeActions)
            presetIconPreview = nil
            rotationPreset = nil
        case .some(.rotationStarter(let rawValue)):
            presetIconPreview = nil
            guard let starter = D200XPresetRotationStarter(rawValue: rawValue) else { return }
            rotationPreset = try? starter.makePreset()
        case .some(.savedRotation), .none:
            presetIconPreview = nil
            rotationPreset = nil
        }
    }

    private func matchesSearch(_ starter: D200XPresetRotationStarter) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || starter.title.localizedStandardContains(query)
    }

    private func rotationSummary(_ preset: D200XDialRotationPreset) -> String {
        let left = D200XPresetActionPresentation(binding: preset.left, actions: preset.actions, nativeActions: preset.nativeActions)
        let right = D200XPresetActionPresentation(binding: preset.right, actions: preset.actions, nativeActions: preset.nativeActions)
        return "Left: \(left.summary) · Right: \(right.summary)"
    }

    private func rotationSymbols(_ preset: D200XDialRotationPreset) -> (String, String) {
        let left = D200XPresetActionPresentation(binding: preset.left, actions: preset.actions, nativeActions: preset.nativeActions)
        let right = D200XPresetActionPresentation(binding: preset.right, actions: preset.actions, nativeActions: preset.nativeActions)
        return (left.systemSymbol, right.systemSymbol)
    }

    private func rotationSymbols(_ starter: D200XPresetRotationStarter) -> (String, String) {
        switch starter {
        case .volume:
            ("speaker.wave.1.fill", "speaker.wave.2.fill")
        case .previousNext:
            ("backward.end.fill", "forward.end.fill")
        }
    }

    private func applySelectedPreset() {
        guard canApplySelection else { return }
        let capturedContext = context
        let capturedPresetIcon = presetIconPreview
        let capturedTilePreset = selectedTilePreset
        let capturedRotationPreset = selectedRotationPreset

        isApplying = true
        errorMessage = nil
        Task { @MainActor in
            do {
                guard capturedContext.matches(control: model.selectedControl, applicationID: model.applicationID) else {
                    throw CancellationError()
                }

                switch capturedContext.target {
                case .control(let control):
                    guard var preset = capturedTilePreset else { throw CancellationError() }
                    if let capturedPresetIcon {
                        let reference = try await model.importPresetImage(data: capturedPresetIcon)
                        guard capturedContext.matches(control: model.selectedControl, applicationID: model.applicationID) else {
                            throw CancellationError()
                        }
                        preset.appearance.imageAsset = reference
                    }
                    try model.applyTilePreset(preset: preset, control: control, applicationID: capturedContext.applicationID)
                case .dialRotation(let dialIndex):
                    guard let preset = capturedRotationPreset else { throw CancellationError() }
                    try model.applyDialRotationPreset(preset: preset, dialIndex: dialIndex, applicationID: capturedContext.applicationID)
                }

                onApply()
                dismiss()
            } catch is CancellationError {
                errorMessage = "The selected control or app profile changed. Choose the preset again."
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplying = false
        }
    }
}

enum D200XPresetRotationStarter: String, CaseIterable, Identifiable, Hashable {
    case volume
    case previousNext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: "Volume"
        case .previousNext: "Previous / Next Track"
        }
    }

    var subtitle: String {
        switch self {
        case .volume: "Volume Down on left · Volume Up on right"
        case .previousNext: "Previous Track on left · Next Track on right"
        }
    }

    func makePreset() throws -> D200XDialRotationPreset {
        let leftTemplate: D200XActionTemplate
        let rightTemplate: D200XActionTemplate
        switch self {
        case .volume:
            leftTemplate = .volumeDown
            rightTemplate = .volumeUp
        case .previousNext:
            leftTemplate = .previousTrack
            rightTemplate = .nextTrack
        }

        let leftID = D200XPresetIdentifier.generated()
        let rightID = D200XPresetIdentifier.generated()
        let left = try D200XPresetActionDraft(template: leftTemplate).snapshot(actionID: leftID)
        let right = try D200XPresetActionDraft(template: rightTemplate).snapshot(actionID: rightID)
        return try D200XDialRotationPreset(
            name: title,
            left: left.binding ?? .disabled,
            right: right.binding ?? .disabled,
            actions: left.actions.merging(right.actions) { first, _ in first },
            nativeActions: left.nativeActions.merging(right.nativeActions) { first, _ in first }
        ).validated()
    }
}
