import Darwin
import Foundation
import XCTest
@testable import HidhoggCore

final class ConfigurationStoreTests: XCTestCase {
    func testDigestUsesExactSourceBytes() {
        XCTAssertEqual(ConfigurationStore.digest(Data("abc".utf8)).description,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNotEqual(ConfigurationStore.digest(Data("x\n".utf8)), ConfigurationStore.digest(Data("x\r\n".utf8)))
    }

    func testApplyCommitsValidatedBytesAndReturnsIndependentCopy() throws {
        let (directory, path) = try temporaryConfiguration()
        let source = storeFixture
        try source.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        let expected = try ConfigurationEditor.setProfileLabel(in: source, profileID: "default", label: "Edited")

        let result = try ConfigurationStore.apply(at: path.path, expectedDigest: ConfigurationStore.digest(source)) { input in
            var independent = input
            independent[0] = 0
            XCTAssertEqual(try Data(contentsOf: path), source)
            return expected
        }
        XCTAssertEqual(result.outcome, .committed)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.digest, ConfigurationStore.digest(expected))
        XCTAssertEqual(result.bytes, expected)
        XCTAssertEqual(try HidhoggConfigurationDecoder.decode(result.bytes).profile(id: "default")?.label, "Edited")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber, 0o640)

        var resultCopy = result.bytes
        resultCopy[0] = 0
        XCTAssertEqual(try Data(contentsOf: path), expected)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { !$0.hasPrefix(".hidhogg-config-") })
    }

    func testIdenticalMutationKeepsInodeModeAndModificationTimeWithoutTemporaryFile() throws {
        let (directory, path) = try temporaryConfiguration()
        try storeFixture.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: path.path)
        let before = try FileManager.default.attributesOfItem(atPath: path.path)
        var fileSystem = ConfigurationStoreFileSystem()
        fileSystem.createTemporary = { _ in XCTFail("no-op must not create a temporary file"); return nil }

        let result = try ConfigurationStore.apply(
            at: path.path,
            expectedDigest: ConfigurationStore.digest(storeFixture),
            mutate: { Data($0) },
            fileSystem: fileSystem
        )
        let after = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual(result.outcome, .unchanged)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.digest, ConfigurationStore.digest(storeFixture))
        XCTAssertTrue(result.bytes.isEmpty)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.posixPermissions] as? NSNumber, after[.posixPermissions] as? NSNumber)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [path.lastPathComponent])
    }

    func testStaleDigestSkipsCallbackAndCallbackNoOpRechecksSource() throws {
        let (_, path) = try temporaryConfiguration()
        try storeFixture.write(to: path)
        let external = Data((String(decoding: storeFixture, as: UTF8.self) + "# external edit\n").utf8)
        var callbackCalled = false
        try external.write(to: path)
        XCTAssertThrowsError(try ConfigurationStore.apply(at: path.path, expectedDigest: ConfigurationStore.digest(storeFixture)) { _ in
            callbackCalled = true
            return storeFixture
        }) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .stale)
        }
        XCTAssertFalse(callbackCalled)

        try storeFixture.write(to: path)
        XCTAssertThrowsError(try ConfigurationStore.apply(at: path.path, expectedDigest: ConfigurationStore.digest(storeFixture)) { input in
            try external.write(to: path)
            return input
        }) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .stale)
        }
        XCTAssertEqual(try Data(contentsOf: path), external)
    }

    func testInvalidOriginalConfigurationIsRejectedBeforeCallback() throws {
        let (directory, path) = try temporaryConfiguration()
        let invalid = Data("schema_version = 4\n".utf8)
        try invalid.write(to: path)
        var callbackCalled = false
        var fileSystem = ConfigurationStoreFileSystem()
        fileSystem.createTemporary = { _ in XCTFail("invalid original must not stage a file"); return nil }

        XCTAssertThrowsError(try ConfigurationStore.apply(
            at: path.path,
            expectedDigest: ConfigurationStore.digest(invalid),
            mutate: { source in
                callbackCalled = true
                return source
            },
            fileSystem: fileSystem
        )) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .invalidConfiguration)
        }
        XCTAssertFalse(callbackCalled)
        XCTAssertEqual(try Data(contentsOf: path), invalid)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [path.lastPathComponent])
    }

    func testChangeBetweenInitialAndSecondDigestChecksIsNotOverwritten() throws {
        let (directory, path) = try temporaryConfiguration()
        try storeFixture.write(to: path)
        let external = Data((String(decoding: storeFixture, as: UTF8.self) + "# external edit\n").utf8)
        var fileSystem = ConfigurationStoreFileSystem()
        let createTemporary = fileSystem.createTemporary
        fileSystem.createTemporary = { parent in
            try? external.write(to: path)
            return createTemporary(parent)
        }

        XCTAssertThrowsError(try ConfigurationStore.apply(
            at: path.path,
            expectedDigest: ConfigurationStore.digest(storeFixture),
            mutate: editLabel,
            fileSystem: fileSystem
        )) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .stale)
        }
        XCTAssertEqual(try Data(contentsOf: path), external)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [path.lastPathComponent])
    }

    func testInvalidProspectiveSourceAndMutationErrorsAreSanitized() throws {
        let (directory, path) = try temporaryConfiguration()
        try storeFixture.write(to: path)
        let sentinel = "SYNTHETIC_STORE_SENTINEL"

        XCTAssertThrowsError(try ConfigurationStore.apply(at: path.path, expectedDigest: ConfigurationStore.digest(storeFixture)) { _ in
            Data("schema_version = 3 # \(sentinel)".utf8)
        }) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .invalidConfiguration)
            XCTAssertFalse(error.localizedDescription.contains(sentinel))
            XCTAssertFalse(error.localizedDescription.contains(path.path))
        }
        XCTAssertThrowsError(try ConfigurationStore.apply(at: path.path, expectedDigest: ConfigurationStore.digest(storeFixture)) { _ in
            throw NSError(domain: sentinel, code: 99, userInfo: [NSLocalizedDescriptionKey: path.path])
        }) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .mutationFailed)
            XCTAssertFalse(error.localizedDescription.contains(sentinel))
            XCTAssertFalse(error.localizedDescription.contains(path.path))
        }
        XCTAssertEqual(try Data(contentsOf: path), storeFixture)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [path.lastPathComponent])
    }

    func testRejectsDirectoryAndSymlinkDestinations() throws {
        let (directory, target) = try temporaryConfiguration()
        try storeFixture.write(to: target)
        XCTAssertThrowsError(try ConfigurationStore.apply(at: directory.path, expectedDigest: ConfigurationStore.digest(storeFixture), mutate: editLabel)) {
            XCTAssertEqual($0 as? ConfigurationStoreError, .invalidDestination)
        }

        let link = directory.appendingPathComponent("config-link.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ConfigurationStore.apply(at: link.path, expectedDigest: ConfigurationStore.digest(storeFixture), mutate: editLabel)) {
            XCTAssertEqual($0 as? ConfigurationStoreError, .invalidDestination)
        }
        XCTAssertEqual(try Data(contentsOf: target), storeFixture)
    }

    func testDetectsOpenIdentityMismatch() throws {
        let (directory, path) = try temporaryConfiguration()
        let alternate = directory.appendingPathComponent("alternate.toml")
        try storeFixture.write(to: path)
        try storeFixture.write(to: alternate)
        var fileSystem = ConfigurationStoreFileSystem()
        fileSystem.openRead = { _ in Darwin.open(alternate.path, O_RDONLY | O_CLOEXEC) }
        XCTAssertThrowsError(try ConfigurationStore.apply(
            at: path.path,
            expectedDigest: ConfigurationStore.digest(storeFixture),
            mutate: editLabel,
            fileSystem: fileSystem
        )) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .stale)
        }
        XCTAssertEqual(try Data(contentsOf: path), storeFixture)
    }

    func testDetectsIdentityChangeAfterRead() throws {
        let (directory, path) = try temporaryConfiguration()
        let alternate = directory.appendingPathComponent("alternate.toml")
        let external = Data((String(decoding: storeFixture, as: UTF8.self) + "# external identity\n").utf8)
        try storeFixture.write(to: path)
        try external.write(to: alternate)
        var fileSystem = ConfigurationStoreFileSystem()
        let originalLstat = fileSystem.lstat
        var lstatCount = 0
        fileSystem.lstat = { filePath in
            lstatCount += 1
            if lstatCount == 2 { _ = Darwin.rename(alternate.path, filePath) }
            return originalLstat(filePath)
        }

        XCTAssertThrowsError(try ConfigurationStore.apply(
            at: path.path,
            expectedDigest: ConfigurationStore.digest(storeFixture),
            mutate: editLabel,
            fileSystem: fileSystem
        )) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .stale)
        }
        XCTAssertEqual(try Data(contentsOf: path), external)
    }

    func testPreRenameFaultsCleanTemporaryAndPreserveSource() throws {
        for fault in ["create", "write", "chmod", "file-sync", "file-close", "rename"] {
            let (directory, path) = try temporaryConfiguration()
            try storeFixture.write(to: path)
            var fileSystem = ConfigurationStoreFileSystem()
            var temporaryDescriptor: Int32?
            let createTemporary = fileSystem.createTemporary
            let originalWrite = fileSystem.write
            let originalChmod = fileSystem.chmod
            let originalSync = fileSystem.sync
            let originalClose = fileSystem.close
            let originalRename = fileSystem.rename
            var writeCount = 0

            fileSystem.createTemporary = { parent in
                guard fault != "create" else { return nil }
                let created = createTemporary(parent)
                temporaryDescriptor = created?.descriptor
                return created
            }
            fileSystem.write = { descriptor, bytes, count in
                if fault == "write" {
                    writeCount += 1
                    if writeCount == 1 { return originalWrite(descriptor, bytes, max(1, count / 2)) }
                    errno = EIO
                    return -1
                }
                return originalWrite(descriptor, bytes, count)
            }
            fileSystem.chmod = { descriptor, mode in
                fault == "chmod" ? false : originalChmod(descriptor, mode)
            }
            fileSystem.sync = { descriptor in
                fault == "file-sync" ? false : originalSync(descriptor)
            }
            fileSystem.close = { descriptor in
                let closed = originalClose(descriptor)
                if fault == "file-close", descriptor == temporaryDescriptor { return false }
                return closed
            }
            fileSystem.rename = { oldPath, newPath in
                fault == "rename" ? false : originalRename(oldPath, newPath)
            }

            XCTAssertThrowsError(try ConfigurationStore.apply(
                at: path.path,
                expectedDigest: ConfigurationStore.digest(storeFixture),
                mutate: editLabel,
                fileSystem: fileSystem
            )) { error in
                XCTAssertEqual(error as? ConfigurationStoreError, .diskFailure, "fault: \(fault)")
                XCTAssertFalse(error.localizedDescription.contains(path.path))
            }
            XCTAssertEqual(try Data(contentsOf: path), storeFixture, "fault: \(fault)")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [path.lastPathComponent], "fault: \(fault)")
        }
    }

    func testDestinationReadFaultsReturnSafeStorageErrors() throws {
        for fault in ["open", "fstat", "read", "close"] {
            let (_, path) = try temporaryConfiguration()
            try storeFixture.write(to: path)
            var fileSystem = ConfigurationStoreFileSystem()
            let originalOpen = fileSystem.openRead
            let originalFstat = fileSystem.fstat
            let originalRead = fileSystem.read
            let originalClose = fileSystem.close
            var injectedDescriptor: Int32?
            fileSystem.openRead = { filePath in
                if fault == "open" { return nil }
                guard let descriptor = originalOpen(filePath) else { return nil }
                injectedDescriptor = descriptor
                return descriptor
            }
            fileSystem.fstat = { descriptor in
                fault == "fstat" ? nil : originalFstat(descriptor)
            }
            fileSystem.read = { descriptor, buffer, count in
                if fault == "read" { errno = EIO; return -1 }
                return originalRead(descriptor, buffer, count)
            }
            fileSystem.close = { descriptor in
                let closed = originalClose(descriptor)
                if fault == "close", descriptor == injectedDescriptor { return false }
                return closed
            }

            XCTAssertThrowsError(try ConfigurationStore.apply(
                at: path.path,
                expectedDigest: ConfigurationStore.digest(storeFixture),
                mutate: editLabel,
                fileSystem: fileSystem
            )) { error in
                XCTAssertEqual(error as? ConfigurationStoreError, .diskFailure)
                XCTAssertFalse(error.localizedDescription.contains(path.path))
            }
            XCTAssertEqual(try Data(contentsOf: path), storeFixture)
        }
    }

    func testParentSyncAndCloseFailuresReturnUncertainCommittedBytesWithoutRollback() throws {
        for fault in ["directory-sync", "directory-close", "directory-open"] {
            let (_, path) = try temporaryConfiguration()
            try storeFixture.write(to: path)
            let expected = try ConfigurationEditor.setProfileLabel(in: storeFixture, profileID: "default", label: "Edited")
            var fileSystem = ConfigurationStoreFileSystem()
            let originalSync = fileSystem.sync
            let originalOpenDirectory = fileSystem.openDirectory
            let originalClose = fileSystem.close
            var directoryDescriptor: Int32?
            fileSystem.openDirectory = { directory in
                guard fault != "directory-open" else { return nil }
                let descriptor = originalOpenDirectory(directory)
                directoryDescriptor = descriptor
                return descriptor
            }
            fileSystem.sync = { descriptor in
                fault == "directory-sync" && descriptor == directoryDescriptor
                    ? false
                    : originalSync(descriptor)
            }
            fileSystem.close = { descriptor in
                let closed = originalClose(descriptor)
                if fault == "directory-close", descriptor == directoryDescriptor { return false }
                return closed
            }

            let result = try ConfigurationStore.apply(
                at: path.path,
                expectedDigest: ConfigurationStore.digest(storeFixture),
                mutate: editLabel,
                fileSystem: fileSystem
            )
            XCTAssertEqual(result.outcome, .uncertain)
            XCTAssertEqual(result.error, .uncertain)
            XCTAssertEqual(result.bytes, expected)
            XCTAssertEqual(result.digest, ConfigurationStore.digest(expected))
            XCTAssertEqual(try Data(contentsOf: path), expected)
        }
    }

    private var storeFixture: Data {
        Data("""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        default_profile_id = "default"

        [profiles.default]
        label = "Default"
        positions = { "0_0" = { label = "Clock" } }

        [profiles.other]
        label = "Other"
        """.utf8)
    }

    private func editLabel(_ source: Data) throws -> Data {
        try ConfigurationEditor.setProfileLabel(in: source, profileID: "default", label: "Edited")
    }

    private func temporaryConfiguration() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-store-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("config.toml")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, path)
    }
}
