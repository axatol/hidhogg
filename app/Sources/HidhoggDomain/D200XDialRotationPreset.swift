import Foundation

public struct D200XDialRotationPreset: Codable, Equatable, Sendable {
    public var name: String
    public var left: D200XBinding
    public var right: D200XBinding
    public var actions: [String: ConfiguredExecutable]
    public var nativeActions: [String: NativeAction]

    public init(name: String, left: D200XBinding, right: D200XBinding,
                actions: [String: ConfiguredExecutable] = [:], nativeActions: [String: NativeAction] = [:]) {
        self.name = name
        self.left = left
        self.right = right
        self.actions = actions
        self.nativeActions = nativeActions
    }

    public func validated() throws -> Self {
        let referenced = Set([left.actionID, right.actionID].compactMap { $0 })
        let identifiers = Set(actions.keys).union(nativeActions.keys)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
              actions.count + nativeActions.count <= 2,
              Set(actions.keys).isDisjoint(with: nativeActions.keys), identifiers == referenced,
              identifiers.allSatisfy(ConfiguredExecutable.isValidIdentifier),
              left.isValid(actions: actions, nativeActions: nativeActions),
              right.isValid(actions: actions, nativeActions: nativeActions) else {
            throw ConfigurationValidationError.invalidD200XAction
        }
        for action in actions.values { _ = try action.validated() }
        for action in nativeActions.values { _ = try action.validated() }
        return self
    }

    enum CodingKeys: String, CodingKey { case name, left, right, actions, nativeActions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        left = try container.decode(D200XBinding.self, forKey: .left)
        right = try container.decode(D200XBinding.self, forKey: .right)
        actions = try container.decodeIfPresent([String: ConfiguredExecutable].self, forKey: .actions) ?? [:]
        nativeActions = try container.decodeIfPresent([String: NativeAction].self, forKey: .nativeActions) ?? [:]
    }
}
