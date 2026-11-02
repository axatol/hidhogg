import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import HidhoggDomain

public enum InputPermission: String, Equatable, Sendable {
    case granted, denied
}

public struct PermissionChecks: Equatable, Sendable {
    public let accessibilityTrusted: Bool
    public let eventPostingAllowed: Bool

    public init(accessibilityTrusted: Bool, eventPostingAllowed: Bool) {
        self.accessibilityTrusted = accessibilityTrusted
        self.eventPostingAllowed = eventPostingAllowed
    }
}

public enum ShortcutDeliveryError: Error, LocalizedError {
    case permissionDenied, invalidShortcut, allocationFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Input control permission is required."
        case .invalidShortcut: "The shortcut is invalid."
        case .allocationFailed: "macOS could not create the input events."
        }
    }
}

public struct ShortcutKeyOption: Equatable, Hashable, Identifiable, Sendable {
    public let keyCode: UInt16
    public let name: String
    public let label: String

    public var id: UInt16 { keyCode }
    public var shortcut: KeyboardShortcut { KeyboardShortcut(keyCode: keyCode) }

    public init(keyCode: UInt16, name: String, label: String) {
        self.keyCode = keyCode
        self.name = name
        self.label = label
    }
}

@MainActor
public final class ShortcutSender {
    public private(set) var permissionChecks = PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: false)
    public var permission: InputPermission { permissionChecks.eventPostingAllowed ? .granted : .denied }
    private let accessibilityPreflight: () -> Bool
    private let preflight: () -> Bool
    private let request: () -> Bool
    private let postInputShortcut: (InputShortcut) throws -> Void

    public convenience init() {
        self.init(
            accessibilityPreflight: { AXIsProcessTrusted() },
            preflight: { CGPreflightPostEventAccess() },
            request: { CGRequestPostEventAccess() },
            postInputShortcut: { input in
                try Self.postNativeEvents(
                    input,
                    currentMouseLocation: Self.currentMouseLocation,
                    postEvent: { $0.post(tap: .cgSessionEventTap) }
                )
            }
        )
    }

    public convenience init(preflight: @escaping () -> Bool, request: @escaping () -> Bool,
                            postPair: @escaping (KeyboardShortcut) throws -> Void) {
        self.init(
            accessibilityPreflight: { false },
            preflight: preflight,
            request: request,
            postInputShortcut: { input in
                guard case let .keyboard(shortcut) = input else { throw ShortcutDeliveryError.invalidShortcut }
                try postPair(shortcut)
            }
        )
    }

    public convenience init(accessibilityPreflight: @escaping () -> Bool,
                            preflight: @escaping () -> Bool,
                            request: @escaping () -> Bool,
                            postPair: @escaping (KeyboardShortcut) throws -> Void) {
        self.init(
            accessibilityPreflight: accessibilityPreflight,
            preflight: preflight,
            request: request,
            postInputShortcut: { input in
                guard case let .keyboard(shortcut) = input else { throw ShortcutDeliveryError.invalidShortcut }
                try postPair(shortcut)
            }
        )
    }

    public init(accessibilityPreflight: @escaping () -> Bool,
                preflight: @escaping () -> Bool,
                request: @escaping () -> Bool,
                postInputShortcut: @escaping (InputShortcut) throws -> Void) {
        self.accessibilityPreflight = accessibilityPreflight
        self.preflight = preflight
        self.request = request
        self.postInputShortcut = postInputShortcut
    }

    public convenience init(accessibilityPreflight: @escaping () -> Bool,
                            preflight: @escaping () -> Bool,
                            request: @escaping () -> Bool,
                            currentMouseLocation: @escaping () -> CGPoint,
                            postEvent: @escaping (CGEvent) throws -> Void) {
        self.init(
            accessibilityPreflight: accessibilityPreflight,
            preflight: preflight,
            request: request,
            postInputShortcut: { input in
                try Self.postNativeEvents(
                    input,
                    currentMouseLocation: currentMouseLocation,
                    postEvent: postEvent
                )
            }
        )
    }

    @discardableResult
    public func refreshPermission() -> InputPermission {
        permissionChecks = PermissionChecks(
            accessibilityTrusted: accessibilityPreflight(),
            eventPostingAllowed: preflight()
        )
        return permission
    }

    @discardableResult
    public func requestPermission() -> InputPermission {
        _ = request()
        return refreshPermission()
    }

    public func send(_ shortcut: KeyboardShortcut) throws {
        try send(.keyboard(shortcut))
    }

    public func send(_ shortcut: InputShortcut) throws {
        guard Self.isValid(shortcut) else {
            throw ShortcutDeliveryError.invalidShortcut
        }
        guard refreshPermission() == .granted else { throw ShortcutDeliveryError.permissionDenied }
        try postInputShortcut(shortcut)
    }

    public static func from(event: NSEvent) -> KeyboardShortcut? {
        guard event.type == .keyDown, !event.isARepeat, event.keyCode <= 127,
              !(54...63).contains(event.keyCode) else { return nil }
        return KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers(from: event))
    }

    public static func inputShortcut(from event: NSEvent) -> InputShortcut? {
        if let keyboard = from(event: event) { return .keyboard(keyboard) }

        let button: MouseButton
        switch event.type {
        case .leftMouseDown: button = .left
        case .rightMouseDown: button = .right
        case .otherMouseDown where event.buttonNumber == 2: button = .middle
        default: return nil
        }

        return .mouseClick(MouseShortcut(button: button, modifiers: modifiers(from: event)))
    }

    public static func label(for shortcut: KeyboardShortcut) -> String {
        modifierLabel(shortcut.modifiers) + keyLabel(shortcut.keyCode)
    }

    public static func label(for shortcut: InputShortcut) -> String {
        switch shortcut {
        case let .keyboard(keyboard): return label(for: keyboard)
        case let .mouseClick(mouse):
            let buttonLabel: String
            switch mouse.button {
            case .left: buttonLabel = "Left click"
            case .right: buttonLabel = "Right click"
            case .middle: buttonLabel = "Middle click"
            }
            let prefix = modifierLabel(mouse.modifiers)
            return prefix.isEmpty ? buttonLabel : prefix + " " + buttonLabel
        }
    }

    public static func parse(_ text: String) throws -> InputShortcut {
        try InputShortcutCodec.parse(text, keyCodeForName: keyCode(for:))
    }

    public static func format(_ shortcut: InputShortcut) throws -> String {
        try InputShortcutCodec.format(shortcut, keyNameForCode: keyName(for:))
    }

    public static var keyOptions: [ShortcutKeyOption] {
        (0...127).compactMap { code in
            let keyCode = UInt16(code)
            guard !(54...63).contains(keyCode) else { return nil }
            let label = keyLabel(keyCode)
            guard let name = keyName(for: keyCode) else { return nil }
            return ShortcutKeyOption(
                keyCode: keyCode,
                name: name,
                label: label
            )
        }
    }

    private static func keyLabel(_ code: UInt16) -> String {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌅", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let label = special[code] { return label }
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(code)"
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "Key \(code)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &deadState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "Key \(code)" }
        let result = String(utf16CodeUnits: characters, count: length).uppercased()
        return result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? "Key \(code)" : result
    }

    private static let stableKeyTokens: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        24: "Equal", 27: "Minus", 30: "RightBracket", 33: "LeftBracket", 39: "Quote", 41: "Semicolon",
        42: "Backslash", 43: "Comma", 44: "Slash", 47: "Period", 50: "Grave",
        36: "Return", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape",
        64: "F17", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
        65: "KeypadDecimal", 67: "KeypadMultiply", 69: "KeypadPlus", 71: "KeypadClear", 75: "KeypadDivide",
        76: "KeypadEnter", 78: "KeypadMinus", 81: "KeypadEquals", 82: "Keypad0", 83: "Keypad1", 84: "Keypad2",
        85: "Keypad3", 86: "Keypad4", 87: "Keypad5", 88: "Keypad6", 89: "Keypad7", 91: "Keypad8", 92: "Keypad9",
        114: "Help", 115: "Home", 116: "PageUp", 117: "ForwardDelete", 119: "End", 121: "PageDown",
        123: "Left", 124: "Right", 125: "Down", 126: "Up"
    ]

    private static func keyName(for keyCode: UInt16) -> String? {
        guard keyCode <= 127, !(54...63).contains(keyCode) else { return nil }
        return stableKeyTokens[keyCode] ?? "keycode.\(keyCode)"
    }

    private static func keyCode(for name: String) -> UInt16? {
        guard !name.hasPrefix("keycode.") else { return nil }
        return stableKeyTokens.first { $0.value.caseInsensitiveCompare(name) == .orderedSame }?.key
    }

    private static func modifiers(from event: NSEvent) -> [ShortcutModifier] {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = [ShortcutModifier]()
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.command) { modifiers.append(.command) }
        return modifiers
    }

    private static func modifierLabel(_ modifiers: [ShortcutModifier]) -> String {
        [(ShortcutModifier.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .compactMap { modifier, symbol in modifiers.contains(modifier) ? symbol : nil }
            .joined()
    }

    private static func isValid(_ shortcut: InputShortcut) -> Bool {
        switch shortcut {
        case let .keyboard(keyboard): InputShortcutCodec.isValid(keyboard)
        case let .mouseClick(mouse): InputShortcutCodec.isValid(mouse)
        }
    }

    private static func currentMouseLocation() throws -> CGPoint {
        guard let event = CGEvent(source: nil) else { throw ShortcutDeliveryError.allocationFailed }
        return event.location
    }

    private static func postNativeEvents(
        _ shortcut: InputShortcut,
        currentMouseLocation: () throws -> CGPoint,
        postEvent: (CGEvent) throws -> Void
    ) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ShortcutDeliveryError.allocationFailed
        }

        let events: [CGEvent]
        switch shortcut {
        case let .keyboard(keyboard):
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyboard.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyboard.keyCode, keyDown: false) else {
                throw ShortcutDeliveryError.allocationFailed
            }
            let flags = eventFlags(for: keyboard.modifiers)
            down.flags = flags
            up.flags = flags
            events = [down, up]
        case let .mouseClick(mouse):
            let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton)
            switch mouse.button {
            case .left: (downType, upType, button) = (.leftMouseDown, .leftMouseUp, .left)
            case .right: (downType, upType, button) = (.rightMouseDown, .rightMouseUp, .right)
            case .middle: (downType, upType, button) = (.otherMouseDown, .otherMouseUp, .center)
            }

            let location = try currentMouseLocation()
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: location, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: location, mouseButton: button) else {
                throw ShortcutDeliveryError.allocationFailed
            }
            let flags = eventFlags(for: mouse.modifiers)
            down.flags = flags
            up.flags = flags
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            events = [down, up]
        }

        for event in events { try postEvent(event) }
    }

    private static func eventFlags(for modifiers: [ShortcutModifier]) -> CGEventFlags {
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            }
        }
        return flags
    }
}
