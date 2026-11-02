import Foundation
import HidhoggDomain
import SwiftUI

struct TilePresetEditorView: View {
    private struct FieldsIdentity: Hashable {
        let draftID: UUID
        let selectedID: String?
    }

    @ObservedObject var model: D200XModel
    @Binding var selectedID: String?
    @Binding var draftID: UUID
    let onSaved: (String) -> Void
    let initialTemplate: D200XActionTemplate?

    @State private var activeDraftID = UUID()
    @State private var originalPreset: D200XTilePreset?
    @State private var originalPresetID: String?
    @State private var generatedActionID = ""
    @State private var name = ""
    @State private var appearance = D200XTileAppearance()
    @State private var action = D200XPresetActionDraft()
    @State private var isImportingIcon = false
    @State private var activeIconImportID: UUID?
    @State private var iconImportTask: Task<Void, Never>?
    @State private var errorMessage: String?

    init(
        model: D200XModel,
        selectedID: Binding<String?>,
        draftID: Binding<UUID>,
        onSaved: @escaping (String) -> Void,
        initialTemplate: D200XActionTemplate? = nil
    ) {
        self.model = model
        self._selectedID = selectedID
        self._draftID = draftID
        self.onSaved = onSaved
        self.initialTemplate = initialTemplate
    }

    private var presetID: String {
        if let originalPresetID { return originalPresetID }
        return generatedPresetID(for: name)
    }

    private var candidatePreset: D200XTilePreset? {
        guard let snapshot = try? action.snapshot(actionID: generatedActionID) else { return nil }
        return try? D200XTilePreset(
            name: name,
            appearance: appearance,
            binding: snapshot.binding,
            actions: snapshot.actions,
            nativeActions: snapshot.nativeActions
        ).validated()
    }

    private var validationMessage: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64 else {
            return "Enter a name of at most 64 characters."
        }
        guard appearance.isValid() else {
            return "Check the label, colors and title size."
        }
        if let message = action.validationMessage { return message }
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

            D200XPresetFieldsView(
                model: model,
                name: $name,
                appearance: $appearance,
                action: $action,
                showsAppearance: true,
                previewIconSymbol: initialTemplate == nil ? nil : action.systemSymbol
            )
            .id(FieldsIdentity(draftID: draftID, selectedID: selectedID))

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
                .disabled(!model.canEdit || !model.isConfigured || isImportingIcon || validationMessage != nil)
        }
        .onAppear(perform: loadDraft)
        .onChange(of: selectedID) { _, _ in loadDraft() }
        .onChange(of: draftID) { _, _ in loadDraft() }
        .onDisappear { iconImportTask?.cancel() }
        .alert("Tile preset", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The preset could not be saved.")
        }
    }

    private func loadDraft() {
        iconImportTask?.cancel()
        iconImportTask = nil
        activeIconImportID = nil
        activeDraftID = draftID
        originalPresetID = nil
        generatedActionID = newActionID()
        isImportingIcon = false
        errorMessage = nil

        guard let selectedID, let preset = model.configuration?.tilePresets[selectedID] else {
            originalPreset = nil
            if let initialTemplate {
                let starterName = initialTemplate.title.replacingOccurrences(of: "…", with: "")
                name = starterName
                appearance = initialTemplate.defaultTilePresetAppearance
                action = D200XPresetActionDraft(template: initialTemplate)
            } else {
                name = ""
                appearance = D200XTileAppearance()
                action = D200XPresetActionDraft()
            }
            return
        }

        originalPreset = preset
        originalPresetID = selectedID
        name = preset.name
        appearance = preset.appearance
        action = D200XPresetActionDraft(
            binding: preset.binding,
            actions: preset.actions,
            nativeActions: preset.nativeActions
        )
    }

    private func savePreset() {
        guard model.canEdit, model.isConfigured, let candidatePreset else { return }
        let targetID = presetID
        let expectedDraftID = activeDraftID
        let expectedSelectedID = selectedID
        let expectedName = name
        let expectedAppearance = appearance
        let expectedAction = action

        guard initialTemplate != nil, candidatePreset.appearance.imageAsset == nil else {
            persist(candidatePreset, id: targetID, expectedDraftID: expectedDraftID, selectedID: expectedSelectedID)
            return
        }

        let iconImportID = UUID()
        activeIconImportID = iconImportID
        isImportingIcon = true
        iconImportTask = Task { @MainActor in
            defer {
                if activeIconImportID == iconImportID {
                    activeIconImportID = nil
                    iconImportTask = nil
                    isImportingIcon = false
                }
            }
            do {
                let data = try D200XPresetIconRenderer.pngData(systemSymbol: expectedAction.systemSymbol)
                let reference = try await model.importPresetImage(data: data)
                try Task.checkCancellation()
                guard isCurrentDraft(expectedDraftID, selectedID: expectedSelectedID),
                      name == expectedName, appearance == expectedAppearance, action == expectedAction else { return }
                var preset = candidatePreset
                preset.appearance.imageAsset = reference
                persist(preset, id: targetID, expectedDraftID: expectedDraftID, selectedID: expectedSelectedID)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentDraft(expectedDraftID, selectedID: expectedSelectedID) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func persist(_ preset: D200XTilePreset, id: String, expectedDraftID: UUID, selectedID expectedSelectedID: String?) {
        guard isCurrentDraft(expectedDraftID, selectedID: expectedSelectedID) else { return }
        do {
            try model.saveTilePreset(id: id, preset: preset, replacing: originalPreset)
            originalPreset = preset
            originalPresetID = id
            isImportingIcon = false
            errorMessage = nil
            onSaved(id)
        } catch {
            isImportingIcon = false
            errorMessage = error.localizedDescription
        }
    }

    private func isCurrentDraft(_ expectedDraftID: UUID, selectedID expectedSelectedID: String?) -> Bool {
        activeDraftID == expectedDraftID && draftID == expectedDraftID && selectedID == expectedSelectedID
    }

    private func generatedPresetID(for value: String) -> String {
        guard originalPreset == nil else { return originalPresetID ?? selectedID ?? "preset" }
        let available = model.configuration?.tilePresets.keys ?? Dictionary<String, D200XTilePreset>().keys
        var stem = ""
        var previousWasSeparator = false
        for byte in value.lowercased().utf8 {
            if (48...57).contains(byte) || (97...122).contains(byte) {
                stem.append(Character(UnicodeScalar(byte)))
                previousWasSeparator = false
            } else if !previousWasSeparator, !stem.isEmpty {
                stem.append("-")
                previousWasSeparator = true
            }
        }
        while stem.last == "-" { stem.removeLast() }
        if stem.isEmpty { stem = "preset" }
        if let first = stem.utf8.first, !(48...57).contains(first), !(97...122).contains(first) {
            stem = "preset-\(stem)"
        }

        let truncatedStem = String(stem.prefix(48))
        if !available.contains(truncatedStem) { return truncatedStem }
        for suffix in 2...Int.max {
            let suffixText = "-\(suffix)"
            let prefix = String(truncatedStem.prefix(64 - suffixText.utf8.count))
            let candidate = "\(prefix)\(suffixText)"
            if !available.contains(candidate) { return candidate }
        }
        return UUID().uuidString.lowercased()
    }

    private func newActionID() -> String {
        "preset-action-\(UUID().uuidString.lowercased())"
    }
}
