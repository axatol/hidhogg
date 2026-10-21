import Foundation

public enum MouseControl: String, Codable, CaseIterable, Hashable, Sendable {
    case back
    case forward

    public var title: String { rawValue.capitalized }
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
    public enum Kind: String, Codable, Sendable { case disabled, shortcut }
    public var kind: Kind
    public var shortcut: KeyboardShortcut?

    public init(kind: Kind, shortcut: KeyboardShortcut? = nil) {
        self.kind = kind
        self.shortcut = shortcut
    }

    public static let disabled = Self(kind: .disabled)
    public static func key(_ shortcut: KeyboardShortcut) -> Self {
        Self(kind: .shortcut, shortcut: shortcut)
    }
}

public struct DeviceBindings: Codable, Equatable, Sendable {
    public var id: String
    public var defaults: [String: ControlBinding]
    public var applications: [String: [String: ControlBinding]]
    public var wheelInverted: Bool?
    public var restorePreviousSettingsOnDisconnect: Bool
    public var wheelHighResolution: Bool?
    public var wheelScrollAmount: Double?
    public var thumbwheelInverted: Bool?
    public var thumbwheelScrollAmount: Double?

    public init(
        id: String,
        defaults: [String: ControlBinding],
        applications: [String: [String: ControlBinding]] = [:],
        wheelInverted: Bool? = nil,
        restorePreviousSettingsOnDisconnect: Bool = false,
        wheelHighResolution: Bool? = nil,
        wheelScrollAmount: Double? = nil,
        thumbwheelInverted: Bool? = nil,
        thumbwheelScrollAmount: Double? = nil
    ) {
        self.id = id
        self.defaults = defaults
        self.applications = applications
        self.wheelInverted = wheelInverted
        self.restorePreviousSettingsOnDisconnect = restorePreviousSettingsOnDisconnect
        self.wheelHighResolution = wheelHighResolution
        self.wheelScrollAmount = wheelScrollAmount
        self.thumbwheelInverted = thumbwheelInverted
        self.thumbwheelScrollAmount = thumbwheelScrollAmount
    }

    public func binding(for control: MouseControl, application: String?) -> ControlBinding {
        if let application, let override = applications[application]?[control.rawValue] {
            return override
        }
        return defaults[control.rawValue] ?? .disabled
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let logitechProfileID = "logitech.mx-master-3s"
    public var schemaVersion: Int
    public var devices: [DeviceBindings]
    public var connectOnLaunch: Bool

    public init(
        schemaVersion: Int = currentVersion,
        devices: [DeviceBindings],
        connectOnLaunch: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.devices = devices
        self.connectOnLaunch = connectOnLaunch
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
        for device in devices {
            guard device.wheelScrollAmount.map(WheelScrollAmount.contains) ?? true else {
                throw ConfigurationValidationError.invalidWheelScrollAmount
            }
            guard device.thumbwheelScrollAmount.map(WheelScrollAmount.contains) ?? true else {
                throw ConfigurationValidationError.invalidWheelScrollAmount
            }
            guard Set(device.defaults.keys) == known, device.applications.count <= 128 else {
                throw ConfigurationValidationError.invalidControls
            }
            for (application, overrides) in device.applications {
                guard !application.isEmpty, application.utf8.count <= 255,
                      !application.contains(where: { $0.isWhitespace || $0.isNewline }),
                      Set(overrides.keys).isSubset(of: known) else {
                    throw ConfigurationValidationError.invalidApplication
                }
            }
            for binding in Array(device.defaults.values) + device.applications.values.flatMap({ $0.values }) {
                switch binding.kind {
                case .disabled:
                    guard binding.shortcut == nil else { throw ConfigurationValidationError.invalidShortcut }
                case .shortcut:
                    guard let shortcut = binding.shortcut, shortcut.keyCode <= 127,
                          !(54...63).contains(shortcut.keyCode),
                          Set(shortcut.modifiers).count == shortcut.modifiers.count else {
                        throw ConfigurationValidationError.invalidShortcut
                    }
                }
            }
        }
        return self
    }
}

public enum ConfigurationValidationError: Error, LocalizedError, Sendable {
    case unsupportedVersion, invalidProfile, invalidControls, invalidApplication, invalidShortcut
    case invalidWheelScrollAmount

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "Unsupported configuration version."
        case .invalidProfile: "Expected one Logitech MX Master 3S profile."
        case .invalidControls: "Back and Forward defaults are required; unknown controls are not supported."
        case .invalidApplication: "An application override is invalid."
        case .invalidShortcut: "A shortcut has an unsupported key, duplicate modifiers or inconsistent action."
        case .invalidWheelScrollAmount: "Wheel scroll amount must be a finite value between 0.25 and 10."
        }
    }
}
