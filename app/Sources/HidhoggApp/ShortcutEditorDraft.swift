import HidhoggDomain
import MacOSActions

@MainActor
struct ShortcutEditorDraft {
    let allowsMouse: Bool
    private(set) var representation: String
    private(set) var trigger: InputShortcut?
    private(set) var selectedShortcut: InputShortcut?
    private(set) var modifiers = Set<ShortcutModifier>()
    private(set) var parseError: String?

    var inputText: String {
        get { representation }
        set { updateRepresentation(newValue) }
    }

    var orderedModifiers: [ShortcutModifier] {
        ShortcutModifier.allCases.filter(modifiers.contains)
    }

    var canApply: Bool {
        selectedShortcut != nil && parseError == nil
    }

    var canonicalRepresentation: String? {
        guard canApply, let selectedShortcut else { return nil }
        return try? ShortcutSender.format(selectedShortcut)
    }

    init(initialShortcut: InputShortcut?, allowsMouse: Bool) {
        self.allowsMouse = allowsMouse
        trigger = nil
        selectedShortcut = nil
        representation = ""
        parseError = nil

        if let initialShortcut {
            select(initialShortcut)
        }
    }

    mutating func updateRepresentation(_ representation: String) {
        self.representation = representation
        guard !representation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            trigger = nil
            selectedShortcut = nil
            modifiers = []
            parseError = "Enter a shortcut."
            return
        }

        do {
            let shortcut = try ShortcutSender.parse(representation)
            guard allowsMouse || isKeyboardShortcut(shortcut) else {
                trigger = nil
                selectedShortcut = nil
                modifiers = []
                parseError = "Mouse shortcuts are unavailable in this editor."
                return
            }
            trigger = triggerOnly(for: shortcut)
            modifiers = Set(modifiers(in: shortcut))
            selectedShortcut = shortcut
            parseError = nil
        } catch {
            trigger = nil
            selectedShortcut = nil
            modifiers = []
            parseError = error.localizedDescription
        }
    }

    mutating func select(_ shortcut: InputShortcut) {
        guard allowsMouse || isKeyboardShortcut(shortcut) else {
            trigger = nil
            selectedShortcut = nil
            parseError = "Mouse shortcuts are unavailable in this editor."
            return
        }

        do {
            representation = try ShortcutSender.format(shortcut)
            trigger = triggerOnly(for: shortcut)
            modifiers = Set(modifiers(in: shortcut))
            selectedShortcut = shortcut
            parseError = nil
        } catch {
            trigger = nil
            selectedShortcut = nil
            parseError = error.localizedDescription
        }
    }

    mutating func removeTrigger() {
        trigger = nil
        selectedShortcut = nil
        representation = ""
        parseError = nil
    }

    mutating func toggleModifier(_ modifier: ShortcutModifier) {
        var updatedModifiers = modifiers
        if updatedModifiers.contains(modifier) {
            updatedModifiers.remove(modifier)
        } else {
            updatedModifiers.insert(modifier)
        }

        guard let trigger else {
            modifiers = updatedModifiers
            representation = ""
            selectedShortcut = nil
            parseError = nil
            return
        }

        let orderedModifiers = ShortcutModifier.allCases.filter(updatedModifiers.contains)
        switch trigger {
        case .keyboard(let shortcut):
            select(.keyboard(KeyboardShortcut(keyCode: shortcut.keyCode, modifiers: orderedModifiers)))
        case .mouseClick(let shortcut):
            select(.mouseClick(MouseShortcut(button: shortcut.button, modifiers: orderedModifiers)))
        }
    }

    func isModifierSelected(_ modifier: ShortcutModifier) -> Bool {
        modifiers.contains(modifier)
    }

    private func triggerOnly(for shortcut: InputShortcut) -> InputShortcut {
        switch shortcut {
        case .keyboard(let keyboard):
            .keyboard(KeyboardShortcut(keyCode: keyboard.keyCode))
        case .mouseClick(let mouse):
            .mouseClick(MouseShortcut(button: mouse.button))
        }
    }

    private func modifiers(in shortcut: InputShortcut) -> [ShortcutModifier] {
        switch shortcut {
        case .keyboard(let keyboard): keyboard.modifiers
        case .mouseClick(let mouse): mouse.modifiers
        }
    }

    private func isKeyboardShortcut(_ shortcut: InputShortcut) -> Bool {
        if case .keyboard = shortcut { true } else { false }
    }
}
