import HidhoggDomain
import SwiftUI

struct DialRotationPresetEditorView: View {
    private struct DraftIdentity: Hashable {
        let draftID: UUID
        let selectedID: String?
    }

    @ObservedObject var model: D200XModel
    @Binding var selectedID: String?
    @Binding var draftID: UUID
    let onSaved: (String) -> Void
    let initialPreset: D200XDialRotationPreset?

    @State private var originalPreset: D200XDialRotationPreset?
    @State private var originalPresetID: String?
    @State private var generatedLeftActionID = ""
    @State private var generatedRightActionID = ""
    @State private var name = ""
    @State private var leftAction = D200XPresetActionDraft()
    @State private var rightAction = D200XPresetActionDraft()
    @State private var errorMessage: String?

    init(
        model: D200XModel,
        selectedID: Binding<String?>,
        draftID: Binding<UUID>,
        onSaved: @escaping (String) -> Void,
        initialPreset: D200XDialRotationPreset? = nil
    ) {
        self.model = model
        self._selectedID = selectedID
        self._draftID = draftID
        self.onSaved = onSaved
        self.initialPreset = initialPreset
    }

    private var presetID: String {
        if let originalPresetID { return originalPresetID }
        return generatedPresetID(for: name)
    }

    private var candidatePreset: D200XDialRotationPreset? {
        guard let left = try? leftAction.snapshot(actionID: generatedLeftActionID),
              let right = try? rightAction.snapshot(actionID: generatedRightActionID) else { return nil }
        var actions = left.actions
        actions.merge(right.actions) { _, right in right }
        var nativeActions = left.nativeActions
        nativeActions.merge(right.nativeActions) { _, right in right }
        return try? D200XDialRotationPreset(
            name: name,
            left: left.binding ?? .disabled,
            right: right.binding ?? .disabled,
            actions: actions,
            nativeActions: nativeActions
        ).validated()
    }

    private var validationMessage: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64 else {
            return "Enter a name of at most 64 characters."
        }
        if let message = leftAction.validationMessage { return "Left: \(message)" }
        if let message = rightAction.validationMessage { return "Right: \(message)" }
        guard candidatePreset != nil else { return "Review both rotation assignments before saving." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedID == nil ? "New dial rotation preset" : "Edit dial rotation preset")
                    .font(.title2.weight(.semibold))
                Text("Changes stay in this draft until you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Preset") {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canEdit)
                    .padding(.vertical, 4)
            }

            rotationActionEditor(title: "Rotate Left", draft: $leftAction)
                .id(DraftIdentity(draftID: draftID, selectedID: selectedID))
            rotationActionEditor(title: "Rotate Right", draft: $rightAction)
                .id(DraftIdentity(draftID: draftID, selectedID: selectedID))

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Save Preset", systemImage: "square.and.arrow.down", action: savePreset)
                .disabled(!model.canEdit || !model.isConfigured || validationMessage != nil)
        }
        .onAppear(perform: loadDraft)
        .onChange(of: selectedID) { _, _ in loadDraft() }
        .onChange(of: draftID) { _, _ in loadDraft() }
        .alert("Dial rotation preset", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The preset could not be saved.")
        }
    }

    private func rotationActionEditor(title: String, draft: Binding<D200XPresetActionDraft>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            D200XPresetActionEditorView(draft: draft, configuration: model.configuration)
                .disabled(!model.canEdit)
        }
    }

    private func loadDraft() {
        generatedLeftActionID = newActionID()
        generatedRightActionID = newActionID()
        errorMessage = nil
        originalPresetID = nil

        if let selectedID, let preset = model.configuration?.dialRotationPresets[selectedID] {
            originalPreset = preset
            originalPresetID = selectedID
            name = preset.name
            leftAction = D200XPresetActionDraft(binding: preset.left, actions: preset.actions, nativeActions: preset.nativeActions)
            rightAction = D200XPresetActionDraft(binding: preset.right, actions: preset.actions, nativeActions: preset.nativeActions)
            return
        }

        originalPreset = nil
        guard let initialPreset else {
            name = ""
            leftAction = D200XPresetActionDraft()
            rightAction = D200XPresetActionDraft()
            return
        }
        name = initialPreset.name
        leftAction = D200XPresetActionDraft(binding: initialPreset.left, actions: initialPreset.actions,
            nativeActions: initialPreset.nativeActions)
        rightAction = D200XPresetActionDraft(binding: initialPreset.right, actions: initialPreset.actions,
            nativeActions: initialPreset.nativeActions)
    }

    private func savePreset() {
        guard model.canEdit, model.isConfigured, let candidatePreset else { return }
        do {
            let id = presetID
            try model.saveDialRotationPreset(id: id, preset: candidatePreset, replacing: originalPreset)
            originalPreset = candidatePreset
            originalPresetID = id
            errorMessage = nil
            onSaved(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generatedPresetID(for value: String) -> String {
        guard originalPreset == nil else { return originalPresetID ?? selectedID ?? "rotation" }
        let available = model.configuration?.dialRotationPresets.keys ?? Dictionary<String, D200XDialRotationPreset>().keys
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
        if stem.isEmpty { stem = "rotation" }
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
        "rotation-action-\(UUID().uuidString.lowercased())"
    }
}
