import Foundation

public enum ConfigurationFieldEdit<Value: Sendable>: Sendable {
    case keep
    case set(Value)
    case reset
}

public struct ConfigurationPositionPatch: Sendable {
    public let label: ConfigurationFieldEdit<String>
    public let background: ConfigurationFieldEdit<String>
    public let labelAlignment: ConfigurationFieldEdit<String>
    public let labelSize: ConfigurationFieldEdit<Int>
    public let notificationSources: ConfigurationFieldEdit<[String]>
    public let action: ConfigurationFieldEdit<ConfiguredAction>

    public init(
        label: ConfigurationFieldEdit<String> = .keep,
        background: ConfigurationFieldEdit<String> = .keep,
        labelAlignment: ConfigurationFieldEdit<String> = .keep,
        labelSize: ConfigurationFieldEdit<Int> = .keep,
        notificationSources: ConfigurationFieldEdit<[String]> = .keep,
        action: ConfigurationFieldEdit<ConfiguredAction> = .keep
    ) {
        self.label = label
        self.background = background
        self.labelAlignment = labelAlignment
        self.labelSize = labelSize
        self.notificationSources = notificationSources
        self.action = action
    }
}

public enum ConfigurationEditingError: Error, Sendable, Equatable, CustomStringConvertible {
    case profileNotFound
    case duplicateProfile
    case profileLimitReached
    case profileInUse
    case positionNotSupported
    case sourceEditFailed

    public var description: String {
        switch self {
        case .profileNotFound: return "configuration profile was not found"
        case .duplicateProfile: return "configuration profile already exists"
        case .profileLimitReached: return "configuration has reached its profile limit"
        case .profileInUse: return "configuration profile cannot be deleted while in use"
        case .positionNotSupported: return "configuration position is not supported"
        case .sourceEditFailed: return "configuration source edit failed"
        }
    }
}

public enum ConfigurationEditor {
    public static func setProfileLabel(in source: Data, profileID: String, label: String) throws -> Data {
        let configuration = try HidhoggConfigurationDecoder.decode(source)
        guard let profile = configuration.profile(id: profileID) else {
            throw ConfigurationEditingError.profileNotFound
        }
        if profile.label.utf8.elementsEqual(label.utf8) { return Data(source) }

        var mutation = try sourceMutation(source)
        try applySourceEdit {
            try mutation.set(["profiles", profileID, "label"], value: encodedString(label))
        }
        return try validate(mutation.data)
    }

    public static func cloneProfile(
        in source: Data,
        sourceID: String,
        newID: String,
        label: String
    ) throws -> Data {
        let configuration = try HidhoggConfigurationDecoder.decode(source)
        guard configuration.profile(id: sourceID) != nil else {
            throw ConfigurationEditingError.profileNotFound
        }
        guard configuration.profile(id: newID) == nil else {
            throw ConfigurationEditingError.duplicateProfile
        }
        guard configuration.profiles.count < 31 else {
            throw ConfigurationEditingError.profileLimitReached
        }
        guard let profile = configuration.profile(id: sourceID) else {
            throw ConfigurationEditingError.profileNotFound
        }

        var mutation = try sourceMutation(source)
        if try mutation.hasInlineTable(at: ["profiles"]) {
            try applySourceEdit {
                try mutation.set(["profiles", newID], value: encodedProfileClone(profile, label: label))
            }
        } else {
            mutation.appendBlock(encodedExpandedProfile(
                profile, profileID: newID, label: label, lineEnding: configurationLineEnding(source)
            ))
        }
        return try validate(mutation.data)
    }

    public static func deleteProfile(
        in source: Data,
        profileID: String,
        currentProfileID: String
    ) throws -> Data {
        let configuration = try HidhoggConfigurationDecoder.decode(source)
        guard configuration.profile(id: profileID) != nil,
              configuration.profile(id: currentProfileID) != nil else {
            throw ConfigurationEditingError.profileNotFound
        }
        guard configuration.profiles.count > 1,
              configuration.defaultProfileID != profileID,
              currentProfileID != profileID,
              !profileIsReferenced(configuration, profileID: profileID) else {
            throw ConfigurationEditingError.profileInUse
        }

        var mutation = try sourceMutation(source)
        try applySourceEdit {
            try mutation.deleteSubtree(["profiles", profileID])
        }
        return try validate(mutation.data)
    }

    public static func patchPosition(
        in source: Data,
        profileID: String,
        coordinate: String,
        patch: ConfigurationPositionPatch
    ) throws -> Data {
        let configuration = try HidhoggConfigurationDecoder.decode(source)
        guard HidhoggConfiguration.supportedPositions.contains(where: { byteEqual($0.name, coordinate) }) else {
            throw ConfigurationEditingError.positionNotSupported
        }
        guard let profile = configuration.profile(id: profileID),
              let position = profile.position(named: coordinate) else {
            throw ConfigurationEditingError.profileNotFound
        }

        var mutation = try sourceMutation(source)
        let positionPath = ["profiles", profileID, "positions", coordinate]
        var changed = false

        try editStringField(patch.label, current: position.label, path: positionPath + ["label"],
                            semanticNoOp: true, mutation: &mutation, changed: &changed)
        try editStringField(patch.background, current: position.background, path: positionPath + ["background"],
                            mutation: &mutation, changed: &changed)
        try editStringField(patch.labelAlignment, current: position.labelAlignment, path: positionPath + ["label_alignment"],
                            mutation: &mutation, changed: &changed)
        try editIntegerField(patch.labelSize, current: position.labelSize, path: positionPath + ["label_size"],
                             mutation: &mutation, changed: &changed)
        try editSources(patch.notificationSources, current: position.notificationSources,
                        path: positionPath + ["notification_sources"], mutation: &mutation, changed: &changed)
        try editAction(patch.action, current: position.action, path: positionPath + ["action"],
                       mutation: &mutation, changed: &changed)

        guard changed else { return Data(source) }
        return try validate(mutation.data)
    }
}

private func sourceMutation(_ source: Data) throws -> TomlSourceMutation {
    do { return try TomlSourceMutation(source) }
    catch { throw ConfigurationEditingError.sourceEditFailed }
}

private func applySourceEdit(_ edit: () throws -> Void) throws {
    do { try edit() }
    catch { throw ConfigurationEditingError.sourceEditFailed }
}

private func validate(_ source: Data) throws -> Data {
    _ = try HidhoggConfigurationDecoder.decode(source)
    return Data(source)
}

private func byteEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func profileIsReferenced(_ configuration: HidhoggConfiguration, profileID: String) -> Bool {
    for profile in configuration.profiles {
        for position in profile.positions {
            guard case .activateProfile(let target, _)? = position.action else { continue }
            if byteEqual(target, profileID) { return true }
        }
    }
    return false
}

private func editStringField(
    _ edit: ConfigurationFieldEdit<String>,
    current: String,
    path: [String],
    semanticNoOp: Bool = false,
    mutation: inout TomlSourceMutation,
    changed: inout Bool
) throws {
    switch edit {
    case .keep:
        return
    case .set(let value):
        if byteEqual(current, value) {
            if semanticNoOp { return }
            if try mutation.containsValue(at: path) { return }
        }
        try applySourceEdit { try mutation.set(path, value: encodedString(value)) }
        changed = true
    case .reset:
        guard try mutation.containsValue(at: path) else { return }
        try applySourceEdit { try mutation.delete(path) }
        changed = true
    }
}

private func editIntegerField(
    _ edit: ConfigurationFieldEdit<Int>,
    current: Int,
    path: [String],
    mutation: inout TomlSourceMutation,
    changed: inout Bool
) throws {
    switch edit {
    case .keep:
        return
    case .set(let value):
        if current == value, try mutation.containsValue(at: path) { return }
        try applySourceEdit { try mutation.set(path, value: String(value)) }
        changed = true
    case .reset:
        guard try mutation.containsValue(at: path) else { return }
        try applySourceEdit { try mutation.delete(path) }
        changed = true
    }
}

private func editSources(
    _ edit: ConfigurationFieldEdit<[String]>,
    current: [String]?,
    path: [String],
    mutation: inout TomlSourceMutation,
    changed: inout Bool
) throws {
    switch edit {
    case .keep:
        return
    case .set(let values):
        if let current, current.count == values.count,
           zip(current, values).allSatisfy({ byteEqual($0.0, $0.1) }),
           try mutation.containsValue(at: path) { return }
        let encoded = "[" + values.map(encodedString).joined(separator: ", ") + "]"
        try applySourceEdit { try mutation.set(path, value: encoded) }
        changed = true
    case .reset:
        guard try mutation.containsValue(at: path) else { return }
        try applySourceEdit { try mutation.delete(path) }
        changed = true
    }
}

private func editAction(
    _ edit: ConfigurationFieldEdit<ConfiguredAction>,
    current: ConfiguredAction?,
    path: [String],
    mutation: inout TomlSourceMutation,
    changed: inout Bool
) throws {
    switch edit {
    case .keep:
        return
    case .reset:
        guard try mutation.containsValue(at: path) else { return }
        try applySourceEdit { try mutation.deleteSubtree(path) }
        changed = true
    case .set(let action):
        if current == action { return }
        guard let current else {
            try applySourceEdit { try mutation.set(path, value: encodedAction(action)) }
            changed = true
            return
        }
        try updateExistingAction(current, to: action, path: path, mutation: &mutation)
        changed = true
    }
}

private func updateExistingAction(
    _ current: ConfiguredAction,
    to desired: ConfiguredAction,
    path: [String],
    mutation: inout TomlSourceMutation
) throws {
    let oldFields = Set(actionPayload(current).keys)
    let newPayload = actionPayload(desired)
    let newFields = Set(newPayload.keys)
    for field in oldFields.subtracting(newFields).sorted(by: exactKeyLessThan) {
        let fieldPath = path + [field]
        guard try mutation.containsValue(at: fieldPath) else { continue }
        try applySourceEdit { try mutation.delete(fieldPath) }
    }

    let (oldType, oldGesture) = actionHeader(current)
    let (newType, newGesture) = actionHeader(desired)
    if !byteEqual(oldType, newType) {
        try applySourceEdit { try mutation.set(path + ["type"], value: encodedString(newType)) }
    }
    if oldGesture != newGesture {
        try applySourceEdit { try mutation.set(path + ["gesture"], value: encodedString(newGesture.rawValue)) }
    }

    let oldPayload = actionPayload(current)
    for field in actionPayloadFieldOrder(desired) {
        guard let value = newPayload[field], oldPayload[field]?.typed != value.typed else { continue }
        let absentDefault = oldPayload[field] == nil && value.isDefault
        if absentDefault { continue }
        try applySourceEdit { try mutation.set(path + [field], value: value.source) }
    }
}

private struct EncodedActionField {
    let typed: Toml.TypedValue
    let source: String
    let isDefault: Bool
}

private func actionHeader(_ action: ConfiguredAction) -> (String, ButtonGesture) {
    switch action {
    case .activateProfile(_, let gesture): return ("activate_profile", gesture)
    case .execute(_, _, _, let gesture): return ("execute", gesture)
    case .typeText(_, let gesture): return ("type_text", gesture)
    case .keyPress(_, let gesture): return ("key_press", gesture)
    }
}

private func actionPayload(_ action: ConfiguredAction) -> [String: EncodedActionField] {
    switch action {
    case .activateProfile(let profileID, _):
        return ["profile_id": stringField(profileID)]
    case .execute(let executable, let arguments, let timeoutSeconds, _):
        return [
            "executable": stringField(executable),
            "arguments": EncodedActionField(
                typed: .array(arguments.map(Toml.TypedValue.string)),
                source: "[" + arguments.map(encodedString).joined(separator: ", ") + "]",
                isDefault: arguments.isEmpty
            ),
            "timeout_seconds": EncodedActionField(
                typed: .integer(Int64(timeoutSeconds)), source: String(timeoutSeconds), isDefault: timeoutSeconds == 10
            ),
        ]
    case .typeText(let text, _): return ["text": stringField(text)]
    case .keyPress(let key, _): return ["key": stringField(key)]
    }
}

private func stringField(_ value: String) -> EncodedActionField {
    EncodedActionField(typed: .string(value), source: encodedString(value), isDefault: false)
}

private func encodedAction(_ action: ConfiguredAction) -> String {
    let (type, gesture) = actionHeader(action)
    var fields = ["type = " + encodedString(type)]
    if gesture != .release { fields.append("gesture = " + encodedString(gesture.rawValue)) }
    let payload = actionPayload(action)
    for key in actionPayloadFieldOrder(action) {
        guard let field = payload[key], !field.isDefault else { continue }
        fields.append(encodedKey(key) + " = " + field.source)
    }
    return "{ " + fields.joined(separator: ", ") + " }"
}

private func actionPayloadFieldOrder(_ action: ConfiguredAction) -> [String] {
    switch action {
    case .activateProfile: return ["profile_id"]
    case .execute: return ["executable", "arguments", "timeout_seconds"]
    case .typeText: return ["text"]
    case .keyPress: return ["key"]
    }
}

private func exactKeyLessThan(_ lhs: String, _ rhs: String) -> Bool {
    ExactTomlKey(lhs) < ExactTomlKey(rhs)
}

private func encodedProfileClone(_ profile: ConfiguredProfile, label: String) -> String {
    var fields = ["label = " + encodedString(label)]
    var positions: [String] = []
    for position in profile.positions {
        var positionFields: [String] = []
        if !position.label.isEmpty { positionFields.append("label = " + encodedString(position.label)) }
        if !byteEqual(position.background, "#000000") {
            positionFields.append("background = " + encodedString(position.background))
        }
        if let sources = position.notificationSources {
            positionFields.append("notification_sources = [" + sources.map(encodedString).joined(separator: ", ") + "]")
        }
        if !byteEqual(position.labelAlignment, "bottom") {
            positionFields.append("label_alignment = " + encodedString(position.labelAlignment))
        }
        if position.labelSize != 10 { positionFields.append("label_size = \(position.labelSize)") }
        if let action = position.action { positionFields.append("action = " + encodedAction(action)) }
        guard !positionFields.isEmpty else { continue }
        positions.append(encodedKey(position.position) + " = { " + positionFields.joined(separator: ", ") + " }")
    }
    if !positions.isEmpty {
        fields.append("positions = { " + positions.joined(separator: ", ") + " }")
    }
    return "{ " + fields.joined(separator: ", ") + " }"
}

private func encodedExpandedProfile(
    _ profile: ConfiguredProfile,
    profileID: String,
    label: String,
    lineEnding: String
) -> String {
    var lines = ["[profiles.\(encodedKey(profileID))]", "label = \(encodedString(label))"]
    for position in profile.positions {
        var fields: [String] = []
        if !position.label.isEmpty { fields.append("label = \(encodedString(position.label))") }
        if !byteEqual(position.background, "#000000") {
            fields.append("background = \(encodedString(position.background))")
        }
        if let sources = position.notificationSources {
            fields.append("notification_sources = [" + sources.map(encodedString).joined(separator: ", ") + "]")
        }
        if !byteEqual(position.labelAlignment, "bottom") {
            fields.append("label_alignment = \(encodedString(position.labelAlignment))")
        }
        if position.labelSize != 10 { fields.append("label_size = \(position.labelSize)") }
        if let action = position.action { fields.append("action = \(encodedAction(action))") }
        guard !fields.isEmpty else { continue }
        lines.append("")
        lines.append("[profiles.\(encodedKey(profileID)).positions.\(encodedKey(position.position))]")
        lines.append(contentsOf: fields)
    }
    return lines.joined(separator: lineEnding) + lineEnding
}

private func configurationLineEnding(_ source: Data) -> String {
    let bytes = Array(source)
    for index in bytes.indices where bytes[index] == 0x0A {
        return index > 0 && bytes[index - 1] == 0x0D ? "\r\n" : "\n"
    }
    return "\n"
}
