import Foundation

public struct ProfileMapping: Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let profileID: String

    public init(bundleIdentifier: String, profileID: String) {
        self.bundleIdentifier = bundleIdentifier
        self.profileID = profileID
    }
}

public enum ProfileMappingInvalidReason: Equatable, Hashable, Sendable {
    case invalidBundleIdentifier
    case invalidProfileIdentifier
    case mappingLimitExceeded
}

public struct InvalidProfileMapping: Equatable, Hashable, Sendable {
    public let mapping: ProfileMapping
    public let reason: ProfileMappingInvalidReason

    public init(mapping: ProfileMapping, reason: ProfileMappingInvalidReason) {
        self.mapping = mapping
        self.reason = reason
    }
}

public enum ProfileMappingPreferencesError: Error, Equatable, Sendable {
    case invalidBundleIdentifier
    case invalidProfileIdentifier
    case mappingLimitExceeded
}

public protocol ProfileMappingPreferencesStore: Sendable {
    func dictionary(forKey key: String) -> [String: String]?
    func set(_ value: [String: String]?, forKey key: String)
}

public final class UserDefaultsProfileMappingPreferencesStore: @unchecked Sendable, ProfileMappingPreferencesStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func dictionary(forKey key: String) -> [String: String]? {
        defaults.dictionary(forKey: key) as? [String: String]
    }

    public func set(_ value: [String: String]?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

public struct ProfileMappingPreferences: Equatable, Sendable {
    public static let mappingsKey = "profileMappings"
    public static let maximumMappingCount = 128
    public static let maximumIdentifierByteCount = 255

    public let persistedMappings: [String: String]
    public let mappings: [String: String]
    public let invalidMappings: [InvalidProfileMapping]

    public init(mappings: [String: String] = [:]) {
        persistedMappings = mappings

        if mappings.count > Self.maximumMappingCount {
            self.mappings = [:]
            invalidMappings = mappings
                .map { key, value in
                    InvalidProfileMapping(
                        mapping: ProfileMapping(bundleIdentifier: key, profileID: value),
                        reason: .mappingLimitExceeded
                    )
                }
                .sorted { $0.mapping.bundleIdentifier < $1.mapping.bundleIdentifier }
            return
        }

        var validMappings: [String: String] = [:]
        var invalidMappings: [InvalidProfileMapping] = []
        for (bundleIdentifier, profileID) in mappings {
            let mapping = ProfileMapping(bundleIdentifier: bundleIdentifier, profileID: profileID)
            if !Self.isValidIdentifier(bundleIdentifier) {
                invalidMappings.append(
                    InvalidProfileMapping(mapping: mapping, reason: .invalidBundleIdentifier)
                )
                continue
            }
            if !Self.isValidIdentifier(profileID) {
                invalidMappings.append(
                    InvalidProfileMapping(mapping: mapping, reason: .invalidProfileIdentifier)
                )
                continue
            }
            validMappings[bundleIdentifier] = profileID
        }

        self.mappings = validMappings
        self.invalidMappings = invalidMappings.sorted {
            if $0.mapping.bundleIdentifier == $1.mapping.bundleIdentifier {
                return $0.mapping.profileID < $1.mapping.profileID
            }
            return $0.mapping.bundleIdentifier < $1.mapping.bundleIdentifier
        }
    }

    public init(store: any ProfileMappingPreferencesStore) {
        self.init(mappings: store.dictionary(forKey: Self.mappingsKey) ?? [:])
    }

    public var sortedMappings: [ProfileMapping] {
        mappings
            .map { ProfileMapping(bundleIdentifier: $0.key, profileID: $0.value) }
            .sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    public func profileID(for bundleIdentifier: String) -> String? {
        mappings[bundleIdentifier]
    }

    public func saving(to store: any ProfileMappingPreferencesStore) -> Self {
        store.set(persistedMappings, forKey: Self.mappingsKey)
        return self
    }

    public func save(to store: any ProfileMappingPreferencesStore) {
        store.set(persistedMappings, forKey: Self.mappingsKey)
    }

    public func setting(
        profileID: String,
        forBundleIdentifier bundleIdentifier: String
    ) throws -> Self {
        guard Self.isValidIdentifier(bundleIdentifier) else {
            throw ProfileMappingPreferencesError.invalidBundleIdentifier
        }
        guard Self.isValidIdentifier(profileID) else {
            throw ProfileMappingPreferencesError.invalidProfileIdentifier
        }

        var updatedMappings = persistedMappings
        if updatedMappings[bundleIdentifier] == nil,
           updatedMappings.count >= Self.maximumMappingCount {
            throw ProfileMappingPreferencesError.mappingLimitExceeded
        }
        updatedMappings[bundleIdentifier] = profileID
        return Self(mappings: updatedMappings)
    }

    public func removing(bundleIdentifier: String) -> Self {
        var updatedMappings = persistedMappings
        updatedMappings.removeValue(forKey: bundleIdentifier)
        return Self(mappings: updatedMappings)
    }

    public func removingMapping(forBundleIdentifier bundleIdentifier: String) -> Self {
        removing(bundleIdentifier: bundleIdentifier)
    }

    public static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumIdentifierByteCount else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value != 0 && scalar.properties.generalCategory != .control
        }
    }
}

public typealias ApplicationProfileMapping = ProfileMapping
public typealias ApplicationProfileMappingPreferences = ProfileMappingPreferences
