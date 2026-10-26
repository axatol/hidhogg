import Foundation
import Darwin
import HidhoggDomain

public enum AutomationIdentifier {
    public static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, isAlphanumeric(first) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

public enum AutomationEndpoint {
    public static func defaultSocketURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-\(getuid())", isDirectory: true)
            .appendingPathComponent("automation.sock")
    }
}

public enum AutomationMethod: String, Codable, Sendable {
    case notificationsEmit = "notifications.emit"
    case notificationsClear = "notifications.clear"
    case notificationsHistory = "notifications.history"
    case actionsInvoke = "actions.invoke"
    case actionsHistory = "actions.history"
    case status
}

public struct AutomationParameters: Codable, Sendable, Equatable {
    public var topic: String?
    public var text: String?
    public var ttlSeconds: Int?
    public var notificationID: UUID?
    public var actionID: String?

    public init(topic: String? = nil, text: String? = nil, ttlSeconds: Int? = nil, notificationID: UUID? = nil, actionID: String? = nil) {
        self.topic = topic
        self.text = text
        self.ttlSeconds = ttlSeconds
        self.notificationID = notificationID
        self.actionID = actionID
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case topic, text, ttlSeconds = "ttl_seconds", notificationID = "notification_id", actionID = "action_id"
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        topic = try values.optional(String.self, forKey: .topic)
        text = try values.optional(String.self, forKey: .text)
        ttlSeconds = try values.optional(Int.self, forKey: .ttlSeconds)
        notificationID = try values.optional(UUID.self, forKey: .notificationID)
        actionID = try values.optional(String.self, forKey: .actionID)
    }
}

public struct AutomationRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: String
    public let method: AutomationMethod
    public let params: AutomationParameters?

    public init(requestID: String = UUID().uuidString, method: AutomationMethod, params: AutomationParameters? = nil) {
        protocolVersion = 1
        self.requestID = requestID
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol_version", requestID = "request_id", method, params
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        requestID = try values.decode(String.self, forKey: .requestID)
        method = try values.decode(AutomationMethod.self, forKey: .method)
        params = try values.optional(AutomationParameters.self, forKey: .params)
        try validated()
    }

    public func validated() throws {
        guard protocolVersion == 1, AutomationIdentifier.isValid(requestID) else { throw AutomationProtocolError.invalidRequest }
        let fields = params ?? AutomationParameters()
        switch method {
        case .notificationsEmit:
            guard let topic = fields.topic, NotificationTopic.isValidTopic(topic), let text = fields.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 256, text.unicodeScalars.count <= 64,
                  text.unicodeScalars.allSatisfy(Self.permittedText),
                  fields.ttlSeconds.map({ (1...86400).contains($0) }) ?? true,
                  fields.notificationID == nil, fields.actionID == nil else { throw AutomationProtocolError.invalidRequest }
        case .notificationsClear:
            guard fields.notificationID != nil, fields.topic == nil, fields.text == nil,
                  fields.ttlSeconds == nil, fields.actionID == nil else { throw AutomationProtocolError.invalidRequest }
        case .actionsInvoke:
            guard let actionID = fields.actionID, AutomationIdentifier.isValid(actionID), fields.topic == nil,
                  fields.text == nil, fields.ttlSeconds == nil, fields.notificationID == nil else { throw AutomationProtocolError.invalidRequest }
        case .notificationsHistory, .actionsHistory, .status:
            guard fields == AutomationParameters() else { throw AutomationProtocolError.invalidRequest }
        }
    }

    private static func permittedText(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.newlines.contains(scalar)
            && scalar.value != 0x061C && scalar.value != 0x200E && scalar.value != 0x200F
            && !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
    }
}

public enum AutomationValue: Codable, Sendable, Equatable {
    case object([String: AutomationValue]), array([AutomationValue]), string(String), integer(Int), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([AutomationValue].self) { self = .array(result) }
        else { self = .object(try value.decode([String: AutomationValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .string(let result): try value.encode(result)
        case .integer(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .bool(let result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }

    public static func encoding<T: Encodable>(_ value: T) throws -> AutomationValue {
        try JSONDecoder().decode(AutomationValue.self, from: JSONEncoder().encode(value))
    }
}

public struct AutomationFailure: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    enum CodingKeys: String, CodingKey { case code, message }

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: ["code", "message"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(String.self, forKey: .code)
        message = try values.decode(String.self, forKey: .message)
    }
}

public struct AutomationResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: String
    public let result: AutomationValue?
    public let error: AutomationFailure?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case protocolVersion = "protocol_version", requestID = "request_id", result, error
    }

    private init(requestID: String, result: AutomationValue?, error: AutomationFailure?) {
        protocolVersion = 1
        self.requestID = requestID
        self.result = result
        self.error = error
    }

    public static func success(requestID: String, result: AutomationValue = .object([:])) -> Self {
        Self(requestID: requestID, result: result, error: nil)
    }

    public static func failure(requestID: String, code: String, message: String) -> Self {
        Self(requestID: requestID, result: nil, error: AutomationFailure(code: code, message: message))
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        requestID = try values.decode(String.self, forKey: .requestID)
        result = try values.optional(AutomationValue.self, forKey: .result)
        error = try values.optional(AutomationFailure.self, forKey: .error)
        guard protocolVersion == 1, AutomationIdentifier.isValid(requestID), (result == nil) != (error == nil) else {
            throw AutomationProtocolError.invalidRequest
        }
    }
}

public enum AutomationProtocolError: Error { case invalidRequest, frameTooLarge, invalidFrame, duplicateField, unknownField }

public enum AutomationFrame {
    public static let maximumBytes = 32 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        guard data.count <= maximumBytes else { throw AutomationProtocolError.frameTooLarge }
        return data
    }

    public static func decodeRequest(_ frame: Data) throws -> AutomationRequest {
        try decode(AutomationRequest.self, frame: frame)
    }

    public static func decodeResponse(_ frame: Data) throws -> AutomationResponse {
        try decode(AutomationResponse.self, frame: frame)
    }

    private static func decode<T: Decodable>(_ type: T.Type, frame: Data) throws -> T {
        guard frame.count <= maximumBytes else { throw AutomationProtocolError.frameTooLarge }
        guard frame.last == 10, !frame.dropLast().contains(10), !frame.contains(13) else { throw AutomationProtocolError.invalidFrame }
        var scanner = UniqueJSONFields(bytes: Array(frame.dropLast()))
        try scanner.validate()
        return try JSONDecoder().decode(type, from: frame.dropLast())
    }
}

private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: DynamicKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw AutomationProtocolError.unknownField }
}

private extension KeyedDecodingContainer {
    func optional<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}

private struct UniqueJSONFields {
    let bytes: [UInt8]
    var index = 0

    mutating func validate() throws {
        try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw AutomationProtocolError.invalidFrame }
    }

    private mutating func value(depth: Int) throws {
        guard depth < 16 else { throw AutomationProtocolError.invalidFrame }
        whitespace()
        guard index < bytes.count else { throw AutomationProtocolError.invalidFrame }
        switch bytes[index] {
        case 123:
            index += 1
            whitespace()
            if consume(125) { return }
            var keys = Set<String>()
            while true {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw AutomationProtocolError.duplicateField }
                whitespace()
                guard consume(58) else { throw AutomationProtocolError.invalidFrame }
                whitespace()
                let start = index
                try value(depth: depth + 1)
                if key == "ttl_seconds" || key == "protocol_version" {
                    guard index > start, bytes[start..<index].allSatisfy({ (48...57).contains($0) }) else {
                        throw AutomationProtocolError.invalidRequest
                    }
                }
                whitespace()
                if consume(125) { return }
                guard consume(44) else { throw AutomationProtocolError.invalidFrame }
            }
        case 91:
            index += 1
            whitespace()
            if consume(93) { return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                if consume(93) { return }
                guard consume(44) else { throw AutomationProtocolError.invalidFrame }
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count, ![UInt8(32), 9, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw AutomationProtocolError.invalidFrame }
        }
    }

    private mutating func string() throws -> String {
        let start = index
        guard consume(34) else { throw AutomationProtocolError.invalidFrame }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 {
                guard index < bytes.count else { throw AutomationProtocolError.invalidFrame }
                index += 1
            } else if byte == 34 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
        }
        throw AutomationProtocolError.invalidFrame
    }

    private mutating func whitespace() {
        while index < bytes.count, bytes[index] == 32 || bytes[index] == 9 { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
