import Foundation

public enum D200XGesture: UInt8, Codable, CaseIterable, Hashable, Sendable {
    case press = 1
    case left = 2
    case right = 3
    case heldLeft = 4
    case heldRight = 5

    public var title: String {
        switch self {
        case .press: "Press"
        case .left: "Left"
        case .right: "Right"
        case .heldLeft: "Held Left"
        case .heldRight: "Held Right"
        }
    }
}

public enum D200XControl: String, Codable, CaseIterable, Hashable, Sendable {
    case key0
    case key1
    case key2
    case key3
    case key4
    case key5
    case key6
    case key7
    case key8
    case key9
    case key10
    case key11
    case key12
    case key13
    case side0
    case side1
    case dial0Press
    case dial0Left
    case dial0Right
    case dial0HeldLeft
    case dial0HeldRight
    case dial1Press
    case dial1Left
    case dial1Right
    case dial1HeldLeft
    case dial1HeldRight
    case dial2Press
    case dial2Left
    case dial2Right
    case dial2HeldLeft
    case dial2HeldRight

    public var title: String {
        if let keyIndex {
            return "Key \(keyIndex + 1)"
        }

        switch self {
        case .side0: return "Front button 1"
        case .side1: return "Front button 2"
        default:
            guard let gesture else { return rawValue.capitalized }
            return "Dial \(wireIndex - 16) \(gesture.title)"
        }
    }

    public var wireIndex: Int {
        switch self {
        case .key0: 0
        case .key1: 1
        case .key2: 2
        case .key3: 3
        case .key4: 4
        case .key5: 5
        case .key6: 6
        case .key7: 7
        case .key8: 8
        case .key9: 9
        case .key10: 10
        case .key11: 11
        case .key12: 12
        case .key13: 13
        case .side0: 15
        case .side1: 16
        case .dial0Press, .dial0Left, .dial0Right, .dial0HeldLeft, .dial0HeldRight: 17
        case .dial1Press, .dial1Left, .dial1Right, .dial1HeldLeft, .dial1HeldRight: 18
        case .dial2Press, .dial2Left, .dial2Right, .dial2HeldLeft, .dial2HeldRight: 19
        }
    }

    public var gesture: D200XGesture? {
        switch self {
        case .dial0Press, .dial1Press, .dial2Press: .press
        case .dial0Left, .dial1Left, .dial2Left: .left
        case .dial0Right, .dial1Right, .dial2Right: .right
        case .dial0HeldLeft, .dial1HeldLeft, .dial2HeldLeft: .heldLeft
        case .dial0HeldRight, .dial1HeldRight, .dial2HeldRight: .heldRight
        default: nil
        }
    }

    public var isTile: Bool { keyIndex != nil }

    private var keyIndex: Int? {
        guard rawValue.hasPrefix("key") else { return nil }
        return Int(rawValue.dropFirst(3))
    }
}

public struct D200XTileAppearance: Codable, Equatable, Sendable {
    public static let defaultBackgroundHex = "30343B"

    public var label: String
    public var backgroundHex: String

    public init(label: String = "Key 1", backgroundHex: String = Self.defaultBackgroundHex) {
        self.label = label
        self.backgroundHex = backgroundHex
    }

    func isValid() -> Bool {
        label.count <= 64 && Self.isHexColor(backgroundHex)
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

public struct D200XConfiguration: Codable, Equatable, Sendable {
    public var defaults: [String: ControlBinding]
    public var applications: [String: [String: ControlBinding]]
    public var tiles: [String: D200XTileAppearance]

    public init(
        defaults: [String: ControlBinding] = [:],
        applications: [String: [String: ControlBinding]] = [:],
        tiles: [String: D200XTileAppearance] = [:]
    ) {
        self.defaults = defaults
        self.applications = applications
        self.tiles = tiles
    }

    public static let empty = Self()

    public func binding(for control: D200XControl, application: String?) -> ControlBinding {
        if let application, let override = applications[application]?[control.rawValue] {
            return override
        }
        return defaults[control.rawValue] ?? .disabled
    }

    public func appearance(for control: D200XControl) -> D200XTileAppearance {
        tiles[control.rawValue] ?? Self.defaultAppearance(for: control)
    }

    public static func defaultAppearance(for control: D200XControl) -> D200XTileAppearance {
        D200XTileAppearance(label: control.title)
    }

    public func validated() throws -> Self {
        let knownControls = Set(D200XControl.allCases.map(\.rawValue))
        let knownTiles = Set(D200XControl.allCases.filter(\.isTile).map(\.rawValue))

        guard Set(defaults.keys).isSubset(of: knownControls), applications.count <= 128 else {
            throw ConfigurationValidationError.invalidD200XControls
        }

        for (application, overrides) in applications {
            guard ConfigurationValueValidation.isValid(application: application),
                  Set(overrides.keys).isSubset(of: knownControls) else {
                throw ConfigurationValidationError.invalidApplication
            }
        }

        for binding in Array(defaults.values) + applications.values.flatMap({ $0.values }) {
            guard ConfigurationValueValidation.isValid(binding: binding) else {
                throw ConfigurationValidationError.invalidShortcut
            }
        }

        guard Set(tiles.keys).isSubset(of: knownTiles), tiles.values.allSatisfy({ $0.isValid() }) else {
            throw ConfigurationValidationError.invalidD200XAppearance
        }

        return self
    }
}
