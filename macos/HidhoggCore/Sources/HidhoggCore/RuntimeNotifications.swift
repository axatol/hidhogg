import Foundation

public struct RuntimeNotificationRequest: Sendable, Equatable {
    public let source: String
    public let text: String
    public let ttlSeconds: Int?

    public init(source: String, text: String, ttlSeconds: Int? = nil) {
        self.source = source
        self.text = text
        self.ttlSeconds = ttlSeconds
    }
}

public struct RuntimeNotificationEmitResult: Sendable, Equatable {
    public let notificationID: String
    public let matchedCount: Int
}

public struct RuntimeNotificationClearResult: Sendable, Equatable {
    public let clearedCount: Int
}

public enum RuntimeNotificationError: Error, Sendable, Equatable {
    case invalidRequest
    case busy
    case closed
    case uncertain
}

struct RuntimeNotificationOverlay: Sendable, Equatable {
    let notificationID: String
    let source: String
    let text: String
    let profileID: String
    let positionID: String
    let coordinate: String
    var deadline: RuntimeMonotonicInstant?
}

struct RuntimeNotificationSelection: Sendable, Equatable {
    let overlay: RuntimeNotificationOverlay
    let wireIndex: UInt8
    let action: ConfiguredAction?
}

enum RuntimeNotificationValidation {
    static func isValid(_ request: RuntimeNotificationRequest) -> Bool {
        validSource(request.source) && validText(request.text) &&
            request.ttlSeconds.map { (1...86_400).contains($0) } != false
    }

    static func isValidID(_ identifier: String) -> Bool {
        let bytes = Array(identifier.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == 45 else { return false }
            } else if !isLowercaseHex(byte) {
                return false
            }
        }
        return true
    }

    private static func validSource(_ source: String) -> Bool {
        let bytes = Array(source.utf8)
        guard let first = bytes.first, bytes.count <= 64, isASCIIAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    private static func validText(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 64, text.utf8.count <= 256 else { return false }
        var visible = false
        for scalar in scalars {
            let properties = scalar.properties
            switch properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return false
            default:
                break
            }
            if properties.isWhitespace { continue }
            switch properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .unassigned, .privateUse, .surrogate:
                continue
            default:
                visible = true
            }
        }
        return visible
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}
