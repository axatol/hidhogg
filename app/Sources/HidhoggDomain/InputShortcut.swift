import Foundation

public enum MouseButton: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right
    case middle
}

public struct MouseShortcut: Codable, Equatable, Hashable, Sendable {
    public var button: MouseButton
    public var modifiers: [ShortcutModifier]

    public init(button: MouseButton, modifiers: [ShortcutModifier] = []) {
        self.button = button
        self.modifiers = modifiers
    }
}

public enum InputShortcut: Hashable, Sendable {
    case keyboard(KeyboardShortcut)
    case mouseClick(MouseShortcut)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.keyboard(left), .keyboard(right)):
            left.keyCode == right.keyCode && canonical(left.modifiers) == canonical(right.modifiers)
                && left.modifiers.count == right.modifiers.count
        case let (.mouseClick(left), .mouseClick(right)):
            left.button == right.button && canonical(left.modifiers) == canonical(right.modifiers)
                && left.modifiers.count == right.modifiers.count
        case (.keyboard(_), .mouseClick(_)), (.mouseClick(_), .keyboard(_)):
            false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .keyboard(shortcut):
            hasher.combine(0)
            hasher.combine(shortcut.keyCode)
            hasher.combine(shortcut.modifiers.count)
            Self.canonical(shortcut.modifiers).forEach { hasher.combine($0) }
        case let .mouseClick(shortcut):
            hasher.combine(1)
            hasher.combine(shortcut.button)
            hasher.combine(shortcut.modifiers.count)
            Self.canonical(shortcut.modifiers).forEach { hasher.combine($0) }
        }
    }

    private static func canonical(_ modifiers: [ShortcutModifier]) -> [ShortcutModifier] {
        [.command, .control, .option, .shift].filter(modifiers.contains)
    }
}

public enum InputShortcutCodecError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case tooLong
    case malformed
    case unsupportedSequence
    case unknownModifier(String)
    case duplicateModifier(ShortcutModifier)
    case bareModifier
    case missingTrigger
    case multipleTriggers
    case unknownMouseButton(String)
    case unknownKey(String)
    case invalidShortcut
    case keyNameUnavailable(UInt16)
    case invalidKeyName

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a shortcut."
        case .tooLong: "The shortcut text is too long."
        case .malformed: "The shortcut text is malformed."
        case .unsupportedSequence: "Enter one key or mouse click with modifiers."
        case let .unknownModifier(name): "Unknown shortcut token: ${\(name)}."
        case .duplicateModifier: "Each modifier can appear only once."
        case .bareModifier: "A shortcut needs a key or mouse click after its modifiers."
        case .missingTrigger: "A shortcut needs a key or mouse click."
        case .multipleTriggers: "A shortcut can contain only one key or mouse click."
        case let .unknownMouseButton(name): "Unknown mouse button: \(name)."
        case let .unknownKey(name): "Unknown key name: \(name)."
        case .invalidShortcut: "The shortcut is invalid."
        case let .keyNameUnavailable(keyCode): "No key name is available for key code \(keyCode)."
        case .invalidKeyName: "The key name cannot be represented in shortcut text."
        }
    }
}

public enum InputShortcutCodec {
    private static let modifierTokens: [(ShortcutModifier, String)] = [
        (.command, "cmd"),
        (.control, "ctrl"),
        (.option, "option"),
        (.shift, "shift")
    ]

    public static func parse(
        _ text: String,
        keyCodeForName: (String) -> UInt16?
    ) throws -> InputShortcut {
        guard !text.isEmpty else { throw InputShortcutCodecError.empty }
        guard text.utf8.count <= 256 else { throw InputShortcutCodecError.tooLong }
        guard !text.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" }) else {
            throw InputShortcutCodecError.unsupportedSequence
        }

        let tokens = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard tokens.allSatisfy({ !$0.isEmpty }) else { throw InputShortcutCodecError.malformed }

        var modifiers = [ShortcutModifier]()
        var trigger: InputShortcut?

        for token in tokens {
            if token.hasPrefix("${") || token.hasSuffix("}") {
                guard token.hasPrefix("${"), token.hasSuffix("}"), token.count > 3 else {
                    throw InputShortcutCodecError.malformed
                }

                let name = String(token.dropFirst(2).dropLast())
                if let modifier = modifierTokens.first(where: { $0.1 == name })?.0 {
                    guard !modifiers.contains(modifier) else {
                        throw InputShortcutCodecError.duplicateModifier(modifier)
                    }
                    modifiers.append(modifier)
                    continue
                }

                if name.hasPrefix("mouse.") {
                    guard trigger == nil else { throw InputShortcutCodecError.multipleTriggers }
                    let buttonName = String(name.dropFirst("mouse.".count))
                    guard let button = MouseButton(rawValue: buttonName) else {
                        throw InputShortcutCodecError.unknownMouseButton(buttonName)
                    }
                    trigger = .mouseClick(MouseShortcut(button: button))
                    continue
                }

                if name.hasPrefix("keycode.") {
                    guard trigger == nil else { throw InputShortcutCodecError.multipleTriggers }
                    let codeText = String(name.dropFirst("keycode.".count))
                    guard let keyCode = UInt16(codeText), String(keyCode) == codeText else {
                        throw InputShortcutCodecError.malformed
                    }
                    guard isValid(keyCode: keyCode) else { throw InputShortcutCodecError.invalidShortcut }
                    trigger = .keyboard(KeyboardShortcut(keyCode: keyCode))
                    continue
                }

                throw InputShortcutCodecError.unknownModifier(name)
            }

            if isBareModifier(token) { throw InputShortcutCodecError.bareModifier }
            guard !token.contains("$") && !token.contains("{") && !token.contains("}") else {
                throw InputShortcutCodecError.malformed
            }
            guard !token.hasPrefix("keycode.") else { throw InputShortcutCodecError.malformed }
            guard let keyCode = keyCodeForName(token) else { throw InputShortcutCodecError.unknownKey(token) }
            guard isValid(keyCode: keyCode) else { throw InputShortcutCodecError.invalidShortcut }
            guard trigger == nil else { throw InputShortcutCodecError.multipleTriggers }
            trigger = .keyboard(KeyboardShortcut(keyCode: keyCode))
        }

        guard let trigger else {
            if !modifiers.isEmpty { throw InputShortcutCodecError.bareModifier }
            throw InputShortcutCodecError.missingTrigger
        }

        switch trigger {
        case let .keyboard(shortcut):
            return .keyboard(KeyboardShortcut(keyCode: shortcut.keyCode, modifiers: canonical(modifiers)))
        case let .mouseClick(shortcut):
            return .mouseClick(MouseShortcut(button: shortcut.button, modifiers: canonical(modifiers)))
        }
    }

    public static func format(
        _ shortcut: InputShortcut,
        keyNameForCode: (UInt16) -> String?
    ) throws -> String {
        switch shortcut {
        case let .keyboard(keyboard):
            guard isValid(keyboard) else { throw InputShortcutCodecError.invalidShortcut }
            guard let keyName = keyNameForCode(keyboard.keyCode) else {
                throw InputShortcutCodecError.keyNameUnavailable(keyboard.keyCode)
            }
            let keyToken: String
            if keyName.hasPrefix("keycode.") {
                let codeText = String(keyName.dropFirst("keycode.".count))
                guard let keyCode = UInt16(codeText), String(keyCode) == codeText,
                      isValid(keyCode: keyCode), keyCode == keyboard.keyCode else {
                    throw InputShortcutCodecError.invalidKeyName
                }
                keyToken = "${\(keyName)}"
            } else {
                guard isValidKeyName(keyName) else { throw InputShortcutCodecError.invalidKeyName }
                keyToken = keyName
            }
            return (try modifierPrefix(keyboard.modifiers)) + keyToken
        case let .mouseClick(mouse):
            guard isValid(mouse) else { throw InputShortcutCodecError.invalidShortcut }
            return (try modifierPrefix(mouse.modifiers)) + "${mouse.\(mouse.button.rawValue)}"
        }
    }

    public static func isValid(_ shortcut: KeyboardShortcut) -> Bool {
        isValid(keyCode: shortcut.keyCode) && hasUniqueModifiers(shortcut.modifiers)
    }

    public static func isValid(_ shortcut: MouseShortcut) -> Bool {
        hasUniqueModifiers(shortcut.modifiers)
    }

    private static func modifierPrefix(_ modifiers: [ShortcutModifier]) throws -> String {
        guard hasUniqueModifiers(modifiers) else { throw InputShortcutCodecError.invalidShortcut }
        let tokens = canonical(modifiers).compactMap { modifier in
            modifierTokens.first(where: { $0.0 == modifier }).map { "${\($0.1)}" }
        }
        return tokens.isEmpty ? "" : tokens.joined(separator: "+") + "+"
    }

    private static func canonical(_ modifiers: [ShortcutModifier]) -> [ShortcutModifier] {
        modifierTokens.map(\.0).filter(modifiers.contains)
    }

    private static func hasUniqueModifiers(_ modifiers: [ShortcutModifier]) -> Bool {
        Set(modifiers).count == modifiers.count
    }

    private static func isValid(keyCode: UInt16) -> Bool {
        keyCode <= 127 && !(54...63).contains(keyCode)
    }

    private static func isValidKeyName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 64
            && !name.contains(where: { $0.isWhitespace || $0 == "+" || $0 == "," || $0 == ";" })
            && !name.contains("$")
            && !name.contains("{")
            && !name.contains("}")
            && !isBareModifier(name)
    }

    private static func isBareModifier(_ token: String) -> Bool {
        modifierTokens.contains(where: { $0.1 == token })
    }
}
