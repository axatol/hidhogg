import Foundation
import XCTest
@testable import HidhoggCore

final class D200XProtocolTests: XCTestCase {
    func testFramesUseExactD200XPacketAndReportLayoutAtPayloadBoundaries() throws {
        for length in [0, 1, 1_016, 1_017, 2_040, 2_041] {
            let payload = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 31) })
            let frame = D200XOutboundFrame(command: .completeDisplayUpload, payload: payload)
            let reports = try D200XFrameCodec.encode(frame)
            let expectedReportCount = 1 + max(0, (length - D200XFrameCodec.firstPayloadCapacity + D200XFrameCodec.packetSize - 1) / D200XFrameCodec.packetSize)
            XCTAssertEqual(reports.count, expectedReportCount, "payload length \(length)")
            XCTAssertTrue(reports.allSatisfy { $0.count == D200XFrameCodec.reportSize && $0.first == 0 })

            let firstPacket = Array(reports[0].dropFirst())
            XCTAssertEqual(Array(firstPacket[0...3]), [0x7c, 0x7c, 0x00, 0x01])
            XCTAssertEqual(Array(firstPacket[4...7]), [UInt8(length & 0xff), UInt8((length >> 8) & 0xff), 0, 0])
            if length < D200XFrameCodec.firstPayloadCapacity {
                XCTAssertTrue(firstPacket[(D200XFrameCodec.headerSize + length)...].allSatisfy { $0 == 0 })
            }

            let decoded = try D200XFrameCodec.decode(reports: reports)
            XCTAssertEqual(decoded.command, D200XOutboundCommand.completeDisplayUpload.rawValue)
            XCTAssertEqual(decoded.payload, payload)
        }
    }

    func testReportNormalizationAndMalformedFramesAreRejectedPrecisely() throws {
        let valid = try D200XFrameCodec.encode(D200XOutboundFrame(command: .brightness, payload: Data("42".utf8)))[0]
        XCTAssertEqual(try D200XFrameAssembler(firstReport: Data(valid.dropFirst())).frame().payload, Data("42".utf8))

        var unsupportedID = valid
        unsupportedID[0] = 1
        XCTAssertThrowsError(try D200XFrameAssembler(firstReport: unsupportedID)) { error in
            XCTAssertEqual(error as? D200XProtocolError, .unsupportedReportID(1))
        }
        XCTAssertThrowsError(try D200XFrameAssembler(firstReport: Data(repeating: 0, count: 1_023))) { error in
            XCTAssertEqual(error as? D200XProtocolError, .invalidReportLength(actual: 1_023))
        }

        var badMagic = valid
        badMagic[1] = 0
        XCTAssertThrowsError(try D200XFrameAssembler(firstReport: badMagic)) { error in
            XCTAssertEqual(error as? D200XProtocolError, .invalidFrameMagic(0, 0x7c))
        }

        var tooLarge = valid
        let declared = D200XFrameCodec.maximumPayloadLength + 1
        tooLarge[5] = UInt8(declared & 0xff)
        tooLarge[6] = UInt8((declared >> 8) & 0xff)
        tooLarge[7] = UInt8((declared >> 16) & 0xff)
        tooLarge[8] = UInt8((declared >> 24) & 0xff)
        XCTAssertThrowsError(try D200XFrameAssembler(firstReport: tooLarge)) { error in
            XCTAssertEqual(error as? D200XProtocolError, .payloadTooLarge(actual: declared, limit: D200XFrameCodec.maximumPayloadLength))
        }

        let longPayload = Data(repeating: 0x5a, count: D200XFrameCodec.firstPayloadCapacity + 1)
        let reports = try D200XFrameCodec.encode(D200XOutboundFrame(command: .completeDisplayUpload, payload: longPayload))
        XCTAssertThrowsError(try D200XFrameCodec.decode(reports: Array(reports.dropLast()))) { error in
            XCTAssertEqual(error as? D200XProtocolError, .truncatedPayload(received: D200XFrameCodec.firstPayloadCapacity, expected: longPayload.count))
        }
        XCTAssertThrowsError(try D200XFrameCodec.decode(reports: reports + [reports[1]])) { error in
            XCTAssertEqual(error as? D200XProtocolError, .unexpectedContinuation)
        }
    }

    func testMaximumPayloadIsAcceptedAndOneByteOverIsRejected() throws {
        let maximum = Data(repeating: 0xa5, count: D200XFrameCodec.maximumPayloadLength)
        let reports = try D200XFrameCodec.encode(D200XOutboundFrame(command: .completeDisplayUpload, payload: maximum))
        XCTAssertEqual(reports.count, 1 + (maximum.count - D200XFrameCodec.firstPayloadCapacity + D200XFrameCodec.packetSize - 1) / D200XFrameCodec.packetSize)

        XCTAssertThrowsError(try D200XFrameCodec.encode(D200XOutboundFrame(command: .completeDisplayUpload, payload: Data(repeating: 0, count: maximum.count + 1)))) { error in
            XCTAssertEqual(error as? D200XProtocolError, .payloadTooLarge(actual: maximum.count + 1, limit: maximum.count))
        }
    }

    func testInputDecoderPreservesUnknownWireValuesAndRejectsShortPayloads() throws {
        let raw = Data([0xa7, 13, 0xf2, 0xf3, 0x44])
        let eventFrame = D200XDecodedFrame(command: 0x0101, payload: raw)
        let event = try XCTUnwrap(D200XFrameCodec.decodeInput(eventFrame))
        XCTAssertEqual(event.deviceState, 0xa7)
        XCTAssertEqual(event.wireIndex, 13)
        XCTAssertEqual(event.marker, 0xf2)
        XCTAssertEqual(event.action, 0xf3)
        XCTAssertEqual(event.rawPayload, raw)
        XCTAssertNil(try D200XFrameCodec.decodeInput(D200XDecodedFrame(command: 0x0002, payload: raw)))

        for length in [0, 3] {
            XCTAssertThrowsError(try D200XFrameCodec.decodeInput(D200XDecodedFrame(command: 0x0101, payload: Data(repeating: 0, count: length)))) { error in
                XCTAssertEqual(error as? D200XProtocolError, .malformedInputPayload(actual: length))
            }
        }
    }

    func testSafeOutboundBatchesPreserveStartupAndKeepaliveCommands() throws {
        let page = try D200XPageRenderer.render(profile: decodeD200XProfile())
        let startup = try D200XOutboundBatch.startup(page: page, brightness: 0).makeFrames()
        XCTAssertEqual(startup.map(\.command), [.unlockScreen, .completeDisplayUpload, .brightness, .enableInputStream])
        XCTAssertEqual(startup[2].payload, Data("0".utf8))
        XCTAssertEqual(try D200XOutboundBatch.keepAlive.makeFrames().map(\.command), [.enableInputStream])
        XCTAssertEqual(try D200XOutboundBatch.redraw(page: page).makeFrames().map(\.command), [.completeDisplayUpload])
        XCTAssertEqual(try D200XOutboundBatch.setBrightness(100).makeFrames()[0].payload, Data("100".utf8))
    }

    func testInvalidBrightnessFailsBeforeAnyStartupOrBrightnessFramesExist() throws {
        let page = try D200XPageRenderer.render(profile: decodeD200XProfile())
        for brightness in [-1, 101] {
            XCTAssertThrowsError(try D200XOutboundBatch.startup(page: page, brightness: brightness).makeFrames()) { error in
                XCTAssertEqual(error as? D200XProtocolError, .invalidBrightness(brightness))
            }
            XCTAssertThrowsError(try D200XOutboundBatch.setBrightness(brightness).makeFrames()) { error in
                XCTAssertEqual(error as? D200XProtocolError, .invalidBrightness(brightness))
            }
        }
    }
}
