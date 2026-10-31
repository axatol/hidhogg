import Foundation

enum FlowLite84Setting: UInt16, CaseIterable, Sendable {
    case lightingMode = 8496
    case lightingEnabled = 8498
    case idleOff = 8500
    case systemMode = 9416
}

enum FlowLite84Request: Equatable, Sendable {
    case identify([UInt8])
    case online
    case battery
    case keyboardVersion
    case receiverVersion
    case setting(FlowLite84Setting)
    case effect(mode: UInt8)
    case lightingWrite(address: UInt16, bytes: [UInt8])
    case systemModeWrite(FlowLite84SystemMode)
    case restoreSystemMode([UInt8])

    var command: UInt8 {
        switch self {
        case .identify: 1
        case .online: 3
        case .battery: 4
        case .setting, .effect: 8
        case .lightingWrite, .systemModeWrite, .restoreSystemMode: 7
        case .keyboardVersion: 18
        case .receiverVersion: 29
        }
    }

    var address: UInt16 {
        switch self {
        case .setting(let setting): setting.rawValue
        case .effect(let mode): 8544 + UInt16(mode) * 32
        case .lightingWrite(let address, _): address
        case .systemModeWrite, .restoreSystemMode: FlowLite84Setting.systemMode.rawValue
        default: 0
        }
    }

    var count: UInt8 {
        switch self {
        case .identify: 8
        case .setting: 2
        case .effect: 4
        case .lightingWrite(_, let bytes): UInt8(clamping: bytes.count)
        case .systemModeWrite, .restoreSystemMode: 2
        default: 0
        }
    }

    var writeOutcomeUnknown: FlowLite84Failure? {
        switch self {
        case .lightingWrite: .lightingOutcomeUnknown
        case .systemModeWrite, .restoreSystemMode: .systemModeOutcomeUnknown
        default: nil
        }
    }
}

struct FlowLite84Reply: Equatable, Sendable {
    let command: UInt8
    let status: UInt8
    let address: UInt16
    let count: UInt8
    let fields: [UInt8]

    func matches(_ request: FlowLite84Request) -> Bool {
        command == request.command && (![7, 8].contains(command) || (address == request.address && count & 0x7f == request.count))
    }

    func validate(for request: FlowLite84Request) throws {
        guard command == request.command else {
            throw FlowLite84Failure.invalidResponse(.replyCommand(expected: request.command, received: command))
        }
        if command == 8 || command == 7 {
            guard address == request.address, count & 0x7f == request.count else {
                throw FlowLite84Failure.invalidResponse(command == 7 ? .writeHeader : .readHeader)
            }
        }
        guard status == 0 else { throw FlowLite84Failure.rejected(command: command, status: status) }
    }
}

enum FlowLite84Codec {
    static let reportID: UInt8 = 8
    static let payloadSize = 16
    static let reportSize = 17
    static let configurationCollection: [UInt8] = [
        0x06, 0x02, 0xff, 0x09, 0x02, 0xa1, 0x01, 0x85, 0x08,
        0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x10,
        0x09, 0x02, 0x81, 0x00, 0x09, 0x02, 0x91, 0x00, 0xc0,
    ]

    private static func isAllowedRead(address: UInt16, count: UInt8) -> Bool {
        (count == 2 && FlowLite84Setting(rawValue: address) != nil) ||
            (count == 4 && address >= 8544 && address <= 9024 && (address - 8544) % 32 == 0)
    }

    static func isAllowedLightingWrite(address: UInt16, count: UInt8) -> Bool {
        (count == 2 && [UInt16(8496), 8498, 8500].contains(address)) ||
            (count == 4 && address >= 8672 && address <= 8864 && (address - 8544) % 32 == 0)
    }

    private static func isAllowedWrite(address: UInt16, count: UInt8) -> Bool {
        isAllowedLightingWrite(address: address, count: count) ||
            (address == FlowLite84Setting.systemMode.rawValue && count == 2)
    }

    static func hasConfigurationCollection(_ descriptor: Data) -> Bool {
        descriptor.range(of: Data(configurationCollection)) != nil
    }

    static func encode(_ request: FlowLite84Request) throws -> Data {
        var payload = [UInt8](repeating: 0, count: payloadSize)
        payload[0] = request.command
        payload[2] = UInt8(request.address >> 8)
        payload[3] = UInt8(request.address & 0xff)
        payload[4] = request.count | 0x80
        switch request {
        case .identify(let challenge):
            guard challenge.count == 4 else { throw FlowLite84Failure.invalidRequest }
            payload.replaceSubrange(5..<9, with: challenge)
        case .effect(let mode):
            guard mode <= 15 else { throw FlowLite84Failure.invalidRequest }
        case .lightingWrite(_, let bytes):
            guard isAllowedLightingWrite(address: request.address, count: request.count),
                  bytes.count == Int(request.count), bytes.reduce(UInt8(0), &+) == 0x55 else {
                throw FlowLite84Failure.invalidRequest
            }
            payload.replaceSubrange(5..<(5 + bytes.count), with: bytes)
        case .systemModeWrite(let mode):
            payload[5] = mode.rawValue
            payload[6] = 0x55 &- mode.rawValue
        case .restoreSystemMode(let bytes):
            guard bytes.count == 2, bytes.reduce(UInt8(0), &+) == 0x55 else {
                throw FlowLite84Failure.invalidRequest
            }
            payload.replaceSubrange(5..<7, with: bytes)
        default: break
        }
        payload[15] = checksum(payload)
        let report = Data([reportID] + payload)
        try validateOutput(report)
        return report
    }

    static func validateOutput(_ report: Data) throws {
        guard report.count == reportSize, report.first == reportID else { throw FlowLite84Failure.invalidRequest }
        let payload = Array(report.dropFirst())
        guard validChecksum(payload), payload[1] == 0, payload[4] & 0x80 != 0 else {
            throw FlowLite84Failure.invalidRequest
        }
        let address = UInt16(payload[2]) << 8 | UInt16(payload[3])
        let count = payload[4] & 0x7f
        switch payload[0] {
        case 1:
            guard address == 0, count == 8, payload[9..<15].allSatisfy({ $0 == 0 }) else {
                throw FlowLite84Failure.invalidRequest
            }
        case 3, 4, 18, 29:
            guard address == 0, count == 0, payload[5..<15].allSatisfy({ $0 == 0 }) else {
                throw FlowLite84Failure.invalidRequest
            }
        case 8:
            guard isAllowedRead(address: address, count: count), payload[5..<15].allSatisfy({ $0 == 0 }) else {
                throw FlowLite84Failure.invalidRequest
            }
        case 7:
            guard isAllowedWrite(address: address, count: count),
                  payload[5..<(5 + Int(count))].reduce(UInt8(0), &+) == 0x55,
                  payload[(5 + Int(count))..<15].allSatisfy({ $0 == 0 }) else {
                throw FlowLite84Failure.invalidRequest
            }
        default: throw FlowLite84Failure.invalidRequest
        }
    }

    static func checksum(_ payload: [UInt8]) -> UInt8 {
        0x55 &- payload.prefix(15).reduce(reportID, &+)
    }

    static func validChecksum(_ payload: [UInt8]) -> Bool {
        payload.count == payloadSize && payload.reduce(reportID, &+) == 0x55
    }

    static func normalize(_ data: Data) throws -> [UInt8] {
        if data.count == payloadSize { return Array(data) }
        guard data.count == reportSize, data.first == reportID else { throw FlowLite84Failure.invalidResponse(.shape) }
        return Array(data.dropFirst())
    }

    static func decode(_ data: Data) throws -> FlowLite84Reply {
        let payload = try normalize(data)
        guard validChecksum(payload) else { throw FlowLite84Failure.invalidResponse(.packetChecksum) }
        let fields: [UInt8]
        switch payload[0] {
        case 1: fields = Array(payload[9...11])
        case 3, 10: fields = [payload[5]]
        case 4: fields = Array(payload[5...8])
        case 18, 29: fields = Array(payload[5...6])
        case 8:
            let count = Int(payload[4] & 0x7f)
            let address = UInt16(payload[2]) << 8 | UInt16(payload[3])
            guard isAllowedRead(address: address, count: UInt8(count)) else {
                throw FlowLite84Failure.invalidResponse(.readHeader)
            }
            fields = Array(payload[5..<(5 + count)])
        case 7:
            let address = UInt16(payload[2]) << 8 | UInt16(payload[3])
            guard isAllowedWrite(address: address, count: payload[4] & 0x7f) else {
                throw FlowLite84Failure.invalidResponse(.writeHeader)
            }
            fields = []
        default: throw FlowLite84Failure.invalidResponse(.unsupportedCommand)
        }
        return FlowLite84Reply(
            command: payload[0], status: payload[1], address: UInt16(payload[2]) << 8 | UInt16(payload[3]),
            count: payload[4], fields: fields
        )
    }

    // Validate in the callback buffer, then retain only status fields; online replies also contain private radio bytes.
    static func sanitizedInput(reportID: UInt32, bytes: UnsafeBufferPointer<UInt8>) throws -> Data? {
        guard reportID == UInt32(Self.reportID), bytes.count == payloadSize || bytes.count == reportSize else { return nil }
        let offset = bytes.count == reportSize ? 1 : 0
        guard offset == 0 || bytes[0] == Self.reportID else { throw FlowLite84Failure.invalidResponse(.shape) }
        guard bytes[offset..<bytes.count].reduce(Self.reportID, &+) == 0x55 else { throw FlowLite84Failure.invalidResponse(.packetChecksum) }
        var safe = [UInt8](repeating: 0, count: payloadSize)
        for index in 0...4 { safe[index] = bytes[offset + index] }
        let range: Range<Int>
        switch safe[0] {
        case 1: range = 9..<12
        case 3, 10: range = 5..<6
        case 4: range = 5..<9
        case 18, 29: range = 5..<7
        case 7:
            let address = UInt16(safe[2]) << 8 | UInt16(safe[3])
            guard isAllowedWrite(address: address, count: safe[4] & 0x7f) else {
                throw FlowLite84Failure.invalidResponse(.writeHeader)
            }
            range = 5..<5
        case 8:
            let address = UInt16(safe[2]) << 8 | UInt16(safe[3])
            let count = safe[4] & 0x7f
            guard isAllowedRead(address: address, count: count) else {
                throw FlowLite84Failure.invalidResponse(.readHeader)
            }
            range = 5..<(5 + Int(count))
        default: throw FlowLite84Failure.invalidResponse(.unsupportedCommand)
        }
        for index in range { safe[index] = bytes[offset + index] }
        safe[15] = checksum(safe)
        return Data(safe)
    }

    static func scalar(_ reply: FlowLite84Reply) throws -> UInt8 {
        guard reply.fields.count == 2, reply.fields.reduce(UInt8(0), &+) == 0x55 else {
            throw FlowLite84Failure.invalidResponse(.scalarChecksum)
        }
        return reply.fields[0]
    }

    static func version(_ reply: FlowLite84Reply) -> String? {
        guard reply.fields.count == 2, !reply.fields.contains(0xff) else { return nil }
        return String(format: "v%u.%02x", UInt32(reply.fields[0]), UInt32(reply.fields[1]))
    }

    static func battery(_ reply: FlowLite84Reply) -> FlowLite84Battery {
        let fields = reply.fields
        let voltage = UInt16(fields[2]) << 8 | UInt16(fields[3])
        return FlowLite84Battery(
            reportedLevel: fields[0] <= 100 ? fields[0] : nil,
            charging: fields[1] <= 1 ? fields[1] == 1 : nil,
            voltageMillivolts: voltage != 0 && voltage != .max ? voltage : nil
        )
    }
}
