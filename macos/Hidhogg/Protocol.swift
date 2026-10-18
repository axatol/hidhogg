import Foundation
import HidhoggCore

public enum RuntimeMethod: String, Sendable {
    case health
    case status
    case profilesList = "profiles.list"
    case profilesActivate = "profiles.activate"
    case displayHostStateSet = "display.host_state.set"
    case configEditorSnapshot = "config.editor.snapshot"
    case configEditorProfileGet = "config.editor.profile.get"
    case configEditorProfileLabelSet = "config.editor.profile_label.set"
    case configEditorProfileCreate = "config.editor.profile.create"
    case configEditorProfileDelete = "config.editor.profile.delete"
    case configEditorPositionsList = "config.editor.positions.list"
    case configEditorPositionGet = "config.editor.position.get"
    case configEditorPositionLabelSet = "config.editor.position_label.set"
    case configEditorPositionPatch = "config.editor.position.patch"
}

public struct RuntimeError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RuntimeResponse: Equatable, Sendable {
    public let requestID: String?
    public let instanceID: String?
    public let state: String?
    public let protocolVersion: Int?
    public let error: RuntimeError?

    public var isSuccess: Bool { error == nil }

    public init(
        requestID: String?,
        instanceID: String?,
        state: String?,
        protocolVersion: Int?,
        error: RuntimeError?
    ) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.state = state
        self.protocolVersion = protocolVersion
        self.error = error
    }
}

public struct ProfileSummary: Equatable, Sendable {
    public let id: String
    public let label: String
    public let isDefault: Bool
    public let isCurrent: Bool

    public init(id: String, label: String, isDefault: Bool, isCurrent: Bool) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.isCurrent = isCurrent
    }
}

public struct ProfileListResponse: Equatable, Sendable {
    public let requestID: String
    public let instanceID: String
    public let profiles: [ProfileSummary]

    public init(requestID: String, instanceID: String, profiles: [ProfileSummary]) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.profiles = profiles
    }
}

public struct ProfileActivationResponse: Equatable, Sendable {
    public let requestID: String
    public let profileID: String
    public let changed: Bool

    public init(requestID: String, profileID: String, changed: Bool) {
        self.requestID = requestID
        self.profileID = profileID
        self.changed = changed
    }
}

public struct DisplayHostStateResponse: Equatable, Sendable {
    public let requestID: String
    public let instanceID: String
    public let displayAwake: Bool
    public let changed: Bool

    public init(requestID: String, instanceID: String, displayAwake: Bool, changed: Bool) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.displayAwake = displayAwake
        self.changed = changed
    }
}

public struct ConfigEditorSnapshotResponse: Equatable, Sendable {
    public let requestID: String
    public let instanceID: String
    public let sourceDigest: String
    public let revision: UInt64
    public let defaultProfileID: String
    public let currentProfileID: String
    public let profileIDs: [String]

    public init(
        requestID: String,
        instanceID: String,
        sourceDigest: String,
        revision: UInt64,
        defaultProfileID: String,
        currentProfileID: String,
        profileIDs: [String]
    ) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.sourceDigest = sourceDigest
        self.revision = revision
        self.defaultProfileID = defaultProfileID
        self.currentProfileID = currentProfileID
        self.profileIDs = profileIDs
    }
}

public struct ConfigEditorProfileResponse: Equatable, Sendable {
    public let requestID: String
    public let instanceID: String
    public let sourceDigest: String
    public let profileID: String
    public let label: String

    public init(requestID: String, instanceID: String, sourceDigest: String, profileID: String, label: String) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.sourceDigest = sourceDigest
        self.profileID = profileID
        self.label = label
    }
}

public struct ConfigEditorPositionSummary: Equatable, Sendable {
    public let positionID: String
    public let position: String

    public init(positionID: String, position: String) {
        self.positionID = positionID
        self.position = position
    }
}

public struct ConfigEditorPositionsResponse: Equatable, Sendable {
    public let requestID: String
    public let instanceID: String
    public let sourceDigest: String
    public let profileID: String
    public let positions: [ConfigEditorPositionSummary]

    public init(
        requestID: String,
        instanceID: String,
        sourceDigest: String,
        profileID: String,
        positions: [ConfigEditorPositionSummary]
    ) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.sourceDigest = sourceDigest
        self.profileID = profileID
        self.positions = positions
    }
}

public struct ConfigEditorPositionResponse: Equatable, Sendable {
    public let requestID: String
    public let instanceID: String
    public let sourceDigest: String
    public let profileID: String
    public let positionID: String
    public let label: String
    public let background: String
    public let labelAlignment: String
    public let labelSize: Int
    public let notificationSources: [String]
    public let action: ConfiguredAction?

    public init(
        requestID: String,
        instanceID: String,
        sourceDigest: String,
        profileID: String,
        positionID: String,
        label: String,
        background: String = "#000000",
        labelAlignment: String = "bottom",
        labelSize: Int = 10,
        notificationSources: [String] = [],
        action: ConfiguredAction? = nil
    ) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.sourceDigest = sourceDigest
        self.profileID = profileID
        self.positionID = positionID
        self.label = label
        self.background = background
        self.labelAlignment = labelAlignment
        self.labelSize = labelSize
        self.notificationSources = notificationSources
        self.action = action
    }
}

public enum ConfigEditorFileCommit: String, Equatable, Sendable {
    case unchanged
    case committed
    case uncertain
}

public enum ConfigEditorReloadOutcome: String, Equatable, Sendable {
    case unchanged
    case changed
    case rejected
    case uncertain
    case notAttempted = "not_attempted"
}

public enum ConfigEditorEffect: String, Equatable, Sendable {
    case unchanged
    case actionOnly = "action-only"
    case display
    case brightness
    case idle
    case `default`
    case catalog
}

public enum ConfigEditorReason: String, Equatable, Sendable {
    case none
    case candidateRejected = "candidate-rejected"
    case settingsPending = "settings-pending"
    case canceled
    case deviceWriteFailed = "device-write-failed"
    case closed
}

public struct ConfigEditorMutationResponse: Equatable, Sendable {
    public let requestID: String
    public let instanceID: String
    public let sourceDigest: String
    public let fileCommit: ConfigEditorFileCommit
    public let reloadOutcome: ConfigEditorReloadOutcome
    public let revision: UInt64
    public let effect: ConfigEditorEffect
    public let reason: ConfigEditorReason

    public init(
        requestID: String,
        instanceID: String,
        sourceDigest: String,
        fileCommit: ConfigEditorFileCommit,
        reloadOutcome: ConfigEditorReloadOutcome,
        revision: UInt64,
        effect: ConfigEditorEffect,
        reason: ConfigEditorReason
    ) {
        self.requestID = requestID
        self.instanceID = instanceID
        self.sourceDigest = sourceDigest
        self.fileCommit = fileCommit
        self.reloadOutcome = reloadOutcome
        self.revision = revision
        self.effect = effect
        self.reason = reason
    }
}

public enum ResponseValidationError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidEnvelope
    case unsupportedVersion
    case invalidRequestID
    case requestIDMismatch
    case invalidResult
    case invalidError
    case serverError(RuntimeError)
}

public enum UUIDValidation {
    public static func isCanonical(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

public enum ProtocolV1 {
    public static let frameLimit = 16_384
    public static let protocolVersion = 1
    public static let healthStatusErrorCodes: Set<String> = [
        "invalid_json",
        "invalid_envelope",
        "unsupported_version",
        "unknown_method",
        "instance_mismatch",
        "message_too_large",
        "internal"
    ]

    public static let profileErrorCodes: Set<String> = healthStatusErrorCodes.union([
        "profile_not_found",
        "activation_failed",
        "device_write_failed",
        "shutting_down",
        "busy"
    ])

    static let configEditorErrorMessages: [String: String] = [
        "invalid_json": "request is not valid JSON",
        "invalid_envelope": "request envelope is invalid",
        "unsupported_version": "protocol version is not supported",
        "unknown_method": "request method is not supported",
        "instance_mismatch": "runtime instance does not match",
        "message_too_large": "request message is too large",
        "internal": "internal server error",
        "stale_source": "configuration source changed; refresh and retry",
        "edit_invalid": "configuration edit is invalid",
        "file_commit_failed": "configuration edit could not be committed",
        "busy": "runtime is busy",
        "shutting_down": "runtime is shutting down"
    ]

    public static let allowedErrorCodes = profileErrorCodes

    public static func request(
        method: RuntimeMethod,
        requestID: String,
        instanceID: String,
        profileID: String? = nil
    ) -> Data {
        var params = "\"instance_id\":\"\(instanceID)\""
        if method == .profilesActivate, let profileID {
            params += ",\"profile_id\":\"\(profileID)\""
        }
        let payload = "{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"method\":\"\(method.rawValue)\",\"params\":{\(params)}}\n"
        return Data(payload.utf8)
    }

    public static func profileRequest(
        method: RuntimeMethod,
        requestID: String,
        instanceID: String,
        profileID: String? = nil
    ) throws -> Data {
        guard method == .profilesList || method == .profilesActivate else {
            throw ProtocolRequestValidationError.invalidMethod
        }
        if method == .profilesActivate {
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
        } else if profileID != nil {
            throw ProtocolRequestValidationError.unexpectedProfileID
        }
        return request(method: method, requestID: requestID, instanceID: instanceID, profileID: profileID)
    }

    public static func displayHostStateRequest(
        requestID: String,
        instanceID: String,
        displayAwake: Bool
    ) throws -> Data {
        guard UUIDValidation.isCanonical(requestID) else {
            throw ProtocolRequestValidationError.invalidRequestID
        }
        guard UUIDValidation.isCanonical(instanceID) else {
            throw ProtocolRequestValidationError.invalidInstanceID
        }

        let envelope: [String: Any] = [
            "protocol_version": protocolVersion,
            "request_id": requestID,
            "method": RuntimeMethod.displayHostStateSet.rawValue,
            "params": [
                "instance_id": instanceID,
                "display_awake": displayAwake
            ]
        ]
        do {
            var frame = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            frame.append(0x0a)
            guard frame.count <= frameLimit else {
                throw ProtocolRequestValidationError.frameTooLarge
            }
            return frame
        } catch let error as ProtocolRequestValidationError {
            throw error
        } catch {
            throw ProtocolRequestValidationError.encodingFailed
        }
    }

    public static func configEditorRequest(
        method: RuntimeMethod,
        requestID: String,
        instanceID: String,
        profileID: String? = nil,
        positionID: String? = nil,
        sourceDigest: String? = nil,
        expectedDigest: String? = nil,
        label: String? = nil,
        sourceProfileID: String? = nil,
        positionPatch: ConfigurationPositionPatch? = nil
    ) throws -> Data {
        guard UUIDValidation.isCanonical(requestID) else {
            throw ProtocolRequestValidationError.invalidRequestID
        }
        guard UUIDValidation.isCanonical(instanceID) else {
            throw ProtocolRequestValidationError.invalidInstanceID
        }

        var params: [String: Any] = ["instance_id": instanceID]
        switch method {
        case .configEditorSnapshot:
            guard profileID == nil, positionID == nil, sourceDigest == nil, expectedDigest == nil, label == nil, sourceProfileID == nil, positionPatch == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
        case .configEditorProfileGet:
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
            guard let sourceDigest, ProfileValidation.isValidSourceDigest(sourceDigest) else {
                throw ProtocolRequestValidationError.invalidSourceDigest
            }
            guard positionID == nil, expectedDigest == nil, label == nil, sourceProfileID == nil, positionPatch == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
            params["source_digest"] = sourceDigest
            params["profile_id"] = profileID
        case .configEditorProfileLabelSet:
            guard let expectedDigest, ProfileValidation.isValidSourceDigest(expectedDigest) else {
                throw ProtocolRequestValidationError.invalidSourceDigest
            }
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
            guard let label, ProfileValidation.isValidLabel(label) else {
                throw ProtocolRequestValidationError.invalidLabel
            }
            guard positionID == nil, sourceDigest == nil, sourceProfileID == nil, positionPatch == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
            params["expected_digest"] = expectedDigest
            params["profile_id"] = profileID
            params["label"] = label
        case .configEditorProfileCreate:
            guard let expectedDigest, ProfileValidation.isValidSourceDigest(expectedDigest) else {
                throw ProtocolRequestValidationError.invalidSourceDigest
            }
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
            guard let label, ProfileValidation.isValidLabel(label) else {
                throw ProtocolRequestValidationError.invalidLabel
            }
            guard positionID == nil, sourceDigest == nil, positionPatch == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
            if let sourceProfileID {
                guard ProfileValidation.isValidID(sourceProfileID) else {
                    throw ProtocolRequestValidationError.invalidProfileID
                }
                params["source_profile_id"] = sourceProfileID
            }
            params["expected_digest"] = expectedDigest
            params["profile_id"] = profileID
            params["label"] = label
        case .configEditorProfileDelete:
            guard let expectedDigest, ProfileValidation.isValidSourceDigest(expectedDigest) else {
                throw ProtocolRequestValidationError.invalidSourceDigest
            }
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
            guard positionID == nil, sourceDigest == nil, label == nil, sourceProfileID == nil, positionPatch == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
            params["expected_digest"] = expectedDigest
            params["profile_id"] = profileID
        case .configEditorPositionsList:
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
            guard let sourceDigest, ProfileValidation.isValidSourceDigest(sourceDigest) else {
                throw ProtocolRequestValidationError.invalidSourceDigest
            }
            guard positionID == nil, expectedDigest == nil, label == nil, sourceProfileID == nil, positionPatch == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
            params["source_digest"] = sourceDigest
            params["profile_id"] = profileID
        case .configEditorPositionGet:
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
            guard let positionID, ProfileValidation.isValidPositionCoordinate(positionID) else {
                throw ProtocolRequestValidationError.invalidPositionID
            }
            guard let sourceDigest, ProfileValidation.isValidSourceDigest(sourceDigest) else {
                throw ProtocolRequestValidationError.invalidSourceDigest
            }
            guard expectedDigest == nil, label == nil, sourceProfileID == nil, positionPatch == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
            params["source_digest"] = sourceDigest
            params["profile_id"] = profileID
            params["position_id"] = positionID
        case .configEditorPositionLabelSet:
            guard let expectedDigest, ProfileValidation.isValidSourceDigest(expectedDigest) else {
                throw ProtocolRequestValidationError.invalidSourceDigest
            }
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
            guard let positionID, ProfileValidation.isValidPositionCoordinate(positionID) else {
                throw ProtocolRequestValidationError.invalidPositionID
            }
            guard let label, ProfileValidation.isValidPositionLabel(label) else {
                throw ProtocolRequestValidationError.invalidLabel
            }
            guard sourceDigest == nil, sourceProfileID == nil, positionPatch == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
            params["expected_digest"] = expectedDigest
            params["profile_id"] = profileID
            params["position_id"] = positionID
            params["label"] = label
        case .configEditorPositionPatch:
            guard let expectedDigest, ProfileValidation.isValidSourceDigest(expectedDigest) else {
                throw ProtocolRequestValidationError.invalidSourceDigest
            }
            guard let profileID, ProfileValidation.isValidID(profileID) else {
                throw ProtocolRequestValidationError.invalidProfileID
            }
            guard let positionID, ProfileValidation.isValidPositionCoordinate(positionID) else {
                throw ProtocolRequestValidationError.invalidPositionID
            }
            guard let positionPatch,
                  ProfileValidation.isValidPositionPatch(positionPatch) else {
                throw ProtocolRequestValidationError.invalidPatch
            }
            guard sourceDigest == nil, label == nil, sourceProfileID == nil else {
                throw ProtocolRequestValidationError.invalidFields
            }
            params["expected_digest"] = expectedDigest
            params["profile_id"] = profileID
            params["position_id"] = positionID
            params["patch"] = try Self.positionPatchObject(positionPatch)
        default:
            throw ProtocolRequestValidationError.invalidMethod
        }

        let envelope: [String: Any] = [
            "protocol_version": protocolVersion,
            "request_id": requestID,
            "method": method.rawValue,
            "params": params
        ]
        do {
            var frame = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            frame.append(0x0a)
            guard frame.count <= frameLimit else {
                throw ProtocolRequestValidationError.frameTooLarge
            }
            return frame
        } catch let error as ProtocolRequestValidationError {
            throw error
        } catch {
            throw ProtocolRequestValidationError.encodingFailed
        }
    }

    private static func positionPatchObject(_ patch: ConfigurationPositionPatch) throws -> [String: Any] {
        var result = [String: Any]()
        try addEdit(patch.label, to: &result, key: "label") { $0 }
        try addEdit(patch.background, to: &result, key: "background") { $0 }
        try addEdit(patch.labelAlignment, to: &result, key: "label_alignment") { $0 }
        try addEdit(patch.labelSize, to: &result, key: "label_size") { $0 }
        try addEdit(patch.notificationSources, to: &result, key: "notification_sources") { $0 }
        try addEdit(patch.action, to: &result, key: "action", transform: Self.configuredActionObject)
        return result
    }

    private static func addEdit<Value: Sendable>(
        _ edit: ConfigurationFieldEdit<Value>,
        to object: inout [String: Any],
        key: String,
        transform: (Value) throws -> Any
    ) throws {
        switch edit {
        case .keep:
            return
        case .reset:
            object[key] = ["op": "reset"]
        case .set(let value):
            object[key] = ["op": "set", "value": try transform(value)]
        }
    }

    private static func configuredActionObject(_ action: ConfiguredAction) -> [String: Any] {
        switch action {
        case .activateProfile(let profileID, let gesture):
            return ["type": "activate_profile", "profile_id": profileID, "gesture": gesture.rawValue]
        case .execute(let executable, let arguments, let timeoutSeconds, let gesture):
            return [
                "type": "execute",
                "executable": executable,
                "arguments": arguments,
                "timeout_seconds": timeoutSeconds,
                "gesture": gesture.rawValue
            ]
        case .typeText(let text, let gesture):
            return ["type": "type_text", "text": text, "gesture": gesture.rawValue]
        case .keyPress(let key, let gesture):
            return ["type": "key_press", "key": key, "gesture": gesture.rawValue]
        }
    }
}

public enum ProtocolRequestValidationError: Error, Equatable, Sendable {
    case invalidMethod
    case invalidRequestID
    case invalidInstanceID
    case invalidProfileID
    case invalidPositionID
    case invalidSourceDigest
    case invalidLabel
    case invalidPatch
    case invalidFields
    case frameTooLarge
    case encodingFailed
    case unexpectedProfileID
}

public enum ProfileValidation {
    private static let supportedPositionCoordinates: Set<String> = [
        "0_0", "1_0", "2_0", "3_0", "4_0",
        "0_1", "1_1", "2_1", "3_1", "4_1",
        "0_2", "1_2", "2_2", "3_2"
    ]

    public static func isValidID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first else {
            return false
        }
        guard isASCIIAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte) || byte == 0x2e || byte == 0x5f || byte == 0x2d
        }
    }

    public static func isValidSourceDigest(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    public static func isValidPositionCoordinate(_ value: String) -> Bool {
        supportedPositionCoordinates.contains(value)
    }

    public static func isValidPositionLabel(_ value: String) -> Bool {
        value.isEmpty || isValidLabel(value)
    }

    public static func isValidPositionBackground(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (7...9).contains(bytes.count), bytes.first == 0x23,
              bytes.count == 7 || bytes.count == 9 else { return false }
        return bytes.dropFirst().allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    public static func isValidPositionPatch(_ patch: ConfigurationPositionPatch) -> Bool {
        isValid(patch.label, value: isValidPositionLabel) &&
            isValid(patch.background, value: isValidPositionBackground) &&
            isValid(patch.labelAlignment, value: { $0 == "bottom" || $0 == "center" }) &&
            isValid(patch.labelSize, value: { (8...32).contains($0) }) &&
            isValid(patch.notificationSources, value: { sources in
                (1...16).contains(sources.count) &&
                    sources.allSatisfy(isValidID) &&
                    Set(sources).count == sources.count
            }) &&
            isValid(patch.action, value: isValidConfiguredAction)
    }

    private static func isValid<Value: Sendable>(
        _ edit: ConfigurationFieldEdit<Value>,
        value: (Value) -> Bool
    ) -> Bool {
        guard case .set(let candidate) = edit else { return true }
        return value(candidate)
    }

    private static func isValidConfiguredAction(_ action: ConfiguredAction) -> Bool {
        switch action {
        case .activateProfile(let profileID, _):
            return isValidID(profileID)
        case .execute(let executable, let arguments, let timeoutSeconds, _):
            return isValidExecutable(executable) &&
                (1...60).contains(timeoutSeconds) &&
                arguments.count <= 32 &&
                arguments.allSatisfy { $0.utf8.count <= 1024 && !$0.utf8.contains(0) } &&
                arguments.reduce(0) { $0 + $1.utf8.count } <= 8192
        case .typeText(let text, _):
            return !text.isEmpty && text.utf16.count <= 64 && !text.utf8.contains(0)
        case .keyPress(let key, _):
            return key == "enter"
        }
    }

    fileprivate static func isValidExecutable(_ value: String) -> Bool {
        value.utf8.first == 0x2f && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    public static func isValidLabel(_ value: String) -> Bool {
        guard (1...64).contains(value.unicodeScalars.count), value.utf8.count <= 256 else {
            return false
        }
        var visible = false
        for scalar in value.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .control || category == .format {
                return false
            }
            switch category {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator,
                 .nonspacingMark, .enclosingMark,
                 .unassigned, .privateUse, .surrogate:
                continue
            default:
                visible = true
            }
        }
        return visible
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x61 && byte <= 0x7a) ||
        (byte >= 0x30 && byte <= 0x39)
    }
}

public enum ResponseValidator {
    public static func validate(
        frame: Data,
        expectedRequestID: String?,
        method: RuntimeMethod,
        expectedInstanceID: String
    ) throws -> RuntimeResponse {
        let root = try parseFrame(frame)
        return try validateResponse(
            root,
            expectedRequestID: expectedRequestID,
            method: method,
            expectedInstanceID: expectedInstanceID
        )
    }

    public static func validateProfilesList(
        frame: Data,
        expectedRequestID: String,
        expectedInstanceID: String
    ) throws -> ProfileListResponse {
        let root = try parseFrame(frame)
        let envelope = try validateProfileEnvelope(
            root,
            expectedRequestID: expectedRequestID
        )
        guard case .object(let fields) = envelope.result else {
            throw ResponseValidationError.invalidResult
        }
        let resultMap = try exactMap(fields, keys: ["instance_id", "profiles"])
        guard case .string(let instanceID) = resultMap["instance_id"],
              UUIDValidation.isCanonical(instanceID),
              instanceID == expectedInstanceID,
              case .array(let profileValues) = resultMap["profiles"],
              (1...31).contains(profileValues.count) else {
            throw ResponseValidationError.invalidResult
        }

        var profiles: [ProfileSummary] = []
        profiles.reserveCapacity(profileValues.count)
        var profileIDs = Set<String>()
        var defaultCount = 0
        var currentCount = 0
        for value in profileValues {
            guard case .object(let summaryFields) = value else {
                throw ResponseValidationError.invalidResult
            }
            let summaryMap = try exactMap(summaryFields, keys: ["id", "label", "is_default", "is_current"])
            guard case .string(let id) = summaryMap["id"],
                  ProfileValidation.isValidID(id),
                  profileIDs.insert(id).inserted,
                  case .string(let label) = summaryMap["label"],
                  ProfileValidation.isValidLabel(label),
                  case .boolean(let isDefault) = summaryMap["is_default"],
                  case .boolean(let isCurrent) = summaryMap["is_current"] else {
                throw ResponseValidationError.invalidResult
            }
            if isDefault { defaultCount += 1 }
            if isCurrent { currentCount += 1 }
            profiles.append(ProfileSummary(id: id, label: label, isDefault: isDefault, isCurrent: isCurrent))
        }
        guard defaultCount == 1, currentCount == 1 else {
            throw ResponseValidationError.invalidResult
        }
        return ProfileListResponse(requestID: envelope.requestID, instanceID: instanceID, profiles: profiles)
    }

    public static func validateProfileActivation(
        frame: Data,
        expectedRequestID: String,
        expectedProfileID: String
    ) throws -> ProfileActivationResponse {
        let root = try parseFrame(frame)
        let envelope = try validateProfileEnvelope(
            root,
            expectedRequestID: expectedRequestID
        )
        guard case .object(let fields) = envelope.result else {
            throw ResponseValidationError.invalidResult
        }
        let resultMap = try exactMap(fields, keys: ["profile_id", "changed"])
        guard case .string(let profileID) = resultMap["profile_id"],
              ProfileValidation.isValidID(profileID),
              profileID == expectedProfileID,
              case .boolean(let changed) = resultMap["changed"] else {
            throw ResponseValidationError.invalidResult
        }
        return ProfileActivationResponse(requestID: envelope.requestID, profileID: profileID, changed: changed)
    }

    public static func validateDisplayHostState(
        frame: Data,
        expectedRequestID: String,
        expectedInstanceID: String,
        expectedDisplayAwake: Bool
    ) throws -> DisplayHostStateResponse {
        let root = try parseFrame(frame)
        let envelope = try validateProfileEnvelope(root, expectedRequestID: expectedRequestID)
        guard case .object(let fields) = envelope.result else {
            throw ResponseValidationError.invalidResult
        }
        let resultMap = try exactMap(fields, keys: ["instance_id", "display_awake", "changed"])
        guard case .string(let instanceID) = resultMap["instance_id"],
              UUIDValidation.isCanonical(instanceID),
              instanceID == expectedInstanceID,
              case .boolean(let displayAwake) = resultMap["display_awake"],
              displayAwake == expectedDisplayAwake,
              case .boolean(let changed) = resultMap["changed"] else {
            throw ResponseValidationError.invalidResult
        }
        return DisplayHostStateResponse(
            requestID: envelope.requestID,
            instanceID: instanceID,
            displayAwake: displayAwake,
            changed: changed
        )
    }

    public static func validateConfigEditorSnapshot(
        frame: Data,
        expectedRequestID: String,
        expectedInstanceID: String
    ) throws -> ConfigEditorSnapshotResponse {
        let root = try parseFrame(frame)
        let envelope = try validateConfigEditorEnvelope(root, expectedRequestID: expectedRequestID)
        guard case .object(let fields) = envelope.result else {
            throw ResponseValidationError.invalidResult
        }
        let resultMap = try exactMap(
            fields,
            keys: ["instance_id", "source_digest", "revision", "default_profile_id", "current_profile_id", "profile_ids"]
        )
        guard case .string(let instanceID) = resultMap["instance_id"],
              UUIDValidation.isCanonical(instanceID),
              instanceID == expectedInstanceID,
              case .string(let sourceDigest) = resultMap["source_digest"],
              ProfileValidation.isValidSourceDigest(sourceDigest),
              case .number(let revisionNumber) = resultMap["revision"],
              let revision = UInt64(revisionNumber.rawValue), revision > 0,
              case .string(let defaultProfileID) = resultMap["default_profile_id"],
              ProfileValidation.isValidID(defaultProfileID),
              case .string(let currentProfileID) = resultMap["current_profile_id"],
              ProfileValidation.isValidID(currentProfileID),
              case .array(let profileValues) = resultMap["profile_ids"],
              (1...31).contains(profileValues.count) else {
            throw ResponseValidationError.invalidResult
        }

        var profileIDs: [String] = []
        var seenProfileIDs = Set<String>()
        profileIDs.reserveCapacity(profileValues.count)
        for value in profileValues {
            guard case .string(let profileID) = value,
                  ProfileValidation.isValidID(profileID),
                  seenProfileIDs.insert(profileID).inserted else {
                throw ResponseValidationError.invalidResult
            }
            profileIDs.append(profileID)
        }
        guard seenProfileIDs.contains(defaultProfileID), seenProfileIDs.contains(currentProfileID) else {
            throw ResponseValidationError.invalidResult
        }

        return ConfigEditorSnapshotResponse(
            requestID: envelope.requestID,
            instanceID: instanceID,
            sourceDigest: sourceDigest,
            revision: revision,
            defaultProfileID: defaultProfileID,
            currentProfileID: currentProfileID,
            profileIDs: profileIDs
        )
    }

    public static func validateConfigEditorProfile(
        frame: Data,
        expectedRequestID: String,
        expectedInstanceID: String,
        expectedSourceDigest: String,
        expectedProfileID: String
    ) throws -> ConfigEditorProfileResponse {
        let root = try parseFrame(frame)
        let envelope = try validateConfigEditorEnvelope(root, expectedRequestID: expectedRequestID)
        guard case .object(let fields) = envelope.result else {
            throw ResponseValidationError.invalidResult
        }
        let resultMap = try exactMap(fields, keys: ["instance_id", "source_digest", "profile_id", "label"])
        guard case .string(let instanceID) = resultMap["instance_id"],
              UUIDValidation.isCanonical(instanceID),
              instanceID == expectedInstanceID,
              case .string(let sourceDigest) = resultMap["source_digest"],
              ProfileValidation.isValidSourceDigest(sourceDigest),
              sourceDigest == expectedSourceDigest,
              case .string(let profileID) = resultMap["profile_id"],
              ProfileValidation.isValidID(profileID),
              profileID == expectedProfileID,
              case .string(let label) = resultMap["label"],
              ProfileValidation.isValidLabel(label) else {
            throw ResponseValidationError.invalidResult
        }
        return ConfigEditorProfileResponse(
            requestID: envelope.requestID,
            instanceID: instanceID,
            sourceDigest: sourceDigest,
            profileID: profileID,
            label: label
        )
    }

    public static func validateConfigEditorPositions(
        frame: Data,
        expectedRequestID: String,
        expectedInstanceID: String,
        expectedSourceDigest: String,
        expectedProfileID: String
    ) throws -> ConfigEditorPositionsResponse {
        let root = try parseFrame(frame)
        let envelope = try validateConfigEditorEnvelope(root, expectedRequestID: expectedRequestID)
        guard case .object(let fields) = envelope.result else {
            throw ResponseValidationError.invalidResult
        }
        let resultMap = try exactMap(
            fields,
            keys: ["instance_id", "source_digest", "profile_id", "positions"]
        )
        guard case .string(let instanceID) = resultMap["instance_id"],
              UUIDValidation.isCanonical(instanceID),
              instanceID == expectedInstanceID,
              case .string(let sourceDigest) = resultMap["source_digest"],
              ProfileValidation.isValidSourceDigest(sourceDigest),
              sourceDigest == expectedSourceDigest,
              case .string(let profileID) = resultMap["profile_id"],
              ProfileValidation.isValidID(profileID),
              profileID == expectedProfileID,
              case .array(let positionValues) = resultMap["positions"],
              positionValues.count == 14 else {
            throw ResponseValidationError.invalidResult
        }

        var positions: [ConfigEditorPositionSummary] = []
        var seenPositionIDs = Set<String>()
        var seenCoordinates = Set<String>()
        positions.reserveCapacity(positionValues.count)
        for value in positionValues {
            guard case .object(let positionFields) = value else {
                throw ResponseValidationError.invalidResult
            }
            let positionMap = try exactMap(positionFields, keys: ["position_id", "position"])
            guard case .string(let positionID) = positionMap["position_id"],
                  ProfileValidation.isValidPositionCoordinate(positionID),
                  case .string(let position) = positionMap["position"],
                  ProfileValidation.isValidPositionCoordinate(position),
                  positionID == position,
                  seenPositionIDs.insert(positionID).inserted,
                  seenCoordinates.insert(position).inserted else {
                throw ResponseValidationError.invalidResult
            }
            positions.append(ConfigEditorPositionSummary(positionID: positionID, position: position))
        }
        guard seenCoordinates.count == 14 else {
            throw ResponseValidationError.invalidResult
        }

        return ConfigEditorPositionsResponse(
            requestID: envelope.requestID,
            instanceID: instanceID,
            sourceDigest: sourceDigest,
            profileID: profileID,
            positions: positions
        )
    }

    public static func validateConfigEditorPosition(
        frame: Data,
        expectedRequestID: String,
        expectedInstanceID: String,
        expectedSourceDigest: String,
        expectedProfileID: String,
        expectedPositionID: String
    ) throws -> ConfigEditorPositionResponse {
        let root = try parseFrame(frame)
        let envelope = try validateConfigEditorEnvelope(root, expectedRequestID: expectedRequestID)
        guard case .object(let fields) = envelope.result else {
            throw ResponseValidationError.invalidResult
        }
        let baseKeys: Set<String> = [
            "instance_id", "source_digest", "profile_id", "position_id", "label"
        ]
        let presentationKeys = baseKeys.union([
            "background", "label_alignment", "label_size", "notification_sources"
        ])
        let actualKeys = Set(fields.map(\.0))
        guard actualKeys.count == fields.count,
              actualKeys == baseKeys
                || actualKeys == presentationKeys
                || actualKeys == presentationKeys.union(["action"]) else {
            throw ResponseValidationError.invalidResult
        }
        let resultMap = Dictionary(uniqueKeysWithValues: fields)
        guard case .string(let instanceID) = resultMap["instance_id"],
              UUIDValidation.isCanonical(instanceID),
              instanceID == expectedInstanceID,
              case .string(let sourceDigest) = resultMap["source_digest"],
              ProfileValidation.isValidSourceDigest(sourceDigest),
              sourceDigest == expectedSourceDigest,
              case .string(let profileID) = resultMap["profile_id"],
              ProfileValidation.isValidID(profileID),
              profileID == expectedProfileID,
              case .string(let positionID) = resultMap["position_id"],
              ProfileValidation.isValidPositionCoordinate(positionID),
              positionID == expectedPositionID,
              case .string(let label) = resultMap["label"],
              ProfileValidation.isValidPositionLabel(label) else {
            throw ResponseValidationError.invalidResult
        }
        let background: String
        let labelAlignment: String
        let labelSize: Int
        let notificationSources: [String]
        if actualKeys == baseKeys {
            background = "#000000"
            labelAlignment = "bottom"
            labelSize = 10
            notificationSources = []
        } else {
            guard case .string(let configuredBackground) = resultMap["background"],
                  Self.isHexColor(configuredBackground),
                  case .string(let configuredAlignment) = resultMap["label_alignment"],
                  configuredAlignment == "bottom" || configuredAlignment == "center",
                  case .number(let configuredSize) = resultMap["label_size"],
                  let size = Int(configuredSize.rawValue),
                  (8...32).contains(size),
                  case .array(let sourcesValue) = resultMap["notification_sources"],
                  sourcesValue.count <= 16 else {
                throw ResponseValidationError.invalidResult
            }
            var sources = [String]()
            var seenSources = Set<String>()
            for value in sourcesValue {
                guard case .string(let source) = value,
                      ProfileValidation.isValidID(source),
                      seenSources.insert(source).inserted else {
                    throw ResponseValidationError.invalidResult
                }
                sources.append(source)
            }
            background = configuredBackground
            labelAlignment = configuredAlignment
            labelSize = size
            notificationSources = sources
        }
        let action = try Self.decodeConfiguredAction(resultMap["action"])
        return ConfigEditorPositionResponse(
            requestID: envelope.requestID,
            instanceID: instanceID,
            sourceDigest: sourceDigest,
            profileID: profileID,
            positionID: positionID,
            label: label,
            background: background,
            labelAlignment: labelAlignment,
            labelSize: labelSize,
            notificationSources: notificationSources,
            action: action
        )
    }

    private static func isHexColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (bytes.count == 7 || bytes.count == 9) && bytes[0] == 0x23 && bytes.dropFirst().allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    private static func decodeConfiguredAction(_ value: JSONValue?) throws -> ConfiguredAction? {
        guard let value else { return nil }
        guard case .object(let actionFields) = value else {
            throw ResponseValidationError.invalidResult
        }
        let values = Dictionary(uniqueKeysWithValues: actionFields)
        guard case .string(let type) = values["type"] else {
            throw ResponseValidationError.invalidResult
        }
        let gesture: ButtonGesture
        if let gestureValue = values["gesture"] {
            guard case .string(let configuredGesture) = gestureValue else {
                throw ResponseValidationError.invalidResult
            }
            guard let value = ButtonGesture(rawValue: configuredGesture) else {
                throw ResponseValidationError.invalidResult
            }
            gesture = value
        } else {
            gesture = .release
        }
        let fieldNames = Set(values.keys)
        switch type {
        case "activate_profile":
            guard fieldNames == ["type", "profile_id"]
                    || fieldNames == ["type", "profile_id", "gesture"],
                  case .string(let profileID) = values["profile_id"],
                  ProfileValidation.isValidID(profileID) else {
                throw ResponseValidationError.invalidResult
            }
            return .activateProfile(profileID: profileID, gesture: gesture)
        case "execute":
            guard fieldNames == ["type", "executable", "arguments", "timeout_seconds"]
                    || fieldNames == ["type", "executable", "arguments", "timeout_seconds", "gesture"],
                  case .string(let executable) = values["executable"],
                  ProfileValidation.isValidExecutable(executable),
                  case .array(let argumentValues) = values["arguments"],
                  argumentValues.allSatisfy({ if case .string = $0 { true } else { false } }),
                  case .number(let rawTimeout) = values["timeout_seconds"],
                  let timeout = Int(rawTimeout.rawValue),
                  (1...60).contains(timeout) else {
                throw ResponseValidationError.invalidResult
            }
            let arguments = argumentValues.compactMap { value -> String? in
                guard case .string(let argument) = value else { return nil }
                return argument
            }
            guard arguments.count <= 32,
                  arguments.allSatisfy({ $0.utf8.count <= 1024 && !$0.utf8.contains(0) }),
                  arguments.reduce(0, { $0 + $1.utf8.count }) <= 8192 else {
                throw ResponseValidationError.invalidResult
            }
            return .execute(executable: executable, arguments: arguments, timeoutSeconds: timeout, gesture: gesture)
        case "type_text":
            guard fieldNames == ["type", "text"] || fieldNames == ["type", "text", "gesture"],
                  case .string(let text) = values["text"],
                  !text.isEmpty, text.utf16.count <= 64, !text.utf8.contains(0) else {
                throw ResponseValidationError.invalidResult
            }
            return .typeText(text: text, gesture: gesture)
        case "key_press":
            guard fieldNames == ["type", "key"] || fieldNames == ["type", "key", "gesture"],
                  case .some(.string("enter")) = values["key"] else {
                throw ResponseValidationError.invalidResult
            }
            return .keyPress(key: "enter", gesture: gesture)
        default:
            throw ResponseValidationError.invalidResult
        }
    }

    public static func validateConfigEditorMutation(
        frame: Data,
        expectedRequestID: String,
        expectedInstanceID: String,
        method: RuntimeMethod
    ) throws -> ConfigEditorMutationResponse {
        guard method == .configEditorProfileLabelSet ||
                method == .configEditorProfileCreate ||
                method == .configEditorProfileDelete ||
                method == .configEditorPositionLabelSet ||
                method == .configEditorPositionPatch else {
            throw ResponseValidationError.invalidResult
        }
        let root = try parseFrame(frame)
        let envelope = try validateConfigEditorEnvelope(root, expectedRequestID: expectedRequestID)
        guard case .object(let fields) = envelope.result else {
            throw ResponseValidationError.invalidResult
        }
        let resultMap = try exactMap(
            fields,
            keys: ["instance_id", "source_digest", "file_commit", "reload_outcome", "revision", "effect", "reason"]
        )
        guard case .string(let instanceID) = resultMap["instance_id"],
              UUIDValidation.isCanonical(instanceID),
              instanceID == expectedInstanceID,
              case .string(let sourceDigest) = resultMap["source_digest"],
              ProfileValidation.isValidSourceDigest(sourceDigest),
              case .string(let fileCommitValue) = resultMap["file_commit"],
              let fileCommit = ConfigEditorFileCommit(rawValue: fileCommitValue),
              case .string(let reloadOutcomeValue) = resultMap["reload_outcome"],
              let reloadOutcome = ConfigEditorReloadOutcome(rawValue: reloadOutcomeValue),
              case .number(let revisionNumber) = resultMap["revision"],
              let revision = UInt64(revisionNumber.rawValue), revision > 0,
              case .string(let effectValue) = resultMap["effect"],
              let effect = ConfigEditorEffect(rawValue: effectValue),
              case .string(let reasonValue) = resultMap["reason"],
              let reason = ConfigEditorReason(rawValue: reasonValue) else {
            throw ResponseValidationError.invalidResult
        }
        return ConfigEditorMutationResponse(
            requestID: envelope.requestID,
            instanceID: instanceID,
            sourceDigest: sourceDigest,
            fileCommit: fileCommit,
            reloadOutcome: reloadOutcome,
            revision: revision,
            effect: effect,
            reason: reason
        )
    }

    private struct ProfileEnvelope {
        let requestID: String
        let result: JSONValue
    }

    private static func validateConfigEditorEnvelope(
        _ root: JSONValue,
        expectedRequestID: String
    ) throws -> ProfileEnvelope {
        guard UUIDValidation.isCanonical(expectedRequestID) else {
            throw ResponseValidationError.invalidRequestID
        }
        guard case .object(let fields) = root else {
            throw ResponseValidationError.invalidEnvelope
        }
        let fieldMap = try exactMap(
            fields,
            keys: ["protocol_version", "request_id", "result", "error"],
            failure: .invalidEnvelope
        )
        guard case .number(let version) = fieldMap["protocol_version"],
              version.rawValue == "1" else {
            throw ResponseValidationError.unsupportedVersion
        }
        guard case .string(let requestID) = fieldMap["request_id"],
              UUIDValidation.isCanonical(requestID),
              requestID == expectedRequestID else {
            throw ResponseValidationError.requestIDMismatch
        }
        let result = fieldMap["result"]
        let error = fieldMap["error"]
        let resultIsNull = result?.isNull ?? true
        let errorIsNull = error?.isNull ?? true
        guard resultIsNull != errorIsNull else {
            throw ResponseValidationError.invalidEnvelope
        }
        if errorIsNull {
            guard let result else { throw ResponseValidationError.invalidResult }
            return ProfileEnvelope(requestID: requestID, result: result)
        }
        guard case .object(let errorFields) = error else {
            throw ResponseValidationError.invalidError
        }
        let errorMap = try exactMap(errorFields, keys: ["code", "message"], failure: .invalidError)
        guard case .string(let code) = errorMap["code"],
              let safeMessage = ProtocolV1.configEditorErrorMessages[code],
              case .string(let message) = errorMap["message"],
              message == safeMessage else {
            throw ResponseValidationError.invalidError
        }
        throw ResponseValidationError.serverError(RuntimeError(code: code, message: safeMessage))
    }

    private static func parseFrame(_ frame: Data) throws -> JSONValue {
        let bytes = [UInt8](frame)
        guard bytes.count <= ProtocolV1.frameLimit,
              let lineEnd = bytes.firstIndex(of: 0x0a) else {
            throw ResponseValidationError.invalidJSON
        }
        let payload = Array(bytes[..<lineEnd])
        do {
            guard String(data: Data(payload), encoding: .utf8) != nil else {
                throw JSONParseFailure.invalidUTF8
            }
            var parser = JSONParser(bytes: payload)
            return try parser.parse()
        } catch let error as ResponseValidationError {
            throw error
        } catch {
            throw ResponseValidationError.invalidJSON
        }
    }

    private static func validateProfileEnvelope(
        _ root: JSONValue,
        expectedRequestID: String
    ) throws -> ProfileEnvelope {
        guard case .object(let fields) = root else {
            throw ResponseValidationError.invalidEnvelope
        }
        let fieldMap = try exactMap(
            fields,
            keys: ["protocol_version", "request_id", "result", "error"],
            failure: .invalidEnvelope
        )
        guard case .number(let version) = fieldMap["protocol_version"],
              version.rawValue == "1" else {
            throw ResponseValidationError.unsupportedVersion
        }
        guard case .string(let requestID) = fieldMap["request_id"],
              UUIDValidation.isCanonical(requestID),
              requestID == expectedRequestID else {
            throw ResponseValidationError.requestIDMismatch
        }
        let result = fieldMap["result"]
        let error = fieldMap["error"]
        let resultIsNull = result?.isNull ?? true
        let errorIsNull = error?.isNull ?? true
        guard resultIsNull != errorIsNull else {
            throw ResponseValidationError.invalidEnvelope
        }
        if errorIsNull {
            guard let result else { throw ResponseValidationError.invalidResult }
            return ProfileEnvelope(requestID: requestID, result: result)
        }
        guard case .object(let errorFields) = error else {
            throw ResponseValidationError.invalidError
        }
        let errorMap = try exactMap(errorFields, keys: ["code", "message"], failure: .invalidError)
        guard case .string(let code) = errorMap["code"],
              ProtocolV1.profileErrorCodes.contains(code),
              case .string(let message) = errorMap["message"],
              message.utf8.count <= 256 else {
            throw ResponseValidationError.invalidError
        }
        throw ResponseValidationError.serverError(RuntimeError(code: code, message: message))
    }

    private static func exactMap(
        _ fields: [(String, JSONValue)],
        keys: [String],
        failure: ResponseValidationError = .invalidResult
    ) throws -> [String: JSONValue] {
        let map = Dictionary(uniqueKeysWithValues: fields)
        guard map.count == keys.count, Set(map.keys) == Set(keys) else {
            throw failure
        }
        return map
    }

    private static func validateResponse(
        _ root: JSONValue,
        expectedRequestID: String?,
        method: RuntimeMethod,
        expectedInstanceID: String
    ) throws -> RuntimeResponse {
        guard method == .health || method == .status else {
            throw ResponseValidationError.invalidResult
        }
        guard case .object(let fields) = root else {
            throw ResponseValidationError.invalidEnvelope
        }
        let fieldMap = Dictionary(uniqueKeysWithValues: fields)
        guard fieldMap.count == 4,
              Set(fieldMap.keys) == Set(["protocol_version", "request_id", "result", "error"]) else {
            throw ResponseValidationError.invalidEnvelope
        }

        guard case .number(let version) = fieldMap["protocol_version"],
              version.rawValue == "1" else {
            throw ResponseValidationError.unsupportedVersion
        }

        let requestID: String?
        switch fieldMap["request_id"] {
        case .some(.null):
            requestID = nil
        case .some(.string(let value)) where UUIDValidation.isCanonical(value):
            requestID = value
        default:
            throw ResponseValidationError.invalidRequestID
        }

        let result = fieldMap["result"]
        let error = fieldMap["error"]
        let resultIsNull = result == nil || result!.isNull
        let errorIsNull = error == nil || error!.isNull
        guard resultIsNull != errorIsNull else {
            throw ResponseValidationError.invalidEnvelope
        }

        if errorIsNull {
            guard let expectedRequestID, requestID == expectedRequestID else {
                throw ResponseValidationError.requestIDMismatch
            }
            guard case .object(let resultFields) = result else {
                throw ResponseValidationError.invalidResult
            }
            let resultMap = Dictionary(uniqueKeysWithValues: resultFields)
            let expectedKeys: Set<String> = method == .health
                ? ["instance_id", "state"]
                : ["instance_id", "state", "protocol_version"]
            guard Set(resultMap.keys) == expectedKeys else {
                throw ResponseValidationError.invalidResult
            }
            guard case .string(let instanceID) = resultMap["instance_id"],
                  UUIDValidation.isCanonical(instanceID),
                  instanceID == expectedInstanceID,
                  case .string("ready") = resultMap["state"] else {
                throw ResponseValidationError.invalidResult
            }

            var resultProtocolVersion: Int?
            if method == .status {
                guard case .number(let value) = resultMap["protocol_version"],
                      value.rawValue == "1" else {
                    throw ResponseValidationError.invalidResult
                }
                resultProtocolVersion = ProtocolV1.protocolVersion
            } else {
                resultProtocolVersion = nil
            }
            return RuntimeResponse(
                requestID: requestID,
                instanceID: instanceID,
                state: "ready",
                protocolVersion: resultProtocolVersion,
                error: nil
            )
        }

        guard case .object(let errorFields) = error else {
            throw ResponseValidationError.invalidError
        }
        let errorMap = Dictionary(uniqueKeysWithValues: errorFields)
        guard Set(errorMap.keys) == Set(["code", "message"]),
              case .string(let code) = errorMap["code"],
              ProtocolV1.healthStatusErrorCodes.contains(code),
              case .string(let message) = errorMap["message"],
              message.utf8.count <= 256 else {
            throw ResponseValidationError.invalidError
        }
        guard requestID == expectedRequestID else {
            throw ResponseValidationError.requestIDMismatch
        }
        throw ResponseValidationError.serverError(RuntimeError(code: code, message: message))
    }
}

private indirect enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(JSONNumber)
    case boolean(Bool)
    case null

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

private struct JSONNumber {
    let rawValue: String
}

private enum JSONParseFailure: Error {
    case invalidUTF8
    case syntax
    case duplicateKey
}

private struct JSONParser {
    let bytes: [UInt8]
    var index: Int = 0

    mutating func parse() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw JSONParseFailure.syntax }
        return value
    }

    mutating private func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw JSONParseFailure.syntax }
        switch bytes[index] {
        case 0x7b:
            return try parseObject()
        case 0x5b:
            return try parseArray()
        case 0x22:
            return .string(try parseString())
        case 0x2d, 0x30...0x39:
            return .number(try parseNumber())
        case 0x74:
            try consumeKeyword(Array("true".utf8))
            return .boolean(true)
        case 0x66:
            try consumeKeyword(Array("false".utf8))
            return .boolean(false)
        case 0x6e:
            try consumeKeyword(Array("null".utf8))
            return .null
        default:
            throw JSONParseFailure.syntax
        }
    }

    mutating private func parseObject() throws -> JSONValue {
        try consume(0x7b)
        skipWhitespace()
        var fields: [(String, JSONValue)] = []
        var keys = Set<String>()
        if consumeIfPresent(0x7d) { return .object(fields) }

        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw JSONParseFailure.syntax
            }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw JSONParseFailure.duplicateKey }
            skipWhitespace()
            try consume(0x3a)
            skipWhitespace()
            fields.append((key, try parseValue()))
            skipWhitespace()
            if consumeIfPresent(0x7d) { return .object(fields) }
            try consume(0x2c)
        }
    }

    mutating private func parseArray() throws -> JSONValue {
        try consume(0x5b)
        skipWhitespace()
        var values: [JSONValue] = []
        if consumeIfPresent(0x5d) { return .array(values) }
        while true {
            skipWhitespace()
            values.append(try parseValue())
            skipWhitespace()
            if consumeIfPresent(0x5d) { return .array(values) }
            try consume(0x2c)
        }
    }

    mutating private func parseString() throws -> String {
        try consume(0x22)
        var output = ""
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                return output
            }
            if byte == 0x5c {
                index += 1
                guard index < bytes.count else { throw JSONParseFailure.syntax }
                switch bytes[index] {
                case 0x22, 0x5c, 0x2f:
                    output.append(Character(UnicodeScalar(bytes[index])))
                    index += 1
                case 0x62:
                    output.append("\u{8}")
                    index += 1
                case 0x66:
                    output.append("\u{c}")
                    index += 1
                case 0x6e:
                    output.append("\n")
                    index += 1
                case 0x72:
                    output.append("\r")
                    index += 1
                case 0x74:
                    output.append("\t")
                    index += 1
                case 0x75:
                    let scalar = try parseUnicodeScalar()
                    guard let unicodeScalar = UnicodeScalar(scalar) else {
                        throw JSONParseFailure.syntax
                    }
                    output.unicodeScalars.append(unicodeScalar)
                default:
                    throw JSONParseFailure.syntax
                }
                continue
            }
            guard byte >= 0x20 else { throw JSONParseFailure.syntax }
            let start = index
            while index < bytes.count,
                  bytes[index] != 0x22,
                  bytes[index] != 0x5c,
                  bytes[index] >= 0x20 {
                index += 1
            }
            guard let raw = String(data: Data(bytes[start..<index]), encoding: .utf8) else {
                throw JSONParseFailure.invalidUTF8
            }
            output.append(raw)
        }
        throw JSONParseFailure.syntax
    }

    mutating private func parseUnicodeScalar() throws -> UInt32 {
        try consume(0x75)
        let high = try parseHexQuad()
        if (0xd800...0xdbff).contains(high) {
            guard index + 5 < bytes.count,
                  bytes[index] == 0x5c,
                  bytes[index + 1] == 0x75 else {
                throw JSONParseFailure.syntax
            }
            index += 2
            let low = try parseHexQuad()
            guard (0xdc00...0xdfff).contains(low) else {
                throw JSONParseFailure.syntax
            }
            return 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00)
        }
        guard !(0xdc00...0xdfff).contains(high) else {
            throw JSONParseFailure.syntax
        }
        return high
    }

    mutating private func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw JSONParseFailure.syntax }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = hexValue(bytes[index]) else {
                throw JSONParseFailure.syntax
            }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }

    mutating private func parseNumber() throws -> JSONNumber {
        let start = index
        if consumeIfPresent(0x2d) {}
        if consumeIfPresent(0x30) {
            if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                throw JSONParseFailure.syntax
            }
        } else {
            guard index < bytes.count, bytes[index] >= 0x31, bytes[index] <= 0x39 else {
                throw JSONParseFailure.syntax
            }
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                index += 1
            }
        }
        if consumeIfPresent(0x2e) {
            guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else {
                throw JSONParseFailure.syntax
            }
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                index += 1
            }
        }
        if index < bytes.count, bytes[index] == 0x65 || (index < bytes.count && bytes[index] == 0x45) {
            index += 1
            if index < bytes.count, bytes[index] == 0x2b || bytes[index] == 0x2d {
                index += 1
            }
            guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else {
                throw JSONParseFailure.syntax
            }
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                index += 1
            }
        }
        return JSONNumber(rawValue: String(decoding: bytes[start..<index], as: UTF8.self))
    }

    mutating private func consume(_ expected: UInt8) throws {
        guard index < bytes.count, bytes[index] == expected else {
            throw JSONParseFailure.syntax
        }
        index += 1
    }

    mutating private func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    mutating private func consumeKeyword(_ keyword: [UInt8]) throws {
        guard bytes[index..<min(index + keyword.count, bytes.count)].elementsEqual(keyword) else {
            throw JSONParseFailure.syntax
        }
        index += keyword.count
    }

    mutating private func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0a, 0x0d:
                index += 1
            default:
                return
            }
        }
    }

    private func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: return UInt32(byte - 0x30)
        case 0x41...0x46: return UInt32(byte - 0x41 + 10)
        case 0x61...0x66: return UInt32(byte - 0x61 + 10)
        default: return nil
        }
    }
}
