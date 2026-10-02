import Foundation

public enum RuntimeBackendSelection: Sendable {
    case native
    case simulated
}

public enum RuntimeLifecycle: String, Sendable, Equatable {
    case created
    case running
    case failed
    case stopping
    case stopped
}

public struct RuntimeSnapshot: Sendable, Equatable {
    public let lifecycle: RuntimeLifecycle
    public let profileID: String?
    public let revision: UInt64
    public let displayAwake: Bool
    public let dimmed: Bool
    public let transitioning: Bool
    public let cleanupUncertain: Bool
}

public struct RuntimeActivationResult: Sendable, Equatable {
    public let profileID: String
    public let changed: Bool
    public let revision: UInt64
}

public struct RuntimeReloadResult: Sendable, Equatable {
    public let profileID: String
    public let changed: Bool
    public let revision: UInt64
}

public enum RuntimeStopOutcome: Sendable, Equatable {
    case closed
    case cleanupUncertain
}

public enum RuntimeCoordinatorError: Error, Sendable, Equatable {
    case alreadyStarted
    case notRunning
    case unknownProfile
    case configurationRejected
    case sessionUnavailable
    case physicalWriteFailed
    case cleanupUncertain
    case cancelledBeforeAdmission
    case storeFailure(ConfigurationStoreError)
}

public enum RuntimeConfigurationEdit: Sendable {
    case setProfileLabel(profileID: String, label: String)
    case cloneProfile(sourceID: String, newID: String, label: String)
    case deleteProfile(profileID: String)
    case patchPosition(profileID: String, coordinate: String, patch: ConfigurationPositionPatch)
}

public enum RuntimeConfigurationReloadOutcome: Sendable, Equatable {
    case unchanged
    case reloaded
    case rejected
    case runtimeFailed
}

public struct RuntimeConfigurationEditResult: Sendable {
    public let fileOutcome: ConfigurationStoreOutcome
    public let digest: ConfigurationStoreDigest
    public let reloadOutcome: RuntimeConfigurationReloadOutcome
    public let snapshot: RuntimeSnapshot
}

struct RuntimeStaticActionRequest: Sendable {
    let profileID: String
    let coordinate: String
    let action: ConfiguredAction
}
