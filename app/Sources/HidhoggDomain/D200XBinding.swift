import Foundation

public struct D200XBinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case disabled, shortcut, action }
    public var kind: Kind
    public var shortcut: KeyboardShortcut?
    public var actionID: String?

    public init(kind: Kind, shortcut: KeyboardShortcut? = nil, actionID: String? = nil) {
        self.kind = kind
        self.shortcut = shortcut
        self.actionID = actionID
    }

    public static let disabled = Self(kind: .disabled)
    public static func key(_ shortcut: KeyboardShortcut) -> Self { Self(kind: .shortcut, shortcut: shortcut) }
    public static func action(_ id: String) -> Self { Self(kind: .action, actionID: id) }

    func isValid(actions: [String: ConfiguredExecutable], nativeActions: [String: NativeAction] = [:]) -> Bool {
        switch kind {
        case .disabled: shortcut == nil && actionID == nil
        case .shortcut: actionID == nil && ConfigurationValueValidation.isValid(binding: ControlBinding(kind: .shortcut, shortcut: shortcut))
        case .action: shortcut == nil && actionID.map { actions[$0] != nil || nativeActions[$0] != nil } == true
        }
    }
}
