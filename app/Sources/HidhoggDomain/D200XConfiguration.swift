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

public enum D200XTitlePlacement: String, Codable, CaseIterable, Sendable { case top, center, bottom }
public enum D200XTitleAlignment: String, Codable, CaseIterable, Sendable { case left, center, right }

public struct D200XTileAppearance: Codable, Equatable, Sendable {
    public static let defaultBackgroundHex = "30343B"

    public var label: String
    public var backgroundHex: String
    public var imageAsset: String?
    public var titleSize: Double
    public var titleColorHex: String?
    public var titlePlacement: D200XTitlePlacement
    public var titleAlignment: D200XTitleAlignment
    public var showTitle: Bool

    public init(label: String = "Key 1", backgroundHex: String = Self.defaultBackgroundHex,
                imageAsset: String? = nil, titleSize: Double = 22, titleColorHex: String? = nil,
                titlePlacement: D200XTitlePlacement = .center, showTitle: Bool = true,
                titleAlignment: D200XTitleAlignment = .left) {
        self.label = label
        self.backgroundHex = backgroundHex
        self.imageAsset = imageAsset
        self.titleSize = titleSize
        self.titleColorHex = titleColorHex
        self.titlePlacement = titlePlacement
        self.titleAlignment = titleAlignment
        self.showTitle = showTitle
    }

    public func isValid() -> Bool {
        label.count <= 64 && Self.isHexColor(backgroundHex)
            && titleSize.isFinite && (8...48).contains(titleSize)
            && (titleColorHex.map(Self.isHexColor) ?? true)
            && (imageAsset.map(Self.isValidAssetReference) ?? true)
    }

    public static func isValidAssetReference(_ value: String) -> Bool {
        let stem = value.dropLast(4)
        return value.hasSuffix(".png") && stem.utf8.count == 64
            && stem.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isHexColor(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

public struct D200XConfiguration: Codable, Equatable, Sendable {
    public var defaults: [String: D200XBinding]
    public var applications: [String: [String: D200XBinding]]
    public var tiles: [String: D200XTileAppearance]
    public var brightnessPercent: Int?
    public var wideDisplayMode: D200XWideDisplayMode
    public var clockFormat: D200XClockFormat
    public var actions: [String: ConfiguredExecutable]
    public var nativeActions: [String: NativeAction]
    public var notificationTopics: [String: [String]]
    public var applicationTiles: [String: [String: D200XTileAppearance]]
    public var applicationNotificationTopics: [String: [String: [String]]]
    public var tilePresets: [String: D200XTilePreset]
    public var dialRotationPresets: [String: D200XDialRotationPreset]

    public init(
        defaults: [String: D200XBinding] = [:],
        applications: [String: [String: D200XBinding]] = [:],
        tiles: [String: D200XTileAppearance] = [:],
        brightnessPercent: Int? = nil,
        actions: [String: ConfiguredExecutable] = [:],
        notificationTopics: [String: [String]] = [:],
        applicationTiles: [String: [String: D200XTileAppearance]] = [:],
        applicationNotificationTopics: [String: [String: [String]]] = [:],
        tilePresets: [String: D200XTilePreset] = [:],
        nativeActions: [String: NativeAction] = [:],
        wideDisplayMode: D200XWideDisplayMode = .custom,
        clockFormat: D200XClockFormat = .twentyFourHour,
        dialRotationPresets: [String: D200XDialRotationPreset] = [:]
    ) {
        self.defaults = defaults
        self.applications = applications
        self.tiles = tiles
        self.brightnessPercent = brightnessPercent
        self.wideDisplayMode = wideDisplayMode
        self.clockFormat = clockFormat
        self.actions = actions
        self.nativeActions = nativeActions
        self.notificationTopics = notificationTopics
        self.applicationTiles = applicationTiles
        self.applicationNotificationTopics = applicationNotificationTopics
        self.tilePresets = tilePresets
        self.dialRotationPresets = dialRotationPresets
    }

    enum CodingKeys: String, CodingKey {
        case defaults, applications, tiles, brightnessPercent, wideDisplayMode, clockFormat, actions, nativeActions, notificationTopics, applicationTiles, applicationNotificationTopics, tilePresets, dialRotationPresets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaults = try container.decode([String: D200XBinding].self, forKey: .defaults)
        applications = try container.decode([String: [String: D200XBinding]].self, forKey: .applications)
        tiles = try container.decode([String: D200XTileAppearance].self, forKey: .tiles)
        brightnessPercent = try container.decodeIfPresent(Int.self, forKey: .brightnessPercent)
        wideDisplayMode = try container.decode(D200XWideDisplayMode.self, forKey: .wideDisplayMode)
        clockFormat = try container.decode(D200XClockFormat.self, forKey: .clockFormat)
        actions = try container.decode([String: ConfiguredExecutable].self, forKey: .actions)
        nativeActions = try container.decode([String: NativeAction].self, forKey: .nativeActions)
        notificationTopics = try container.decode([String: [String]].self, forKey: .notificationTopics)
        applicationTiles = try container.decode([String: [String: D200XTileAppearance]].self, forKey: .applicationTiles)
        applicationNotificationTopics = try container.decode([String: [String: [String]]].self, forKey: .applicationNotificationTopics)
        tilePresets = try container.decode([String: D200XTilePreset].self, forKey: .tilePresets)
        dialRotationPresets = try container.decodeIfPresent([String: D200XDialRotationPreset].self, forKey: .dialRotationPresets) ?? [:]
    }

    public static let empty = Self()

    public var actionIDs: [String] { Set(actions.keys).union(nativeActions.keys).sorted() }

    public func actionDefinition(id: String) -> ConfiguredActionDefinition? {
        if let executable = actions[id] { return .executable(executable) }
        return nativeActions[id].map(ConfiguredActionDefinition.native)
    }

    public func binding(for control: D200XControl, application: String?) -> D200XBinding {
        if let application, let override = applications[application]?[control.rawValue] {
            return override
        }
        return defaults[control.rawValue] ?? .disabled
    }

    public func appearance(for control: D200XControl, application: String? = nil) -> D200XTileAppearance {
        if let application, let appearance = applicationTiles[application]?[control.rawValue] { return appearance }
        return tiles[control.rawValue] ?? Self.defaultAppearance(for: control)
    }

    public var applicationIDs: [String] {
        Set(applications.keys).union(applicationTiles.keys).union(applicationNotificationTopics.keys).sorted()
    }

    public func topics(for control: D200XControl, application: String?) -> [String] {
        if let application, let topics = applicationNotificationTopics[application]?[control.rawValue] { return topics }
        return notificationTopics[control.rawValue] ?? []
    }

    public func resolved(application: String?) -> Self {
        var result = self
        if let application {
            result.defaults.merge(applications[application] ?? [:]) { _, override in override }
            result.tiles.merge(applicationTiles[application] ?? [:]) { _, override in override }
            result.notificationTopics.merge(applicationNotificationTopics[application] ?? [:]) { _, override in override }
        }
        result.applications = [:]
        result.applicationTiles = [:]
        result.applicationNotificationTopics = [:]
        result.tilePresets = [:]
        result.dialRotationPresets = [:]
        return result
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
            guard binding.isValid(actions: actions, nativeActions: nativeActions) else {
                throw ConfigurationValidationError.invalidShortcut
            }
        }

        guard Set(tiles.keys).isSubset(of: knownTiles), tiles.values.allSatisfy({ $0.isValid() }) else {
            throw ConfigurationValidationError.invalidD200XAppearance
        }

        guard brightnessPercent.map({ (1...100).contains($0) }) ?? true,
              actionIDs.count <= 64, actionIDs.allSatisfy(ConfiguredExecutable.isValidIdentifier),
              Set(actions.keys).isDisjoint(with: nativeActions.keys),
              Set(notificationTopics.keys).isSubset(of: knownTiles),
              notificationTopics.values.allSatisfy({ topics in
                  topics.count <= 16 && Set(topics).count == topics.count
                      && topics.allSatisfy(NotificationTopic.isValidFilter)
              }) else { throw ConfigurationValidationError.invalidD200XAction }
        for action in actions.values { _ = try action.validated() }
        for action in nativeActions.values { _ = try action.validated() }

        guard applicationIDs.count <= 128,
              applicationIDs.allSatisfy(ConfigurationValueValidation.isValid(application:)),
              applicationTiles.values.allSatisfy({ Set($0.keys).isSubset(of: knownTiles) && $0.values.allSatisfy { $0.isValid() } }),
              applicationNotificationTopics.values.allSatisfy({ overrides in
                  Set(overrides.keys).isSubset(of: knownTiles) && overrides.values.allSatisfy { topics in
                      topics.count <= 16 && Set(topics).count == topics.count && topics.allSatisfy(NotificationTopic.isValidFilter)
                  }
              }), tilePresets.count <= 128,
              tilePresets.keys.allSatisfy(ConfiguredExecutable.isValidIdentifier),
              dialRotationPresets.count <= 128,
              dialRotationPresets.keys.allSatisfy(ConfiguredExecutable.isValidIdentifier) else {
            throw ConfigurationValidationError.invalidD200XAppearance
        }
        for preset in tilePresets.values { _ = try preset.validated() }
        for preset in dialRotationPresets.values { _ = try preset.validated() }

        return self
    }
}
