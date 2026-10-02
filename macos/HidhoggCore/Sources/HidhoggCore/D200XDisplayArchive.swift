import Compression
import Foundation

enum D200XArchiveError: Error, Equatable {
    case invalidPaddingLength(Int)
    case tooManyFiles
    case invalidFilename
    case fieldOverflow
    case payloadTooLarge(actual: Int, limit: Int)
    case compressionFailed
    case noFirmwareSafePadding
}

struct D200XArchiveFile {
    let name: String
    let data: Data
    let method: UInt16
}

struct D200XDisplayArchive: Equatable {
    let data: Data
    let paddingLength: Int
}

enum D200XDisplayArchiveBuilder {
    static let maximumPayloadLength = D200XFrameCodec.maximumPayloadLength
    static let maximumPaddingLength = 4096

    static func makeFirmwareSafe(files: [D200XArchiveFile]) throws -> D200XDisplayArchive {
        let compressedFiles = try files.map(compress)
        for paddingLength in 0..<maximumPaddingLength {
            let archive = try assemble(files: compressedFiles, paddingLength: paddingLength)
            guard archive.count <= maximumPayloadLength else {
                throw D200XArchiveError.payloadTooLarge(actual: archive.count, limit: maximumPayloadLength)
            }
            if isFirmwareSafe(archive) {
                return D200XDisplayArchive(data: archive, paddingLength: paddingLength)
            }
        }
        throw D200XArchiveError.noFirmwareSafePadding
    }

    static func deflateRaw(_ source: Data) throws -> Data {
        if source.isEmpty { return Data([0x03, 0x00]) }
        let capacity = max(64, source.count + source.count / 8 + 1024)
        var destination = [UInt8](repeating: 0, count: capacity)
        let encodedCount = source.withUnsafeBytes { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                compression_encode_buffer(
                    destinationBuffer.baseAddress!,
                    destinationBuffer.count,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard encodedCount > 0 else { throw D200XArchiveError.compressionFailed }
        return Data(destination.prefix(encodedCount))
    }

    static func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xffff_ffff
        for byte in data {
            checksum = (checksum >> 8) ^ crcTable[Int((checksum ^ UInt32(byte)) & 0xff)]
        }
        return checksum ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var entry = UInt32(value)
        for _ in 0..<8 {
            entry = entry & 1 == 1 ? (entry >> 1) ^ 0xedb8_8320 : entry >> 1
        }
        return entry
    }

    private static func compress(_ file: D200XArchiveFile) throws -> CompressedFile {
        guard file.method == 0 || file.method == 8, file.name.utf8.count <= Int(UInt16.max) else {
            throw D200XArchiveError.invalidFilename
        }
        let compressed = file.method == 0 ? file.data : try deflateRaw(file.data)
        guard compressed.count <= Int(UInt32.max), file.data.count <= Int(UInt32.max) else {
            throw D200XArchiveError.fieldOverflow
        }
        return CompressedFile(
            name: Data(file.name.utf8),
            method: file.method,
            data: file.data,
            compressed: compressed,
            checksum: crc32(file.data)
        )
    }

    private static func assemble(files: [CompressedFile], paddingLength: Int) throws -> Data {
        guard (0..<maximumPaddingLength).contains(paddingLength) else {
            throw D200XArchiveError.invalidPaddingLength(paddingLength)
        }

        var ordered = [CompressedFile]()
        if paddingLength > 0 {
            let data = Data(repeating: 0, count: paddingLength)
            ordered.append(CompressedFile(name: Data("dummy.txt".utf8), method: 0, data: data, compressed: data, checksum: crc32(data)))
        }
        ordered.append(contentsOf: files)
        guard ordered.count <= Int(UInt16.max) else { throw D200XArchiveError.tooManyFiles }

        var archive = Data()
        var localOffsets = [UInt32]()
        for file in ordered {
            guard archive.count <= Int(UInt32.max) else { throw D200XArchiveError.fieldOverflow }
            localOffsets.append(UInt32(archive.count))
            appendUInt32(0x0403_4b50, to: &archive)
            appendUInt16(file.method == 0 ? 10 : 20, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(file.method, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0x0021, to: &archive)
            appendUInt32(file.checksum, to: &archive)
            appendUInt32(UInt32(file.compressed.count), to: &archive)
            appendUInt32(UInt32(file.data.count), to: &archive)
            appendUInt16(UInt16(file.name.count), to: &archive)
            appendUInt16(0, to: &archive)
            archive.append(file.name)
            archive.append(file.compressed)
        }

        guard archive.count <= Int(UInt32.max) else { throw D200XArchiveError.fieldOverflow }
        let centralOffset = UInt32(archive.count)
        for (index, file) in ordered.enumerated() {
            appendUInt32(0x0201_4b50, to: &archive)
            appendUInt16(20, to: &archive)
            appendUInt16(file.method == 0 ? 10 : 20, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(file.method, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0x0021, to: &archive)
            appendUInt32(file.checksum, to: &archive)
            appendUInt32(UInt32(file.compressed.count), to: &archive)
            appendUInt32(UInt32(file.data.count), to: &archive)
            appendUInt16(UInt16(file.name.count), to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(0, to: &archive)
            appendUInt32(localOffsets[index], to: &archive)
            archive.append(file.name)
        }

        guard archive.count >= Int(centralOffset), archive.count <= Int(UInt32.max) else {
            throw D200XArchiveError.fieldOverflow
        }
        let centralSize = UInt32(archive.count - Int(centralOffset))
        appendUInt32(0x0605_4b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(ordered.count), to: &archive)
        appendUInt16(UInt16(ordered.count), to: &archive)
        appendUInt32(centralSize, to: &archive)
        appendUInt32(centralOffset, to: &archive)
        appendUInt16(0, to: &archive)
        return archive
    }

    private static func isFirmwareSafe(_ archive: Data) -> Bool {
        var offset = D200XFrameCodec.firstPayloadCapacity
        while offset < archive.count {
            let byte = archive[offset]
            if byte == 0 || byte == 0x7c { return false }
            offset += D200XFrameCodec.packetSize
        }
        return true
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}

private struct CompressedFile {
    let name: Data
    let method: UInt16
    let data: Data
    let compressed: Data
    let checksum: UInt32
}
