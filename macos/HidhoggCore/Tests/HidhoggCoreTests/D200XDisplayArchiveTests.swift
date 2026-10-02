import Compression
import Foundation
import XCTest
@testable import HidhoggCore

final class D200XDisplayArchiveTests: XCTestCase {
    func testRawDeflateAndCRC32UseInteroperableClassicZIPValues() throws {
        let sample = Data("123456789".utf8)
        XCTAssertEqual(D200XDisplayArchiveBuilder.crc32(sample), 0xcbf4_3926)
        let compressed = try D200XDisplayArchiveBuilder.deflateRaw(sample)
        var decoded = [UInt8](repeating: 0, count: sample.count)
        let count = compressed.withUnsafeBytes { source in
            decoded.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        XCTAssertEqual(count, sample.count)
        XCTAssertEqual(Data(decoded), sample)
        XCTAssertEqual(try D200XDisplayArchiveBuilder.deflateRaw(Data()), Data([0x03, 0x00]))
    }

    func testFirmwareSafePaddingAndClassicZIPDirectoryAreValidAndDeterministic() throws {
        let files = [
            D200XArchiveFile(name: "manifest.json", data: Data(#"{"ok":true}"#.utf8), method: 8),
            D200XArchiveFile(name: "Images/sample.png", data: Data(repeating: 0x51, count: 2_000), method: 8),
        ]
        let first = try D200XDisplayArchiveBuilder.makeFirmwareSafe(files: files)
        let second = try D200XDisplayArchiveBuilder.makeFirmwareSafe(files: files)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Data(first.data.prefix(4)), Data([0x50, 0x4b, 0x03, 0x04]))

        for offset in stride(from: D200XFrameCodec.firstPayloadCapacity, to: first.data.count, by: D200XFrameCodec.packetSize) {
            XCTAssertNotEqual(first.data[offset], 0)
            XCTAssertNotEqual(first.data[offset], 0x7c)
        }

        let members = try parseClassicZIP(first.data)
        XCTAssertEqual(members.map(\.name), first.paddingLength > 0 ? ["dummy.txt", "manifest.json", "Images/sample.png"] : ["manifest.json", "Images/sample.png"])
        XCTAssertEqual(members.last?.data, files[1].data)
        XCTAssertEqual(members.first(where: { $0.name == "manifest.json" })?.data, files[0].data)
        if first.paddingLength > 0 {
            let dummy = try XCTUnwrap(members.first)
            XCTAssertEqual(dummy.method, 0)
            XCTAssertEqual(dummy.data.count, first.paddingLength)
            XCTAssertTrue(dummy.data.allSatisfy { $0 == 0 })
        }
    }
}

struct D200XTestZIPMember {
    let name: String
    let method: UInt16
    let data: Data
}

func parseClassicZIP(_ archive: Data) throws -> [D200XTestZIPMember] {
    var members = [D200XTestZIPMember]()
    var offset = 0
    while offset + 4 <= archive.count, readUInt32(archive, at: offset) == 0x0403_4b50 {
        guard offset + 30 <= archive.count else { throw D200XTestFailure.invalidArchive }
        let flags = readUInt16(archive, at: offset + 6)
        let method = readUInt16(archive, at: offset + 8)
        let checksum = readUInt32(archive, at: offset + 14)
        let compressedLength = Int(readUInt32(archive, at: offset + 18))
        let uncompressedLength = Int(readUInt32(archive, at: offset + 22))
        let nameLength = Int(readUInt16(archive, at: offset + 26))
        let extraLength = Int(readUInt16(archive, at: offset + 28))
        guard flags == 0, method == 0 || method == 8 else { throw D200XTestFailure.invalidArchive }
        let nameStart = offset + 30
        let dataStart = nameStart + nameLength + extraLength
        let dataEnd = dataStart + compressedLength
        guard dataEnd <= archive.count,
              let name = String(data: archive[nameStart..<(nameStart + nameLength)], encoding: .utf8) else {
            throw D200XTestFailure.invalidArchive
        }
        let compressed = Data(archive[dataStart..<dataEnd])
        let data: Data
        if method == 0 {
            data = compressed
        } else {
            var decoded = [UInt8](repeating: 0, count: uncompressedLength)
            let count = compressed.withUnsafeBytes { source in
                decoded.withUnsafeMutableBufferPointer { destination in
                    compression_decode_buffer(
                        destination.baseAddress!,
                        destination.count,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        source.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard count == uncompressedLength else { throw D200XTestFailure.decompressionFailed }
            data = Data(decoded)
        }
        guard data.count == uncompressedLength, D200XDisplayArchiveBuilder.crc32(data) == checksum else {
            throw D200XTestFailure.invalidArchive
        }
        members.append(D200XTestZIPMember(name: name, method: method, data: data))
        offset = dataEnd
    }

    guard offset + 22 <= archive.count, readUInt32(archive, at: offset) == 0x0201_4b50 else {
        throw D200XTestFailure.invalidArchive
    }
    let centralOffset = Int(readUInt32(archive, at: archive.count - 22 + 16))
    guard centralOffset == offset else { throw D200XTestFailure.invalidArchive }
    return members
}

func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
}
