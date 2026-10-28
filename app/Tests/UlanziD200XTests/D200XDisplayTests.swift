import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UlanziD200X

struct D200XDisplayTests {
    @Test func nonTelemetryModesKeepNumericFieldsRequiredByAcceptedModeProbe() throws {
        for mode in [1, 2, 200, 201, 202, 203] {
            let status = D200XWideStatus(mode: mode, time: "13:24:59", clockFormat: "24H")
            #expect(String(decoding: try status.payload(), as: UTF8.self) == "\(mode)|0|0|13:24:59|0|24H|")
            #expect(status.cpu == nil && status.memory == nil && status.gpu == nil)
        }
    }

    @Test func wideBackgroundManifestFieldIsScopedAndRejectsUnverifiedValues() throws {
        let plain = try Self.manifest(D200XPage(slots: ["3_2": D200XSlot(image: syntheticPNG)]))
        #expect(Set(try #require(plain["3_2"]).keys) == ["State", "ViewParam"])
        let marked = try Self.manifest(D200XPage(slots: [
            "0_0": D200XSlot(image: syntheticPNG),
            "3_2": D200XSlot(image: syntheticPNG, smallViewMode: 2)
        ]))
        #expect(marked["3_2"]?["SmallViewMode"] as? Int == 2)
        #expect(marked["0_0"]?["SmallViewMode"] == nil)
        for mode in [0, 1, 100, 200, 203] {
            #expect(throws: D200XFailure.invalidPage) {
                try D200XPage(slots: ["3_2": D200XSlot(image: syntheticPNG, smallViewMode: mode)]).archive()
            }
        }
        #expect(throws: D200XFailure.invalidPage) {
            try D200XPage(slots: ["0_0": D200XSlot(image: syntheticPNG, smallViewMode: 2)]).archive()
        }
    }

    @Test func statusPayloadPreservesSevenFieldsAndTrailingEmptyField() throws {
        for mode in [0, 1, 2, 200, 201, 202, 203] {
            let status = D200XWideStatus(mode: mode, cpu: 12, memory: 63, gpu: 26,
                time: "13:24:59", clockFormat: "12H", dateWeekText: mode == 201 ? "Wednesday" : "")
            let text = String(decoding: try status.payload(), as: UTF8.self)
            #expect(text == "\(mode)|12|63|13:24:59|26|12H|\(mode == 201 ? "Wednesday" : "")")
            #expect(text.split(separator: "|", omittingEmptySubsequences: false).count == 7)
        }
    }

    @Test func nonTelemetryFillersPreserveAbsentReadingsAndSystemStatusRequiresCompleteMetrics() throws {
        let status = D200XWideStatus(mode: 203, time: "01:02:03", clockFormat: "24H")
        #expect(String(decoding: try status.payload(), as: UTF8.self) == "203|0|0|01:02:03|0|24H|")
        #expect(status.cpu == nil && status.memory == nil && status.gpu == nil)
        #expect(throws: D200XFailure.invalidPage) {
            try D200XWideStatus(mode: 0, cpu: 10, memory: 20, time: "01:02:03", clockFormat: "24H").payload()
        }
    }

    @Test func rejectsUnknownModesInvalidCountersAndFieldInjection() {
        for mode in [100, 17, -1, 204] {
            #expect(throws: D200XFailure.invalidPage) {
                try D200XWideStatus(mode: mode, time: "01:02:03", clockFormat: "24H").payload()
            }
        }
        for number in [Double.nan, .infinity, -1, 101] {
            #expect(throws: D200XFailure.invalidPage) {
                try D200XWideStatus(mode: 203, gpu: number, time: "01:02:03", clockFormat: "24H").payload()
            }
        }
        for time in ["24:00:00", "12:60:00", "12:00:60", "1:00:00", "aa:bb:cc"] {
            #expect(throws: D200XFailure.invalidPage) {
                try D200XWideStatus(mode: 203, time: time, clockFormat: "24H").payload()
            }
        }
        #expect(throws: D200XFailure.invalidPage) {
            try D200XWideStatus(mode: 200, time: "01:02:03", clockFormat: "24H", dateWeekText: "date|injection").payload()
        }
    }

    @Test func screensaverArchiveContainsExactlyOneRootJPEGAndNoPageManifest() throws {
        let jpeg = try Self.jpeg()
        let archive = try D200XScreensaver(jpeg: jpeg).archive()
        #expect(Array(archive.prefix(4)) == [0x50, 0x4b, 0x03, 0x04])
        let filenameLength = Int(archive[26]) | Int(archive[27]) << 8
        #expect(String(decoding: archive[30..<30 + filenameLength], as: UTF8.self) == "screensaver.jpg")
        #expect(Data(archive[30 + filenameLength..<30 + filenameLength + jpeg.count]) == jpeg)
        #expect(!String(decoding: archive, as: UTF8.self).contains("manifest.json"))
        #expect(archive[archive.count - 12] == 1)
        #expect(throws: D200XFailure.invalidPage) { try D200XScreensaver(jpeg: Data([0xff, 0xd8, 0xff, 0xd9])).archive() }
        #expect(throws: D200XFailure.invalidPage) { try D200XScreensaver(jpeg: Self.jpeg(width: 120)).archive() }
    }

    @Test func sessionSendsDisplayAndScreensaverCommandsWithRecoveredEmptyActivationPayload() async throws {
        let transport = DisplayFixtureTransport()
        let session = D200XSession(makeTransport: { transport })
        try await session.connect()
        let status = D200XWideStatus(mode: 203, time: "12:34:56", clockFormat: "24H")
        try await session.setWideDisplay(status)
        let saver = D200XScreensaver(jpeg: try Self.jpeg())
        try await session.applyScreensaver(saver)
        try await session.setKeepAwakeEnabled(false)
        try await session.showScreensaver()
        let writes = await transport.writes
        #expect(writes.map { $0[0][3] } == [3, 6, 9, 4])
        #expect(Self.payload(writes[3]).isEmpty)
        #expect(Self.payload(writes[1]) == (try status.payload()))
        #expect(Self.payload(writes[2]) == (try saver.archive()))
        await session.disconnect()
        await #expect(throws: D200XFailure.disconnected) { try await session.setWideDisplay(status) }
    }

    private static func payload(_ reports: [Data]) -> Data {
        let frame = reports.reduce(into: Data()) { $0.append($1) }
        let size = Int(frame[4]) | Int(frame[5]) << 8 | Int(frame[6]) << 16 | Int(frame[7]) << 24
        return Data(frame[8..<8 + size])
    }

    private static func manifest(_ page: D200XPage) throws -> [String: [String: Any]] {
        let bytes = [UInt8](try page.archive())
        let word: (Int) -> Int = { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
        let integer: (Int) -> Int = { word($0) | word($0 + 2) << 16 }
        var offset = 0
        while integer(offset) == 0x04034b50 {
            let nameLength = word(offset + 26)
            let start = offset + 30 + nameLength + word(offset + 28)
            let size = integer(offset + 18)
            let name = String(decoding: bytes[offset + 30..<offset + 30 + nameLength], as: UTF8.self)
            if name == "manifest.json" {
                return try #require(JSONSerialization.jsonObject(with: Data(bytes[start..<start + size])) as? [String: [String: Any]])
            }
            offset = start + size
        }
        Issue.record("missing manifest")
        return [:]
    }

    static func jpeg(width: Int = 1220) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: 708, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 708))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private actor DisplayFixtureTransport: D200XTransport {
    nonisolated let reports: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var writes = [[Data]]()

    init() {
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        reports = stream.stream
        continuation = stream.continuation
    }

    func open() async throws {}
    func close() async { continuation.finish() }
    func write(_ reports: [Data]) async throws {
        writes.append(reports)
        if reports.first?[3] == 3 { continuation.yield(response(.identity, payload: syntheticIdentity, paddedLength: 1014)) }
    }
}
