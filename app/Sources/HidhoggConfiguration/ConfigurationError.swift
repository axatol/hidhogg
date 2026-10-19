import Foundation

public enum ConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidLocation
    case fileTooLarge
    case invalidDocument
    case unknownKey(String)
    case unsupportedVersion(Int)
    case invalidConfiguration(String)
    case revisionConflict
    case symbolicLinkNotAllowed
    case filesystemAccessFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidLocation:
            "Configuration must use an absolute file URL."
        case .fileTooLarge:
            "Configuration file exceeds the 256 KiB size limit."
        case .invalidDocument:
            "Configuration is invalid TOML or does not match the supported schema."
        case .unknownKey(let key):
            "Configuration contains unsupported key: \(String(key.prefix(80)))."
        case .unsupportedVersion(let version):
            "Configuration schema version \(version) is not supported."
        case .invalidConfiguration(let reason):
            "Configuration is invalid: \(reason)"
        case .revisionConflict:
            "Configuration changed on disk since it was loaded. Reload before saving."
        case .symbolicLinkNotAllowed:
            "Configuration paths cannot traverse symbolic links."
        case .filesystemAccessFailed:
            "Configuration could not be read or written. Check file and directory permissions."
        case .encodingFailed:
            "Configuration could not be encoded as TOML."
        }
    }
}
