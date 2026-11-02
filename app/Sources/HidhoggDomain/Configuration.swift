import Foundation

public enum MouseControl: String, Codable, CaseIterable, Hashable, Sendable {
    case back
    case forward
    case middle
    case wheelMode
    case thumbRest

    public var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .middle: "Middle button"
        case .wheelMode: "Wheel mode button"
        case .thumbRest: "Thumb button"
        }
    }
}

public enum ShortcutModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case option
    case control
    case shift
}

public enum WheelScrollAmount {
    public static let range = 0.25...10.0
    public static let defaultSelection = 1.0

    public static func contains(_ amount: Double) -> Bool {
        amount.isFinite && range.contains(amount)
    }
}

public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: [ShortcutModifier]

    public init(keyCode: UInt16, modifiers: [ShortcutModifier] = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct ControlBinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case disabled
        case shortcut
        case mouseShortcut = "mouse_shortcut"
    }

    public var kind: Kind
    public var shortcut: KeyboardShortcut?
    public var mouseShortcut: MouseShortcut?

    public init(kind: Kind, shortcut: KeyboardShortcut? = nil, mouseShortcut: MouseShortcut? = nil) {
        self.kind = kind
        self.shortcut = shortcut
        self.mouseShortcut = mouseShortcut
    }

    public static let disabled = Self(kind: .disabled)
    public static func key(_ shortcut: KeyboardShortcut) -> Self {
        Self(kind: .shortcut, shortcut: shortcut)
    }
    public static func mouse(_ shortcut: MouseShortcut) -> Self {
        Self(kind: .mouseShortcut, mouseShortcut: shortcut)
    }
    public static func input(_ shortcut: InputShortcut) -> Self {
        switch shortcut {
        case let .keyboard(keyboard): .key(keyboard)
        case let .mouseClick(mouse): .mouse(mouse)
        }
    }

    public var inputShortcut: InputShortcut? {
        switch kind {
        case .disabled:
            return nil
        case .shortcut:
            guard mouseShortcut == nil else { return nil }
            return shortcut.map(InputShortcut.keyboard)
        case .mouseShortcut:
            guard shortcut == nil else { return nil }
            return mouseShortcut.map(InputShortcut.mouseClick)
        }
    }
}

public struct DeviceBindings: Codable, Equatable, Sendable {
    public var id: String
    public var defaults: [String: ControlBinding]
    public var applications: [String: [String: ControlBinding]]
    private var storedWheelInverted: Bool
    public var wheelInverted: Bool? {
        get { storedWheelInverted }
        set { storedWheelInverted = newValue ?? Self.defaultWheelInverted }
    }
    public var effectiveWheelInverted: Bool { storedWheelInverted }
    public var restorePreviousSettingsOnDisconnect: Bool
    public var wheelHighResolution: Bool?
    public var wheelScrollAmount: Double?
    private var storedThumbwheelInverted: Bool
    public var thumbwheelInverted: Bool? {
        get { storedThumbwheelInverted }
        set { storedThumbwheelInverted = newValue ?? Self.defaultThumbwheelInverted }
    }
    public var effectiveThumbwheelInverted: Bool { storedThumbwheelInverted }
    public var thumbwheelScrollAmount: Double?
    public var lowBatteryNotificationsEnabled: Bool
    public var hardwarePreferences: MouseHardwarePreferences?

    public static let defaultWheelInverted = false
    public static let defaultThumbwheelInverted = true

    public init(
        id: String,
        defaults: [String: ControlBinding],
        applications: [String: [String: ControlBinding]] = [:],
        wheelInverted: Bool? = nil,
        restorePreviousSettingsOnDisconnect: Bool = false,
        wheelHighResolution: Bool? = nil,
        wheelScrollAmount: Double? = nil,
        thumbwheelInverted: Bool? = nil,
        thumbwheelScrollAmount: Double? = nil,
        lowBatteryNotificationsEnabled: Bool = false,
        hardwarePreferences: MouseHardwarePreferences? = nil
    ) {
        self.id = id
        self.defaults = defaults
        self.applications = applications
        self.storedWheelInverted = wheelInverted ?? Self.defaultWheelInverted
        self.restorePreviousSettingsOnDisconnect = restorePreviousSettingsOnDisconnect
        self.wheelHighResolution = wheelHighResolution
        self.wheelScrollAmount = wheelScrollAmount
        self.storedThumbwheelInverted = thumbwheelInverted ?? Self.defaultThumbwheelInverted
        self.thumbwheelScrollAmount = thumbwheelScrollAmount
        self.lowBatteryNotificationsEnabled = lowBatteryNotificationsEnabled
        self.hardwarePreferences = hardwarePreferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        defaults = try container.decode([String: ControlBinding].self, forKey: .defaults)
        applications = try container.decode([String: [String: ControlBinding]].self, forKey: .applications)
        storedWheelInverted = try container.decodeIfPresent(Bool.self, forKey: .wheelInverted)
            ?? Self.defaultWheelInverted
        restorePreviousSettingsOnDisconnect = try container.decode(
            Bool.self, forKey: .restorePreviousSettingsOnDisconnect
        )
        wheelHighResolution = try container.decodeIfPresent(Bool.self, forKey: .wheelHighResolution)
        wheelScrollAmount = try container.decodeIfPresent(Double.self, forKey: .wheelScrollAmount)
        storedThumbwheelInverted = try container.decodeIfPresent(Bool.self, forKey: .thumbwheelInverted)
            ?? Self.defaultThumbwheelInverted
        thumbwheelScrollAmount = try container.decodeIfPresent(Double.self, forKey: .thumbwheelScrollAmount)
        lowBatteryNotificationsEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .lowBatteryNotificationsEnabled
        ) ?? false
        hardwarePreferences = try container.decodeIfPresent(MouseHardwarePreferences.self, forKey: .hardwarePreferences)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(defaults, forKey: .defaults)
        try container.encode(applications, forKey: .applications)
        try container.encode(storedWheelInverted, forKey: .wheelInverted)
        try container.encode(restorePreviousSettingsOnDisconnect, forKey: .restorePreviousSettingsOnDisconnect)
        try container.encodeIfPresent(wheelHighResolution, forKey: .wheelHighResolution)
        try container.encodeIfPresent(wheelScrollAmount, forKey: .wheelScrollAmount)
        try container.encode(storedThumbwheelInverted, forKey: .thumbwheelInverted)
        try container.encodeIfPresent(thumbwheelScrollAmount, forKey: .thumbwheelScrollAmount)
        try container.encode(lowBatteryNotificationsEnabled, forKey: .lowBatteryNotificationsEnabled)
        try container.encodeIfPresent(hardwarePreferences, forKey: .hardwarePreferences)
    }

    public func binding(for control: MouseControl, application: String?) -> ControlBinding {
        configuredBinding(for: control, application: application) ?? .disabled
    }

    public func configuredBinding(for control: MouseControl, application: String?) -> ControlBinding? {
        if let application, let override = applications[application]?[control.rawValue] {
            return override
        }
        return defaults[control.rawValue]
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case defaults
        case applications
        case wheelInverted
        case restorePreviousSettingsOnDisconnect
        case wheelHighResolution
        case wheelScrollAmount
        case thumbwheelInverted
        case thumbwheelScrollAmount
        case lowBatteryNotificationsEnabled
        case hardwarePreferences
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let logitechProfileID = "logitech.mx-master-3s"
    public var schemaVersion: Int
    public var devices: [DeviceBindings]
    public var connectOnLaunch: Bool
    public var d200x: D200XConfiguration?

    public init(
        schemaVersion: Int = currentVersion,
        devices: [DeviceBindings],
        connectOnLaunch: Bool = true,
        d200x: D200XConfiguration? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.devices = devices
        self.connectOnLaunch = connectOnLaunch
        self.d200x = d200x
    }

    public static var empty: Self {
        Self(devices: [DeviceBindings(id: logitechProfileID, defaults: ["back": .disabled, "forward": .disabled])])
    }

    public static var defaultConfiguration: Self {
        Self(devices: [DeviceBindings(
            id: logitechProfileID,
            defaults: [
                MouseControl.back.rawValue: .key(NavigationPreset.pageBack.shortcut),
                MouseControl.forward.rawValue: .key(NavigationPreset.pageForward.shortcut)
            ]
        )])
    }

    public var mouse: DeviceBindings? { devices.first { $0.id == Self.logitechProfileID } }

    public func validated() throws -> Self {
        guard schemaVersion == Self.currentVersion else { throw ConfigurationValidationError.unsupportedVersion }
        guard devices.count == 1, devices[0].id == Self.logitechProfileID else {
            throw ConfigurationValidationError.invalidProfile
        }
        let known = Set(MouseControl.allCases.map(\.rawValue))
        let required = Set([MouseControl.back.rawValue, MouseControl.forward.rawValue])
        for device in devices {
            guard device.wheelScrollAmount.map(WheelScrollAmount.contains) ?? true else {
                throw ConfigurationValidationError.invalidWheelScrollAmount
            }
            guard device.thumbwheelScrollAmount.map(WheelScrollAmount.contains) ?? true else {
                throw ConfigurationValidationError.invalidWheelScrollAmount
            }
            _ = try device.hardwarePreferences?.validated()
            let defaultControls = Set(device.defaults.keys)
            guard required.isSubset(of: defaultControls), defaultControls.isSubset(of: known),
                  device.applications.count <= 128 else {
                throw ConfigurationValidationError.invalidControls
            }
            for (application, overrides) in device.applications {
                guard ConfigurationValueValidation.isValid(application: application),
                      Set(overrides.keys).isSubset(of: known) else {
                    throw ConfigurationValidationError.invalidApplication
                }
            }
            for binding in Array(device.defaults.values) + device.applications.values.flatMap({ $0.values }) {
                guard ConfigurationValueValidation.isValid(binding: binding) else {
                    throw ConfigurationValidationError.invalidShortcut
                }
            }
        }

        _ = try d200x?.validated()

        return self
    }
}

enum ConfigurationValueValidation {
    static func isValid(application: String) -> Bool {
        !application.isEmpty && application.utf8.count <= 255
            && !application.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    static func isValid(binding: ControlBinding) -> Bool {
        switch binding.kind {
        case .disabled:
            return binding.shortcut == nil && binding.mouseShortcut == nil
        case .shortcut:
            guard let shortcut = binding.shortcut, binding.mouseShortcut == nil else { return false }
            return InputShortcutCodec.isValid(shortcut)
        case .mouseShortcut:
            guard let shortcut = binding.mouseShortcut, binding.shortcut == nil else { return false }
            return InputShortcutCodec.isValid(shortcut)
        }
    }
}

public enum ConfigurationValidationError: Error, LocalizedError, Sendable {
    case unsupportedVersion, invalidProfile, invalidControls, invalidApplication, invalidShortcut
    case invalidD200XControls, invalidD200XAppearance, invalidD200XAction
    case invalidWheelScrollAmount
    case invalidMouseHardwarePreferences
    case invalidRegistry

    public var errorDescription: String? {
        switch self {
        case .invalidRegistry: "Device registrations require unique UUIDs and endpoints, singleton D200X and Flow Lite84 entries, and valid names."
        case .unsupportedVersion: "Unsupported configuration version."
        case .invalidProfile: "Expected one Logitech MX Master 3S profile."
        case .invalidControls: "Back and Forward defaults are required; unknown controls are not supported."
        case .invalidApplication: "An application override is invalid."
        case .invalidShortcut: "A shortcut has an unsupported key, duplicate modifiers or inconsistent action."
        case .invalidD200XControls: "A D200X control key is unknown or there are too many application overrides."
        case .invalidD200XAppearance: "A D200X tile key, label or background color is invalid."
        case .invalidD200XAction: "A D200X action, notification source or brightness preference is invalid."
        case .invalidWheelScrollAmount: "Wheel scroll amount must be a finite value between 0.25 and 10."
        case .invalidMouseHardwarePreferences: "A mouse hardware preference is out of range or conflicts with its mode."
        }
    }
}
