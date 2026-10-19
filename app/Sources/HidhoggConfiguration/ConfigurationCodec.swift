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
    let devices: [DeviceDocument]

    var configuration: AppConfiguration {
        AppConfiguration(schemaVersion: schemaVersion, devices: devices.map(\.configuration))
    }

    init(configuration: AppConfiguration) {
        self.schemaVersion = configuration.schemaVersion
        self.devices = configuration.devices.map(DeviceDocument.init(configuration:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["schema_version", "devices"])
        schemaVersion = try container.decode(Int.self, forKey: AnyCodingKey("schema_version"))
        devices = try container.decode([DeviceDocument].self, forKey: AnyCodingKey("devices"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(devices, forKey: .devices)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case devices
    }
}

private struct DeviceDocument: Codable {
    let id: String
    let defaults: [String: BindingDocument]
    let applications: [String: [String: BindingDocument]]

    var configuration: DeviceBindings {
        DeviceBindings(
            id: id,
            defaults: defaults.mapValues(\.configuration),
            applications: applications.mapValues { $0.mapValues(\.configuration) }
        )
    }

    init(configuration: DeviceBindings) {
        self.id = configuration.id
        self.defaults = configuration.defaults.mapValues(BindingDocument.init(configuration:))
        self.applications = configuration.applications.mapValues {
            $0.mapValues(BindingDocument.init(configuration:))
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try container.rejectUnknownKeys(["id", "defaults", "applications"])
        id = try container.decode(String.self, forKey: AnyCodingKey("id"))
        defaults = try container.decode([String: BindingDocument].self, forKey: AnyCodingKey("defaults"))
        applications = try container.decodeIfPresent(
            [String: [String: BindingDocument]].self,
            forKey: AnyCodingKey("applications")
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(defaults, forKey: .defaults)
        if !applications.isEmpty {
            try container.encode(applications, forKey: .applications)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case defaults
        case applications
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
