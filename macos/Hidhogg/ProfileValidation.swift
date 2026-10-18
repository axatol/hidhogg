import Foundation
import HidhoggCore

public enum UUIDValidation {
    public static func isCanonical(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
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

    private static func isValidExecutable(_ value: String) -> Bool {
        value.utf8.first == 0x2f && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x61 && byte <= 0x7a) ||
        (byte >= 0x30 && byte <= 0x39)
    }
}
