public enum NavigationPreset: String, CaseIterable, Identifiable, Sendable {
    case pageBack
    case pageForward

    public var id: Self { self }

    public var title: String {
        switch self {
        case .pageBack: "Page Back"
        case .pageForward: "Page Forward"
        }
    }

    public var shortcut: KeyboardShortcut {
        switch self {
        case .pageBack: KeyboardShortcut(keyCode: 33, modifiers: [.command])
        case .pageForward: KeyboardShortcut(keyCode: 30, modifiers: [.command])
        }
    }
}
