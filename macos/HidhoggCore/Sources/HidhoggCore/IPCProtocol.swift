import Foundation

public enum IPCMethod: String, CaseIterable, Sendable {
    case health
    case status
    case profilesList = "profiles.list"
    case profilesActivate = "profiles.activate"
    case executionsList = "executions.list"
    case executionsGet = "executions.get"
    case configReload = "config.reload"
    case configStatus = "config.status"
    case editorSnapshot = "config.editor.snapshot"
    case editorPositionsList = "config.editor.positions.list"
    case editorProfileGet = "config.editor.profile.get"
    case editorPositionGet = "config.editor.position.get"
    case editorProfileCreate = "config.editor.profile.create"
    case editorProfileDelete = "config.editor.profile.delete"
    case editorProfileLabelSet = "config.editor.profile_label.set"
    case editorPositionLabelSet = "config.editor.position_label.set"
    case editorPositionPatch = "config.editor.position.patch"
    case displayHostStateSet = "display.host_state.set"
    case inputStatus = "input.status"
    case inputRequestPermission = "input.request_permission"
    case doctor
    case notificationsEmit = "notifications.emit"
    case notificationsClear = "notifications.clear"
}

public enum IPCCommand: Sendable {
    case health
    case status
    case profilesList
    case profilesActivate(profileID: String)
    case executionsList(limit: Int?)
    case executionsGet(id: String)
    case configReload
    case configStatus
    case editorSnapshot
    case editorPositions(sourceDigest: String, profileID: String)
    case editorProfile(sourceDigest: String, profileID: String)
    case editorPosition(sourceDigest: String, profileID: String, positionID: String)
    case editorSetProfileLabel(expectedDigest: String, profileID: String, label: String)
    case editorSetPositionLabel(expectedDigest: String, profileID: String, positionID: String, label: String)
    case editorCreateProfile(expectedDigest: String, profileID: String, label: String, sourceProfileID: String?)
    case editorDeleteProfile(expectedDigest: String, profileID: String)
    case editorPatchPosition(expectedDigest: String, profileID: String, positionID: String, patch: ConfigurationPositionPatch)
    case setDisplayHostState(awake: Bool)
    case inputStatus
    case requestInputPermission
    case doctor
    case emitNotification(source: String, text: String, ttlSeconds: Int?)
    case clearNotification(id: String)

    var method: IPCMethod {
        switch self {
        case .health: .health
        case .status: .status
        case .profilesList: .profilesList
        case .profilesActivate: .profilesActivate
        case .executionsList: .executionsList
        case .executionsGet: .executionsGet
        case .configReload: .configReload
        case .configStatus: .configStatus
        case .editorSnapshot: .editorSnapshot
        case .editorPositions: .editorPositionsList
        case .editorProfile: .editorProfileGet
        case .editorPosition: .editorPositionGet
        case .editorSetProfileLabel: .editorProfileLabelSet
        case .editorSetPositionLabel: .editorPositionLabelSet
        case .editorCreateProfile: .editorProfileCreate
        case .editorDeleteProfile: .editorProfileDelete
        case .editorPatchPosition: .editorPositionPatch
        case .setDisplayHostState: .displayHostStateSet
        case .inputStatus: .inputStatus
        case .requestInputPermission: .inputRequestPermission
        case .doctor: .doctor
        case .emitNotification: .notificationsEmit
        case .clearNotification: .notificationsClear
        }
    }

    func params(instanceID: String) -> IPCJSONValue {
        var fields = [(String, IPCJSONValue)]()
        fields.append(("instance_id", .string(instanceID)))
        switch self {
        case .health, .status, .profilesList, .configReload, .configStatus, .editorSnapshot,
             .inputStatus, .requestInputPermission, .doctor:
            break
        case let .profilesActivate(profileID):
            fields.append(("profile_id", .string(profileID)))
        case let .executionsList(limit):
            if let limit { fields.append(("limit", .number(IPCJSONNumber(rawValue: String(limit))))) }
        case let .executionsGet(id):
            fields.append(("execution_id", .string(id)))
        case let .editorPositions(sourceDigest, profileID), let .editorProfile(sourceDigest, profileID):
            fields.append(("source_digest", .string(sourceDigest)))
            fields.append(("profile_id", .string(profileID)))
        case let .editorPosition(sourceDigest, profileID, positionID):
            fields.append(("source_digest", .string(sourceDigest)))
            fields.append(("profile_id", .string(profileID)))
            fields.append(("position_id", .string(positionID)))
        case let .editorSetProfileLabel(expectedDigest, profileID, label):
            fields.append(contentsOf: [
                ("expected_digest", .string(expectedDigest)),
                ("profile_id", .string(profileID)),
                ("label", .string(label)),
            ])
        case let .editorSetPositionLabel(expectedDigest, profileID, positionID, label):
            fields.append(contentsOf: [
                ("expected_digest", .string(expectedDigest)),
                ("profile_id", .string(profileID)),
                ("position_id", .string(positionID)),
                ("label", .string(label)),
            ])
        case let .editorCreateProfile(expectedDigest, profileID, label, sourceProfileID):
            fields.append(contentsOf: [
                ("expected_digest", .string(expectedDigest)),
                ("profile_id", .string(profileID)),
                ("label", .string(label)),
            ])
            if let sourceProfileID { fields.append(("source_profile_id", .string(sourceProfileID))) }
        case let .editorDeleteProfile(expectedDigest, profileID):
            fields.append(contentsOf: [
                ("expected_digest", .string(expectedDigest)),
                ("profile_id", .string(profileID)),
            ])
        case let .editorPatchPosition(expectedDigest, profileID, positionID, patch):
            fields.append(contentsOf: [
                ("expected_digest", .string(expectedDigest)),
                ("profile_id", .string(profileID)),
                ("position_id", .string(positionID)),
                ("patch", IPCProtocol.encode(patch)),
            ])
        case let .setDisplayHostState(awake):
            fields.append(("display_awake", .boolean(awake)))
        case let .emitNotification(source, text, ttlSeconds):
            fields.append(contentsOf: [("source", .string(source)), ("text", .string(text))])
            if let ttlSeconds { fields.append(("ttl_seconds", .number(IPCJSONNumber(rawValue: String(ttlSeconds))))) }
        case let .clearNotification(id):
            fields.append(("notification_id", .string(id)))
        }
        return .object(fields.map { IPCJSONField(key: $0.0, value: $0.1) })
    }
}

public struct IPCProtocolFailure: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    public let requestID: String?

    public init(code: String, message: String, requestID: String? = nil) {
        self.code = code
        self.message = message
        self.requestID = requestID
    }
}

public struct IPCWireRequest: Sendable, Equatable {
    public let requestID: String
    public let method: IPCMethod
    public let instanceID: String
    public let params: IPCJSONValue

    init(requestID: String, method: IPCMethod, instanceID: String, params: IPCJSONValue) {
        self.requestID = requestID
        self.method = method
        self.instanceID = instanceID
        self.params = params
    }
}

public struct IPCWireResponse: Sendable, Equatable {
    public let requestID: String?
    public let result: IPCJSONValue?
    public let failure: IPCProtocolFailure?

    public init(requestID: String?, result: IPCJSONValue? = nil, failure: IPCProtocolFailure? = nil) {
        self.requestID = requestID
        self.result = result
        self.failure = failure
    }
}

public enum IPCFrameError: Error, Sendable, Equatable {
    case tooLarge
    case incomplete
    case invalidFrame
}

public enum IPCProtocol {
    public static let version = 1
    public static let maximumFrameBytes = 16_384

    public static func frame(_ payload: IPCJSONValue) throws -> Data {
        let encoded = IPCJSONCodec.encode(payload)
        do { _ = try IPCJSONCodec.decode(encoded) }
        catch { throw IPCFrameError.invalidFrame }
        var bytes = Array(encoded)
        bytes.append(0x0a)
        guard bytes.count <= maximumFrameBytes else { throw IPCFrameError.tooLarge }
        return Data(bytes)
    }

    public static func firstFrame(in data: Data) throws -> Data {
        let bytes = Array(data)
        guard let newline = bytes.firstIndex(of: 0x0a) else {
            if bytes.count >= maximumFrameBytes { throw IPCFrameError.tooLarge }
            throw IPCFrameError.incomplete
        }
        guard newline + 1 <= maximumFrameBytes else { throw IPCFrameError.tooLarge }
        return Data(bytes[...newline])
    }

    public static func decodeRequest(_ data: Data) -> Result<IPCWireRequest, IPCProtocolFailure> {
        let frame: Data
        do { frame = try firstFrame(in: data) }
        catch IPCFrameError.tooLarge {
            return .failure(failure("message_too_large", "request message is too large"))
        } catch {
            return .failure(failure("invalid_json", "request is not valid JSON"))
        }
        let payload = Data(frame.dropLast())
        let value: IPCJSONValue
        do { value = try IPCJSONCodec.decode(payload) }
        catch IPCJSONError.duplicateKey {
            return .failure(failure("invalid_envelope", "request envelope is invalid"))
        } catch {
            return .failure(failure("invalid_json", "request is not valid JSON"))
        }

        guard let fields = value.objectFields else {
            return .failure(failure("invalid_envelope", "request envelope is invalid"))
        }
        let rawID = value.value(for: "request_id")?.stringValue
        let requestID = rawID.flatMap { isCanonicalUUID($0) ? $0 : nil }
        guard exactly(fields, ["protocol_version", "request_id", "method", "params"]),
              let rawID,
              let methodName = value.value(for: "method")?.stringValue,
              let params = value.value(for: "params"),
              params.objectFields != nil else {
            return .failure(failure("invalid_envelope", "request envelope is invalid", requestID: requestID))
        }
        guard isCanonicalUUID(rawID) else {
            return .failure(failure("invalid_envelope", "request envelope is invalid"))
        }
        guard value.value(for: "protocol_version")?.integerValue == Int64(version) else {
            return .failure(failure("unsupported_version", "protocol version is not supported", requestID: rawID))
        }
        guard let method = IPCMethod(rawValue: methodName) else {
            return .failure(failure("unknown_method", "request method is not supported", requestID: rawID))
        }
        guard validateParams(params, method: method) else {
            return .failure(failure("invalid_envelope", "request envelope is invalid", requestID: rawID))
        }
        guard let instanceID = params.value(for: "instance_id")?.stringValue else {
            return .failure(failure("invalid_envelope", "request envelope is invalid", requestID: rawID))
        }
        return .success(IPCWireRequest(requestID: rawID, method: method, instanceID: instanceID, params: params))
    }

    public static func encodeRequest(requestID: String, command: IPCCommand, instanceID: String) throws -> Data {
        guard isCanonicalUUID(requestID), isCanonicalUUID(instanceID) else { throw IPCFrameError.invalidFrame }
        let payload = IPCJSONValue.object([
            ("protocol_version", .number(IPCJSONNumber(rawValue: "1"))),
            ("request_id", .string(requestID)),
            ("method", .string(command.method.rawValue)),
            ("params", command.params(instanceID: instanceID)),
        ])
        guard case .success = decodeRequest(try frame(payload)) else { throw IPCFrameError.invalidFrame }
        return try frame(payload)
    }

    public static func encodeResponse(_ response: IPCWireResponse) throws -> Data {
        let payload: IPCJSONValue
        if let failure = response.failure {
            guard errorCodes.contains(failure.code), failure.message.utf8.count <= 256 else { throw IPCFrameError.invalidFrame }
            payload = .object([
                ("protocol_version", .number(IPCJSONNumber(rawValue: "1"))),
                ("request_id", (response.requestID ?? failure.requestID).map(IPCJSONValue.string) ?? .null),
                ("result", .null),
                ("error", .object([
                    IPCJSONField(key: "code", value: .string(failure.code)),
                    IPCJSONField(key: "message", value: .string(failure.message)),
                ])),
            ])
        } else if let result = response.result {
            payload = .object([
                ("protocol_version", .number(IPCJSONNumber(rawValue: "1"))),
                ("request_id", response.requestID.map(IPCJSONValue.string) ?? .null),
                ("result", result),
                ("error", .null),
            ])
        } else {
            throw IPCFrameError.invalidFrame
        }
        return try frame(payload)
    }

    static func validate(_ response: IPCWireResponse, for request: IPCWireRequest) -> Bool {
        guard response.requestID == request.requestID else { return false }
        if let failure = response.failure {
            return response.result == nil && errorCodes.contains(failure.code) && failure.message.utf8.count <= 256
        }
        guard response.failure == nil, let result = response.result else { return false }
        do { try validateResponseResult(result, method: request.method, instanceID: request.instanceID) }
        catch { return false }
        return true
    }

    public static func decodeResponse(
        _ data: Data,
        expectedRequestID: String,
        expectedInstanceID: String,
        method: IPCMethod
    ) throws -> IPCWireResponse {
        let frame = try firstFrame(in: data)
        let value = try IPCJSONCodec.decode(Data(frame.dropLast()))
        guard let fields = value.objectFields,
              exactly(fields, ["protocol_version", "request_id", "result", "error"]),
              value.value(for: "protocol_version")?.integerValue == 1 else { throw IPCFrameError.invalidFrame }
        guard let requestID = value.value(for: "request_id")?.stringValue,
              isCanonicalUUID(requestID), requestID == expectedRequestID else { throw IPCFrameError.invalidFrame }
        guard let result = value.value(for: "result"), let error = value.value(for: "error") else {
            throw IPCFrameError.invalidFrame
        }
        if case .null = result {
            guard case .object = error,
                  let errorFields = error.objectFields,
                  exactly(errorFields, ["code", "message"]),
                  let code = error.value(for: "code")?.stringValue,
                  Self.errorCodes.contains(code),
                  let message = error.value(for: "message")?.stringValue,
                  message.utf8.count <= 256 else { throw IPCFrameError.invalidFrame }
            return IPCWireResponse(requestID: requestID, failure: IPCProtocolFailure(code: code, message: message, requestID: requestID))
        }
        guard case .null = error else { throw IPCFrameError.invalidFrame }
        try validateResponseResult(result, method: method, instanceID: expectedInstanceID)
        return IPCWireResponse(requestID: requestID, result: result)
    }

    static func encode(_ patch: ConfigurationPositionPatch) -> IPCJSONValue {
        var fields = [IPCJSONField]()
        append(patch.label, key: "label", to: &fields) { .string($0) }
        append(patch.background, key: "background", to: &fields) { .string($0) }
        append(patch.labelAlignment, key: "label_alignment", to: &fields) { .string($0) }
        append(patch.labelSize, key: "label_size", to: &fields) { .number(IPCJSONNumber(rawValue: String($0))) }
        append(patch.notificationSources, key: "notification_sources", to: &fields) { .array($0.map(IPCJSONValue.string)) }
        switch patch.action {
        case .keep: break
        case .reset: fields.append(IPCJSONField(key: "action", value: operation(.reset)))
        case let .set(action): fields.append(IPCJSONField(key: "action", value: operation(.set(encodeAction(action)))))
        }
        return .object(fields)
    }

    private static func append<Value: Sendable>(
        _ edit: ConfigurationFieldEdit<Value>,
        key: String,
        to fields: inout [IPCJSONField],
        encode: (Value) -> IPCJSONValue
    ) {
        switch edit {
        case .keep: break
        case .reset: fields.append(IPCJSONField(key: key, value: operation(.reset)))
        case let .set(value): fields.append(IPCJSONField(key: key, value: operation(.set(encode(value)))))
        }
    }

    private enum Operation {
        case reset
        case set(IPCJSONValue)
    }

    private static func operation(_ operation: Operation) -> IPCJSONValue {
        switch operation {
        case .reset:
            .object([("op", .string("reset"))])
        case let .set(value):
            .object([("op", .string("set")), ("value", value)])
        }
    }

    static func encodeAction(_ action: ConfiguredAction) -> IPCJSONValue {
        var fields = [IPCJSONField]()
        switch action {
        case let .activateProfile(profileID, gesture):
            fields = [
                IPCJSONField(key: "type", value: .string("activate_profile")),
                IPCJSONField(key: "profile_id", value: .string(profileID)),
            ]
            if gesture != .release { fields.append(IPCJSONField(key: "gesture", value: .string(gesture.rawValue))) }
        case let .execute(executable, arguments, timeoutSeconds, gesture):
            fields = [
                IPCJSONField(key: "type", value: .string("execute")),
                IPCJSONField(key: "executable", value: .string(executable)),
                IPCJSONField(key: "arguments", value: .array(arguments.map(IPCJSONValue.string))),
                IPCJSONField(key: "timeout_seconds", value: .number(IPCJSONNumber(rawValue: String(timeoutSeconds)))),
            ]
            if gesture != .release { fields.append(IPCJSONField(key: "gesture", value: .string(gesture.rawValue))) }
        case let .typeText(text, gesture):
            fields = [
                IPCJSONField(key: "type", value: .string("type_text")),
                IPCJSONField(key: "text", value: .string(text)),
            ]
            if gesture != .release { fields.append(IPCJSONField(key: "gesture", value: .string(gesture.rawValue))) }
        case let .keyPress(key, gesture):
            fields = [
                IPCJSONField(key: "type", value: .string("key_press")),
                IPCJSONField(key: "key", value: .string(key)),
            ]
            if gesture != .release { fields.append(IPCJSONField(key: "gesture", value: .string(gesture.rawValue))) }
        }
        return .object(fields)
    }

    private static func validateParams(_ params: IPCJSONValue, method: IPCMethod) -> Bool {
        guard let fields = params.objectFields else { return false }
        let names = fields.map(\.key)
        guard params.value(for: "instance_id")?.stringValue.map(isCanonicalUUID) == true else { return false }
        switch method {
        case .health, .status, .profilesList, .configReload, .configStatus, .editorSnapshot, .inputStatus, .inputRequestPermission, .doctor:
            return exactly(fields, ["instance_id"])
        case .profilesActivate:
            return exactly(fields, ["instance_id", "profile_id"]) && isNonemptyString(params.value(for: "profile_id"))
        case .executionsList:
            guard exactly(fields, names.contains("limit") ? ["instance_id", "limit"] : ["instance_id"]) else { return false }
            guard let value = params.value(for: "limit") else { return true }
            guard let limit = value.integerValue else { return false }
            return (1...32).contains(limit)
        case .executionsGet:
            return exactly(fields, ["instance_id", "execution_id"]) && params.value(for: "execution_id")?.stringValue.map(isCanonicalUUID) == true
        case .editorPositionsList, .editorProfileGet:
            return exactly(fields, ["instance_id", "source_digest", "profile_id"]) &&
                validDigest(params.value(for: "source_digest")) && validProfileID(params.value(for: "profile_id"))
        case .editorPositionGet:
            return exactly(fields, ["instance_id", "source_digest", "profile_id", "position_id"]) &&
                validDigest(params.value(for: "source_digest")) && validProfileID(params.value(for: "profile_id")) && validCoordinate(params.value(for: "position_id"))
        case .editorProfileLabelSet:
            return exactly(fields, ["instance_id", "expected_digest", "profile_id", "label"]) &&
                validDigest(params.value(for: "expected_digest")) && validProfileID(params.value(for: "profile_id")) && validProfileLabel(params.value(for: "label"), allowsEmpty: false)
        case .editorPositionLabelSet:
            return exactly(fields, ["instance_id", "expected_digest", "profile_id", "position_id", "label"]) &&
                validDigest(params.value(for: "expected_digest")) && validProfileID(params.value(for: "profile_id")) && validCoordinate(params.value(for: "position_id")) && validProfileLabel(params.value(for: "label"), allowsEmpty: true)
        case .editorProfileCreate:
            let hasSource = params.value(for: "source_profile_id") != nil
            return exactly(fields, hasSource
                ? ["instance_id", "expected_digest", "profile_id", "label", "source_profile_id"]
                : ["instance_id", "expected_digest", "profile_id", "label"]) &&
                validDigest(params.value(for: "expected_digest")) && validProfileID(params.value(for: "profile_id")) &&
                validProfileLabel(params.value(for: "label"), allowsEmpty: false) &&
                (!hasSource || validProfileID(params.value(for: "source_profile_id")))
        case .editorProfileDelete:
            return exactly(fields, ["instance_id", "expected_digest", "profile_id"]) &&
                validDigest(params.value(for: "expected_digest")) && validProfileID(params.value(for: "profile_id"))
        case .editorPositionPatch:
            return exactly(fields, ["instance_id", "expected_digest", "profile_id", "position_id", "patch"]) &&
                validDigest(params.value(for: "expected_digest")) && validProfileID(params.value(for: "profile_id")) &&
                validCoordinate(params.value(for: "position_id")) && decodePatch(params.value(for: "patch")) != nil
        case .displayHostStateSet:
            return exactly(fields, ["instance_id", "display_awake"]) && params.value(for: "display_awake")?.booleanValue != nil
        case .notificationsEmit:
            let hasTTL = params.value(for: "ttl_seconds") != nil
            guard exactly(fields, hasTTL ? ["instance_id", "source", "text", "ttl_seconds"] : ["instance_id", "source", "text"]) else { return false }
            guard validStableID(params.value(for: "source")), validNotificationText(params.value(for: "text")) else { return false }
            guard let ttl = params.value(for: "ttl_seconds") else { return true }
            guard let seconds = ttl.integerValue else { return false }
            return (1...86_400).contains(seconds)
        case .notificationsClear:
            return exactly(fields, ["instance_id", "notification_id"]) && params.value(for: "notification_id")?.stringValue.map(isCanonicalUUID) == true
        }
    }

    static func decodePatch(_ value: IPCJSONValue?) -> ConfigurationPositionPatch? {
        guard let value, let fields = value.objectFields else { return nil }
        let permitted = ["label", "background", "label_alignment", "label_size", "notification_sources", "action"]
        guard fields.allSatisfy({ field in permitted.contains { key in key.utf8.elementsEqual(field.key.utf8) } }) else { return nil }
        let label: ConfigurationFieldEdit<String>? = decodeOperation(value.value(for: "label"), as: { value in value.stringValue.flatMap { validProfileLabelString($0, allowsEmpty: true) ? $0 : nil } })
        let background: ConfigurationFieldEdit<String>? = decodeOperation(value.value(for: "background"), as: { value in value.stringValue.flatMap { isHexColor($0) ? $0 : nil } })
        let alignment: ConfigurationFieldEdit<String>? = decodeOperation(value.value(for: "label_alignment"), as: { value in
            guard let string = value.stringValue, string == "bottom" || string == "center" else { return nil }
            return string
        })
        let size: ConfigurationFieldEdit<Int>? = decodeOperation(value.value(for: "label_size"), as: { value in
            guard let integer = value.integerValue, (8...32).contains(integer) else { return nil }
            return Int(integer)
        })
        let sources: ConfigurationFieldEdit<[String]>? = decodeOperation(value.value(for: "notification_sources"), as: decodeSources)
        let action: ConfigurationFieldEdit<ConfiguredAction>? = decodeOperation(value.value(for: "action"), as: decodeAction)
        guard let label, let background, let alignment, let size, let sources, let action else { return nil }
        return ConfigurationPositionPatch(
            label: label,
            background: background,
            labelAlignment: alignment,
            labelSize: size,
            notificationSources: sources,
            action: action
        )
    }

    private static func decodeOperation<Value: Sendable>(
        _ value: IPCJSONValue?,
        as decode: (IPCJSONValue) -> Value?
    ) -> ConfigurationFieldEdit<Value>? {
        guard let value else { return .keep }
        guard let fields = value.objectFields else { return nil }
        guard let operation = value.value(for: "op")?.stringValue else { return nil }
        if operation == "reset" {
            return exactly(fields, ["op"]) ? .reset : nil
        }
        guard operation == "set", exactly(fields, ["op", "value"]), let payload = value.value(for: "value"), let decoded = decode(payload) else { return nil }
        return .set(decoded)
    }

    private static func decodeSources(_ value: IPCJSONValue) -> [String]? {
        guard let values = value.arrayValues, (1...16).contains(values.count) else { return nil }
        var result = [String]()
        for item in values {
            guard let string = item.stringValue, validStableIDString(string), !result.contains(where: { $0.utf8.elementsEqual(string.utf8) }) else { return nil }
            result.append(string)
        }
        return result
    }

    static func decodeAction(_ value: IPCJSONValue) -> ConfiguredAction? {
        guard value.objectFields != nil,
              let type = value.value(for: "type")?.stringValue else { return nil }
        let keys = value.objectFields!.map(\.key)
        let gesture: ButtonGesture
        if let rawGestureValue = value.value(for: "gesture") {
            guard let rawGesture = rawGestureValue.stringValue else { return nil }
            guard let parsed = ButtonGesture(rawValue: rawGesture) else { return nil }
            gesture = parsed
        } else {
            gesture = .release
        }
        switch type {
        case "activate_profile":
            guard exactlyKeys(keys, ["type", "profile_id"], optional: ["gesture"]),
                  let profileID = value.value(for: "profile_id")?.stringValue,
                  validProfileIDString(profileID) else { return nil }
            return .activateProfile(profileID: profileID, gesture: gesture)
        case "execute":
            guard exactlyKeys(keys, ["type", "executable"], optional: ["gesture", "arguments", "timeout_seconds"]),
                  let executable = value.value(for: "executable")?.stringValue,
                  executable.utf8.first == 0x2f,
                  !executable.utf8.contains(0) else { return nil }
            let arguments: [String]
            if let value = value.value(for: "arguments") {
                guard let values = value.arrayValues, values.count <= 32 else { return nil }
                var totalBytes = 0
                var strings = [String]()
                for argument in values {
                    guard let string = argument.stringValue, string.utf8.count <= 1024, !string.utf8.contains(0) else { return nil }
                    totalBytes += string.utf8.count
                    guard totalBytes <= 8192 else { return nil }
                    strings.append(string)
                }
                arguments = strings
            } else {
                arguments = []
            }
            let timeout: Int64
            if let rawTimeout = value.value(for: "timeout_seconds") {
                guard let parsed = rawTimeout.integerValue else { return nil }
                timeout = parsed
            } else {
                timeout = 10
            }
            guard (1...60).contains(timeout) else { return nil }
            return .execute(executable: executable, arguments: arguments, timeoutSeconds: Int(timeout), gesture: gesture)
        case "type_text":
            guard exactlyKeys(keys, ["type", "text"], optional: ["gesture"]),
                  let text = value.value(for: "text")?.stringValue,
                  !text.isEmpty,
                  text.utf16.count <= 64,
                  !text.utf8.contains(0) else { return nil }
            return .typeText(text: text, gesture: gesture)
        case "key_press":
            guard exactlyKeys(keys, ["type", "key"], optional: ["gesture"]),
                  let key = value.value(for: "key")?.stringValue,
                  key == "enter" else { return nil }
            return .keyPress(key: key, gesture: gesture)
        default:
            return nil
        }
    }

    private static func validateResponseResult(_ value: IPCJSONValue, method: IPCMethod, instanceID: String) throws {
        guard let fields = value.objectFields else { throw IPCFrameError.invalidFrame }
        let expected: [String]
        switch method {
        case .health: expected = ["instance_id", "state"]
        case .status: expected = ["instance_id", "state", "protocol_version"]
        case .profilesList: expected = ["instance_id", "profiles"]
        case .profilesActivate: expected = ["profile_id", "changed"]
        case .executionsList: expected = ["instance_id", "executions"]
        case .executionsGet: expected = ["instance_id", "execution"]
        case .configReload: expected = ["instance_id", "revision", "changed", "effect", "catalog_changed", "default_changed", "current_profile_changed", "current_profile_fallback", "action_changed", "display_changed", "brightness_changed", "idle_changed", "display_updated"]
        case .configStatus: expected = ["instance_id", "revision", "active", "state", "outcome", "reason", "diagnostic"]
        case .editorSnapshot: expected = ["instance_id", "source_digest", "revision", "default_profile_id", "current_profile_id", "profile_ids"]
        case .editorPositionsList: expected = ["instance_id", "source_digest", "profile_id", "positions"]
        case .editorProfileGet: expected = ["instance_id", "source_digest", "profile_id", "label"]
        case .editorPositionGet: expected = ["instance_id", "source_digest", "profile_id", "position_id", "label", "background", "label_alignment", "label_size", "notification_sources"]
        case .editorProfileLabelSet, .editorPositionLabelSet, .editorProfileCreate, .editorProfileDelete, .editorPositionPatch:
            expected = ["instance_id", "source_digest", "file_commit", "reload_outcome", "revision", "effect", "reason"]
        case .displayHostStateSet: expected = ["instance_id", "display_awake", "changed"]
        case .inputStatus: expected = ["instance_id", "input"]
        case .inputRequestPermission: expected = ["instance_id", "input"]
        case .doctor: expected = ["instance_id", "doctor"]
        case .notificationsEmit: expected = ["instance_id", "notification_id", "matched_count"]
        case .notificationsClear: expected = ["instance_id", "cleared_count"]
        }
        if method == .editorPositionGet,
           fields.count == expected.count + 1,
           fields.contains(where: { $0.key.utf8.elementsEqual("action".utf8) }) {
            guard exactly(fields, expected + ["action"]) else { throw IPCFrameError.invalidFrame }
        } else {
            guard exactly(fields, expected) else { throw IPCFrameError.invalidFrame }
        }
        if method != .profilesActivate,
           value.value(for: "instance_id")?.stringValue != instanceID {
            throw IPCFrameError.invalidFrame
        }
        guard validateResponseValues(value, method: method) else { throw IPCFrameError.invalidFrame }
    }

    private static let errorCodes: Set<String> = [
        "invalid_json", "invalid_envelope", "unsupported_version", "unknown_method", "instance_mismatch",
        "message_too_large", "internal", "profile_not_found", "activation_failed", "device_write_failed",
        "shutting_down", "busy", "execution_not_found", "history_unavailable", "reload_rejected",
        "invalid_notification", "stale_source", "edit_invalid", "file_commit_failed",
    ]

    private static func validateResponseValues(_ value: IPCJSONValue, method: IPCMethod) -> Bool {
        switch method {
        case .health:
            return value.value(for: "state")?.stringValue == "ready"
        case .status:
            return value.value(for: "state")?.stringValue == "ready" && value.value(for: "protocol_version")?.integerValue == 1
        case .profilesList:
            guard let profiles = value.value(for: "profiles")?.arrayValues, profiles.count <= 31 else { return false }
            var ids = [String]()
            for item in profiles {
                guard let fields = item.objectFields,
                      exactly(fields, ["id", "label", "is_default", "is_current"]),
                      let id = item.value(for: "id")?.stringValue,
                      validProfileIDString(id),
                      let label = item.value(for: "label")?.stringValue,
                      validProfileLabelString(label, allowsEmpty: false),
                      item.value(for: "is_default")?.booleanValue != nil,
                      item.value(for: "is_current")?.booleanValue != nil,
                      !ids.contains(where: { $0.utf8.elementsEqual(id.utf8) }) else { return false }
                ids.append(id)
            }
            return true
        case .profilesActivate:
            return value.value(for: "profile_id")?.stringValue.map(validProfileIDString) == true &&
                value.value(for: "changed")?.booleanValue != nil
        case .executionsList:
            guard let executions = value.value(for: "executions")?.arrayValues, executions.count <= 32 else { return false }
            return executions.allSatisfy(validateExecutionSummary)
        case .executionsGet:
            guard let record = value.value(for: "execution"), let fields = record.objectFields,
                  exactly(fields, ["action_type", "execution_id", "profile_id", "position_id", "state", "submitted_at", "started_at", "finished_at", "duration_ns", "exit_code", "signal", "supervision_error", "stdout", "stdout_total_bytes", "stdout_truncated", "stderr", "stderr_total_bytes", "stderr_truncated"]) else { return false }
            return validateExecutionSummaryFields(record) &&
                record.value(for: "stdout")?.stringValue.flatMap({ Data(base64Encoded: $0) }) != nil &&
                record.value(for: "stderr")?.stringValue.flatMap({ Data(base64Encoded: $0) }) != nil &&
                record.value(for: "stdout_truncated")?.booleanValue != nil &&
                record.value(for: "stderr_truncated")?.booleanValue != nil &&
                (record.value(for: "stdout_total_bytes")?.integerValue ?? -1) >= 0 &&
                (record.value(for: "stderr_total_bytes")?.integerValue ?? -1) >= 0
        case .configReload:
            return positiveInteger(value.value(for: "revision")) &&
                value.value(for: "changed")?.booleanValue != nil &&
                ["unchanged", "action-only", "display", "brightness", "idle", "default", "catalog"].contains(value.value(for: "effect")?.stringValue ?? "") &&
                ["catalog_changed", "default_changed", "current_profile_changed", "current_profile_fallback", "action_changed", "display_changed", "brightness_changed", "idle_changed", "display_updated"].allSatisfy { value.value(for: $0)?.booleanValue != nil }
        case .configStatus:
            guard positiveInteger(value.value(for: "revision")),
                  value.value(for: "active")?.booleanValue != nil,
                  ["idle", "reloading", "closed"].contains(value.value(for: "state")?.stringValue ?? ""),
                  ["ready", "changed", "unchanged", "rejected", "unsupported"].contains(value.value(for: "outcome")?.stringValue ?? ""),
                  ["none", "candidate-rejected", "settings-pending", "canceled", "device-write-failed", "closed"].contains(value.value(for: "reason")?.stringValue ?? "") else { return false }
            return validateDiagnostic(value.value(for: "diagnostic"), outcome: value.value(for: "outcome")?.stringValue, reason: value.value(for: "reason")?.stringValue)
        case .editorSnapshot:
            guard validDigest(value.value(for: "source_digest")),
                  positiveInteger(value.value(for: "revision")),
                  let defaultID = value.value(for: "default_profile_id")?.stringValue,
                  validProfileIDString(defaultID),
                  let currentID = value.value(for: "current_profile_id")?.stringValue,
                  validProfileIDString(currentID),
                  let ids = value.value(for: "profile_ids")?.arrayValues,
                  (1...31).contains(ids.count) else { return false }
            let strings = ids.compactMap(\.stringValue)
            guard strings.count == ids.count, strings.allSatisfy(validProfileIDString) else { return false }
            let unique = Set(strings.map { Data($0.utf8) })
            return unique.count == strings.count &&
                strings.contains(where: { $0.utf8.elementsEqual(defaultID.utf8) }) &&
                strings.contains(where: { $0.utf8.elementsEqual(currentID.utf8) })
        case .editorPositionsList:
            guard validDigest(value.value(for: "source_digest")), validProfileID(value.value(for: "profile_id")),
                  let positions = value.value(for: "positions")?.arrayValues, positions.count == HidhoggConfiguration.supportedPositions.count else { return false }
            let coordinates = positions.compactMap { position -> String? in
                guard let fields = position.objectFields, exactly(fields, ["position_id", "position"]),
                      let id = position.value(for: "position_id")?.stringValue,
                      let positionID = position.value(for: "position")?.stringValue,
                      id.utf8.elementsEqual(positionID.utf8) else { return nil }
                return id
            }
            return coordinates.count == positions.count && HidhoggConfiguration.supportedPositions.allSatisfy { expected in
                coordinates.contains { $0.utf8.elementsEqual(expected.name.utf8) }
            }
        case .editorProfileGet:
            guard validDigest(value.value(for: "source_digest")), validProfileID(value.value(for: "profile_id")),
                  let label = value.value(for: "label")?.stringValue else { return false }
            return validProfileLabelString(label, allowsEmpty: false)
        case .editorPositionGet:
            guard validDigest(value.value(for: "source_digest")), validProfileID(value.value(for: "profile_id")),
                  validCoordinate(value.value(for: "position_id")),
                  let label = value.value(for: "label")?.stringValue,
                  validProfileLabelString(label, allowsEmpty: true),
                  let background = value.value(for: "background")?.stringValue, isHexColor(background),
                  let alignment = value.value(for: "label_alignment")?.stringValue,
                  alignment == "bottom" || alignment == "center",
                  let size = value.value(for: "label_size")?.integerValue, (8...32).contains(size),
                  let sources = value.value(for: "notification_sources")?.arrayValues,
                  sources.count <= 16,
                  sources.allSatisfy({ validStableID($0) }) else { return false }
            if let action = value.value(for: "action") { return decodeAction(action) != nil }
            return true
        case .editorProfileLabelSet, .editorPositionLabelSet, .editorProfileCreate, .editorProfileDelete, .editorPositionPatch:
            guard validDigest(value.value(for: "source_digest")),
                  ["unchanged", "committed", "uncertain"].contains(value.value(for: "file_commit")?.stringValue ?? ""),
                  ["unchanged", "changed", "rejected", "uncertain", "not_attempted"].contains(value.value(for: "reload_outcome")?.stringValue ?? ""),
                  positiveInteger(value.value(for: "revision")),
                  ["unchanged", "action-only", "display", "brightness", "idle", "default", "catalog"].contains(value.value(for: "effect")?.stringValue ?? ""),
                  ["none", "candidate-rejected", "settings-pending", "canceled", "device-write-failed", "closed"].contains(value.value(for: "reason")?.stringValue ?? "") else { return false }
            return true
        case .displayHostStateSet:
            return value.value(for: "display_awake")?.booleanValue != nil && value.value(for: "changed")?.booleanValue != nil
        case .inputStatus, .inputRequestPermission:
            return validateInputStatus(value.value(for: "input"))
        case .doctor:
            guard let doctor = value.value(for: "doctor"), let fields = doctor.objectFields,
                  exactly(fields, ["checks", "input"]), validateInputStatus(doctor.value(for: "input")),
                  let checks = doctor.value(for: "checks")?.arrayValues, checks.count == 4 else { return false }
            return checks.allSatisfy { check in
                guard let checkFields = check.objectFields,
                      exactly(checkFields, ["name", "state", "detail"]) else { return false }
                return check.value(for: "name")?.stringValue != nil && check.value(for: "state")?.stringValue != nil && check.value(for: "detail")?.stringValue != nil
            }
        case .notificationsEmit:
            return value.value(for: "notification_id")?.stringValue.map(isCanonicalUUID) == true && nonnegativeInteger(value.value(for: "matched_count"))
        case .notificationsClear:
            return nonnegativeInteger(value.value(for: "cleared_count"))
        }
    }

    private static func validateExecutionSummary(_ value: IPCJSONValue) -> Bool {
        guard let fields = value.objectFields,
              exactly(fields, ["action_type", "execution_id", "profile_id", "position_id", "state", "submitted_at", "started_at", "finished_at", "duration_ns", "exit_code", "signal", "supervision_error"]) else { return false }
        return validateExecutionSummaryFields(value)
    }

    private static func validateExecutionSummaryFields(_ value: IPCJSONValue) -> Bool {
        guard ["execute", "type_text", "key_press"].contains(value.value(for: "action_type")?.stringValue ?? ""),
              value.value(for: "execution_id")?.stringValue.map(isCanonicalUUID) == true,
              validStableID(value.value(for: "profile_id")), validCoordinate(value.value(for: "position_id")),
              ["running", "exited", "signaled", "timed_out", "canceled", "start_failed", "rejected_busy", "queued", "posted", "permission_denied", "failed", "rejected_queue_full"].contains(value.value(for: "state")?.stringValue ?? ""),
              nonnegativeInteger(value.value(for: "duration_ns")),
              value.value(for: "supervision_error")?.booleanValue != nil else { return false }
        for name in ["submitted_at", "started_at", "finished_at"] {
            guard let timestamp = value.value(for: name) else { return false }
            if case .null = timestamp { continue }
            guard let string = timestamp.stringValue, string.utf8.count <= 64 else { return false }
        }
        for name in ["exit_code", "signal"] {
            guard let number = value.value(for: name) else { return false }
            if case .null = number { continue }
            guard number.integerValue != nil else { return false }
        }
        if let exitCode = value.value(for: "exit_code"), case .number = exitCode,
           let signal = value.value(for: "signal"), case .number = signal { return false }
        return true
    }

    private static func validateDiagnostic(_ value: IPCJSONValue?, outcome: String?, reason: String?) -> Bool {
        guard let value else { return false }
        if case .null = value { return outcome != "rejected" || reason != "candidate-rejected" }
        guard let fields = value.objectFields, exactly(fields, ["category", "key", "line", "column", "detail"]),
              ["read-not-found", "read-denied", "read-invalid", "read", "decode", "unknown-key", "missing-key", "schema-version", "validation"].contains(value.value(for: "category")?.stringValue ?? ""),
              let detail = value.value(for: "detail")?.stringValue, validDiagnosticText(detail, allowsEmpty: false) else { return false }
        let key = value.value(for: "key")
        guard let key, isNull(key) || key.stringValue.map({ validDiagnosticText($0, allowsEmpty: false) }) == true else { return false }
        guard let line = value.value(for: "line"), let column = value.value(for: "column") else { return false }
        if isNull(line) || isNull(column) { return isNull(line) && isNull(column) && outcome == "rejected" && reason == "candidate-rejected" }
        guard let lineValue = line.integerValue, let columnValue = column.integerValue else { return false }
        return (1...1_000_000).contains(lineValue) && (1...1_000_000).contains(columnValue) && outcome == "rejected" && reason == "candidate-rejected"
    }

    private static func validDiagnosticText(_ value: String, allowsEmpty: Bool) -> Bool {
        if !allowsEmpty && value.isEmpty || value.utf8.count > 160 { return false }
        return !value.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }

    private static func validateInputStatus(_ value: IPCJSONValue?) -> Bool {
        guard let value, let fields = value.objectFields,
              exactly(fields, ["backend_state", "permission", "ready", "queue_depth", "queue_capacity", "request_in_progress", "detail"]),
              value.value(for: "backend_state")?.stringValue != nil,
              value.value(for: "permission")?.stringValue != nil,
              value.value(for: "ready")?.booleanValue != nil,
              value.value(for: "request_in_progress")?.booleanValue != nil,
              let depth = value.value(for: "queue_depth")?.integerValue,
              let capacity = value.value(for: "queue_capacity")?.integerValue,
              (0...16).contains(depth), (0...16).contains(capacity),
              let detail = value.value(for: "detail")?.stringValue else { return false }
        return detail.utf8.count <= 256
    }

    private static func positiveInteger(_ value: IPCJSONValue?) -> Bool {
        guard let integer = value?.integerValue else { return false }
        return integer > 0
    }

    private static func nonnegativeInteger(_ value: IPCJSONValue?) -> Bool {
        guard let integer = value?.integerValue else { return false }
        return integer >= 0
    }

    private static func isNull(_ value: IPCJSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func exactly(_ fields: [IPCJSONField], _ expected: [String]) -> Bool {
        fields.count == expected.count && expected.allSatisfy { expectedKey in
            fields.contains { $0.key.utf8.elementsEqual(expectedKey.utf8) }
        }
    }

    private static func exactlyKeys(_ keys: [String], _ required: [String], optional: [String]) -> Bool {
        keys.count >= required.count && keys.count <= required.count + optional.count &&
            required.allSatisfy { name in keys.contains { $0.utf8.elementsEqual(name.utf8) } } &&
            keys.allSatisfy { name in
                required.contains { $0.utf8.elementsEqual(name.utf8) } || optional.contains { $0.utf8.elementsEqual(name.utf8) }
            }
    }

    private static func isNonemptyString(_ value: IPCJSONValue?) -> Bool {
        guard let value = value?.stringValue else { return false }
        return !value.isEmpty
    }

    private static func validDigest(_ value: IPCJSONValue?) -> Bool {
        guard let value = value?.stringValue, value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func validProfileID(_ value: IPCJSONValue?) -> Bool {
        guard let value = value?.stringValue else { return false }
        return validProfileIDString(value)
    }

    private static func validProfileIDString(_ value: String) -> Bool {
        validStableIDString(value)
    }

    private static func validStableID(_ value: IPCJSONValue?) -> Bool {
        guard let value = value?.stringValue else { return false }
        return validStableIDString(value)
    }

    private static func validStableIDString(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), isASCIIAlphaNumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { isASCIIAlphaNumeric($0) || $0 == 0x2e || $0 == 0x5f || $0 == 0x2d }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte) || (0x30...0x39).contains(byte)
    }

    private static func validCoordinate(_ value: IPCJSONValue?) -> Bool {
        guard let value = value?.stringValue else { return false }
        return HidhoggConfiguration.supportedPositions.contains { $0.name.utf8.elementsEqual(value.utf8) }
    }

    private static func validProfileLabel(_ value: IPCJSONValue?, allowsEmpty: Bool) -> Bool {
        guard let value = value?.stringValue else { return false }
        return validProfileLabelString(value, allowsEmpty: allowsEmpty)
    }

    private static func validProfileLabelString(_ value: String, allowsEmpty: Bool) -> Bool {
        if value.isEmpty { return allowsEmpty }
        let scalars = Array(value.unicodeScalars)
        guard (1...64).contains(scalars.count), value.utf8.count <= 256 else { return false }
        var visible = false
        for scalar in scalars {
            let category = scalar.properties.generalCategory
            if category == .control || category == .format { return false }
            if category == .spaceSeparator || category == .lineSeparator || category == .paragraphSeparator ||
                category == .nonspacingMark || category == .enclosingMark || category == .unassigned || category == .privateUse || category == .surrogate {
                continue
            }
            if scalar.value == 0x09 || scalar.value == 0x0a || scalar.value == 0x0b || scalar.value == 0x0c || scalar.value == 0x0d { continue }
            visible = true
        }
        return visible
    }

    private static func validNotificationText(_ value: IPCJSONValue?) -> Bool {
        guard let value = value?.stringValue else { return false }
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 64, value.utf8.count <= 256 else { return false }
        var visible = false
        for scalar in scalars {
            let category = scalar.properties.generalCategory
            if category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator { return false }
            if category == .spaceSeparator || category == .nonspacingMark || category == .enclosingMark || category == .unassigned || category == .privateUse || category == .surrogate { continue }
            visible = true
        }
        return visible
    }

    private static func isHexColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 7 || bytes.count == 9, bytes[0] == 0x23 else { return false }
        return bytes.dropFirst().allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36, bytes[8] == 0x2d, bytes[13] == 0x2d, bytes[18] == 0x2d, bytes[23] == 0x2d else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index) || (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }

    private static func failure(_ code: String, _ message: String, requestID: String? = nil) -> IPCProtocolFailure {
        IPCProtocolFailure(code: code, message: message, requestID: requestID)
    }
}
