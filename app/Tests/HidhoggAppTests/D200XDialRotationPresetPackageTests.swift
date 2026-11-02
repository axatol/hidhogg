import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggApp

final class D200XDialRotationPresetPackageTests: XCTestCase {
    func testStrictRotationEnvelopeRoundTripsNativeExecutableAndShortcutSnapshots() throws {
        let preset = D200XDialRotationPreset(name: "Mixed", left: .action("custom"), right: .action("bell"),
            actions: ["custom": .init(executable: "/synthetic/action", arguments: ["literal"])],
            nativeActions: ["bell": .init(kind: .bell)])
        let package = D200XDialRotationPresetPackage(preset: preset)
        XCTAssertEqual(try D200XDialRotationPresetPackage.decode(package.encoded()), package)
        let shortcuts = D200XDialRotationPresetPackage(preset: .init(name: "Shortcuts",
            left: .key(.init(keyCode: 0, modifiers: [.command])), right: .disabled))
        XCTAssertEqual(try D200XDialRotationPresetPackage.decode(shortcuts.encoded()), shortcuts)
    }

    func testRejectsWrongKindVersionImageAndUnknownNestedFields() throws {
        let preset = D200XDialRotationPreset(name: "Bell", left: .action("bell"), right: .disabled,
            nativeActions: ["bell": .init(kind: .bell)])
        let data = try D200XDialRotationPresetPackage(preset: preset).encoded()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("kind", "tile" as Any), ("version", 2 as Any), ("image", "AA==" as Any), ("unexpected", true as Any)] {
            var object = original
            object[key] = value
            XCTAssertThrowsError(try D200XDialRotationPresetPackage.decode(JSONSerialization.data(withJSONObject: object)))
        }
        for key in ["kind", "version", "preset"] {
            var object = original
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try D200XDialRotationPresetPackage.decode(JSONSerialization.data(withJSONObject: object)))
        }
        var object = original
        var nested = try XCTUnwrap(object["preset"] as? [String: Any])
        nested["appearance"] = [:] as [String: Any]
        object["preset"] = nested
        XCTAssertThrowsError(try D200XDialRotationPresetPackage.decode(JSONSerialization.data(withJSONObject: object)))
        for field in ["left", "right", "nativeActions"] {
            object = original
            nested = try XCTUnwrap(object["preset"] as? [String: Any])
            var child = try XCTUnwrap(nested[field] as? [String: Any])
            if field == "nativeActions" {
                var action = try XCTUnwrap(child["bell"] as? [String: Any])
                action["unexpected"] = true
                child["bell"] = action
            } else { child["unexpected"] = true }
            nested[field] = child
            object["preset"] = nested
            XCTAssertThrowsError(try D200XDialRotationPresetPackage.decode(JSONSerialization.data(withJSONObject: object)))
        }
        XCTAssertThrowsError(try D200XDialRotationPresetPackage.decode(Data(repeating: 0, count: D200XDialRotationPresetPackage.maximumBytes + 1)))
    }

    func testReadAcceptsRegularPackageAndRejectsSymlinkDirectoryAndOversize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rotation.json")
        let package = D200XDialRotationPresetPackage(preset: .init(name: "None", left: .disabled, right: .disabled))
        try package.encoded().write(to: url)
        XCTAssertEqual(try D200XDialRotationPresetPackage.read(from: url), package)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try D200XDialRotationPresetPackage.read(from: link))
        XCTAssertThrowsError(try D200XDialRotationPresetPackage.read(from: root))
        try Data(repeating: 0, count: D200XDialRotationPresetPackage.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try D200XDialRotationPresetPackage.read(from: url))
    }
}
