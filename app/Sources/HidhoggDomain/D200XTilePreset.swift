import Foundation

public struct D200XTilePreset: Codable, Equatable, Sendable {
    public var name: String
    public var appearance: D200XTileAppearance
    public var binding: D200XBinding?
    public var actions: [String: ConfiguredExecutable]
    public var nativeActions: [String: NativeAction]

    public init(name: String, appearance: D200XTileAppearance, binding: D200XBinding? = nil,
                actions: [String: ConfiguredExecutable] = [:], nativeActions: [String: NativeAction] = [:]) {
        self.name = name
        self.appearance = appearance
        self.binding = binding
        self.actions = actions
        self.nativeActions = nativeActions
    }

    public func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
              appearance.isValid(), actions.count + nativeActions.count <= 1,
              Set(actions.keys).union(nativeActions.keys) == Set(binding?.actionID.map { [$0] } ?? []),
              Set(actions.keys).union(nativeActions.keys).allSatisfy(ConfiguredExecutable.isValidIdentifier),
              binding.map({ $0.isValid(actions: actions, nativeActions: nativeActions) }) ?? (actions.isEmpty && nativeActions.isEmpty) else {
            throw ConfigurationValidationError.invalidD200XAppearance
        }
        for action in actions.values { _ = try action.validated() }
        for action in nativeActions.values { _ = try action.validated() }
        return self
    }

    enum CodingKeys: String, CodingKey { case name, appearance, binding, actions, nativeActions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        appearance = try container.decode(D200XTileAppearance.self, forKey: .appearance)
        binding = try container.decodeIfPresent(D200XBinding.self, forKey: .binding)
        actions = try container.decodeIfPresent([String: ConfiguredExecutable].self, forKey: .actions) ?? [:]
        nativeActions = try container.decodeIfPresent([String: NativeAction].self, forKey: .nativeActions) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(appearance, forKey: .appearance)
        try container.encodeIfPresent(binding, forKey: .binding)
        try container.encode(actions, forKey: .actions)
        if !nativeActions.isEmpty { try container.encode(nativeActions, forKey: .nativeActions) }
    }
}
