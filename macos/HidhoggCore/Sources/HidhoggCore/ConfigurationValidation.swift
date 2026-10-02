import Foundation

private struct ValidationIssue {
    let path: [String]
    let message: String
}

func validateRawFields(profiles: [ExactTomlKey: SourceProfile]) throws {
    var issues: [ValidationIssue] = []
    for profileKey in profiles.keys.sorted() {
        guard let profile = profiles[profileKey] else { continue }
        for coordinateKey in profile.positions.keys.sorted() {
            guard let position = profile.positions[coordinateKey] else { continue }
            let positionPath = ["profiles", profileKey.value, "positions", coordinateKey.value]
            if let alignment = position.labelAlignment, alignment.isEmpty {
                issues.append(ValidationIssue(path: positionPath + ["label_alignment"], message: "explicit alignment is empty"))
            }
            if position.labelSize == 0 {
                issues.append(ValidationIssue(path: positionPath + ["label_size"], message: "explicit size is zero"))
            }
            guard let action = position.action else { continue }
            let actionPath = positionPath + ["action"]
            if action.gesture == "" {
                issues.append(ValidationIssue(path: actionPath + ["gesture"], message: "explicit gesture is empty"))
            }
            let forbidden: [String]
            switch action.type {
            case "activate_profile":
                forbidden = presentFields(action, ["executable", "arguments", "timeout_seconds", "text", "key"])
            case "execute":
                forbidden = presentFields(action, ["profile_id", "text", "key"])
                if action.timeoutSeconds == 0 {
                    issues.append(ValidationIssue(path: actionPath + ["timeout_seconds"], message: "explicit timeout is zero"))
                }
            case "type_text":
                forbidden = presentFields(action, ["profile_id", "executable", "arguments", "timeout_seconds", "key"])
            case "key_press":
                forbidden = presentFields(action, ["profile_id", "executable", "arguments", "timeout_seconds", "text"])
            default:
                forbidden = []
            }
            for field in forbidden {
                issues.append(ValidationIssue(path: actionPath + [field], message: "field is forbidden for this action type"))
            }
        }
    }
    try throwFirst(issues, category: .validation)
}

private func presentFields(_ action: SourceAction, _ fields: [String]) -> [String] {
    fields.filter { field in
        switch field {
        case "profile_id": return action.profileID != nil
        case "executable": return action.executable != nil
        case "arguments": return action.arguments != nil
        case "timeout_seconds": return action.timeoutSeconds != nil
        case "text": return action.text != nil
        case "key": return action.key != nil
        default: return false
        }
    }
}

func validatePositionKeys(profiles: [ExactTomlKey: SourceProfile]) throws {
    let supported = Set(HidhoggConfiguration.supportedPositions.map { ExactTomlKey($0.name) })
    var issues: [ValidationIssue] = []
    for profileKey in profiles.keys.sorted() {
        guard let profile = profiles[profileKey] else { continue }
        for coordinateKey in profile.positions.keys.sorted() where !supported.contains(coordinateKey) {
            issues.append(ValidationIssue(path: ["profiles", profileKey.value, "positions", coordinateKey.value], message: "unsupported coordinate"))
        }
    }
    try throwFirst(issues, category: .validation)
}

func validateRoot(
    schemaVersion: Int,
    adapter: String,
    brightness: Int,
    idleTimeout: Int,
    defaultProfileID: String,
    profiles: [ExactTomlKey: SourceProfile]
) throws {
    var issues: [ValidationIssue] = []
    if schemaVersion != 4 { issues.append(ValidationIssue(path: ["schema_version"], message: "must equal 4")) }
    if adapter != "ulanzi.d200x" { issues.append(ValidationIssue(path: ["adapter"], message: "adapter is unsupported")) }
    if !(0...100).contains(brightness) { issues.append(ValidationIssue(path: ["brightness"], message: "brightness is out of range")) }
    if !validStableID(defaultProfileID) { issues.append(ValidationIssue(path: ["default_profile_id"], message: "default profile ID is invalid")) }
    if !(0...86_400).contains(idleTimeout) { issues.append(ValidationIssue(path: ["idle_timeout_seconds"], message: "idle timeout is out of range")) }
    if !(1...31).contains(profiles.count) { issues.append(ValidationIssue(path: ["profiles"], message: "profile count is out of range")) }
    if profiles[ExactTomlKey(defaultProfileID)] == nil { issues.append(ValidationIssue(path: ["default_profile_id"], message: "default profile does not resolve")) }
    try throwFirst(issues, category: .validation)
}

func validateProfiles(_ profiles: [ExactTomlKey: SourceProfile]) throws {
    var issues: [ValidationIssue] = []
    for profileKey in profiles.keys.sorted() {
        let profileID = profileKey.value
        guard let profile = profiles[profileKey] else { continue }
        let path = ["profiles", profileID]
        if !validStableID(profileID) {
            issues.append(ValidationIssue(path: path, message: "profile ID is invalid"))
        }
        if let label = profile.label, !validLabel(label) {
            issues.append(ValidationIssue(path: path + ["label"], message: "profile label is invalid"))
        }
    }
    try throwFirst(issues, category: .validation)
}

func validateAllPositions(_ profiles: [ExactTomlKey: SourceProfile]) throws {
    var issues: [ValidationIssue] = []
    let profileIDs = Set(profiles.keys)
    for profileKey in profiles.keys.sorted() {
        guard let profile = profiles[profileKey] else { continue }
        for coordinateKey in profile.positions.keys.sorted() {
            guard let position = profile.positions[coordinateKey] else { continue }
            let path = ["profiles", profileKey.value, "positions", coordinateKey.value]
            let label = position.label ?? ""
            if !label.isEmpty, !validLabel(label) {
                issues.append(ValidationIssue(path: path + ["label"], message: "position label is invalid"))
            }
            if !validBackground(position.background ?? "#000000") {
                issues.append(ValidationIssue(path: path + ["background"], message: "background is invalid"))
            }
            let alignment = position.labelAlignment ?? "bottom"
            if alignment != "bottom" && alignment != "center" {
                issues.append(ValidationIssue(path: path + ["label_alignment"], message: "alignment is invalid"))
            }
            let labelSize = position.labelSize ?? 10
            if !(8...32).contains(labelSize) {
                issues.append(ValidationIssue(path: path + ["label_size"], message: "label size is invalid"))
            }
            collectNotificationSourceIssues(position.notificationSources, path: path + ["notification_sources"], into: &issues)
            if let action = position.action {
                collectActionIssues(action, path: path + ["action"], profileIDs: profileIDs, into: &issues)
            }
        }
    }
    try throwFirst(issues, category: .validation)
}

private func collectNotificationSourceIssues(_ sources: [String]?, path: [String], into issues: inout [ValidationIssue]) {
    guard let sources else { return }
    if !(1...16).contains(sources.count) {
        issues.append(ValidationIssue(path: path, message: "notification source count is invalid"))
    }
    var seen = Set<String>()
    for (index, source) in sources.enumerated() {
        let itemPath = path + [String(index)]
        if !validStableID(source) {
            issues.append(ValidationIssue(path: itemPath, message: "notification source ID is invalid"))
        }
        if !seen.insert(source).inserted {
            issues.append(ValidationIssue(path: itemPath, message: "notification source is duplicated"))
        }
    }
}

private func collectActionIssues(_ action: SourceAction, path: [String], profileIDs: Set<ExactTomlKey>, into issues: inout [ValidationIssue]) {
    let supportedTypes = ["activate_profile", "execute", "type_text", "key_press"]
    guard let type = action.type, supportedTypes.contains(type) else {
        issues.append(ValidationIssue(path: path + ["type"], message: "action type is invalid"))
        return
    }
    let gesture = action.gesture ?? "release"
    if gesture != "press" && gesture != "release" {
        issues.append(ValidationIssue(path: path + ["gesture"], message: "gesture is invalid"))
    }
    switch type {
    case "activate_profile":
        let profileID = action.profileID ?? ""
        if !validStableID(profileID) {
            issues.append(ValidationIssue(path: path + ["profile_id"], message: "profile ID is invalid"))
        }
        if profileIDs.contains(ExactTomlKey(profileID)) == false {
            issues.append(ValidationIssue(path: path + ["profile_id"], message: "target profile does not resolve"))
        }
    case "execute":
        let executable = action.executable ?? ""
        if !validExecutable(executable) {
            issues.append(ValidationIssue(path: path + ["executable"], message: "executable path is invalid"))
        }
        let arguments = action.arguments ?? []
        if arguments.count > 32 {
            issues.append(ValidationIssue(path: path + ["arguments"], message: "argument count is invalid"))
        }
        var aggregateBytes = 0
        for (index, argument) in arguments.enumerated() {
            let argumentPath = path + ["arguments", String(index)]
            let byteCount = argument.utf8.count
            aggregateBytes += byteCount
            if argument.unicodeScalars.contains(where: { $0.value == 0 }) {
                issues.append(ValidationIssue(path: argumentPath, message: "argument contains NUL"))
            }
            if byteCount > 1_024 {
                issues.append(ValidationIssue(path: argumentPath, message: "argument is too long"))
            }
        }
        if aggregateBytes > 8_192 {
            issues.append(ValidationIssue(path: path + ["arguments"], message: "argument total is too long"))
        }
        let timeout = action.timeoutSeconds ?? 10
        if timeout != 0 && !(1...60).contains(timeout) {
            issues.append(ValidationIssue(path: path + ["timeout_seconds"], message: "timeout is out of range"))
        }
    case "type_text":
        let text = action.text ?? ""
        if text.isEmpty || text.utf16.count > 64 || text.unicodeScalars.contains(where: { $0.value == 0 }) {
            issues.append(ValidationIssue(path: path + ["text"], message: "text payload is invalid"))
        }
    case "key_press":
        if action.key != "enter" {
            issues.append(ValidationIssue(path: path + ["key"], message: "key is unsupported"))
        }
    default:
        break
    }
}

private func validExecutable(_ value: String) -> Bool {
    value.utf8.first == 0x2F && !value.unicodeScalars.contains(where: { $0.value == 0 })
}

func normalizePosition(
    _ source: SourcePosition,
    id: String,
    path: [String],
    profileIDs: Set<ExactTomlKey>
) throws -> ConfiguredPosition {
    let label = source.label ?? ""
    if !label.isEmpty, !validLabel(label) { throw invalid(path + ["label"]) }

    let background = source.background ?? "#000000"
    guard validBackground(background) else { throw invalid(path + ["background"]) }

    let alignment = source.labelAlignment ?? "bottom"
    guard alignment == "bottom" || alignment == "center" else { throw invalid(path + ["label_alignment"]) }

    let labelSize = source.labelSize ?? 10
    guard (8...32).contains(labelSize) else { throw invalid(path + ["label_size"]) }

    try validateNotificationSources(source.notificationSources, path: path + ["notification_sources"])
    let action = try source.action.map {
        try normalizeAction($0, path: path + ["action"], profileIDs: profileIDs)
    }

    return ConfiguredPosition(
        id: id,
        position: id,
        label: label,
        background: background,
        notificationSources: source.notificationSources,
        labelAlignment: alignment,
        labelSize: labelSize,
        action: action
    )
}

private func normalizeAction(
    _ source: SourceAction,
    path: [String],
    profileIDs: Set<ExactTomlKey>
) throws -> ConfiguredAction {
    let gestureValue = source.gesture ?? "release"
    guard let gesture = ButtonGesture(rawValue: gestureValue) else { throw invalid(path + ["gesture"]) }
    switch source.type ?? "" {
    case "activate_profile":
        let profileID = source.profileID ?? ""
        guard validStableID(profileID), profileIDs.contains(ExactTomlKey(profileID)) else { throw invalid(path + ["profile_id"]) }
        return .activateProfile(profileID: profileID, gesture: gesture)
    case "execute":
        let executable = source.executable ?? ""
        guard validExecutable(executable) else {
            throw invalid(path + ["executable"])
        }
        let arguments = source.arguments ?? []
        guard arguments.count <= 32 else { throw invalid(path + ["arguments"]) }
        let argumentBytes = arguments.map { $0.utf8.count }
        guard argumentBytes.allSatisfy({ $0 <= 1_024 }), argumentBytes.reduce(0, +) <= 8_192,
              !arguments.contains(where: { $0.unicodeScalars.contains(where: { $0.value == 0 }) }) else {
            throw invalid(path + ["arguments"])
        }
        let timeout = source.timeoutSeconds ?? 10
        guard (1...60).contains(timeout) else { throw invalid(path + ["timeout_seconds"]) }
        return .execute(executable: executable, arguments: arguments, timeoutSeconds: timeout, gesture: gesture)
    case "type_text":
        let text = source.text ?? ""
        guard !text.isEmpty, text.utf16.count <= 64,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw invalid(path + ["text"])
        }
        return .typeText(text: text, gesture: gesture)
    case "key_press":
        let key = source.key ?? ""
        guard key == "enter" else { throw invalid(path + ["key"]) }
        return .keyPress(key: key, gesture: gesture)
    default:
        throw invalid(path + ["type"])
    }
}

private func validateNotificationSources(_ sources: [String]?, path: [String]) throws {
    guard let sources else { return }
    guard (1...16).contains(sources.count) else { throw invalid(path) }
    var seen = Set<String>()
    for (index, source) in sources.enumerated() {
        guard validStableID(source), seen.insert(source).inserted else {
            throw invalid(path + [String(index)])
        }
    }
}

private func validStableID(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard (1...64).contains(scalars.count) else { return false }
    for (index, scalar) in scalars.enumerated() {
        let value = scalar.value
        let alphaNumeric = (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) || (0x30...0x39).contains(value)
        if index == 0 {
            guard alphaNumeric else { return false }
        } else if !alphaNumeric && value != 0x2E && value != 0x5F && value != 0x2D {
            return false
        }
    }
    return true
}

private func validLabel(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard !scalars.isEmpty, scalars.count <= 64, value.utf8.count <= 256 else { return false }
    var visible = false
    for scalar in scalars {
        let category = scalar.properties.generalCategory
        if category == .control || category == .format { return false }
        if scalar.properties.isWhitespace || category == .nonspacingMark || category == .enclosingMark ||
            category == .unassigned || category == .privateUse || category == .surrogate {
            continue
        }
        visible = true
    }
    return visible
}

private func validBackground(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard (value.utf8.count == 7 || value.utf8.count == 9), scalars.count == value.utf8.count, scalars.first == "#" else { return false }
    return scalars.dropFirst().allSatisfy { scalar in
        (0x30...0x39).contains(scalar.value) || (0x41...0x46).contains(scalar.value) || (0x61...0x66).contains(scalar.value)
    }
}

private func invalid(_ path: [String]) -> ConfigurationDiagnostic {
    ConfigurationDiagnostic.make(.validation, key: diagnosticPath(path))
}

private func throwFirst(_ issues: [ValidationIssue], category: ConfigurationDiagnosticCategory) throws {
    guard let first = issues.sorted(by: { left, right in
        let leftPath = diagnosticPath(left.path)
        let rightPath = diagnosticPath(right.path)
        return leftPath == rightPath ? left.message < right.message : leftPath < rightPath
    }).first else { return }
    throw ConfigurationDiagnostic.make(category, key: diagnosticPath(first.path))
}
