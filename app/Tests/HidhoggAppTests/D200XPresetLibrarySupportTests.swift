import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggApp

final class D200XPresetLibrarySupportTests: XCTestCase {
    func testAssignmentContextCapturesControlOrPairedDialAndProfile() {
        let tile = D200XPresetAssignmentContext(control: .key3, applicationID: "com.example.Editor")
        XCTAssertEqual(tile.target, .control(.key3))
        XCTAssertTrue(tile.matches(control: .key3, applicationID: "com.example.Editor"))
        XCTAssertFalse(tile.matches(control: .key4, applicationID: "com.example.Editor"))
        XCTAssertFalse(tile.matches(control: .key3, applicationID: nil))

        let rotation = D200XPresetAssignmentContext(control: .dial1Left, applicationID: nil)
        XCTAssertEqual(rotation.target, .dialRotation(1))
        XCTAssertTrue(rotation.matches(control: .dial1Right, applicationID: nil))
        XCTAssertTrue(rotation.matches(control: .dial1Press, applicationID: nil))
        XCTAssertFalse(rotation.matches(control: .dial0Right, applicationID: nil))
        XCTAssertFalse(rotation.matches(control: .dial1Right, applicationID: "com.example.Editor"))

        let press = D200XPresetAssignmentContext(control: .dial1Press, applicationID: nil)
        XCTAssertEqual(press.target, .control(.dial1Press))
        XCTAssertFalse(press.matches(control: .dial1Left, applicationID: nil))
    }

    func testImportDispatcherRoutesLegacyTileAndStrictDialPackages() throws {
        let assetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tile = D200XTilePresetPackage(preset: .init(name: "Blank", appearance: .init(label: "Blank")), image: nil)
        let tileData = try tile.encoded()
        guard case .tile(let decodedTile) = try D200XPresetImportPackage.decode(tileData, assetDirectory: assetDirectory).package else {
            return XCTFail("Expected a tile preset package")
        }
        XCTAssertEqual(decodedTile, tile)

        let rotation = D200XDialRotationPresetPackage(preset: .init(name: "Volume", left: .disabled, right: .disabled))
        let rotationData = try rotation.encoded()
        guard case .dialRotation(let decodedRotation) = try D200XPresetImportPackage.decode(rotationData, assetDirectory: assetDirectory).package else {
            return XCTFail("Expected a dial rotation preset package")
        }
        XCTAssertEqual(decodedRotation, rotation)

        let unsupportedKind = try JSONSerialization.data(withJSONObject: ["kind": "unsupported"])
        XCTAssertThrowsError(try D200XPresetImportPackage.decode(unsupportedKind, assetDirectory: assetDirectory))
    }

    func testImportDispatcherRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let package = D200XTilePresetPackage(preset: .init(name: "Blank", appearance: .init(label: "Blank")), image: nil)
        let regularFile = directory.appendingPathComponent("preset.json")
        let symbolicLink = directory.appendingPathComponent("linked-preset.json")
        try package.encoded().write(to: regularFile)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: regularFile)

        XCTAssertThrowsError(try D200XPresetImportPackage.read(from: symbolicLink, assetDirectory: directory))
    }

    func testGeneratedPresetIdentifiersAreValidAndDistinct() {
        let first = D200XPresetIdentifier.generated()
        let second = D200XPresetIdentifier.generated()

        XCTAssertTrue(ConfiguredExecutable.isValidIdentifier(first))
        XCTAssertTrue(ConfiguredExecutable.isValidIdentifier(second))
        XCTAssertNotEqual(first, second)
    }
}
