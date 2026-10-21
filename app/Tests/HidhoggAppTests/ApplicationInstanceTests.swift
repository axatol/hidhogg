import Darwin
import Foundation
import XCTest
@testable import HidhoggApp

final class ApplicationInstanceLeaseTests: XCTestCase {
    func testIndependentDescriptorsExcludeAndReacquireWithoutReplacingFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ApplicationInstanceLease(parentURL: root)
        let file = root.appendingPathComponent("com.hidhogg.instance/owner.lock")
        let marker = Data("stale process metadata must be ignored".utf8)
        try marker.write(to: file)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        let second = try ApplicationInstanceLease(parentURL: root)

        XCTAssertTrue(try first.acquire())
        XCTAssertFalse(try second.acquire())
        try first.release()
        XCTAssertTrue(try second.acquire())
        XCTAssertFalse(try first.acquire())
        try second.release()
        XCTAssertTrue(try first.acquire())
        XCTAssertEqual(try Data(contentsOf: file), marker)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, inode)
    }

    func testDescriptorLifetimeReleasesLeaseAndPreservesPersistentLock() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var first: ApplicationInstanceLease? = try ApplicationInstanceLease(parentURL: root)
        XCTAssertTrue(try XCTUnwrap(first).acquire())
        let second = try ApplicationInstanceLease(parentURL: root)
        XCTAssertFalse(try second.acquire())
        first = nil
        XCTAssertTrue(try second.acquire())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("com.hidhogg.instance/owner.lock").path))
    }

    func testPrivateModesAndNonOwnerRelease() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try ApplicationInstanceLease(parentURL: root)
        XCTAssertThrowsError(try lease.release())
        let directory = root.appendingPathComponent("com.hidhogg.instance")
        let file = directory.appendingPathComponent("owner.lock")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try lease.acquire())
        XCTAssertThrowsError(try ApplicationInstanceLease(parentURL: root))
    }

    func testSymlinkedDirectoryAndParentAreRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let link = root.appendingPathComponent("com.hidhogg.instance")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ApplicationInstanceLease(parentURL: root))
        XCTAssertThrowsError(try ApplicationInstanceLease(parentURL: link))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testSymlinkedAndHardLinkedFilesAreRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("com.hidhogg.instance")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent("target")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let file = directory.appendingPathComponent("owner.lock")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try ApplicationInstanceLease(parentURL: root))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        XCTAssertThrowsError(try ApplicationInstanceLease(parentURL: root))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
    }

    func testUnsafeDirectoryModeAndFileTypeFailClosed() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("com.hidhogg.instance")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try ApplicationInstanceLease(parentURL: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("owner.lock"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try ApplicationInstanceLease(parentURL: root))
    }

    func testWritableParentIsRejectedBeforeCreatingOwnershipDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: root.path)
        XCTAssertThrowsError(try ApplicationInstanceLease(parentURL: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("com.hidhogg.instance").path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}

@MainActor
final class ApplicationInstanceBootstrapTests: XCTestCase {
    func testListenerAndOwnershipPrecedeOwnerFactory() throws {
        var events = [String]()
        let lease = FakeInstanceOwnership(acquire: { events.append("acquire"); return true })
        let bootstrap = ApplicationInstanceBootstrap(
            observeActivation: { _ in events.append("listen"); return NSObject() },
            postActivation: { events.append("notify") }
        )
        try bootstrap.run(
            diagnostics: { events.append("diagnostics"); return false },
            makeLease: { events.append("lease"); return lease },
            owner: { XCTAssertTrue(bootstrap.isOwner); events.append("model") }
        )
        XCTAssertEqual(events, ["diagnostics", "lease", "listen", "acquire", "model"])
    }

    func testDiagnosticModeSkipsLockListenerAndOwnerFactory() throws {
        let bootstrap = ApplicationInstanceBootstrap(
            observeActivation: { _ in XCTFail("Diagnostics must not install an owner listener."); return NSObject() },
            postActivation: { XCTFail("Diagnostics must not notify the owner.") }
        )
        try bootstrap.run(
            diagnostics: { true },
            makeLease: { XCTFail("Diagnostics must not open a lease."); return FakeInstanceOwnership() },
            owner: { XCTFail("Diagnostics must not construct a runtime.") }
        )
    }

    func testDuplicateNotifiesWithoutConstructingOwnerOrHandlingActivation() throws {
        var handler: (@MainActor () -> Void)?
        var notifications = 0
        var opens = 0
        let bootstrap = ApplicationInstanceBootstrap(
            observeActivation: { handler = $0; return NSObject() },
            postActivation: { notifications += 1 }
        )
        try bootstrap.run(
            diagnostics: { false },
            makeLease: { FakeInstanceOwnership(acquire: { false }) },
            owner: { XCTFail("A duplicate must not construct the runtime.") }
        )
        handler?()
        bootstrap.installWorkspace { opens += 1 }
        handler?()
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(opens, 0)
    }

    func testOwnerQueuesActivationUntilAdapterAndIgnoresActivationAfterRelease() throws {
        var handler: (@MainActor () -> Void)?
        var opens = 0
        let lease = FakeInstanceOwnership()
        let bootstrap = ApplicationInstanceBootstrap(
            observeActivation: { handler = $0; return NSObject() },
            postActivation: { XCTFail("An owner must not notify a duplicate.") }
        )
        XCTAssertTrue(try bootstrap.start(lease: lease))
        handler?()
        handler?()
        bootstrap.installWorkspace { opens += 1 }
        XCTAssertEqual(opens, 1)
        handler?()
        XCTAssertEqual(opens, 2)
        try lease.release()
        handler?()
        XCTAssertNil(bootstrap.constructOwner { "forbidden" })
        bootstrap.installWorkspace { opens += 1 }
        XCTAssertEqual(opens, 2)
    }

    func testOwnershipErrorDoesNotNotifyOrConstructOwner() {
        let bootstrap = ApplicationInstanceBootstrap(
            observeActivation: { _ in NSObject() },
            postActivation: { XCTFail("Filesystem failure is not lock contention.") }
        )
        XCTAssertThrowsError(try bootstrap.run(
            diagnostics: { false },
            makeLease: { FakeInstanceOwnership(acquire: { throw InstanceLeaseFailure.unsafeFilesystem }) },
            owner: { XCTFail("Ownership errors must fail closed.") }
        ))
    }
}

private final class FakeInstanceOwnership: ApplicationInstanceOwnership {
    private(set) var isHeld = false
    private let acquireResult: () throws -> Bool

    init(acquire: @escaping () throws -> Bool = { true }) {
        acquireResult = acquire
    }

    func acquire() throws -> Bool {
        isHeld = try acquireResult()
        return isHeld
    }

    func release() throws {
        isHeld = false
    }
}
