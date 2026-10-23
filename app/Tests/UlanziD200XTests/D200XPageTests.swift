import Foundation
import Testing
@testable import UlanziD200X

let syntheticPNG = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])

private func word(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
}

private func integer(_ bytes: [UInt8], _ offset: Int) -> Int {
    word(bytes, offset) | word(bytes, offset + 2) << 16
}

private func unzipStored(_ archive: Data) throws -> [String: Data] {
    let bytes = [UInt8](archive)
    var result: [String: Data] = [:]
    var offset = 0
    while integer(bytes, offset) == 0x04034b50 {
        #expect(word(bytes, offset + 8) == 0)
        let size = integer(bytes, offset + 18)
        #expect(integer(bytes, offset + 22) == size)
        let nameLength = word(bytes, offset + 26)
        let extraLength = word(bytes, offset + 28)
        let name = String(decoding: bytes[offset + 30..<offset + 30 + nameLength], as: UTF8.self)
        let start = offset + 30 + nameLength + extraLength
        let content = Data(bytes[start..<start + size])
        #expect(Int(D200XStoredZIP.crc32(content)) == integer(bytes, offset + 14))
        result[name] = content
        offset = start + size
    }
    #expect(integer(bytes, offset) == 0x02014b50)
    let end = bytes.count - 22
    #expect(integer(bytes, end) == 0x06054b50)
    #expect(word(bytes, end + 10) == result.count)
    #expect(integer(bytes, end + 16) == offset)
    #expect(integer(bytes, end + 12) == end - offset)
    var central = offset
    while central < end {
        #expect(integer(bytes, central) == 0x02014b50)
        let local = integer(bytes, central + 42)
        #expect(integer(bytes, local) == 0x04034b50)
        #expect(integer(bytes, central + 16) == integer(bytes, local + 14))
        let nameLength = word(bytes, central + 28)
        #expect(Array(bytes[central + 46..<central + 46 + nameLength]) == Array(bytes[local + 30..<local + 30 + nameLength]))
        central += 46 + nameLength + word(bytes, central + 30) + word(bytes, central + 32)
    }
    #expect(central == end)
    return result
}

struct D200XPageTests {
    @Test func archiveContainsManifestAndContentNamedAssets() throws {
        let page = D200XPage(slots: [
            "0_0": D200XSlot(image: syntheticPNG, text: "first"),
            "3_2": D200XSlot(image: syntheticPNG, text: "wide"),
        ])
        let bytes = try page.archive()
        #expect(try page.archive() == bytes)
        let files = try unzipStored(bytes)
        #expect(files.count == 2)
        let manifest = try #require(files["manifest.json"])
        let decoded = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: [String: Any]])
        #expect(Set(decoded.keys) == ["0_0", "3_2"])
        let views = try #require(decoded["0_0"]?["ViewParam"] as? [[String: Any]])
        let icon = try #require(views.first?["Icon"] as? String)
        #expect(files[icon] == syntheticPNG)
        #expect(icon.hasPrefix("Images/"))
        #expect(icon.count == "Images/".count + 64 + ".png".count)
        #expect(views.first?["Text"] as? String == "first")
        let changed = try unzipStored(D200XPage(slots: ["0_0": D200XSlot(image: syntheticPNG + Data([4]))]).archive())
        #expect(Set(changed.keys) != Set(files.keys))
    }

    @Test func emptyPageAndInvalidCoordinates() throws {
        let files = try unzipStored(D200XPage(slots: [:]).archive())
        #expect(files["manifest.json"] == Data("{}".utf8))
        #expect(throws: D200XFailure.invalidPage) {
            try D200XPage(slots: ["4_2": D200XSlot(image: syntheticPNG)]).archive()
        }
        #expect(throws: D200XFailure.invalidPage) {
            try D200XPage(slots: ["../../escape": D200XSlot(image: syntheticPNG)]).archive()
        }
        #expect(throws: D200XFailure.invalidPage) {
            try D200XPage(slots: ["0_0": D200XSlot(image: Data([1]))]).archive()
        }
        #expect(D200XStoredZIP.crc32(Data("123456789".utf8)) == 0xcbf43926)
    }
}
