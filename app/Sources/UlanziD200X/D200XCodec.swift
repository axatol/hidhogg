import Foundation

public enum D200XFailure: Error, Equatable, Sendable {
    case unavailable, ambiguous, disconnected, busy, cancelled, timeout, transport, overflow
    case invalidFrame, invalidChecksum, invalidIdentity, unsupportedDevice, invalidPage, oversized
}

public struct D200XCommand: Equatable, Sendable {
    public let family: UInt8
    public let code: UInt8

    public init(_ family: UInt8, _ code: UInt8) {
        self.family = family
        self.code = code
    }

    public static let getBase = Self(0, 3)
    public static let identity = Self(3, 3)
    public static let input = Self(1, 1)
    public static let fontRequest = Self(1, 11)
}

public struct D200XFrame: Equatable, Sendable {
    public let command: D200XCommand
    public let payload: Data

    public init(command: D200XCommand, payload: Data = Data()) {
        self.command = command
        self.payload = payload
    }
}

public enum D200XCodec {
    public static let reportSize = 1024
    public static let maximumPayloadSize = 4 * 1024 * 1024

    public static func reports(for frame: D200XFrame) throws -> [Data] {
        guard frame.payload.count <= maximumPayloadSize else { throw D200XFailure.oversized }
        var bytes = Data([0x7c, 0x7c, frame.command.family, frame.command.code])
        bytes.appendLE(UInt32(frame.payload.count))
        bytes.append(frame.payload)
        bytes.append(contentsOf: [0, 0])
        // The recovered writer emits another report when the frame is exactly aligned.
        bytes.append(Data(repeating: 0, count: reportSize - bytes.count % reportSize))
        return stride(from: 0, to: bytes.count, by: reportSize).map { Data(bytes[$0..<$0 + reportSize]) }
    }

    public static func crc16(_ bytes: Data) -> UInt16 {
        bytes.reduce(UInt16.max) { checksum, byte in
            var value = checksum ^ UInt16(byte) << 8
            for _ in 0..<8 { value = value & 0x8000 == 0 ? value << 1 : (value << 1) ^ 0x1021 }
            return value
        }
    }

    public static func decodeResponse(_ report: Data) throws -> D200XFrame {
        let bytes = [UInt8](report)
        guard (10...reportSize).contains(bytes.count), bytes[0] == 0x7c, bytes[1] == 0x7c else {
            throw D200XFailure.invalidFrame
        }
        let length = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        guard length <= bytes.count - 10 else { throw D200XFailure.invalidFrame }
        let command = D200XCommand(bytes[2], bytes[3])
        let padded = Data(bytes[8..<8 + length])
        let meaningful: Data
        switch command {
        case .input:
            guard length >= 4, padded.dropFirst(4).allSatisfy({ $0 == 0 }) else { throw D200XFailure.invalidFrame }
            meaningful = Data(padded.prefix(4))
        case .identity:
            meaningful = Data(padded.prefix((padded.lastIndex(where: { $0 != 0 }) ?? -1) + 1))
        case .fontRequest:
            guard padded.allSatisfy({ $0 == 0 }) else { throw D200XFailure.invalidFrame }
            meaningful = Data()
        default:
            throw D200XFailure.invalidFrame
        }
        let checksum = UInt16(bytes[8 + length]) | UInt16(bytes[9 + length]) << 8
        guard crc16(meaningful) == checksum else { throw D200XFailure.invalidChecksum }
        guard bytes.dropFirst(10 + length).allSatisfy({ $0 == 0 }) else { throw D200XFailure.invalidFrame }
        return D200XFrame(command: command, payload: meaningful)
    }
}

public struct D200XIdentity: Equatable, Sendable {
    public let model: String
    public let solution: String
    public let firmware: String?
    public let hardware: String?

    public init(payload: Data) throws {
        struct Base: Decodable {
            let SerialNumber: String
            let Dversion: String?
            let HardwareVersion: String?
        }
        guard payload.count <= D200XCodec.reportSize,
              let base = try? JSONDecoder().decode(Base.self, from: payload) else { throw D200XFailure.invalidIdentity }
        let identifier = Array(base.SerialNumber.utf8)
        guard identifier.count == 17, identifier.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else {
            throw D200XFailure.invalidIdentity
        }
        solution = String(decoding: identifier[0..<2], as: UTF8.self)
        model = String(decoding: identifier[5..<9], as: UTF8.self)
        guard solution == "02", model == "A045" else { throw D200XFailure.unsupportedDevice }
        firmware = Self.version(base.Dversion)
        hardware = Self.version(base.HardwareVersion, alphanumeric: true)
    }

    private static func version(_ value: String?, alphanumeric: Bool = false) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 32,
              value.utf8.allSatisfy({
                  (48...57).contains($0) || $0 == 46 || (alphanumeric && ((65...90).contains($0) || (97...122).contains($0)))
              }) else { return nil }
        return value
    }
}

public struct D200XInput: Equatable, Sendable {
    public enum Gesture: Equatable, Sendable {
        case release, press, left, right, heldLeft, heldRight, unknown
    }

    public let prefix: UInt8
    public let index: UInt8
    public let family: UInt8
    public let state: UInt8

    public init(payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count == 4 else { throw D200XFailure.invalidFrame }
        prefix = bytes[0]
        index = bytes[1]
        family = bytes[2]
        state = bytes[3]
    }

    public var gesture: Gesture {
        if family == 1 { return state == 0 ? .release : .press }
        guard family == 2 else { return .unknown }
        let gestures: [Gesture] = [.release, .press, .left, .right, .heldLeft, .heldRight]
        return gestures.indices.contains(Int(state)) ? gestures[Int(state)] : .unknown
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
