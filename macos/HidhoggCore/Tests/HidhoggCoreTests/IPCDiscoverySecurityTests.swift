import Darwin
import Foundation
import XCTest
@testable import HidhoggCore

final class IPCDiscoverySecurityTests: XCTestCase {
    func testResolveUsesNoFollowFlagsAndAcceptsOnlySyntheticOwnedSocketIdentity() throws {
        let fixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let liveOpen = fixture.operations.open
        let flags = IPCOpenFlagRecorder()
        var operations = fixture.operations
        operations.open = { path, openFlags, mode in
            flags.record(path: path, flags: openFlags)
            return liveOpen(path, openFlags, mode)
        }

        let resolved = try IPCRuntimeDiscovery.resolve(fixture.directory.path, operations: operations)

        XCTAssertEqual(resolved.metadata.instanceID, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(flags.paths, [fixture.directory.path, fixture.paths.metadataPath])
        XCTAssertTrue(flags.values.allSatisfy { $0 & O_NOFOLLOW != 0 })
        XCTAssertEqual(resolved.socketIdentity.inode, 91)
    }

    func testResolveRejectsInsecureDirectoryAndFileModes() throws {
        let directoryFixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: directoryFixture.directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directoryFixture.directory.path)
        XCTAssertThrowsError(try IPCRuntimeDiscovery.resolve(directoryFixture.directory.path, operations: directoryFixture.operations)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .insecureRuntimeDirectory)
        }

        let metadataFixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: metadataFixture.directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: metadataFixture.paths.metadataPath)
        XCTAssertThrowsError(try IPCRuntimeDiscovery.resolve(metadataFixture.directory.path, operations: metadataFixture.operations)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .invalidMetadata)
        }
    }

    func testResolveRejectsDirectoryAndMetadataSymlinks() throws {
        let directoryFixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: directoryFixture.directory) }
        let directoryLink = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("hgipc-link-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryLink) }
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directoryFixture.directory)
        XCTAssertThrowsError(try IPCRuntimeDiscovery.resolve(directoryLink.path, operations: directoryFixture.operations)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .insecureRuntimeDirectory)
        }

        let metadataFixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: metadataFixture.directory) }
        let target = metadataFixture.directory.appendingPathComponent("target.json")
        try Data("synthetic".utf8).write(to: target)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: metadataFixture.paths.metadataPath))
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: metadataFixture.paths.metadataPath),
            withDestinationURL: target
        )
        XCTAssertThrowsError(try IPCRuntimeDiscovery.resolve(metadataFixture.directory.path, operations: metadataFixture.operations)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .invalidMetadata)
        }
    }

    func testResolveRejectsSocketTypeOrOwnerMismatch() throws {
        let wrongType = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: wrongType.directory) }
        let wrongTypeOperations = IPCTestRuntimeFixture.operations(paths: wrongType.paths, socketMode: mode_t(S_IFREG | 0o600))
        XCTAssertThrowsError(try IPCRuntimeDiscovery.resolve(wrongType.directory.path, operations: wrongTypeOperations)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .invalidSocket)
        }

        let wrongOwner = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: wrongOwner.directory) }
        let wrongOwnerOperations = IPCTestRuntimeFixture.operations(paths: wrongOwner.paths, socketUserID: UInt32(geteuid()) &+ 1)
        XCTAssertThrowsError(try IPCRuntimeDiscovery.resolve(wrongOwner.directory.path, operations: wrongOwnerOperations)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .invalidSocket)
        }
    }

    func testMetadataMustKeepItsIdentityAcrossRead() throws {
        let fixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let liveRead = fixture.operations.read
        let replaced = IPCOnceFlag()
        var operations = fixture.operations
        operations.read = { descriptor, bytes, count in
            let result = liveRead(descriptor, bytes, count)
            if result.value > 0, replaced.setOnce() {
                let replacement = try? IPCMetadata(
                    schemaVersion: 1,
                    instanceID: "22222222-2222-4222-8222-222222222222",
                    socketName: "runtime.sock"
                ).encode()
                if let replacement {
                    try? Self.replaceFile(at: URL(fileURLWithPath: fixture.paths.metadataPath), with: replacement)
                }
            }
            return result
        }

        XCTAssertThrowsError(try IPCRuntimeDiscovery.resolve(fixture.directory.path, operations: operations)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .identityChanged)
        }
    }

    func testMetadataLimitAndSocketIdentityRevalidation() throws {
        let oversized = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: oversized.directory) }
        try Data(repeating: 0x61, count: 1025).write(to: URL(fileURLWithPath: oversized.paths.metadataPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversized.paths.metadataPath)
        XCTAssertThrowsError(try IPCRuntimeDiscovery.resolve(oversized.directory.path, operations: oversized.operations)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .invalidMetadata)
        }

        let identity = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: identity.directory) }
        let changed = IPCTestRuntimeFixture.operations(paths: identity.paths, socketInode: 92)
        XCTAssertThrowsError(try identity.runtime.revalidate(operations: changed)) { error in
            XCTAssertEqual(error as? IPCDiscoveryError, .identityChanged)
        }
    }

    private static func replaceFile(at path: URL, with contents: Data) throws {
        let replacement = path.deletingLastPathComponent().appendingPathComponent("swap-\(UUID().uuidString.lowercased())")
        try contents.write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: replacement, to: path)
    }
}

private final class IPCOpenFlagRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths = [String]()
    private var recordedFlags = [Int32]()

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    var values: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFlags
    }

    func record(path: String, flags: Int32) {
        lock.lock()
        recordedPaths.append(path)
        recordedFlags.append(flags)
        lock.unlock()
    }
}

private final class IPCOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}
