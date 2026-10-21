import HidhoggDomain
import MacOSActions
import SwiftUI

struct ShortcutEditorView: View {
    let onCancel: () -> Void
    let onCommit: (HidhoggDomain.KeyboardShortcut) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKeyCode: UInt16
    @State private var selectedModifiers: Set<ShortcutModifier>

    private static let keyCodes = (UInt16(0)...UInt16(127)).filter { !(UInt16(54)...UInt16(63)).contains($0) }

    init(
        initialShortcut: HidhoggDomain.KeyboardShortcut?,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (HidhoggDomain.KeyboardShortcut) -> Void
    ) {
        self.onCancel = onCancel
        self.onCommit = onCommit
        _selectedKeyCode = State(initialValue: initialShortcut?.keyCode ?? 0)
        _selectedModifiers = State(initialValue: Set(initialShortcut?.modifiers ?? []))
    }

    private var shortcut: HidhoggDomain.KeyboardShortcut {
        HidhoggDomain.KeyboardShortcut(
            keyCode: selectedKeyCode,
            modifiers: ShortcutModifier.allCases.filter(selectedModifiers.contains)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Key", selection: $selectedKeyCode) {
                    ForEach(Self.keyCodes, id: \.self) { keyCode in
                        Text(ShortcutSender.label(for: HidhoggDomain.KeyboardShortcut(keyCode: keyCode)))
                            .tag(keyCode)
                    }
                }

                Section("Modifiers") {
                    ForEach(ShortcutModifier.allCases, id: \.self) { modifier in
                        Toggle(modifier.title, isOn: Binding(
                            get: { selectedModifiers.contains(modifier) },
                            set: { isSelected in
                                if isSelected {
                                    selectedModifiers.insert(modifier)
                                } else {
                                    selectedModifiers.remove(modifier)
                                }
                            }
                        ))
                    }
                }

                LabeledContent("Shortcut", value: ShortcutSender.label(for: shortcut))
            }
            .navigationTitle("Choose Shortcut")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        onCommit(shortcut)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 300)
    }
}

private extension ShortcutModifier {
    var title: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .control: "Control"
        case .shift: "Shift"
        }
    }
}
