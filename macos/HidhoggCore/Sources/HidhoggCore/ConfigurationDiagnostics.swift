import Foundation

public enum ConfigurationDiagnosticCategory: String, Sendable, Equatable {
    case readNotFound = "read-not-found"
    case readDenied = "read-denied"
    case readInvalid = "read-invalid"
    case read
    case decode
    case unknownKey = "unknown-key"
    case missingKey = "missing-key"
    case schemaVersion = "schema-version"
    case validation
}

public struct ConfigurationDiagnosticProjection: Sendable, Equatable {
    public let category: ConfigurationDiagnosticCategory
    public let key: String
    public let line: Int
    public let column: Int
    public let detail: String
}

public struct ConfigurationDiagnostic: Error, Sendable, Equatable, CustomStringConvertible {
    public let category: ConfigurationDiagnosticCategory
    public let key: String
    public let line: Int
    public let column: Int
    public let detail: String

    public var description: String {
        var fields = ["category=\(category.rawValue)"]
        if !key.isEmpty { fields.append("key=\(String(reflecting: key))") }
        if line > 0, column > 0 { fields.append("line=\(line) column=\(column)") }
        fields.append("detail=\(String(reflecting: detail))")
        return "configuration " + fields.joined(separator: " ")
    }

    public func safeProjection() -> ConfigurationDiagnosticProjection {
        ConfigurationDiagnosticProjection(
            category: category,
            key: safeText(key, maximumBytes: 160),
            line: line,
            column: column,
            detail: detail
        )
    }

    static func make(
        _ category: ConfigurationDiagnosticCategory,
        key: String = "",
        location: SourceLocation? = nil
    ) -> ConfigurationDiagnostic {
        let safeKey = safeText(key, maximumBytes: 160)
        let validLocation = (category == .decode || category == .unknownKey ? location : nil).flatMap { point in
            (1...1_000_000).contains(point.line) && (1...1_000_000).contains(point.column) ? point : nil
        }
        let detail: String
        switch category {
        case .readNotFound: detail = "configuration file was not found"
        case .readDenied: detail = "configuration file is not readable"
        case .readInvalid: detail = "configuration path is invalid"
        case .read: detail = "configuration file could not be read"
        case .unknownKey:
            detail = safeKey == "pages" ? "pages is obsolete; use profiles" : "key is not supported"
        case .missingKey: detail = "required key is missing"
        case .schemaVersion: detail = "use schema_version = 4"
        case .validation: detail = "value violates configuration constraints"
        case .decode: detail = "TOML syntax or value type is invalid"
        }
        return ConfigurationDiagnostic(
            category: category,
            key: safeKey,
            line: validLocation?.line ?? 0,
            column: validLocation?.column ?? 0,
            detail: safeText(detail, maximumBytes: 160)
        )
    }
}

struct SourceLocation: Sendable, Equatable {
    let line: Int
    let column: Int
}

private func safeText(_ value: String, maximumBytes: Int) -> String {
    var output = String.UnicodeScalarView()
    var bytes = 0
    for scalar in value.unicodeScalars {
        if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
            continue
        }
        let scalarBytes = String(scalar).utf8.count
        guard bytes + scalarBytes <= maximumBytes else { break }
        output.append(scalar)
        bytes += scalarBytes
    }
    return String(output)
}
