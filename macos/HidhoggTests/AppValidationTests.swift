import Darwin
import Foundation
import XCTest
import HidhoggCore
@testable import Hidhogg

final class AppValidationTests: XCTestCase {
    func testProfileIdentityAndDigestBoundaries() {
        XCTAssertTrue(ProfileValidation.isValidID("Profile-1.test_value"))
        XCTAssertTrue(ProfileValidation.isValidID(String(repeating: "a", count: 64)))
        XCTAssertFalse(ProfileValidation.isValidID(""))
        XCTAssertTrue(ProfileValidation.isValidID("1startsWithDigit"))
        XCTAssertFalse(ProfileValidation.isValidID(".startsWithPunctuation"))
        XCTAssertFalse(ProfileValidation.isValidID("bad profile"))
        XCTAssertFalse(ProfileValidation.isValidID(String(repeating: "a", count: 65)))

        XCTAssertTrue(ProfileValidation.isValidSourceDigest(String(repeating: "a", count: 64)))
        XCTAssertFalse(ProfileValidation.isValidSourceDigest(String(repeating: "A", count: 64)))
        XCTAssertFalse(ProfileValidation.isValidSourceDigest(String(repeating: "a", count: 63)))
        XCTAssertTrue(ProfileValidation.isValidPositionCoordinate("3_2"))
        XCTAssertFalse(ProfileValidation.isValidPositionCoordinate("4_2"))
        XCTAssertTrue(ProfileValidation.isValidPositionBackground("#aBc012"))
        XCTAssertTrue(ProfileValidation.isValidPositionBackground("#aBc012ef"))
        XCTAssertFalse(ProfileValidation.isValidPositionBackground("#12345g"))
        XCTAssertTrue(UUIDValidation.isCanonical("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        XCTAssertFalse(UUIDValidation.isCanonical("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
    }

    func testPositionLabelsAllowBlankButRejectInvisibleAndMalformedValues() {
        XCTAssertTrue(ProfileValidation.isValidPositionLabel(""))
        XCTAssertTrue(ProfileValidation.isValidPositionLabel("Ready"))
        XCTAssertTrue(ProfileValidation.isValidLabel("\u{0903}"))
        XCTAssertFalse(ProfileValidation.isValidLabel(""))
        XCTAssertFalse(ProfileValidation.isValidPositionLabel(" "))
        XCTAssertFalse(ProfileValidation.isValidPositionLabel("\n"))
        XCTAssertFalse(ProfileValidation.isValidPositionLabel("\u{200b}"))
        XCTAssertFalse(ProfileValidation.isValidPositionLabel(String(repeating: "😀", count: 65)))
    }

    func testPositionPatchValidationCoversFieldAndActionBoundaries() {
        let sources16 = (0..<16).map { "Source\($0)" }
        let sources17 = (0..<17).map { "Source\($0)" }
        let execute: (String, [String], Int) -> ConfiguredAction = { executable, arguments, timeout in
            .execute(executable: executable, arguments: arguments, timeoutSeconds: timeout, gesture: .press)
        }
        let typeText: (String) -> ConfiguredAction = { .typeText(text: $0, gesture: .release) }
        let keyPress: (String) -> ConfiguredAction = { .keyPress(key: $0, gesture: .release) }
        let executePatch: (String, [String], Int) -> ConfigurationPositionPatch = {
            ConfigurationPositionPatch(action: .set(execute($0, $1, $2)))
        }
        let typeTextPatch: (String) -> ConfigurationPositionPatch = {
            ConfigurationPositionPatch(action: .set(typeText($0)))
        }
        let keyPressPatch: (String) -> ConfigurationPositionPatch = {
            ConfigurationPositionPatch(action: .set(keyPress($0)))
        }
        let arguments32 = Array(repeating: "arg", count: 32)
        let arguments33 = Array(repeating: "arg", count: 33)
        let argument1024 = String(repeating: "x", count: 1_024)
        let argument1025 = String(repeating: "x", count: 1_025)
        let arguments8192 = Array(repeating: argument1024, count: 8)
        let arguments8193 = arguments8192 + ["x"]
        let text64 = String(repeating: "😀", count: 32)
        let cases: [(String, ConfigurationPositionPatch, Bool)] = [
            ("blank position label", ConfigurationPositionPatch(label: .set("")), true),
            ("64 visible emoji label", ConfigurationPositionPatch(label: .set(String(repeating: "😀", count: 64))), true),
            ("65 scalar label", ConfigurationPositionPatch(label: .set(String(repeating: "😀", count: 65))), false),
            ("whitespace-only label", ConfigurationPositionPatch(label: .set("  ")), false),
            ("control label", ConfigurationPositionPatch(label: .set("clock\u{0001}")), false),
            ("RGB background", ConfigurationPositionPatch(background: .set("#aBc012")), true),
            ("RGBA background", ConfigurationPositionPatch(background: .set("#aBc012ef")), true),
            ("short background", ConfigurationPositionPatch(background: .set("#abcde")), false),
            ("wrong alpha length", ConfigurationPositionPatch(background: .set("#123456789")), false),
            ("non-hex background", ConfigurationPositionPatch(background: .set("#12345g")), false),
            ("bottom alignment", ConfigurationPositionPatch(labelAlignment: .set("bottom")), true),
            ("center alignment", ConfigurationPositionPatch(labelAlignment: .set("center")), true),
            ("unsupported alignment", ConfigurationPositionPatch(labelAlignment: .set("top")), false),
            ("minimum label size", ConfigurationPositionPatch(labelSize: .set(8)), true),
            ("maximum label size", ConfigurationPositionPatch(labelSize: .set(32)), true),
            ("label size below range", ConfigurationPositionPatch(labelSize: .set(7)), false),
            ("label size above range", ConfigurationPositionPatch(labelSize: .set(33)), false),
            ("one source", ConfigurationPositionPatch(notificationSources: .set(["Calendar"])), true),
            ("16 sources", ConfigurationPositionPatch(notificationSources: .set(sources16)), true),
            ("empty source set", ConfigurationPositionPatch(notificationSources: .set([])), false),
            ("17 sources", ConfigurationPositionPatch(notificationSources: .set(sources17)), false),
            ("invalid source ID", ConfigurationPositionPatch(notificationSources: .set(["bad source"])), false),
            ("duplicate source IDs", ConfigurationPositionPatch(notificationSources: .set(["Calendar", "Calendar"])), false),
            ("execute with no arguments", executePatch("/usr/bin/example", [], 10), true),
            ("execute with 32 arguments", executePatch("/usr/bin/example", arguments32, 10), true),
            ("execute with 33 arguments", executePatch("/usr/bin/example", arguments33, 10), false),
            ("1024-byte argument", executePatch("/usr/bin/example", [argument1024], 10), true),
            ("1025-byte argument", executePatch("/usr/bin/example", [argument1025], 10), false),
            ("8192 aggregate argument bytes", executePatch("/usr/bin/example", arguments8192, 10), true),
            ("8193 aggregate argument bytes", executePatch("/usr/bin/example", arguments8193, 10), false),
            ("NUL argument", executePatch("/usr/bin/example", ["bad\0arg"], 10), false),
            ("NUL executable", executePatch("/usr/bin/\0example", [], 10), false),
            ("absolute path with slash-leading combining mark", executePatch("/\u{0301}tool", [], 10), true),
            ("minimum execute timeout", executePatch("/usr/bin/example", [], 1), true),
            ("maximum execute timeout", executePatch("/usr/bin/example", [], 60), true),
            ("zero execute timeout", executePatch("/usr/bin/example", [], 0), false),
            ("execute timeout above range", executePatch("/usr/bin/example", [], 61), false),
            ("64 UTF-16-unit text", typeTextPatch(text64), true),
            ("65 UTF-16-unit text", typeTextPatch(text64 + "a"), false),
            ("empty text", typeTextPatch(""), false),
            ("NUL text", typeTextPatch("bad\0text"), false),
            ("supported key", keyPressPatch("enter"), true),
            ("unsupported key", keyPressPatch("escape"), false)
        ]

        for (name, patch, expected) in cases {
            XCTAssertEqual(ProfileValidation.isValidPositionPatch(patch), expected, name)
        }
    }
}

final class PathSecurityTests: XCTestCase {
    func testSocketPathLimitIncludesTerminatingNul() {
        XCTAssertNoThrow(try PathSecurity.validateEncodedSocketPath(String(repeating: "a", count: 103)))
        XCTAssertThrowsError(try PathSecurity.validateEncodedSocketPath(String(repeating: "a", count: 104)))
    }

    func testGenerationDirectoryIsOwnerOnlyAndRemovable() throws {
        let root = URL(fileURLWithPath: "/tmp/hh-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try PathSecurity.createGenerationDirectory(root: root, directoryName: "generation")
        XCTAssertEqual(try PathSecurity.validateGenerationDirectory(result.url), result.identity)
        try PathSecurity.removeMatchingGeneration(
            directory: result.url,
            directoryIdentity: result.identity,
            socket: result.url.appendingPathComponent("runtime.sock"),
            socketIdentity: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.url.path))
    }

    func testDefaultFactoryUsesLiteralProductionRootAndBoundedGenerationPath() throws {
        let factory = DefaultGenerationDirectoryFactory(uuidProvider: FixedPathUUIDProvider())
        XCTAssertEqual(factory.root.path, "/private/tmp")
        XCTAssertEqual(factory.rootPolicy, .productionPrivateTemporary)

        let generation = try factory.create(instanceID: FixedPathUUIDProvider.instanceID)
        defer {
            _ = try? PathSecurity.removeMatchingGeneration(
                directory: generation.directory,
                directoryIdentity: generation.directoryIdentity,
                socket: generation.socket,
                socketIdentity: nil
            )
        }

        XCTAssertTrue(generation.directory.lastPathComponent.hasPrefix("hidhogg-\(geteuid())-"))
        XCTAssertEqual(generation.directory.lastPathComponent, "hidhogg-\(geteuid())-12345678-1234-4234-8234-123456789abc")
        XCTAssertLessThanOrEqual(generation.socket.path.utf8.count + 1, PathSecurity.unixPathBytes)
        XCTAssertNoThrow(try PathSecurity.validateGenerationRoot(factory.root, policy: .productionPrivateTemporary))
    }

    func testOverlongGenerationSocketPathFailsBeforeRootLookup() {
        let root = URL(fileURLWithPath: "/private/tmp/\(String(repeating: "x", count: 100))", isDirectory: true)
        let factory = DefaultGenerationDirectoryFactory(
            root: root,
            uuidProvider: FixedPathUUIDProvider(),
            rootPolicy: .injected
        )

        XCTAssertThrowsError(try factory.create(instanceID: FixedPathUUIDProvider.instanceID)) { error in
            XCTAssertEqual(error as? PathSecurityError, .pathTooLong)
        }
    }
}

private struct FixedPathUUIDProvider: UUIDProviding, Sendable {
    static let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let value = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!

    func makeUUID() -> UUID { value }
}
