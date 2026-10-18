import Foundation

public struct IPCJSONField: Sendable, Equatable {
    public let key: String
    public let value: IPCJSONValue

    public init(key: String, value: IPCJSONValue) {
        self.key = key
        self.value = value
    }
}

public struct IPCJSONNumber: Sendable, Equatable {
    public let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(integer: Int64) {
        rawValue = String(integer)
    }

    public var exactInt64: Int64? {
        guard !rawValue.contains("."), !rawValue.contains("e"), !rawValue.contains("E") else { return nil }
        return Int64(rawValue)
    }
}

public indirect enum IPCJSONValue: Sendable, Equatable {
    case object([IPCJSONField])
    case array([IPCJSONValue])
    case string(String)
    case number(IPCJSONNumber)
    case boolean(Bool)
    case null

    public static func object(_ fields: [(String, IPCJSONValue)]) -> IPCJSONValue {
        .object(fields.map { IPCJSONField(key: $0.0, value: $0.1) })
    }

    public func value(for key: String) -> IPCJSONValue? {
        guard case let .object(fields) = self else { return nil }
        return fields.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }

    public var objectFields: [IPCJSONField]? {
        guard case let .object(fields) = self else { return nil }
        return fields
    }

    public var arrayValues: [IPCJSONValue]? {
        guard case let .array(values) = self else { return nil }
        return values
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        guard case let .number(value) = self else { return nil }
        return value.exactInt64
    }

    public var booleanValue: Bool? {
        guard case let .boolean(value) = self else { return nil }
        return value
    }
}

public enum IPCJSONError: Error, Sendable, Equatable {
    case invalidUTF8
    case invalidSyntax
    case duplicateKey
    case nestingLimit
}

public enum IPCJSONCodec {
    public static func decode(_ data: Data) throws -> IPCJSONValue {
        var parser = IPCJSONParser(bytes: Array(data))
        return try parser.parse()
    }

    public static func encode(_ value: IPCJSONValue) -> Data {
        var bytes = [UInt8]()
        append(value, to: &bytes)
        return Data(bytes)
    }

    private static func append(_ value: IPCJSONValue, to bytes: inout [UInt8]) {
        switch value {
        case let .object(fields):
            bytes.append(0x7b)
            let sorted = fields.sorted { utf8Less($0.key, $1.key) }
            for index in sorted.indices {
                if index != sorted.startIndex { bytes.append(0x2c) }
                appendString(sorted[index].key, to: &bytes)
                bytes.append(0x3a)
                append(sorted[index].value, to: &bytes)
            }
            bytes.append(0x7d)
        case let .array(values):
            bytes.append(0x5b)
            for index in values.indices {
                if index != values.startIndex { bytes.append(0x2c) }
                append(values[index], to: &bytes)
            }
            bytes.append(0x5d)
        case let .string(value):
            appendString(value, to: &bytes)
        case let .number(value):
            bytes.append(contentsOf: value.rawValue.utf8)
        case let .boolean(value):
            bytes.append(contentsOf: value ? [0x74, 0x72, 0x75, 0x65] : [0x66, 0x61, 0x6c, 0x73, 0x65])
        case .null:
            bytes.append(contentsOf: [0x6e, 0x75, 0x6c, 0x6c])
        }
    }

    private static func appendString(_ value: String, to bytes: inout [UInt8]) {
        bytes.append(0x22)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: bytes.append(contentsOf: [0x5c, 0x22])
            case 0x5c: bytes.append(contentsOf: [0x5c, 0x5c])
            case 0x08: bytes.append(contentsOf: [0x5c, 0x62])
            case 0x0c: bytes.append(contentsOf: [0x5c, 0x66])
            case 0x0a: bytes.append(contentsOf: [0x5c, 0x6e])
            case 0x0d: bytes.append(contentsOf: [0x5c, 0x72])
            case 0x09: bytes.append(contentsOf: [0x5c, 0x74])
            case 0..<0x20:
                let digits = Array(String(format: "%04x", scalar.value).utf8)
                bytes.append(contentsOf: [0x5c, 0x75, 0x30, 0x30])
                bytes.append(contentsOf: digits)
            default:
                bytes.append(contentsOf: String(scalar).utf8)
            }
        }
        bytes.append(0x22)
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private struct IPCJSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private static let maximumDepth = 512

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parse() throws -> IPCJSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw IPCJSONError.invalidSyntax }
        return value
    }

    private mutating func parseValue() throws -> IPCJSONValue {
        guard index < bytes.count else { throw IPCJSONError.invalidSyntax }
        switch bytes[index] {
        case 0x7b: return try parseNestedObject()
        case 0x5b: return try parseNestedArray()
        case 0x22: return .string(try parseString())
        case 0x2d, 0x30...0x39: return .number(try parseNumber())
        case 0x74:
            try consumeKeyword([0x74, 0x72, 0x75, 0x65])
            return .boolean(true)
        case 0x66:
            try consumeKeyword([0x66, 0x61, 0x6c, 0x73, 0x65])
            return .boolean(false)
        case 0x6e:
            try consumeKeyword([0x6e, 0x75, 0x6c, 0x6c])
            return .null
        default: throw IPCJSONError.invalidSyntax
        }
    }

    private mutating func parseNestedObject() throws -> IPCJSONValue {
        guard depth < Self.maximumDepth else { throw IPCJSONError.nestingLimit }
        depth += 1
        defer { depth -= 1 }
        return try parseObject()
    }

    private mutating func parseNestedArray() throws -> IPCJSONValue {
        guard depth < Self.maximumDepth else { throw IPCJSONError.nestingLimit }
        depth += 1
        defer { depth -= 1 }
        return try parseArray()
    }

    private mutating func parseObject() throws -> IPCJSONValue {
        try consume(0x7b)
        skipWhitespace()
        var fields = [IPCJSONField]()
        var keys = Set<Data>()
        if consumeIfPresent(0x7d) { return .object(fields) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw IPCJSONError.invalidSyntax }
            let key = try parseString()
            guard keys.insert(Data(key.utf8)).inserted else { throw IPCJSONError.duplicateKey }
            skipWhitespace()
            try consume(0x3a)
            skipWhitespace()
            fields.append(IPCJSONField(key: key, value: try parseValue()))
            skipWhitespace()
            if consumeIfPresent(0x7d) { return .object(fields) }
            try consume(0x2c)
        }
    }

    private mutating func parseArray() throws -> IPCJSONValue {
        try consume(0x5b)
        skipWhitespace()
        var values = [IPCJSONValue]()
        if consumeIfPresent(0x5d) { return .array(values) }
        while true {
            skipWhitespace()
            values.append(try parseValue())
            skipWhitespace()
            if consumeIfPresent(0x5d) { return .array(values) }
            try consume(0x2c)
        }
    }

    private mutating func parseString() throws -> String {
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
                guard index < bytes.count else { throw IPCJSONError.invalidSyntax }
                switch bytes[index] {
                case 0x22, 0x5c, 0x2f:
                    output.unicodeScalars.append(UnicodeScalar(bytes[index]))
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
                    guard let value = UnicodeScalar(scalar) else { throw IPCJSONError.invalidSyntax }
                    output.unicodeScalars.append(value)
                default: throw IPCJSONError.invalidSyntax
                }
                continue
            }
            guard byte >= 0x20 else { throw IPCJSONError.invalidSyntax }
            let start = index
            while index < bytes.count,
                  bytes[index] != 0x22,
                  bytes[index] != 0x5c,
                  bytes[index] >= 0x20 {
                index += 1
            }
            guard let raw = String(data: Data(bytes[start..<index]), encoding: .utf8) else {
                throw IPCJSONError.invalidUTF8
            }
            output.append(raw)
        }
        throw IPCJSONError.invalidSyntax
    }

    private mutating func parseUnicodeScalar() throws -> UInt32 {
        try consume(0x75)
        let high = try parseHexQuad()
        if (0xd800...0xdbff).contains(high) {
            guard index + 5 < bytes.count, bytes[index] == 0x5c, bytes[index + 1] == 0x75 else {
                throw IPCJSONError.invalidSyntax
            }
            index += 2
            let low = try parseHexQuad()
            guard (0xdc00...0xdfff).contains(low) else { throw IPCJSONError.invalidSyntax }
            return 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00)
        }
        guard !(0xdc00...0xdfff).contains(high) else { throw IPCJSONError.invalidSyntax }
        return high
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw IPCJSONError.invalidSyntax }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt32
            switch bytes[index] {
            case 0x30...0x39: digit = UInt32(bytes[index] - 0x30)
            case 0x41...0x46: digit = UInt32(bytes[index] - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(bytes[index] - 0x61 + 10)
            default: throw IPCJSONError.invalidSyntax
            }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> IPCJSONNumber {
        let start = index
        _ = consumeIfPresent(0x2d)
        if consumeIfPresent(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) { throw IPCJSONError.invalidSyntax }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else { throw IPCJSONError.invalidSyntax }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if consumeIfPresent(0x2e) {
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw IPCJSONError.invalidSyntax }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2b || bytes[index] == 0x2d { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw IPCJSONError.invalidSyntax }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        return IPCJSONNumber(rawValue: String(decoding: bytes[start..<index], as: UTF8.self))
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard index < bytes.count, bytes[index] == expected else { throw IPCJSONError.invalidSyntax }
        index += 1
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func consumeKeyword(_ keyword: [UInt8]) throws {
        guard index + keyword.count <= bytes.count, bytes[index..<(index + keyword.count)].elementsEqual(keyword) else {
            throw IPCJSONError.invalidSyntax
        }
        index += keyword.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
    }
}
