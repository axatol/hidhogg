import Foundation

public enum LogitechMouseModel: String, Codable, CaseIterable, Sendable {
    case mxMaster3S
    case mxMaster4

    public var family: DeviceFamily {
        switch self {
        case .mxMaster3S: .mxMaster3S
        case .mxMaster4: .mxMaster4
        }
    }
}

public enum LogitechConnection: String, Codable, CaseIterable, Sendable {
    case bolt
    case bluetooth
}

public struct LogitechIdentity: Equatable, Sendable {
    public let unitID: String
    public let modelID: String

    public init(unitID: String, modelID: String) {
        self.unitID = unitID.lowercased()
        self.modelID = modelID.lowercased()
    }

    public func validated() throws -> Self {
        guard Self.isNonzeroHex(unitID, length: 8), Self.isNonzeroHex(modelID, length: 12) else {
            throw ConfigurationValidationError.invalidRegistry
        }
        return self
    }

    private static func isNonzeroHex(_ value: String, length: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == length && bytes.contains(where: { $0 != 48 }) && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct LogitechAssociation: Equatable, Sendable {
    public var version: Int
    public var identity: LogitechIdentity
    public var preferredConnection: LogitechConnection

    public init(version: Int = 1, identity: LogitechIdentity, preferredConnection: LogitechConnection) {
        self.version = version
        self.identity = identity
        self.preferredConnection = preferredConnection
    }

    public func validated() throws -> Self {
        guard version == 1 else { throw ConfigurationValidationError.invalidRegistry }
        _ = try identity.validated()
        return self
    }
}
