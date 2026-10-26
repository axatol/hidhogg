import Foundation
import HidhoggDomain
import TOML

public enum ConfigurationCodec {
    public static let maximumFileSize = 256 * 1024

    public static func decode(_ data: Data) throws -> AppConfiguration {
        guard data.count <= maximumFileSize else {
            throw ConfigurationError.fileTooLarge
        }

        let decoder = TOMLDecoder()
        decoder.limits = .init(
            maxInputSize: maximumFileSize,
            maxDepth: 12,
            maxTableKeys: 512,
            maxArrayLength: 256,
            maxStringLength: maximumFileSize
        )

        do {
            let document = try decoder.decode(ConfigurationDocument.self, from: data)
            guard document.schemaVersion == AppConfiguration.currentVersion else {
                throw ConfigurationError.unsupportedVersion(document.schemaVersion)
            }
            return try document.configuration.validated()
        } catch let error as ConfigurationError {
            throw error
        } catch let error as ConfigurationValidationError {
            throw ConfigurationError.invalidConfiguration(error.localizedDescription)
        } catch {
            throw ConfigurationError.invalidDocument
        }
    }

    public static func encode(_ configuration: AppConfiguration) throws -> Data {
        let validated: AppConfiguration
        do {
            validated = try configuration.validated()
        } catch {
            throw ConfigurationError.invalidConfiguration(error.localizedDescription)
        }

        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        do {
            let data = try encoder.encode(ConfigurationDocument(configuration: validated))
            guard data.count <= maximumFileSize else {
                throw ConfigurationError.fileTooLarge
            }
            return data
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.encodingFailed
        }
    }
}

private struct ConfigurationDocument: Codable {
    let schemaVersion: Int
    let connectOnLaunch: Bool
    let devices: [DeviceDocument]
    let d200x: D200XDocument?

    var configuration: AppConfiguration {
        AppConfiguration(
            schemaVersion: schemaVersion,
            devices: devices.map(\.configuration),
            connectOnLaunch: connectOnLaunch,
            d200x: d200x?.configuration
        )
    }

    init(configuration: AppConfiguration) {
        self.schemaVersion = configuration.schemaVersion
        self.connectOnLaunch = configuration.connectOnLaunch
        self.devices = configuration.devices.map(DeviceDocument.init(configuration:))
        self.d200x = configuration.d200x.map(D200XDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["schema_version", "connect_on_launch", "devices", "d200x"])
        schemaVersion = try container.decode(Int.self, forKey: AnyCodingKey("schema_version"))
        connectOnLaunch = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("connect_on_launch")) ?? true
        devices = try container.decode([DeviceDocument].self, forKey: AnyCodingKey("devices"))
        d200x = try container.decodeIfPresent(D200XDocument.self, forKey: AnyCodingKey("d200x"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(connectOnLaunch, forKey: .connectOnLaunch)
        try container.encode(devices, forKey: .devices)
        try container.encodeIfPresent(d200x, forKey: .d200x)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case connectOnLaunch = "connect_on_launch"
        case devices
        case d200x
    }
}

private struct D200XDocument: Codable {
    let defaults: [String: D200XBindingDocument]
    let applications: [String: [String: D200XBindingDocument]]
    let tiles: [String: D200XTileAppearanceDocument]
    let brightnessPercent: Int?
    let actions: [String: ExecutableDocument]
    let nativeActions: [String: NativeActionDocument]
    let notificationTopics: [String: [String]]
    let applicationTiles: [String: [String: D200XTileAppearanceDocument]]
    let applicationNotificationTopics: [String: [String: [String]]]
    let tilePresets: [String: D200XTilePresetDocument]

    var configuration: D200XConfiguration {
        D200XConfiguration(
            defaults: defaults.mapValues(\.configuration),
            applications: applications.mapValues { $0.mapValues(\.configuration) },
            tiles: tiles.mapValues(\.configuration),
            brightnessPercent: brightnessPercent,
            actions: actions.mapValues(\.configuration),
            notificationTopics: notificationTopics,
            applicationTiles: applicationTiles.mapValues { $0.mapValues(\.configuration) },
            applicationNotificationTopics: applicationNotificationTopics,
            tilePresets: tilePresets.mapValues(\.configuration),
            nativeActions: nativeActions.mapValues(\.configuration)
        )
    }

    init(configuration: D200XConfiguration) {
        defaults = configuration.defaults.mapValues(D200XBindingDocument.init(configuration:))
        applications = configuration.applications.mapValues {
            $0.mapValues(D200XBindingDocument.init(configuration:))
        }
        tiles = configuration.tiles.mapValues(D200XTileAppearanceDocument.init(configuration:))
        brightnessPercent = configuration.brightnessPercent
        actions = configuration.actions.mapValues(ExecutableDocument.init(configuration:))
        nativeActions = configuration.nativeActions.mapValues(NativeActionDocument.init(configuration:))
        notificationTopics = configuration.notificationTopics
        applicationTiles = configuration.applicationTiles.mapValues { $0.mapValues(D200XTileAppearanceDocument.init(configuration:)) }
        applicationNotificationTopics = configuration.applicationNotificationTopics
        tilePresets = configuration.tilePresets.mapValues(D200XTilePresetDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["defaults", "applications", "tiles", "brightness_percent", "actions", "native_actions", "notification_topics", "application_tiles", "application_notification_topics", "tile_presets"])
        nativeActions = try container.decodeIfPresent([String: NativeActionDocument].self, forKey: AnyCodingKey("native_actions")) ?? [:]
        applicationTiles = try container.decodeIfPresent([String: [String: D200XTileAppearanceDocument]].self, forKey: AnyCodingKey("application_tiles")) ?? [:]
        applicationNotificationTopics = try container.decodeIfPresent([String: [String: [String]]].self, forKey: AnyCodingKey("application_notification_topics")) ?? [:]
        tilePresets = try container.decodeIfPresent([String: D200XTilePresetDocument].self, forKey: AnyCodingKey("tile_presets")) ?? [:]
        defaults = try container.decodeIfPresent(
            [String: D200XBindingDocument].self,
            forKey: AnyCodingKey("defaults")
        ) ?? [:]
        applications = try container.decodeIfPresent(
            [String: [String: D200XBindingDocument]].self,
            forKey: AnyCodingKey("applications")
        ) ?? [:]
        brightnessPercent = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("brightness_percent"))
        actions = try container.decodeIfPresent([String: ExecutableDocument].self, forKey: AnyCodingKey("actions")) ?? [:]
        notificationTopics = try container.decodeIfPresent([String: [String]].self, forKey: AnyCodingKey("notification_topics")) ?? [:]
        tiles = try container.decodeIfPresent(
            [String: D200XTileAppearanceDocument].self,
            forKey: AnyCodingKey("tiles")
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaults, forKey: .defaults)
        if !applications.isEmpty {
            try container.encode(applications, forKey: .applications)
        }
        if !tiles.isEmpty {
            try container.encode(tiles, forKey: .tiles)
        }
        try container.encodeIfPresent(brightnessPercent, forKey: .brightnessPercent)
        if !actions.isEmpty { try container.encode(actions, forKey: .actions) }
        if !nativeActions.isEmpty { try container.encode(nativeActions, forKey: .nativeActions) }
        if !notificationTopics.isEmpty { try container.encode(notificationTopics, forKey: .notificationTopics) }
        if !applicationTiles.isEmpty { try container.encode(applicationTiles, forKey: .applicationTiles) }
        if !applicationNotificationTopics.isEmpty { try container.encode(applicationNotificationTopics, forKey: .applicationNotificationTopics) }
        if !tilePresets.isEmpty { try container.encode(tilePresets, forKey: .tilePresets) }
    }

    private enum CodingKeys: String, CodingKey {
        case defaults
        case applications
        case tiles
        case brightnessPercent = "brightness_percent"
        case actions
        case nativeActions = "native_actions"
        case notificationTopics = "notification_topics"
        case applicationTiles = "application_tiles"
        case applicationNotificationTopics = "application_notification_topics"
        case tilePresets = "tile_presets"
    }
}

private struct D200XTilePresetDocument: Codable {
    let name: String
    let appearance: D200XTileAppearanceDocument
    let binding: D200XBindingDocument?
    let actions: [String: ExecutableDocument]
    let nativeActions: [String: NativeActionDocument]

    var configuration: D200XTilePreset {
        D200XTilePreset(name: name, appearance: appearance.configuration,
            binding: binding?.configuration, actions: actions.mapValues(\.configuration),
            nativeActions: nativeActions.mapValues(\.configuration))
    }

    init(configuration: D200XTilePreset) {
        name = configuration.name
        appearance = D200XTileAppearanceDocument(configuration: configuration.appearance)
        binding = configuration.binding.map(D200XBindingDocument.init(configuration:))
        actions = configuration.actions.mapValues(ExecutableDocument.init(configuration:))
        nativeActions = configuration.nativeActions.mapValues(NativeActionDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["name", "appearance", "binding", "actions", "native_actions"])
        nativeActions = try container.decodeIfPresent([String: NativeActionDocument].self, forKey: AnyCodingKey("native_actions")) ?? [:]
        name = try container.decode(String.self, forKey: AnyCodingKey("name"))
        appearance = try container.decode(D200XTileAppearanceDocument.self, forKey: AnyCodingKey("appearance"))
        binding = try container.decodeIfPresent(D200XBindingDocument.self, forKey: AnyCodingKey("binding"))
        actions = try container.decodeIfPresent([String: ExecutableDocument].self, forKey: AnyCodingKey("actions")) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(appearance, forKey: .appearance)
        try container.encodeIfPresent(binding, forKey: .binding)
        if !actions.isEmpty { try container.encode(actions, forKey: .actions) }
        if !nativeActions.isEmpty { try container.encode(nativeActions, forKey: .nativeActions) }
    }

    enum CodingKeys: String, CodingKey { case name, appearance, binding, actions; case nativeActions = "native_actions" }
}

private struct D200XTileAppearanceDocument: Codable {
    let label: String
    let backgroundHex: String
    let imageAsset: String?
    let titleSize: Double
    let titleColorHex: String?
    let titlePlacement: D200XTitlePlacement
    let titleAlignment: D200XTitleAlignment
    let showTitle: Bool

    var configuration: D200XTileAppearance {
        D200XTileAppearance(label: label, backgroundHex: backgroundHex, imageAsset: imageAsset,
                            titleSize: titleSize, titleColorHex: titleColorHex,
                            titlePlacement: titlePlacement, showTitle: showTitle, titleAlignment: titleAlignment)
    }

    init(configuration: D200XTileAppearance) {
        label = configuration.label
        backgroundHex = configuration.backgroundHex
        imageAsset = configuration.imageAsset
        titleSize = configuration.titleSize
        titleColorHex = configuration.titleColorHex
        titlePlacement = configuration.titlePlacement
        titleAlignment = configuration.titleAlignment
        showTitle = configuration.showTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["label", "background_hex", "image_asset", "title_size", "title_color_hex", "title_placement", "title_alignment", "show_title"])
        titleAlignment = try container.decodeIfPresent(D200XTitleAlignment.self, forKey: AnyCodingKey("title_alignment")) ?? .left
        label = try container.decode(String.self, forKey: AnyCodingKey("label"))
        backgroundHex = try container.decode(String.self, forKey: AnyCodingKey("background_hex"))
        imageAsset = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("image_asset"))
        titleSize = try container.decodeIfPresent(Double.self, forKey: AnyCodingKey("title_size")) ?? 22
        titleColorHex = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("title_color_hex"))
        titlePlacement = try container.decodeIfPresent(D200XTitlePlacement.self, forKey: AnyCodingKey("title_placement")) ?? .center
        showTitle = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("show_title")) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(backgroundHex, forKey: .backgroundHex)
        try container.encodeIfPresent(imageAsset, forKey: .imageAsset)
        if titleSize != 22 { try container.encode(titleSize, forKey: .titleSize) }
        try container.encodeIfPresent(titleColorHex, forKey: .titleColorHex)
        if titlePlacement != .center { try container.encode(titlePlacement, forKey: .titlePlacement) }
        if titleAlignment != .left { try container.encode(titleAlignment, forKey: .titleAlignment) }
        if !showTitle { try container.encode(showTitle, forKey: .showTitle) }
    }

    private enum CodingKeys: String, CodingKey {
        case label
        case backgroundHex = "background_hex"
        case imageAsset = "image_asset"
        case titleSize = "title_size"
        case titleColorHex = "title_color_hex"
        case titlePlacement = "title_placement"
        case titleAlignment = "title_alignment"
        case showTitle = "show_title"
    }
}

private struct D200XBindingDocument: Codable {
    let configuration: D200XBinding
    init(configuration: D200XBinding) { self.configuration = configuration }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        try c.rejectUnknownKeys(["kind", "shortcut", "action_id"])
        configuration = D200XBinding(
            kind: try c.decode(D200XBinding.Kind.self, forKey: AnyCodingKey("kind")),
            shortcut: try c.decodeIfPresent(ShortcutDocument.self, forKey: AnyCodingKey("shortcut"))?.configuration,
            actionID: try c.decodeIfPresent(String.self, forKey: AnyCodingKey("action_id"))
        )
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(configuration.kind, forKey: AnyCodingKey("kind"))
        try c.encodeIfPresent(configuration.shortcut.map(ShortcutDocument.init(configuration:)), forKey: AnyCodingKey("shortcut"))
        try c.encodeIfPresent(configuration.actionID, forKey: AnyCodingKey("action_id"))
    }
}

private struct NativeActionDocument: Codable {
    let configuration: NativeAction
    init(configuration: NativeAction) { self.configuration = configuration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        try c.rejectUnknownKeys(["kind", "media", "volume", "percent", "target", "topic", "text", "ttl_seconds", "shortcut"])
        configuration = try NativeAction(
            kind: c.decode(NativeAction.Kind.self, forKey: AnyCodingKey("kind")),
            media: c.decodeIfPresent(NativeAction.Media.self, forKey: AnyCodingKey("media")),
            volume: c.decodeIfPresent(NativeAction.Volume.self, forKey: AnyCodingKey("volume")),
            percent: c.decodeIfPresent(Int.self, forKey: AnyCodingKey("percent")),
            target: c.decodeIfPresent(String.self, forKey: AnyCodingKey("target")),
            topic: c.decodeIfPresent(String.self, forKey: AnyCodingKey("topic")),
            text: c.decodeIfPresent(String.self, forKey: AnyCodingKey("text")),
            ttlSeconds: c.decodeIfPresent(Int.self, forKey: AnyCodingKey("ttl_seconds")),
            shortcut: c.decodeIfPresent(ShortcutDocument.self, forKey: AnyCodingKey("shortcut"))?.configuration
        ).validated()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(configuration.kind, forKey: AnyCodingKey("kind"))
        try c.encodeIfPresent(configuration.media, forKey: AnyCodingKey("media"))
        try c.encodeIfPresent(configuration.volume, forKey: AnyCodingKey("volume"))
        try c.encodeIfPresent(configuration.percent, forKey: AnyCodingKey("percent"))
        try c.encodeIfPresent(configuration.target, forKey: AnyCodingKey("target"))
        try c.encodeIfPresent(configuration.topic, forKey: AnyCodingKey("topic"))
        try c.encodeIfPresent(configuration.text, forKey: AnyCodingKey("text"))
        try c.encodeIfPresent(configuration.ttlSeconds, forKey: AnyCodingKey("ttl_seconds"))
        try c.encodeIfPresent(configuration.shortcut.map(ShortcutDocument.init(configuration:)), forKey: AnyCodingKey("shortcut"))
    }
}

private struct ExecutableDocument: Codable {
    let configuration: ConfiguredExecutable
    init(configuration: ConfiguredExecutable) { self.configuration = configuration }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        try c.rejectUnknownKeys(["executable", "arguments", "working_directory", "timeout_seconds"])
        configuration = ConfiguredExecutable(
            executable: try c.decode(String.self, forKey: AnyCodingKey("executable")),
            arguments: try c.decodeIfPresent([String].self, forKey: AnyCodingKey("arguments")) ?? [],
            workingDirectory: try c.decodeIfPresent(String.self, forKey: AnyCodingKey("working_directory")),
            timeoutSeconds: try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("timeout_seconds")) ?? 10
        )
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(configuration.executable, forKey: AnyCodingKey("executable"))
        try c.encode(configuration.arguments, forKey: AnyCodingKey("arguments"))
        try c.encodeIfPresent(configuration.workingDirectory, forKey: AnyCodingKey("working_directory"))
        try c.encode(configuration.timeoutSeconds, forKey: AnyCodingKey("timeout_seconds"))
    }
}

private struct DeviceDocument: Codable {
    let id: String
    let defaults: [String: BindingDocument]
    let applications: [String: [String: BindingDocument]]
    let wheelInverted: Bool?
    let restorePreviousSettingsOnDisconnect: Bool
    let wheelHighResolution: Bool?
    let wheelScrollAmount: Double?
    let thumbwheelInverted: Bool?
    let thumbwheelScrollAmount: Double?
    let lowBatteryNotificationsEnabled: Bool

    var configuration: DeviceBindings {
        DeviceBindings(
            id: id,
            defaults: defaults.mapValues(\.configuration),
            applications: applications.mapValues { $0.mapValues(\.configuration) },
            wheelInverted: wheelInverted,
            restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect,
            wheelHighResolution: wheelHighResolution,
            wheelScrollAmount: wheelScrollAmount,
            thumbwheelInverted: thumbwheelInverted,
            thumbwheelScrollAmount: thumbwheelScrollAmount,
            lowBatteryNotificationsEnabled: lowBatteryNotificationsEnabled
        )
    }

    init(configuration: DeviceBindings) {
        self.id = configuration.id
        self.defaults = configuration.defaults.mapValues(BindingDocument.init(configuration:))
        self.applications = configuration.applications.mapValues {
            $0.mapValues(BindingDocument.init(configuration:))
        }
        self.wheelInverted = configuration.wheelInverted
        self.restorePreviousSettingsOnDisconnect = configuration.restorePreviousSettingsOnDisconnect
        self.wheelHighResolution = configuration.wheelHighResolution
        self.wheelScrollAmount = configuration.wheelScrollAmount
        self.thumbwheelInverted = configuration.thumbwheelInverted
        self.thumbwheelScrollAmount = configuration.thumbwheelScrollAmount
        self.lowBatteryNotificationsEnabled = configuration.lowBatteryNotificationsEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys([
            "id", "defaults", "applications", "wheel_inverted",
            "restore_previous_settings_on_disconnect", "wheel_high_resolution", "wheel_scroll_amount",
            "thumbwheel_inverted", "thumbwheel_scroll_amount", "low_battery_notifications_enabled"
        ])
        id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        defaults = try container.decode([String: BindingDocument].self, forKey: AnyCodingKey("defaults"))
        applications = try container.decodeIfPresent(
            [String: [String: BindingDocument]].self,
            forKey: AnyCodingKey("applications")
        ) ?? [:]
        wheelInverted = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("wheel_inverted"))
        restorePreviousSettingsOnDisconnect = try container.decodeIfPresent(
            Bool.self, forKey: AnyCodingKey("restore_previous_settings_on_disconnect")
        ) ?? false
        wheelHighResolution = try container.decodeIfPresent(
            Bool.self, forKey: AnyCodingKey("wheel_high_resolution")
        )
        wheelScrollAmount = try container.decodeIfPresent(
            Double.self, forKey: AnyCodingKey("wheel_scroll_amount")
        )
        thumbwheelInverted = try container.decodeIfPresent(
            Bool.self, forKey: AnyCodingKey("thumbwheel_inverted")
        )
        thumbwheelScrollAmount = try container.decodeIfPresent(
            Double.self, forKey: AnyCodingKey("thumbwheel_scroll_amount")
        )
        lowBatteryNotificationsEnabled = try container.decodeIfPresent(
            Bool.self, forKey: AnyCodingKey("low_battery_notifications_enabled")
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(defaults, forKey: .defaults)
        if !applications.isEmpty {
            try container.encode(applications, forKey: .applications)
        }
        try container.encodeIfPresent(wheelInverted, forKey: .wheelInverted)
        try container.encode(restorePreviousSettingsOnDisconnect, forKey: .restorePreviousSettingsOnDisconnect)
        try container.encodeIfPresent(wheelHighResolution, forKey: .wheelHighResolution)
        try container.encodeIfPresent(wheelScrollAmount, forKey: .wheelScrollAmount)
        try container.encodeIfPresent(thumbwheelInverted, forKey: .thumbwheelInverted)
        try container.encodeIfPresent(thumbwheelScrollAmount, forKey: .thumbwheelScrollAmount)
        try container.encode(lowBatteryNotificationsEnabled, forKey: .lowBatteryNotificationsEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case defaults
        case applications
        case wheelInverted = "wheel_inverted"
        case restorePreviousSettingsOnDisconnect = "restore_previous_settings_on_disconnect"
        case wheelHighResolution = "wheel_high_resolution"
        case wheelScrollAmount = "wheel_scroll_amount"
        case thumbwheelInverted = "thumbwheel_inverted"
        case thumbwheelScrollAmount = "thumbwheel_scroll_amount"
        case lowBatteryNotificationsEnabled = "low_battery_notifications_enabled"
    }
}

private struct BindingDocument: Codable {
    let kind: ControlBinding.Kind
    let shortcut: ShortcutDocument?

    var configuration: ControlBinding {
        ControlBinding(kind: kind, shortcut: shortcut?.configuration)
    }

    init(configuration: ControlBinding) {
        self.kind = configuration.kind
        self.shortcut = configuration.shortcut.map(ShortcutDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["kind", "shortcut"])
        kind = try container.decode(ControlBinding.Kind.self, forKey: AnyCodingKey("kind"))
        shortcut = try container.decodeIfPresent(ShortcutDocument.self, forKey: AnyCodingKey("shortcut"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case shortcut
    }
}

private struct ShortcutDocument: Codable {
    let keyCode: UInt16
    let modifiers: [ShortcutModifier]

    var configuration: KeyboardShortcut {
        KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    init(configuration: KeyboardShortcut) {
        self.keyCode = configuration.keyCode
        self.modifiers = configuration.modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["key_code", "modifiers"])
        keyCode = try container.decode(UInt16.self, forKey: AnyCodingKey("key_code"))
        modifiers = try container.decode([ShortcutModifier].self, forKey: AnyCodingKey("modifiers"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode = "key_code"
        case modifiers
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == AnyCodingKey {
    func rejectUnknownKeys(_ allowed: Set<String>) throws {
        guard let key = allKeys.first(where: { !allowed.contains($0.stringValue) }) else {
            return
        }
        throw ConfigurationError.unknownKey(key.stringValue)
    }
}
