import CryptoKit
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
    let wideDisplayMode: D200XWideDisplayMode
    let clockFormat: D200XClockFormat
    let actions: [String: ExecutableDocument]
    let nativeActions: [String: NativeActionDocument]
    let notificationTopics: [String: [String]]
    let applicationTiles: [String: [String: D200XTileAppearanceDocument]]
    let applicationNotificationTopics: [String: [String: [String]]]
    let tilePresets: [String: D200XTilePresetDocument]
    let dialRotationPresets: [String: D200XDialRotationPresetDocument]

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
            nativeActions: nativeActions.mapValues(\.configuration),
            wideDisplayMode: wideDisplayMode,
            clockFormat: clockFormat,
            dialRotationPresets: dialRotationPresets.mapValues(\.configuration)
        )
    }

    init(configuration: D200XConfiguration) {
        defaults = configuration.defaults.mapValues(D200XBindingDocument.init(configuration:))
        applications = configuration.applications.mapValues {
            $0.mapValues(D200XBindingDocument.init(configuration:))
        }
        tiles = configuration.tiles.mapValues(D200XTileAppearanceDocument.init(configuration:))
        brightnessPercent = configuration.brightnessPercent
        wideDisplayMode = configuration.wideDisplayMode
        clockFormat = configuration.clockFormat
        actions = configuration.actions.mapValues(ExecutableDocument.init(configuration:))
        nativeActions = configuration.nativeActions.mapValues(NativeActionDocument.init(configuration:))
        notificationTopics = configuration.notificationTopics
        applicationTiles = configuration.applicationTiles.mapValues { $0.mapValues(D200XTileAppearanceDocument.init(configuration:)) }
        applicationNotificationTopics = configuration.applicationNotificationTopics
        tilePresets = configuration.tilePresets.mapValues(D200XTilePresetDocument.init(configuration:))
        dialRotationPresets = configuration.dialRotationPresets.mapValues(D200XDialRotationPresetDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["defaults", "applications", "tiles", "brightness_percent", "wide_display_mode", "clock_format", "actions", "native_actions", "notification_topics", "application_tiles", "application_notification_topics", "tile_presets", "dial_rotation_presets"])
        wideDisplayMode = try container.decodeIfPresent(D200XWideDisplayMode.self, forKey: AnyCodingKey("wide_display_mode")) ?? .custom
        clockFormat = try container.decodeIfPresent(D200XClockFormat.self, forKey: AnyCodingKey("clock_format")) ?? .twentyFourHour
        nativeActions = try container.decodeIfPresent([String: NativeActionDocument].self, forKey: AnyCodingKey("native_actions")) ?? [:]
        applicationTiles = try container.decodeIfPresent([String: [String: D200XTileAppearanceDocument]].self, forKey: AnyCodingKey("application_tiles")) ?? [:]
        applicationNotificationTopics = try container.decodeIfPresent([String: [String: [String]]].self, forKey: AnyCodingKey("application_notification_topics")) ?? [:]
        tilePresets = try container.decodeIfPresent([String: D200XTilePresetDocument].self, forKey: AnyCodingKey("tile_presets")) ?? [:]
        dialRotationPresets = try container.decodeIfPresent([String: D200XDialRotationPresetDocument].self, forKey: AnyCodingKey("dial_rotation_presets")) ?? [:]
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
        if wideDisplayMode != .custom { try container.encode(wideDisplayMode, forKey: .wideDisplayMode) }
        if clockFormat != .twentyFourHour { try container.encode(clockFormat, forKey: .clockFormat) }
        if !actions.isEmpty { try container.encode(actions, forKey: .actions) }
        if !nativeActions.isEmpty { try container.encode(nativeActions, forKey: .nativeActions) }
        if !notificationTopics.isEmpty { try container.encode(notificationTopics, forKey: .notificationTopics) }
        if !applicationTiles.isEmpty { try container.encode(applicationTiles, forKey: .applicationTiles) }
        if !applicationNotificationTopics.isEmpty { try container.encode(applicationNotificationTopics, forKey: .applicationNotificationTopics) }
        if !tilePresets.isEmpty { try container.encode(tilePresets, forKey: .tilePresets) }
        if !dialRotationPresets.isEmpty { try container.encode(dialRotationPresets, forKey: .dialRotationPresets) }
    }

    private enum CodingKeys: String, CodingKey {
        case defaults
        case applications
        case tiles
        case brightnessPercent = "brightness_percent"
        case wideDisplayMode = "wide_display_mode"
        case clockFormat = "clock_format"
        case actions
        case nativeActions = "native_actions"
        case notificationTopics = "notification_topics"
        case applicationTiles = "application_tiles"
        case applicationNotificationTopics = "application_notification_topics"
        case tilePresets = "tile_presets"
        case dialRotationPresets = "dial_rotation_presets"
    }
}

private struct D200XDialRotationPresetDocument: Codable {
    let name: String
    let left: D200XBindingDocument
    let right: D200XBindingDocument
    let actions: [String: ExecutableDocument]
    let nativeActions: [String: NativeActionDocument]

    var configuration: D200XDialRotationPreset {
        D200XDialRotationPreset(name: name, left: left.configuration, right: right.configuration,
            actions: actions.mapValues(\.configuration), nativeActions: nativeActions.mapValues(\.configuration))
    }

    init(configuration: D200XDialRotationPreset) {
        name = configuration.name
        left = D200XBindingDocument(configuration: configuration.left)
        right = D200XBindingDocument(configuration: configuration.right)
        actions = configuration.actions.mapValues(ExecutableDocument.init(configuration:))
        nativeActions = configuration.nativeActions.mapValues(NativeActionDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["name", "left", "right", "actions", "native_actions"])
        name = try container.decode(String.self, forKey: AnyCodingKey("name"))
        left = try container.decode(D200XBindingDocument.self, forKey: AnyCodingKey("left"))
        right = try container.decode(D200XBindingDocument.self, forKey: AnyCodingKey("right"))
        actions = try container.decodeIfPresent([String: ExecutableDocument].self, forKey: AnyCodingKey("actions")) ?? [:]
        nativeActions = try container.decodeIfPresent([String: NativeActionDocument].self, forKey: AnyCodingKey("native_actions")) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(left, forKey: .left)
        try container.encode(right, forKey: .right)
        if !actions.isEmpty { try container.encode(actions, forKey: .actions) }
        if !nativeActions.isEmpty { try container.encode(nativeActions, forKey: .nativeActions) }
    }

    enum CodingKeys: String, CodingKey { case name, left, right, actions; case nativeActions = "native_actions" }
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
        try c.rejectUnknownKeys(["kind", "media", "volume", "percent", "target", "topic", "text", "app_id", "ttl_seconds", "shortcut"])
        configuration = try NativeAction(
            kind: c.decode(NativeAction.Kind.self, forKey: AnyCodingKey("kind")),
            media: c.decodeIfPresent(NativeAction.Media.self, forKey: AnyCodingKey("media")),
            volume: c.decodeIfPresent(NativeAction.Volume.self, forKey: AnyCodingKey("volume")),
            percent: c.decodeIfPresent(Int.self, forKey: AnyCodingKey("percent")),
            target: c.decodeIfPresent(String.self, forKey: AnyCodingKey("target")),
            topic: c.decodeIfPresent(String.self, forKey: AnyCodingKey("topic")),
            text: c.decodeIfPresent(String.self, forKey: AnyCodingKey("text")),
            appID: c.decodeIfPresent(String.self, forKey: AnyCodingKey("app_id")),
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
        try c.encodeIfPresent(configuration.appID, forKey: AnyCodingKey("app_id"))
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
    let wheelInverted: Bool
    let restorePreviousSettingsOnDisconnect: Bool
    let wheelHighResolution: Bool?
    let wheelScrollAmount: Double?
    let thumbwheelInverted: Bool
    let thumbwheelScrollAmount: Double?
    let lowBatteryNotificationsEnabled: Bool
    let hardwarePreferences: MouseHardwarePreferencesDocument?

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
            lowBatteryNotificationsEnabled: lowBatteryNotificationsEnabled,
            hardwarePreferences: hardwarePreferences?.configuration
        )
    }

    init(configuration: DeviceBindings) {
        self.id = configuration.id
        self.defaults = configuration.defaults.mapValues(BindingDocument.init(configuration:))
        self.applications = configuration.applications.mapValues {
            $0.mapValues(BindingDocument.init(configuration:))
        }
        self.wheelInverted = configuration.effectiveWheelInverted
        self.restorePreviousSettingsOnDisconnect = configuration.restorePreviousSettingsOnDisconnect
        self.wheelHighResolution = configuration.wheelHighResolution
        self.wheelScrollAmount = configuration.wheelScrollAmount
        self.thumbwheelInverted = configuration.effectiveThumbwheelInverted
        self.thumbwheelScrollAmount = configuration.thumbwheelScrollAmount
        self.lowBatteryNotificationsEnabled = configuration.lowBatteryNotificationsEnabled
        self.hardwarePreferences = configuration.hardwarePreferences.map(MouseHardwarePreferencesDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys([
            "id", "defaults", "applications", "wheel_inverted",
            "restore_previous_settings_on_disconnect", "wheel_high_resolution", "wheel_scroll_amount",
            "thumbwheel_inverted", "thumbwheel_scroll_amount", "low_battery_notifications_enabled",
            "hardware_preferences"
        ])
        id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        defaults = try container.decode([String: BindingDocument].self, forKey: AnyCodingKey("defaults"))
        applications = try container.decodeIfPresent(
            [String: [String: BindingDocument]].self,
            forKey: AnyCodingKey("applications")
        ) ?? [:]
        wheelInverted = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("wheel_inverted"))
            ?? DeviceBindings.defaultWheelInverted
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
        ) ?? DeviceBindings.defaultThumbwheelInverted
        thumbwheelScrollAmount = try container.decodeIfPresent(
            Double.self, forKey: AnyCodingKey("thumbwheel_scroll_amount")
        )
        lowBatteryNotificationsEnabled = try container.decodeIfPresent(
            Bool.self, forKey: AnyCodingKey("low_battery_notifications_enabled")
        ) ?? false
        hardwarePreferences = try container.decodeIfPresent(
            MouseHardwarePreferencesDocument.self, forKey: AnyCodingKey("hardware_preferences")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(defaults, forKey: .defaults)
        if !applications.isEmpty {
            try container.encode(applications, forKey: .applications)
        }
        try container.encode(wheelInverted, forKey: .wheelInverted)
        try container.encode(restorePreviousSettingsOnDisconnect, forKey: .restorePreviousSettingsOnDisconnect)
        try container.encodeIfPresent(wheelHighResolution, forKey: .wheelHighResolution)
        try container.encodeIfPresent(wheelScrollAmount, forKey: .wheelScrollAmount)
        try container.encode(thumbwheelInverted, forKey: .thumbwheelInverted)
        try container.encodeIfPresent(thumbwheelScrollAmount, forKey: .thumbwheelScrollAmount)
        try container.encode(lowBatteryNotificationsEnabled, forKey: .lowBatteryNotificationsEnabled)
        try container.encodeIfPresent(hardwarePreferences, forKey: .hardwarePreferences)
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
        case hardwarePreferences = "hardware_preferences"
    }
}

private struct MouseHardwarePreferencesDocument: Codable {
    let smartShiftMode: MouseSmartShiftMode?
    let smartShiftThreshold: UInt8?
    let smartShiftTorque: UInt8?
    let dpi: UInt16?
    let pointerSpeed: Double?
    let hapticsEnabled: Bool?
    let hapticIntensity: UInt8?
    let hapticPowerSaving: Bool?
    let forceThreshold: UInt16?

    var configuration: MouseHardwarePreferences {
        MouseHardwarePreferences(
            smartShiftMode: smartShiftMode,
            smartShiftThreshold: smartShiftThreshold,
            smartShiftTorque: smartShiftTorque,
            dpi: dpi,
            pointerSpeed: pointerSpeed,
            hapticsEnabled: hapticsEnabled,
            hapticIntensity: hapticIntensity,
            hapticPowerSaving: hapticPowerSaving,
            forceThreshold: forceThreshold
        )
    }

    init(configuration: MouseHardwarePreferences) {
        smartShiftMode = configuration.smartShiftMode
        smartShiftThreshold = configuration.smartShiftThreshold
        smartShiftTorque = configuration.smartShiftTorque
        dpi = configuration.dpi
        pointerSpeed = configuration.pointerSpeed
        hapticsEnabled = configuration.hapticsEnabled
        hapticIntensity = configuration.hapticIntensity
        hapticPowerSaving = configuration.hapticPowerSaving
        forceThreshold = configuration.forceThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys([
            "smart_shift_mode", "smart_shift_threshold", "smart_shift_torque", "dpi", "pointer_speed",
            "haptics_enabled", "haptic_intensity", "haptic_power_saving", "force_threshold"
        ])
        smartShiftMode = try container.decodeIfPresent(MouseSmartShiftMode.self, forKey: AnyCodingKey("smart_shift_mode"))
        smartShiftThreshold = try container.decodeIfPresent(UInt8.self, forKey: AnyCodingKey("smart_shift_threshold"))
        smartShiftTorque = try container.decodeIfPresent(UInt8.self, forKey: AnyCodingKey("smart_shift_torque"))
        dpi = try container.decodeIfPresent(UInt16.self, forKey: AnyCodingKey("dpi"))
        pointerSpeed = try container.decodeIfPresent(Double.self, forKey: AnyCodingKey("pointer_speed"))
        hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("haptics_enabled"))
        hapticIntensity = try container.decodeIfPresent(UInt8.self, forKey: AnyCodingKey("haptic_intensity"))
        hapticPowerSaving = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("haptic_power_saving"))
        forceThreshold = try container.decodeIfPresent(UInt16.self, forKey: AnyCodingKey("force_threshold"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(smartShiftMode, forKey: .smartShiftMode)
        try container.encodeIfPresent(smartShiftThreshold, forKey: .smartShiftThreshold)
        try container.encodeIfPresent(smartShiftTorque, forKey: .smartShiftTorque)
        try container.encodeIfPresent(dpi, forKey: .dpi)
        try container.encodeIfPresent(pointerSpeed, forKey: .pointerSpeed)
        try container.encodeIfPresent(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encodeIfPresent(hapticIntensity, forKey: .hapticIntensity)
        try container.encodeIfPresent(hapticPowerSaving, forKey: .hapticPowerSaving)
        try container.encodeIfPresent(forceThreshold, forKey: .forceThreshold)
    }

    private enum CodingKeys: String, CodingKey {
        case smartShiftMode = "smart_shift_mode"
        case smartShiftThreshold = "smart_shift_threshold"
        case smartShiftTorque = "smart_shift_torque"
        case dpi
        case pointerSpeed = "pointer_speed"
        case hapticsEnabled = "haptics_enabled"
        case hapticIntensity = "haptic_intensity"
        case hapticPowerSaving = "haptic_power_saving"
        case forceThreshold = "force_threshold"
    }
}

private struct BindingDocument: Codable {
    let kind: ControlBinding.Kind
    let shortcut: ShortcutDocument?
    let mouseShortcut: MouseShortcutDocument?

    var configuration: ControlBinding {
        ControlBinding(kind: kind, shortcut: shortcut?.configuration, mouseShortcut: mouseShortcut?.configuration)
    }

    init(configuration: ControlBinding) {
        self.kind = configuration.kind
        self.shortcut = configuration.shortcut.map(ShortcutDocument.init(configuration:))
        self.mouseShortcut = configuration.mouseShortcut.map(MouseShortcutDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["kind", "shortcut", "mouse_shortcut"])
        kind = try container.decode(ControlBinding.Kind.self, forKey: AnyCodingKey("kind"))
        shortcut = try container.decodeIfPresent(ShortcutDocument.self, forKey: AnyCodingKey("shortcut"))
        mouseShortcut = try container.decodeIfPresent(MouseShortcutDocument.self, forKey: AnyCodingKey("mouse_shortcut"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
        try container.encodeIfPresent(mouseShortcut, forKey: .mouseShortcut)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case shortcut
        case mouseShortcut = "mouse_shortcut"
    }
}

private struct MouseShortcutDocument: Codable {
    let button: MouseButton
    let modifiers: [ShortcutModifier]

    var configuration: MouseShortcut { MouseShortcut(button: button, modifiers: modifiers) }

    init(configuration: MouseShortcut) {
        button = configuration.button
        modifiers = configuration.modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["button", "modifiers"])
        button = try container.decode(MouseButton.self, forKey: AnyCodingKey("button"))
        modifiers = try container.decode([ShortcutModifier].self, forKey: AnyCodingKey("modifiers"))
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

struct AnyCodingKey: CodingKey {
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

extension KeyedDecodingContainer where Key == AnyCodingKey {
    func rejectUnknownKeys(_ allowed: Set<String>) throws {
        guard let key = allKeys.first(where: { !allowed.contains($0.stringValue) }) else {
            return
        }
        throw ConfigurationError.unknownKey(key.stringValue)
    }
}

struct RegistryManifest: Codable {
    var schemaVersion: Int = WorkspaceConfiguration.currentVersion
    let connectOnLaunch: Bool
    let devices: [RegistryReference]
    let preferredMouseID: UUID?

    init(connectOnLaunch: Bool, devices: [RegistryReference], preferredMouseID: UUID? = nil) {
        self.connectOnLaunch = connectOnLaunch
        self.devices = devices
        self.preferredMouseID = preferredMouseID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["schema_version", "connect_on_launch", "devices", "preferred_mouse_id"])
        schemaVersion = try container.decode(Int.self, forKey: AnyCodingKey("schema_version"))
        guard schemaVersion == WorkspaceConfiguration.currentVersion else {
            throw ConfigurationError.unsupportedVersion(schemaVersion)
        }
        connectOnLaunch = try container.decode(Bool.self, forKey: AnyCodingKey("connect_on_launch"))
        devices = try container.decode([RegistryReference].self, forKey: AnyCodingKey("devices"))
        preferredMouseID = try container.decodeIfPresent(UUID.self, forKey: AnyCodingKey("preferred_mouse_id"))
        let singletonNativeFamilies = devices.map(\.family).filter { !$0.isLogitechMouse && $0 != .genericBluetooth }
        guard devices.count <= 256,
              Set(devices.map(\.id)).count == devices.count,
              Set(singletonNativeFamilies).count == singletonNativeFamilies.count else {
            throw ConfigurationError.invalidDocument
        }
        if let preferredMouseID {
            guard devices.contains(where: { $0.id == preferredMouseID && $0.family.isLogitechMouse }) else {
                throw ConfigurationError.invalidDocument
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", connectOnLaunch = "connect_on_launch", devices
        case preferredMouseID = "preferred_mouse_id"
    }
}

enum RegistryPayloadRevision: Equatable {
    case contentHash(String)
    case legacy(UUID)

    init(serializedValue: String) throws {
        if Self.isContentHash(serializedValue) {
            self = .contentHash(serializedValue)
            return
        }

        guard Self.isCanonicalUUID(serializedValue), let uuid = UUID(uuidString: serializedValue) else {
            throw ConfigurationError.invalidDocument
        }
        self = .legacy(uuid)
    }

    var serializedValue: String {
        switch self {
        case .contentHash(let hash): hash
        case .legacy(let uuid): uuid.uuidString
        }
    }

    static func isContentHash(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 12 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for index in bytes.indices {
            if [8, 13, 18, 23].contains(index) {
                guard bytes[index] == 45 else { return false }
                continue
            }
            let byte = bytes[index]
            guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else {
                return false
            }
        }
        return true
    }
}

struct RegistryReference: Codable {
    let id: UUID
    let family: DeviceFamily
    let displayName: String
    let isEnabled: Bool
    let revision: RegistryPayloadRevision
    var usesLegacyPath: Bool {
        if case .legacy = revision { return true }
        return false
    }
    var relativePath: String {
        switch revision {
        case .contentHash(let hash): "devices/\(family.rawValue).\(id.uuidString).\(hash).toml"
        case .legacy(let uuid): "devices/\(id.uuidString)/\(uuid.uuidString).toml"
        }
    }

    init(device: RegisteredDevice, contentHash: String) {
        id = device.id
        family = device.family
        displayName = device.displayName
        isEnabled = device.isEnabled
        revision = .contentHash(contentHash)
    }

    init(device: RegisteredDevice, legacyRevision: UUID) {
        id = device.id
        family = device.family
        displayName = device.displayName
        isEnabled = device.isEnabled
        revision = .legacy(legacyRevision)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["id", "family", "display_name", "enabled", "revision"])
        id = try container.decode(UUID.self, forKey: AnyCodingKey("id"))
        family = try container.decode(DeviceFamily.self, forKey: AnyCodingKey("family"))
        displayName = try container.decode(String.self, forKey: AnyCodingKey("display_name"))
        isEnabled = try container.decode(Bool.self, forKey: AnyCodingKey("enabled"))
        revision = try RegistryPayloadRevision(
            serializedValue: container.decode(String.self, forKey: AnyCodingKey("revision"))
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(id, forKey: AnyCodingKey("id"))
        try container.encode(family, forKey: AnyCodingKey("family"))
        try container.encode(displayName, forKey: AnyCodingKey("display_name"))
        try container.encode(isEnabled, forKey: AnyCodingKey("enabled"))
        try container.encode(revision.serializedValue, forKey: AnyCodingKey("revision"))
    }

    enum CodingKeys: String, CodingKey {
        case id, family, displayName = "display_name", isEnabled = "enabled", revision
    }
}

private struct RegisteredPayload: Codable {
    let schemaVersion: Int
    let id: UUID
    let family: DeviceFamily
    let mouse: DeviceDocument?
    let d200x: D200XDocument?
    let bluetoothEndpoint: BluetoothEndpoint?
    let bluetoothLowBatteryAlertsEnabled: Bool?
    let bluetoothLowBatteryThreshold: Int?
    let bluetoothIconOverride: BluetoothDeviceKind?
    let logitechAssociation: LogitechAssociationDocument?

    init(device: RegisteredDevice) {
        schemaVersion = 1
        id = device.id
        family = device.family
        if case .mouse(let bindings) = device.configuration { mouse = DeviceDocument(configuration: bindings) }
        else { mouse = nil }
        if case .d200x(let deck) = device.configuration { d200x = deck.map(D200XDocument.init(configuration:)) }
        else { d200x = nil }
        bluetoothEndpoint = device.bluetoothConfiguration?.endpoint
        bluetoothLowBatteryAlertsEnabled = device.bluetoothConfiguration?.lowBatteryAlertsEnabled
        bluetoothLowBatteryThreshold = device.bluetoothConfiguration?.lowBatteryThreshold
        bluetoothIconOverride = device.bluetoothConfiguration?.iconOverride
        logitechAssociation = device.logitechAssociation.map(LogitechAssociationDocument.init(association:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["schema_version", "id", "family", "mouse", "d200x", "bluetooth_endpoint",
            "bluetooth_low_battery_alerts_enabled", "bluetooth_low_battery_threshold", "bluetooth_icon_override",
            "logitech_association"])
        schemaVersion = try container.decode(Int.self, forKey: AnyCodingKey("schema_version"))
        guard schemaVersion == 1 else { throw ConfigurationError.unsupportedVersion(schemaVersion) }
        id = try container.decode(UUID.self, forKey: AnyCodingKey("id"))
        family = try container.decode(DeviceFamily.self, forKey: AnyCodingKey("family"))
        mouse = try container.decodeIfPresent(DeviceDocument.self, forKey: AnyCodingKey("mouse"))
        d200x = try container.decodeIfPresent(D200XDocument.self, forKey: AnyCodingKey("d200x"))
        bluetoothEndpoint = try container.decodeIfPresent(BluetoothEndpoint.self, forKey: AnyCodingKey("bluetooth_endpoint"))
        bluetoothLowBatteryAlertsEnabled = try container.decodeIfPresent(Bool.self, forKey: AnyCodingKey("bluetooth_low_battery_alerts_enabled"))
        bluetoothLowBatteryThreshold = try container.decodeIfPresent(Int.self, forKey: AnyCodingKey("bluetooth_low_battery_threshold"))
        bluetoothIconOverride = try container.decodeIfPresent(BluetoothDeviceKind.self, forKey: AnyCodingKey("bluetooth_icon_override"))
        logitechAssociation = try container.decodeIfPresent(LogitechAssociationDocument.self, forKey: AnyCodingKey("logitech_association"))
        guard bluetoothLowBatteryThreshold.map({ (1...100).contains($0) }) ?? true else { throw ConfigurationError.invalidDocument }
        guard family == .genericBluetooth || (bluetoothEndpoint == nil && bluetoothLowBatteryAlertsEnabled == nil &&
            bluetoothLowBatteryThreshold == nil && bluetoothIconOverride == nil) else { throw ConfigurationError.invalidDocument }
        guard family.isLogitechMouse || logitechAssociation == nil else { throw ConfigurationError.invalidDocument }
        switch family {
        case .mxMaster3S, .mxMaster4: guard mouse != nil, d200x == nil else { throw ConfigurationError.invalidDocument }
        case .d200x: guard mouse == nil else { throw ConfigurationError.invalidDocument }
        case .flowLite84: guard mouse == nil, d200x == nil else { throw ConfigurationError.invalidDocument }
        case .genericBluetooth: guard mouse == nil, d200x == nil, bluetoothEndpoint != nil else { throw ConfigurationError.invalidDocument }
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, family, mouse, d200x
        case bluetoothEndpoint = "bluetooth_endpoint"
        case bluetoothLowBatteryAlertsEnabled = "bluetooth_low_battery_alerts_enabled"
        case bluetoothLowBatteryThreshold = "bluetooth_low_battery_threshold"
        case bluetoothIconOverride = "bluetooth_icon_override"
        case logitechAssociation = "logitech_association"
    }
}

private struct LogitechAssociationDocument: Codable {
    let version: Int
    let unitID: String
    let modelID: String
    let connection: LogitechConnection

    var association: LogitechAssociation {
        LogitechAssociation(version: version,
                            identity: LogitechIdentity(unitID: unitID, modelID: modelID),
                            preferredConnection: connection)
    }

    init(association: LogitechAssociation) {
        version = association.version
        unitID = association.identity.unitID
        modelID = association.identity.modelID
        connection = association.preferredConnection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["version", "unit_id", "model_id", "connection"])
        version = try container.decode(Int.self, forKey: AnyCodingKey("version"))
        unitID = try container.decode(String.self, forKey: AnyCodingKey("unit_id"))
        modelID = try container.decode(String.self, forKey: AnyCodingKey("model_id"))
        connection = try container.decode(LogitechConnection.self, forKey: AnyCodingKey("connection"))
        do { _ = try association.validated() }
        catch { throw ConfigurationError.invalidDocument }
    }

    enum CodingKeys: String, CodingKey {
        case version
        case unitID = "unit_id"
        case modelID = "model_id"
        case connection
    }
}

enum RegistryCodec {
    static func version(_ data: Data) throws -> Int {
        struct Header: Decodable { let schema_version: Int }
        return try decode(Header.self, data: data).schema_version
    }

    static func manifest(_ data: Data) throws -> RegistryManifest { try decode(RegistryManifest.self, data: data) }

    static func device(_ data: Data, reference: RegistryReference) throws -> RegisteredDevice {
        let payload = try decode(RegisteredPayload.self, data: data)
        guard payload.id == reference.id, payload.family == reference.family else {
            throw ConfigurationError.invalidDocument
        }
        let configuration = try deviceConfiguration(payload)
        return RegisteredDevice(id: reference.id, displayName: reference.displayName,
                                isEnabled: reference.isEnabled,
                                configuration: configuration,
                                mouseModel: logitechMouseModel(for: payload.family),
                                logitechAssociation: payload.logitechAssociation?.association)
    }

    static func encode(device: RegisteredDevice) throws -> Data {
        do { _ = try WorkspaceConfiguration(connectOnLaunch: false, devices: [device]).validated() }
        catch { throw ConfigurationError.invalidConfiguration(error.localizedDescription) }
        return try encode(RegisteredPayload(device: device))
    }

    static func shortSHA256(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    static func recognizesManagedPayload(_ data: Data, id: UUID, family: DeviceFamily?) -> Bool {
        guard let payload = try? decode(RegisteredPayload.self, data: data),
              payload.id == id,
              family == nil || payload.family == family,
              let configuration = try? deviceConfiguration(payload) else {
            return false
        }

        let device = RegisteredDevice(id: id, displayName: "Managed payload", isEnabled: true,
                                      configuration: configuration,
                                      mouseModel: logitechMouseModel(for: payload.family),
                                      logitechAssociation: payload.logitechAssociation?.association)
        return (try? WorkspaceConfiguration(connectOnLaunch: false, devices: [device]).validated()) != nil
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = TOMLEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            let data = try encoder.encode(value)
            guard data.count <= ConfigurationCodec.maximumFileSize else { throw ConfigurationError.fileTooLarge }
            return data
        } catch let error as ConfigurationError { throw error }
        catch { throw ConfigurationError.encodingFailed }
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        guard data.count <= ConfigurationCodec.maximumFileSize else { throw ConfigurationError.fileTooLarge }
        let decoder = TOMLDecoder()
        decoder.limits = .init(maxInputSize: ConfigurationCodec.maximumFileSize, maxDepth: 12,
                               maxTableKeys: 512, maxArrayLength: 256,
                               maxStringLength: ConfigurationCodec.maximumFileSize)
        do { return try decoder.decode(type, from: data) }
        catch let error as ConfigurationError { throw error }
        catch { throw ConfigurationError.invalidDocument }
    }

    private static func deviceConfiguration(_ payload: RegisteredPayload) throws -> RegisteredDeviceConfiguration {
        switch payload.family {
        case .mxMaster3S, .mxMaster4:
            guard let mouse = payload.mouse else { throw ConfigurationError.invalidDocument }
            return .mouse(mouse.configuration)
        case .d200x:
            return .d200x(payload.d200x?.configuration)
        case .flowLite84:
            return .flowLite84
        case .genericBluetooth:
            guard let endpoint = payload.bluetoothEndpoint else { throw ConfigurationError.invalidDocument }
            return .genericBluetooth(GenericBluetoothConfiguration(endpoint: endpoint,
                lowBatteryAlertsEnabled: payload.bluetoothLowBatteryAlertsEnabled ?? false,
                lowBatteryThreshold: payload.bluetoothLowBatteryThreshold ?? 10,
                iconOverride: payload.bluetoothIconOverride))
        }
    }

    private static func logitechMouseModel(for family: DeviceFamily) -> LogitechMouseModel? {
        switch family {
        case .mxMaster3S: .mxMaster3S
        case .mxMaster4: .mxMaster4
        case .d200x, .flowLite84, .genericBluetooth: nil
        }
    }
}
