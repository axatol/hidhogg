import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class ConfigurationStoreTests: XCTestCase {
    func testMissingFileLoadsDefaultsWithoutCreatingFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)

        let snapshot = try await store.load()

        XCTAssertEqual(snapshot.configuration, .empty)
        XCTAssertEqual(snapshot.revision, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSaveReloadUsesExactRevisionAndPrivatePermissions() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private/config.toml")
        let store = ConfigurationStore(url: url)
        let saved = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let loaded = try await store.load()
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)

        XCTAssertEqual(saved.configuration, ConfigurationFixtures.configuration)
        XCTAssertTrue(saved.revision.exists)
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["config.toml"])
    }

    func testSaveRejectsStaleMissingRevisionAndPreservesExternalBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        _ = try await store.load()
        let externalBytes = ConfigurationFixtures.data("unrecognized = true\n")
        try externalBytes.write(to: url)

        do {
            _ = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
            XCTFail("Expected stale revision to be rejected")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .revisionConflict)
        }

        XCTAssertEqual(try Data(contentsOf: url), externalBytes)
    }

    func testRevisionDetectsSameLengthExternalByteChanges() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let originalBytes = try ConfigurationCodec.encode(ConfigurationFixtures.configuration)
        try originalBytes.write(to: url)
        let loaded = try await store.load()
        let changedBytes = ConfigurationFixtures.data(
            String(decoding: originalBytes, as: UTF8.self).replacingOccurrences(
                of: "key_code = 4",
                with: "key_code = 5"
            )
        )
        XCTAssertEqual(changedBytes.count, originalBytes.count)
        try changedBytes.write(to: url)

        do {
            _ = try await store.save(ConfigurationFixtures.configuration, expecting: loaded.revision)
            XCTFail("Expected byte-level revision change to be rejected")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .revisionConflict)
        }

        XCTAssertEqual(try Data(contentsOf: url), changedBytes)
    }

    func testLoadRejectsInvalidFileWithoutChangingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let invalidBytes = ConfigurationFixtures.data(
            ConfigurationFixtures.toml.replacingOccurrences(
                of: "schema_version = 1",
                with: "schema_version = 2"
            )
        )
        try invalidBytes.write(to: url)

        do {
            _ = try await store.load()
            XCTFail("Expected unsupported document version")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .unsupportedVersion(2))
        }

        XCTAssertEqual(try Data(contentsOf: url), invalidBytes)
    }

    func testInvalidSaveDoesNotChangeExistingFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let originalBytes = try ConfigurationCodec.encode(ConfigurationFixtures.configuration)
        try originalBytes.write(to: url)
        let loaded = try await store.load()
        let invalid = AppConfiguration(devices: [
            DeviceBindings(id: AppConfiguration.logitechProfileID, defaults: ["back": .disabled])
        ])

        do {
            _ = try await store.save(invalid, expecting: loaded.revision)
            XCTFail("Expected invalid configuration to be rejected")
        } catch let error as ConfigurationError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Expected domain validation error, received \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    func testLoadRejectsFilesOverTheLimitWithoutChangingThem() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let oversizedBytes = Data(repeating: 32, count: ConfigurationCodec.maximumFileSize + 1)
        try oversizedBytes.write(to: url)

        do {
            _ = try await store.load()
            XCTFail("Expected oversized document to be rejected")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .fileTooLarge)
        }

        XCTAssertEqual(try Data(contentsOf: url), oversizedBytes)
    }

    func testRejectsSymlinkedConfigurationFileAndDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.toml")
        let targetBytes = ConfigurationFixtures.data("leave unchanged\n")
        try targetBytes.write(to: target)

        let fileLink = root.appendingPathComponent("file-link.toml")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: target)
        do {
            _ = try await ConfigurationStore(url: fileLink).load()
            XCTFail("Expected symlinked file to be rejected")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .symbolicLinkNotAllowed)
        }

        let directoryTarget = root.appendingPathComponent("directory-target", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
        let directoryLink = root.appendingPathComponent("directory-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directoryTarget)
        do {
            _ = try await ConfigurationStore(url: directoryLink.appendingPathComponent("config.toml")).load()
            XCTFail("Expected symlinked directory to be rejected")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .symbolicLinkNotAllowed)
        }

        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("HidhoggConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
