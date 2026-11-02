import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI

@MainActor
struct ShortcutEditorView: View {
    private let onCancel: () -> Void
    private let onCommit: (InputShortcut) -> Void
    private let supportsRecording: Bool
    private let keyOptions: [ShortcutKeyOption]

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ShortcutEditorDraft
    @State private var isRecording: Bool
    @State private var searchText = ""
    @State private var copyError: String?

    private static let mouseButtons: [MouseButton] = [.left, .right, .middle]

    init(
        initialShortcut: HidhoggDomain.KeyboardShortcut?,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (HidhoggDomain.KeyboardShortcut) -> Void
    ) {
        self.onCancel = onCancel
        supportsRecording = false
        keyOptions = ShortcutSender.keyOptions
        _draft = State(initialValue: ShortcutEditorDraft(
            initialShortcut: .keyboard(initialShortcut ?? HidhoggDomain.KeyboardShortcut(keyCode: 0)),
            allowsMouse: false
        ))
        _isRecording = State(initialValue: false)
        self.onCommit = { shortcut in
            guard case .keyboard(let keyboardShortcut) = shortcut else { return }
            onCommit(keyboardShortcut)
        }
    }

    init(
        initialInputShortcut: InputShortcut?,
        allowsMouse: Bool,
        startsRecording: Bool,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (InputShortcut) -> Void
    ) {
        self.onCancel = onCancel
        self.onCommit = onCommit
        supportsRecording = true
        keyOptions = ShortcutSender.keyOptions
        _draft = State(initialValue: ShortcutEditorDraft(
            initialShortcut: initialInputShortcut,
            allowsMouse: allowsMouse
        ))
        _isRecording = State(initialValue: startsRecording)
    }

    var body: some View {
        NavigationStack {
            Form {
                shortcutSection
                modifierSection
                inputPickerSection
            }
            .formStyle(.grouped)
            .navigationTitle("Choose Shortcut")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: cancelEditor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", systemImage: "checkmark", action: apply)
                        .disabled(!draft.canApply)
                }
            }
            .onChange(of: draft.representation) { _, _ in
                copyError = nil
            }
        }
        .frame(minWidth: 460, minHeight: 480)
    }

    private var shortcutSection: some View {
        Section("Shortcut") {
            if supportsRecording {
                HStack {
                    Button(isRecording ? "Stop Recording" : "Record", systemImage: isRecording ? "stop.circle" : "record.circle", action: toggleRecording)
                    Spacer()
                    Button("Copy Shortcut", systemImage: "doc.on.doc", action: copyShortcut)
                        .disabled(!draft.canApply)
                }

                if isRecording {
                    InputShortcutCaptureView(
                        allowsMouse: draft.allowsMouse,
                        onCapture: recordShortcut,
                        onCancel: stopRecording
                    )
                    .frame(minHeight: 44)
                }
            } else {
                Button("Copy Shortcut", systemImage: "doc.on.doc", action: copyShortcut)
                    .disabled(!draft.canApply)
            }

            tokenChipRow

            TextField("Type or paste shortcut", text: $draft.inputText)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Shortcut token")

            if let parseError = draft.parseError {
                Text(parseError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !draft.canApply {
                Text("Choose a key, paste a token, or record an input.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let copyError {
                Text(copyError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if draft.canApply, let shortcut = draft.selectedShortcut {
                LabeledContent("Readable", value: ShortcutSender.label(for: shortcut))
            }
        }
    }

    private var tokenChipRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.orderedModifiers, id: \.self) { modifier in
                    modifierChip(modifier)
                }

                triggerChip
            }
            .frame(minHeight: 36, alignment: .leading)
        }
        .accessibilityLabel("Shortcut tokens")
    }

    @ViewBuilder
    private var triggerChip: some View {
        if let trigger = draft.trigger {
            let title = ShortcutSender.label(for: trigger)
            Button {
                draft.removeTrigger()
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                    Image(systemName: "xmark.circle.fill")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title) trigger")
        } else {
            Text("Choose a key or mouse button")
                .foregroundStyle(.secondary)
        }
    }

    private var modifierSection: some View {
        Section("Modifiers") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(ShortcutModifier.allCases, id: \.self) { modifier in
                    modifierButton(modifier)
                }
            }
        }
    }

    private var inputPickerSection: some View {
        Section("Find a key or mouse button") {
            TextField("Search keys or mouse buttons", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Search keys or mouse buttons")

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if draft.allowsMouse {
                        ForEach(filteredMouseButtons, id: \.self) { mouseRow($0) }
                    }

                    ForEach(filteredKeyOptions, id: \.keyCode) { keyRow($0) }

                    if filteredKeyOptions.isEmpty && filteredMouseButtons.isEmpty {
                        Text("No matching keys or mouse buttons.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func modifierChip(_ modifier: ShortcutModifier) -> some View {
        let title = modifierTitle(modifier)
        return Button {
            draft.toggleModifier(modifier)
        } label: {
            HStack(spacing: 5) {
                Text("\(modifierSymbol(modifier)) \(title)")
                Image(systemName: "xmark.circle.fill")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(title) modifier")
    }

    private func modifierButton(_ modifier: ShortcutModifier) -> some View {
        let isSelected = draft.isModifierSelected(modifier)
        let title = modifierTitle(modifier)
        return Button {
            draft.toggleModifier(modifier)
        } label: {
            HStack(spacing: 6) {
                Text(modifierSymbol(modifier))
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
        .accessibilityLabel(isSelected ? "Remove \(title) modifier" : "Add \(title) modifier")
    }

    private func keyRow(_ option: ShortcutKeyOption) -> some View {
        let shortcut = HidhoggDomain.KeyboardShortcut(keyCode: option.keyCode, modifiers: draft.orderedModifiers)
        let isSelected = isKeySelected(option.keyCode)
        return Button {
            draft.select(.keyboard(shortcut))
        } label: {
            HStack {
                Text(option.label)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(option.label), key code \(option.keyCode)")
    }

    private func mouseRow(_ button: MouseButton) -> some View {
        let shortcut = MouseShortcut(button: button, modifiers: draft.orderedModifiers)
        let title = mouseButtonTitle(button)
        let isSelected = isMouseSelected(button)
        return Button {
            draft.select(.mouseClick(shortcut))
        } label: {
            HStack {
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(mouseButtonToken(button)) mouse button")
    }

    private func isKeySelected(_ keyCode: UInt16) -> Bool {
        guard case let .keyboard(shortcut)? = draft.trigger else { return false }
        return shortcut.keyCode == keyCode
    }

    private func isMouseSelected(_ button: MouseButton) -> Bool {
        guard case let .mouseClick(shortcut)? = draft.trigger else { return false }
        return shortcut.button == button
    }

    private var filteredKeyOptions: [ShortcutKeyOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = keyOptions.filter { option in
            query.isEmpty || option.name.localizedStandardContains(query)
                || option.label.localizedStandardContains(query)
                || "Key \(option.keyCode)".localizedStandardContains(query)
        }
        return matches
    }

    private var filteredMouseButtons: [MouseButton] {
        guard draft.allowsMouse else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.mouseButtons.filter { button in
            query.isEmpty || mouseButtonTitle(button).localizedStandardContains(query)
                || "mouse.\(mouseButtonToken(button))".localizedStandardContains(query)
        }
    }

    private func modifierTitle(_ modifier: ShortcutModifier) -> String {
        switch modifier {
        case .command: "Command"
        case .option: "Option"
        case .control: "Control"
        case .shift: "Shift"
        }
    }

    private func modifierSymbol(_ modifier: ShortcutModifier) -> String {
        switch modifier {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }

    private func mouseButtonTitle(_ button: MouseButton) -> String {
        switch button {
        case .left: "Mouse Left"
        case .right: "Mouse Right"
        case .middle: "Mouse Middle"
        }
    }

    private func mouseButtonToken(_ button: MouseButton) -> String {
        switch button {
        case .left: "left"
        case .right: "right"
        case .middle: "middle"
        }
    }

    private func toggleRecording() {
        isRecording.toggle()
    }

    private func stopRecording() {
        isRecording = false
    }

    private func recordShortcut(_ shortcut: InputShortcut) {
        draft.select(shortcut)
        isRecording = false
    }

    private func copyShortcut() {
        guard let canonicalRepresentation = draft.canonicalRepresentation else {
            copyError = "Could not format this shortcut."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(canonicalRepresentation, forType: .string)
        copyError = nil
    }

    private func apply() {
        guard draft.canApply, let shortcut = draft.selectedShortcut else { return }
        onCommit(shortcut)
        dismiss()
    }

    private func cancelEditor() {
        onCancel()
        dismiss()
    }
}
