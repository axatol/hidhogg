import Foundation

enum D200XProtocolError: Error, Equatable {
    case invalidReportLength(actual: Int)
    case unsupportedReportID(UInt8)
    case invalidFrameMagic(UInt8, UInt8)
    case payloadTooLarge(actual: Int, limit: Int)
    case truncatedPayload(received: Int, expected: Int)
    case unexpectedContinuation
    case malformedInputPayload(actual: Int)
    case invalidBrightness(Int)
}

enum D200XOutboundCommand: UInt16, Equatable {
    case completeDisplayUpload = 0x0001
    case enableInputStream = 0x0002
    case brightness = 0x000A
    case unlockScreen = 0x0010
}

struct D200XOutboundFrame: Equatable {
    let command: D200XOutboundCommand
    let payload: Data

    init(command: D200XOutboundCommand, payload: Data = Data()) {
        self.command = command
        self.payload = payload
    }
}

enum D200XOutboundBatch: Equatable {
    case startup(page: D200XLivePageUpdate, brightness: Int)
    case redraw(page: D200XLivePageUpdate)
    case setBrightness(Int)
    case keepAlive

    func makeFrames() throws -> [D200XOutboundFrame] {
        switch self {
        case let .startup(page, brightness):
            guard (0...100).contains(brightness) else { throw D200XProtocolError.invalidBrightness(brightness) }
            return [
                D200XOutboundFrame(command: .unlockScreen),
                D200XOutboundFrame(command: .completeDisplayUpload, payload: page.archive.data),
                D200XOutboundFrame(command: .brightness, payload: Data(String(brightness).utf8)),
                D200XOutboundFrame(command: .enableInputStream),
            ]
        case let .redraw(page):
            return [D200XOutboundFrame(command: .completeDisplayUpload, payload: page.archive.data)]
        case let .setBrightness(brightness):
            guard (0...100).contains(brightness) else { throw D200XProtocolError.invalidBrightness(brightness) }
            return [D200XOutboundFrame(command: .brightness, payload: Data(String(brightness).utf8))]
        case .keepAlive:
            return [D200XOutboundFrame(command: .enableInputStream)]
        }
    }

}

struct D200XDecodedFrame: Equatable {
    let command: UInt16
    let payload: Data
}

struct D200XInputEvent: Equatable {
    let deviceState: UInt8
    let wireIndex: UInt8
    let marker: UInt8
    let action: UInt8
    let rawPayload: Data
}

enum D200XFrameCodec {
    static let packetSize = 1024
    static let reportSize = packetSize + 1
    static let headerSize = 8
    static let firstPayloadCapacity = packetSize - headerSize
    static let maximumPayloadLength = 16 * 1024 * 1024

    static func encode(_ frame: D200XOutboundFrame) throws -> [Data] {
        guard frame.payload.count <= maximumPayloadLength else {
            throw D200XProtocolError.payloadTooLarge(actual: frame.payload.count, limit: maximumPayloadLength)
        }

        let bytes = [UInt8](frame.payload)
        var packets = [[UInt8]]()
        var first = [UInt8](repeating: 0, count: packetSize)
        first[0] = 0x7c
        first[1] = 0x7c
        first[2] = UInt8(truncatingIfNeeded: frame.command.rawValue >> 8)
        first[3] = UInt8(truncatingIfNeeded: frame.command.rawValue)
        writeLittleEndian(UInt32(bytes.count), into: &first, at: 4)

        let initialCount = min(bytes.count, firstPayloadCapacity)
        if initialCount > 0 {
            first.replaceSubrange(headerSize..<(headerSize + initialCount), with: bytes[..<initialCount])
        }
        packets.append(first)

        var offset = initialCount
        while offset < bytes.count {
            let count = min(packetSize, bytes.count - offset)
            var continuation = [UInt8](repeating: 0, count: packetSize)
            continuation.replaceSubrange(0..<count, with: bytes[offset..<(offset + count)])
            packets.append(continuation)
            offset += count
        }

        return packets.map { Data([0] + $0) }
    }

    static func decode(reports: [Data]) throws -> D200XDecodedFrame {
        guard let first = reports.first else {
            throw D200XProtocolError.truncatedPayload(received: 0, expected: 1)
        }
        var assembler = try D200XFrameAssembler(firstReport: first)
        for report in reports.dropFirst() {
            try assembler.append(report)
        }
        return try assembler.frame()
    }

    static func decodeInput(_ frame: D200XDecodedFrame) throws -> D200XInputEvent? {
        guard frame.command == 0x0101 else { return nil }
        guard frame.payload.count >= 4 else {
            throw D200XProtocolError.malformedInputPayload(actual: frame.payload.count)
        }
        let payload = [UInt8](frame.payload)
        return D200XInputEvent(
            deviceState: payload[0],
            wireIndex: payload[1],
            marker: payload[2],
            action: payload[3],
            rawPayload: frame.payload
        )
    }

    fileprivate static func normalizedPacket(_ report: Data) throws -> [UInt8] {
        let bytes = [UInt8](report)
        switch bytes.count {
        case packetSize:
            return bytes
        case reportSize:
            guard bytes[0] == 0 else { throw D200XProtocolError.unsupportedReportID(bytes[0]) }
            return Array(bytes.dropFirst())
        default:
            throw D200XProtocolError.invalidReportLength(actual: bytes.count)
        }
    }

    fileprivate static func writeLittleEndian(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }
}

struct D200XFrameAssembler {
    private let command: UInt16
    private let declaredLength: Int
    private var payload: [UInt8]

    init(firstReport: Data) throws {
        let packet = try D200XFrameCodec.normalizedPacket(firstReport)
        guard packet[0] == 0x7c, packet[1] == 0x7c else {
            throw D200XProtocolError.invalidFrameMagic(packet[0], packet[1])
        }

        let length = Int(packet[4]) | Int(packet[5]) << 8 | Int(packet[6]) << 16 | Int(packet[7]) << 24
        guard length <= D200XFrameCodec.maximumPayloadLength else {
            throw D200XProtocolError.payloadTooLarge(actual: length, limit: D200XFrameCodec.maximumPayloadLength)
        }

        command = UInt16(packet[2]) << 8 | UInt16(packet[3])
        declaredLength = length
        payload = Array(packet[D200XFrameCodec.headerSize..<(D200XFrameCodec.headerSize + min(length, D200XFrameCodec.firstPayloadCapacity))])
    }

    var isComplete: Bool { payload.count == declaredLength }
    var receivedPayloadLength: Int { payload.count }
    var expectedPayloadLength: Int { declaredLength }

    mutating func append(_ continuationReport: Data) throws {
        guard !isComplete else { throw D200XProtocolError.unexpectedContinuation }
        let packet = try D200XFrameCodec.normalizedPacket(continuationReport)
        let remaining = declaredLength - payload.count
        payload.append(contentsOf: packet.prefix(min(remaining, D200XFrameCodec.packetSize)))
    }

    func frame() throws -> D200XDecodedFrame {
        guard isComplete else {
            throw D200XProtocolError.truncatedPayload(received: payload.count, expected: declaredLength)
        }
        return D200XDecodedFrame(command: command, payload: Data(payload))
    }
}
