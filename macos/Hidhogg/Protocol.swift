import Foundation

public enum RuntimeMethod: String, Sendable {
    case health
    case status
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
    public static let allowedErrorCodes: Set<String> = [
        "invalid_json",
        "invalid_envelope",
        "unsupported_version",
        "unknown_method",
        "instance_mismatch",
        "message_too_large",
        "internal"
    ]

    public static func request(
        method: RuntimeMethod,
        requestID: String,
        instanceID: String
    ) -> Data {
        let payload = "{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"method\":\"\(method.rawValue)\",\"params\":{\"instance_id\":\"\(instanceID)\"}}\n"
        return Data(payload.utf8)
    }
}

public enum ResponseValidator {
    public static func validate(
        frame: Data,
        expectedRequestID: String?,
        method: RuntimeMethod,
        expectedInstanceID: String
    ) throws -> RuntimeResponse {
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
            let root = try parser.parse()
            return try validateResponse(
                root,
                expectedRequestID: expectedRequestID,
                method: method,
                expectedInstanceID: expectedInstanceID
            )
        } catch let error as ResponseValidationError {
            throw error
        } catch {
            throw ResponseValidationError.invalidJSON
        }
    }

    private static func validateResponse(
        _ root: JSONValue,
        expectedRequestID: String?,
        method: RuntimeMethod,
        expectedInstanceID: String
    ) throws -> RuntimeResponse {
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
              ProtocolV1.allowedErrorCodes.contains(code),
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
