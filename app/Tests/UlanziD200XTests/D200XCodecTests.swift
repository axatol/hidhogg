import Foundation
import Testing
@testable import UlanziD200X

func response(_ command: D200XCommand, payload: Data, paddedLength: Int? = nil) -> Data {
    let length = paddedLength ?? payload.count
    var result = Data([0x7c, 0x7c, command.family, command.code])
    result.appendLE(UInt32(length))
    result.append(payload)
    result.append(Data(repeating: 0, count: length - payload.count))
    result.appendLE(D200XCodec.crc16(payload))
    result.append(Data(repeating: 0, count: max(0, 1024 - result.count)))
    return result
}

let syntheticIdentity = Data(#"{"SerialNumber":"02000A04500000000","Dversion":"5.3.1","HardwareVersion":"1.0"}"#.utf8)

struct D200XCodecTests {
    @Test func outboundZeroTrailerAndExactBoundary() throws {
        let empty = try D200XCodec.reports(for: D200XFrame(command: .getBase))
        #expect(empty.count == 1)
        #expect(empty[0].prefix(10) == Data([124, 124, 0, 3, 0, 0, 0, 0, 0, 0]))
        let exact = try D200XCodec.reports(for: D200XFrame(command: D200XCommand(0, 13), payload: Data(repeating: 7, count: 1014)))
        #expect(exact.count == 2)
        #expect(exact.allSatisfy { $0.count == 1024 })
        #expect(exact[0].suffix(2) == Data([0, 0]))
        #expect(exact[1].allSatisfy { $0 == 0 })
        let crossed = try D200XCodec.reports(for: D200XFrame(command: D200XCommand(0, 1), payload: Data(repeating: 8, count: 1015)))
        #expect(crossed.count == 2)
    }

    @Test func crcUsesMeaningfulEventBytesIncludingReleaseZero() throws {
        #expect(D200XCodec.crc16(Data("123456789".utf8)) == 0x29b1)
        let bytes = Data([1, 17, 2, 0])
        let frame = try D200XCodec.decodeResponse(response(.input, payload: bytes, paddedLength: 1014))
        #expect(frame.payload == bytes)
        #expect(try D200XInput(payload: frame.payload).gesture == .release)
        var corrupt = response(.input, payload: bytes, paddedLength: 1014)
        corrupt[9] ^= 1
        #expect(throws: D200XFailure.invalidChecksum) { try D200XCodec.decodeResponse(corrupt) }
    }

    @Test func identityAndEmptyFontCRC() throws {
        let frame = try D200XCodec.decodeResponse(response(.identity, payload: syntheticIdentity, paddedLength: 1014))
        let identity = try D200XIdentity(payload: frame.payload)
        #expect(identity.model == "A045")
        #expect(identity.solution == "02")
        #expect(identity.firmware == "5.3.1")
        #expect(try D200XCodec.decodeResponse(response(.fontRequest, payload: Data())).payload.isEmpty)
        let unsupported = Data(#"{"SerialNumber":"01000A04500000000"}"#.utf8)
        #expect(throws: D200XFailure.unsupportedDevice) { try D200XIdentity(payload: unsupported) }
        #expect(throws: D200XFailure.invalidIdentity) { try D200XIdentity(payload: Data("{}".utf8)) }
    }

    @Test func invalidFramesAreBounded() throws {
        #expect(throws: D200XFailure.invalidFrame) { try D200XCodec.decodeResponse(Data()) }
        var oversized = response(.input, payload: Data([1, 0, 1, 1]))
        oversized.replaceSubrange(4..<8, with: [255, 255, 255, 255])
        #expect(throws: D200XFailure.invalidFrame) { try D200XCodec.decodeResponse(oversized) }
        let extra = response(.input, payload: Data([1, 0, 1, 1, 7]))
        #expect(throws: D200XFailure.invalidFrame) { try D200XCodec.decodeResponse(extra) }
        #expect(throws: D200XFailure.oversized) {
            try D200XCodec.reports(for: D200XFrame(command: .getBase, payload: Data(repeating: 0, count: D200XCodec.maximumPayloadSize + 1)))
        }
    }

    @Test func inputStatesRemainExplicit() throws {
        let expected: [D200XInput.Gesture] = [.release, .press, .left, .right, .heldLeft, .heldRight]
        for state in 0..<6 {
            let input = try D200XInput(payload: Data([1, 19, 2, UInt8(state)]))
            #expect(input.gesture == expected[state])
            #expect(input.index == 19)
        }
        #expect(try D200XInput(payload: Data([1, 19, 2, 99])).gesture == .unknown)
        #expect(try D200XInput(payload: Data([1, 15, 1, 7])).gesture == .press)
        #expect(try D200XInput(payload: Data([1, 20, 9, 1])).gesture == .unknown)
    }
}
