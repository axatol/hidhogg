import Foundation

public enum HidhoggConfigurationDecoder {
    public static func decode(_ data: Data) throws -> HidhoggConfiguration {
        guard let source = String(data: data, encoding: .utf8) else {
            throw ConfigurationDiagnostic.make(.decode)
        }

        let document: Toml.Annotated
        let locatedTree: Toml.LocatedTree
        do {
            document = try Toml.Annotated(parsing: source)
            locatedTree = try document.typedTreeWithLocations()
        } catch let error as Toml.ParseError {
            throw ConfigurationDiagnostic.make(.decode, location: SourceLocation(line: error.line, column: error.column))
        } catch {
            throw ConfigurationDiagnostic.make(.decode)
        }

        let locations = SourceIndex(locatedTree)
        let root = try ConfigurationTable(locatedTree.value, path: [], locations: locations)
        if let version = root.value(forKey: "schema_version") {
            guard case .integer(let value) = version else {
                throw ConfigurationDiagnostic.make(.decode, key: "schema_version", location: locations.valueLocation(for: ["schema_version"]))
            }
            if value != 4 {
                throw ConfigurationDiagnostic.make(.schemaVersion, key: "schema_version")
            }
        }

        try root.rejectUnknown(allowed: [
            "schema_version", "adapter", "brightness", "idle_timeout_seconds", "default_profile_id", "profiles",
        ])

        let schemaVersion = try root.integer("schema_version")
        let adapter = try root.string("adapter")
        let brightness = try root.integer("brightness")
        let idleTimeout = try root.optionalInteger("idle_timeout_seconds")
        let defaultProfileID = try root.string("default_profile_id")
        let profileTable = try root.optionalTable("profiles")

        var sourceProfiles: [ExactTomlKey: SourceProfile] = [:]
        for profileID in profileTable?.sortedKeys ?? [] {
            guard let profileTable else { throw ConfigurationDiagnostic.make(.decode) }
            let profile = try profileTable.childTable(profileID)
            try profile.rejectUnknown(allowed: ["label", "positions"])
            let label = try profile.optionalString("label")
            let positions = try profile.optionalTable("positions")
            var sourcePositions: [ExactTomlKey: SourcePosition] = [:]
            if let positions {
                for coordinate in positions.sortedKeys {
                    let position = try positions.childTable(coordinate)
                    try position.rejectUnknown(allowed: [
                        "label", "background", "notification_sources", "label_alignment", "label_size", "action",
                    ])
                    let action = try position.optionalTable("action")
                    sourcePositions[ExactTomlKey(coordinate)] = SourcePosition(
                        label: try position.optionalString("label"),
                        background: try position.optionalString("background"),
                        notificationSources: try position.optionalStringArray("notification_sources"),
                        labelAlignment: try position.optionalString("label_alignment"),
                        labelSize: try position.optionalInteger("label_size"),
                        action: try action.map { try decodeAction($0) }
                    )
                }
            }
            sourceProfiles[ExactTomlKey(profileID)] = SourceProfile(label: label, positions: sourcePositions)
        }

        let missing = requiredKeys(root: root, profiles: sourceProfiles)
        if let first = missing.sorted(by: { $0.key < $1.key }).first {
            throw ConfigurationDiagnostic.make(.missingKey, key: first.key)
        }

        guard let schemaVersion, let adapter, let brightness, let defaultProfileID else {
            throw ConfigurationDiagnostic.make(.decode)
        }
        let resolvedIdleTimeout = idleTimeout ?? 300
        try validateRawFields(profiles: sourceProfiles)
        try validatePositionKeys(profiles: sourceProfiles)
        try validateRoot(
            schemaVersion: schemaVersion,
            adapter: adapter,
            brightness: brightness,
            idleTimeout: resolvedIdleTimeout,
            defaultProfileID: defaultProfileID,
            profiles: sourceProfiles
        )
        try validateProfiles(sourceProfiles)
        try validateAllPositions(sourceProfiles)

        let defaultKey = ExactTomlKey(defaultProfileID)
        let orderedIDs = sourceProfiles.keys.sorted { left, right in
            if left == defaultKey { return right != defaultKey }
            if right == defaultKey { return false }
            return left < right
        }
        let profiles = try orderedIDs.map { profileKey -> ConfiguredProfile in
            let profileID = profileKey.value
            guard let sourceProfile = sourceProfiles[ExactTomlKey(profileID)], let label = sourceProfile.label else {
                throw ConfigurationDiagnostic.make(.decode)
            }
            let positions = try HidhoggConfiguration.supportedPositions.map { spec -> ConfiguredPosition in
                let path = ["profiles", profileID, "positions", spec.name]
                let sourcePosition = sourceProfile.positions[ExactTomlKey(spec.name)]
                return try normalizePosition(sourcePosition ?? SourcePosition(), id: spec.name, path: path,
                                             profileIDs: Set(sourceProfiles.keys))
            }
            return ConfiguredProfile(id: profileID, label: label, positions: positions)
        }

        return HidhoggConfiguration(
            schemaVersion: schemaVersion,
            adapter: adapter,
            brightness: brightness,
            idleTimeoutSeconds: resolvedIdleTimeout,
            defaultProfileID: defaultProfileID,
            profiles: profiles
        )
    }
}

private struct ConfigurationTable {
    let entries: [(key: String, value: Toml.TypedValue)]
    let path: [String]
    let locations: SourceIndex

    var sortedKeys: [String] {
        entries.map(\.key).sorted { ExactTomlKey($0) < ExactTomlKey($1) }
    }

    init(_ value: Toml.TypedValue, path: [String], locations: SourceIndex) throws {
        guard case .table(let entries) = value else {
            throw ConfigurationDiagnostic.make(.decode, key: diagnosticPath(path), location: locations.valueLocation(for: path))
        }
        self.entries = entries
        self.path = path
        self.locations = locations
    }

    func value(forKey key: String) -> Toml.TypedValue? {
        entries.first { ExactTomlKey($0.key) == ExactTomlKey(key) }?.value
    }

    func childTable(_ key: String) throws -> ConfigurationTable {
        guard let value = value(forKey: key) else {
            throw ConfigurationDiagnostic.make(.decode, key: diagnosticPath(path + [key]), location: locations.valueLocation(for: path + [key]))
        }
        return try ConfigurationTable(value, path: path + [key], locations: locations)
    }

    func optionalTable(_ key: String) throws -> ConfigurationTable? {
        guard value(forKey: key) != nil else { return nil }
        return try childTable(key)
    }

    func string(_ key: String) throws -> String? {
        try optionalString(key)
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = value(forKey: key) else { return nil }
        guard case .string(let string) = value else { throw typeError(key) }
        return string
    }

    func integer(_ key: String) throws -> Int? {
        guard let value = value(forKey: key) else { return nil }
        guard case .integer(let integer) = value, let converted = Int(exactly: integer) else { throw typeError(key) }
        return converted
    }

    func optionalInteger(_ key: String) throws -> Int? {
        try integer(key)
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        guard let value = value(forKey: key) else { return nil }
        guard case .array(let values) = value else { throw typeError(key) }
        return try values.map { element in
            guard case .string(let string) = element else { throw typeError(key) }
            return string
        }
    }

    func rejectUnknown(allowed: Set<String>) throws {
        let unknowns = entries.map(\.key).filter { key in
            !allowed.contains { ExactTomlKey($0) == ExactTomlKey(key) }
        }
        guard let unknown = unknowns.sorted(by: { ExactTomlKey($0) < ExactTomlKey($1) }).first else { return }
        let directPath = path + [unknown]
        let unknownPath = locations.declaredSourcePath(for: directPath) ?? directPath
        throw ConfigurationDiagnostic.make(.unknownKey, key: diagnosticPath(unknownPath),
                                           location: locations.keyLocation(for: unknownPath))
    }

    private func typeError(_ key: String) -> ConfigurationDiagnostic {
        let fieldPath = path + [key]
        return ConfigurationDiagnostic.make(.decode, key: diagnosticPath(fieldPath), location: locations.valueLocation(for: fieldPath))
    }
}

struct SourceProfile {
    let label: String?
    let positions: [ExactTomlKey: SourcePosition]
}

struct SourcePosition {
    var label: String? = nil
    var background: String? = nil
    var notificationSources: [String]? = nil
    var labelAlignment: String? = nil
    var labelSize: Int? = nil
    var action: SourceAction? = nil
}

struct SourceAction {
    let type: String?
    let gesture: String?
    let profileID: String?
    let executable: String?
    let arguments: [String]?
    let timeoutSeconds: Int?
    let text: String?
    let key: String?
}

private func decodeAction(_ table: ConfigurationTable) throws -> SourceAction {
    try table.rejectUnknown(allowed: [
        "type", "gesture", "profile_id", "executable", "arguments", "timeout_seconds", "text", "key",
    ])
    return SourceAction(
        type: try table.optionalString("type"),
        gesture: try table.optionalString("gesture"),
        profileID: try table.optionalString("profile_id"),
        executable: try table.optionalString("executable"),
        arguments: try table.optionalStringArray("arguments"),
        timeoutSeconds: try table.optionalInteger("timeout_seconds"),
        text: try table.optionalString("text"),
        key: try table.optionalString("key")
    )
}

private struct MissingKey {
    let key: String
}

private func requiredKeys(root: ConfigurationTable, profiles: [ExactTomlKey: SourceProfile]) -> [MissingKey] {
    var missing: [MissingKey] = []
    for key in ["schema_version", "adapter", "brightness", "default_profile_id", "profiles"] where root.value(forKey: key) == nil {
        missing.append(MissingKey(key: key))
    }
    for profileKey in profiles.keys.sorted() where profiles[profileKey]?.label == nil {
        let path = ["profiles", profileKey.value, "label"]
        missing.append(MissingKey(key: diagnosticPath(path)))
    }
    return missing
}

struct SourceIndex {
    private let keyLocations: [ExactTomlPath: SourceLocation]
    private let valueLocations: [ExactTomlPath: SourceLocation]
    private let headerPaths: Set<ExactTomlPath>
    private let dottedPaths: Set<ExactTomlPath>

    init(_ tree: Toml.LocatedTree) {
        self.keyLocations = tree.keyLocations.mapValues { SourceLocation(line: $0.line, column: $0.column) }
        self.valueLocations = tree.valueLocations.mapValues { SourceLocation(line: $0.line, column: $0.column) }
        self.headerPaths = tree.headerPaths
        self.dottedPaths = tree.dottedPaths
    }

    func keyLocation(for path: [String]) -> SourceLocation? {
        keyLocations[ExactTomlPath(path)]
    }

    func valueLocation(for path: [String]) -> SourceLocation? {
        valueLocations[ExactTomlPath(path)]
    }

    func declaredSourcePath(for path: [String]) -> [String]? {
        let headerPath = deepestPath(in: headerPaths, prefixedBy: path)
        return headerPath ?? deepestPath(in: dottedPaths, prefixedBy: path)
    }

    private func deepestPath(in candidates: Set<ExactTomlPath>, prefixedBy path: [String]) -> [String]? {
        candidates
            .filter { $0.hasPrefix(path) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs < rhs
            }
            .first?.values
    }

}

func diagnosticPath(_ path: [String]) -> String {
    var output = ""
    for (index, component) in path.enumerated() {
        if index == 0 {
            output = component
        } else if path[index - 1] == "profiles" || path[index - 1] == "positions" {
            output += "[\(String(reflecting: component))]"
        } else if (path[index - 1] == "notification_sources" || path[index - 1] == "arguments"), Int(component) != nil {
            output += "[\(component)]"
        } else {
            output += ".\(component)"
        }
    }
    return output
}
