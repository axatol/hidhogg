import AppKit
import Carbon
import CoreGraphics
import HidhoggDomain

public enum InputPermission: String, Equatable, Sendable {
    case granted, denied
}

public enum ShortcutDeliveryError: Error, LocalizedError {
    case permissionDenied, invalidShortcut, allocationFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Keyboard control permission is required."
        case .invalidShortcut: "The keyboard shortcut is invalid."
        case .allocationFailed: "macOS could not create the keyboard events."
        }
    }
}

@MainActor
public final class ShortcutSender {
    public private(set) var permission: InputPermission = .denied
    private let preflight: () -> Bool
    private let request: () -> Bool
    private let postPair: (KeyboardShortcut) throws -> Void

    public init() {
        preflight = { CGPreflightPostEventAccess() }
        request = { CGRequestPostEventAccess() }
        postPair = Self.postNativePair
    }

    public init(preflight: @escaping () -> Bool, request: @escaping () -> Bool,
                postPair: @escaping (KeyboardShortcut) throws -> Void) {
        self.preflight = preflight
        self.request = request
        self.postPair = postPair
    }

    @discardableResult
    public func refreshPermission() -> InputPermission {
        permission = preflight() ? .granted : .denied
        return permission
    }

    @discardableResult
    public func requestPermission() -> InputPermission {
        _ = request()
        return refreshPermission()
    }

    public func send(_ shortcut: KeyboardShortcut) throws {
        guard shortcut.keyCode <= 127, !(54...63).contains(shortcut.keyCode),
              Set(shortcut.modifiers).count == shortcut.modifiers.count else {
            throw ShortcutDeliveryError.invalidShortcut
        }
        guard refreshPermission() == .granted else { throw ShortcutDeliveryError.permissionDenied }
        try postPair(shortcut)
    }

    public static func from(event: NSEvent) -> KeyboardShortcut? {
        guard event.type == .keyDown, !event.isARepeat, event.keyCode <= 127,
              !(54...63).contains(event.keyCode) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = [ShortcutModifier]()
        if flags.contains(.control) { modifiers.append(.control) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.command) { modifiers.append(.command) }
        return KeyboardShortcut(keyCode: event.keyCode, modifiers: modifiers)
    }

    public static func label(for shortcut: KeyboardShortcut) -> String {
        var prefix = ""
        for (modifier, symbol) in [(ShortcutModifier.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
            if shortcut.modifiers.contains(modifier) { prefix += symbol }
        }
        return prefix + keyLabel(shortcut.keyCode)
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

    private static func postNativePair(_ shortcut: KeyboardShortcut) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else {
            throw ShortcutDeliveryError.allocationFailed
        }
        var flags = CGEventFlags()
        for modifier in shortcut.modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            }
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
