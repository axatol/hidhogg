import Foundation

public protocol AppPreferencesStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

public final class UserDefaultsAppPreferencesStore: @unchecked Sendable, AppPreferencesStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

public typealias UserDefaultsStore = UserDefaultsAppPreferencesStore

public struct AppPreferences: Equatable, Sendable {
    public static let configurationPathKey = "configurationPath"

    public let persistedConfigurationPath: String?
    public let configurationPath: String?

    public init(configurationPath: String?) {
        persistedConfigurationPath = configurationPath
        self.configurationPath = Self.validConfigurationPath(configurationPath)
    }

    public init(store: any AppPreferencesStore) {
        self.init(configurationPath: store.string(forKey: Self.configurationPathKey))
    }

    public var hasValidConfigurationPath: Bool {
        configurationPath != nil
    }

    public func save(to store: any AppPreferencesStore) {
        store.set(persistedConfigurationPath, forKey: Self.configurationPathKey)
    }

    public func savingConfigurationPath(_ path: String?, to store: any AppPreferencesStore) -> AppPreferences {
        let updated = AppPreferences(configurationPath: path)
        store.set(updated.persistedConfigurationPath, forKey: Self.configurationPathKey)
        return updated
    }

    public static func validConfigurationPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty, path.first == "/" else { return nil }
        guard path.unicodeScalars.allSatisfy({ scalar in
            scalar.value != 0 && scalar.value >= 0x20 && scalar.value != 0x7F
        }) else {
            return nil
        }
        return path
    }
}
