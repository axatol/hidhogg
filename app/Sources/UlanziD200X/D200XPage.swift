import CryptoKit
import Foundation

public struct D200XSlot: Equatable, Sendable {
    public enum ImageFormat: String, Sendable { case png, gif }
    public let image: Data
    public let format: ImageFormat
    public let text: String

    public init(image: Data, format: ImageFormat = .png, text: String = "") {
        self.image = image
        self.format = format
        self.text = text
    }
}

public struct D200XPage: Equatable, Sendable {
    public let slots: [String: D200XSlot]

    public init(slots: [String: D200XSlot]) { self.slots = slots }

    public func archive() throws -> Data {
        guard slots.count <= 14 else { throw D200XFailure.invalidPage }
        var files: [(String, Data)] = []
        var assets: Set<String> = []
        var manifest: [String: ManifestSlot] = [:]
        var total = 0
        for coordinate in slots.keys.sorted() {
            guard Self.coordinates.contains(coordinate), let slot = slots[coordinate],
                  slot.text.utf8.count <= 4096, !slot.image.isEmpty else { throw D200XFailure.invalidPage }
            total += slot.image.count
            guard total <= D200XCodec.maximumPayloadSize else { throw D200XFailure.oversized }
            let signature = slot.format == .png ? Data([137, 80, 78, 71, 13, 10, 26, 10]) : Data("GIF8".utf8)
            guard slot.image.starts(with: signature) else { throw D200XFailure.invalidPage }
            let hash = SHA256.hash(data: slot.image).map { String(format: "%02x", $0) }.joined()
            let path = "Images/\(hash).\(slot.format.rawValue)"
            if assets.insert(path).inserted { files.append((path, slot.image)) }
            manifest[coordinate] = ManifestSlot(State: 0, ViewParam: [View(Icon: path, Text: slot.text)])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        files.append(("manifest.json", try encoder.encode(manifest)))
        return try D200XStoredZIP.build(files)
    }

    private static let coordinates = Set((0..<14).map { "\($0 % 5)_\($0 / 5)" })
    private struct View: Encodable { let Icon: String; let Text: String }
    private struct ManifestSlot: Encodable { let State: Int; let ViewParam: [View] }
}

public enum D200XPageUpdate: Sendable { case replace, incremental }

enum D200XStoredZIP {
    static func build(_ files: [(String, Data)]) throws -> Data {
        guard files.count < Int(UInt16.max) else { throw D200XFailure.oversized }
        var result = Data()
        var directory = Data()
        for (name, bytes) in files {
            let path = Data(name.utf8)
            guard path.count <= Int(UInt16.max), bytes.count <= D200XCodec.maximumPayloadSize,
                  result.count + bytes.count + path.count + directory.count + 100 <= D200XCodec.maximumPayloadSize else {
                throw D200XFailure.oversized
            }
            let offset = UInt32(result.count)
            let size = UInt32(bytes.count)
            let checksum = crc32(bytes)
            result.appendLE(UInt32(0x04034b50))
            result.appendLE(UInt16(20))
            result.appendLE(UInt16(0x0800))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0))
            result.appendLE(UInt16(0x0021))
            result.appendLE(checksum)
            result.appendLE(size)
            result.appendLE(size)
            result.appendLE(UInt16(path.count))
            result.appendLE(UInt16(0))
            result.append(path)
            result.append(bytes)
            directory.appendLE(UInt32(0x02014b50))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(20))
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0x0021))
            directory.appendLE(checksum)
            directory.appendLE(size)
            directory.appendLE(size)
            directory.appendLE(UInt16(path.count))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt16(0))
            directory.appendLE(UInt32(0))
            directory.appendLE(offset)
            directory.append(path)
        }
        let directoryOffset = UInt32(result.count)
        result.append(directory)
        result.appendLE(UInt32(0x06054b50))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(0))
        result.appendLE(UInt16(files.count))
        result.appendLE(UInt16(files.count))
        result.appendLE(UInt32(directory.count))
        result.appendLE(directoryOffset)
        result.appendLE(UInt16(0))
        guard result.count <= D200XCodec.maximumPayloadSize else { throw D200XFailure.oversized }
        return result
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        }
        return crc ^ UInt32.max
    }
}
