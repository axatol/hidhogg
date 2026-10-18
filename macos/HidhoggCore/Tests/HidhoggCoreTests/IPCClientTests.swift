import Darwin
import Foundation
import XCTest
@testable import HidhoggCore

final class IPCClientTests: XCTestCase {
    func testValidResponseUsesResolvedIdentityAndRevalidatesAfterExchange() async throws {
        let fixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let exchange = IPCExchangeRecorder { socketPath, request, deadlines in
            XCTAssertEqual(socketPath, fixture.runtime.paths.socketPath)
            XCTAssertEqual(deadlines, fixture.deadlines)
            let decoded = try Self.decodeRequest(request)
            return try Self.healthResponse(requestID: decoded.requestID, instanceID: decoded.instanceID)
        }
        let revalidation = IPCRevalidationRecorder()
        let client = IPCClient(
            runtime: fixture.runtime,
            transport: exchange,
            deadlines: fixture.deadlines,
            revalidateEndpoint: { try revalidation.revalidate() }
        )

        let response = try await client.call(.health)

        XCTAssertEqual(response.result?.value(for: "state")?.stringValue, "ready")
        XCTAssertEqual(exchange.callCount, 1)
        XCTAssertEqual(revalidation.callCount, 1)
    }

    func testTransportErrorIsPreservedUnlessEndpointChanged() async throws {
        let fixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transport = IPCExchangeRecorder { _, _, _ in throw IPCClientError.transport }

        let stable = IPCClient(runtime: fixture.runtime, transport: transport, revalidateEndpoint: {})
        do {
            _ = try await stable.call(.health)
            XCTFail("expected transport error")
        } catch {
            XCTAssertEqual(error as? IPCClientError, .transport)
        }

        let changed = IPCClient(
            runtime: fixture.runtime,
            transport: transport,
            revalidateEndpoint: { throw IPCDiscoveryError.identityChanged }
        )
        do {
            _ = try await changed.call(.health)
            XCTFail("expected endpoint change")
        } catch {
            XCTAssertEqual(error as? IPCClientError, .endpointChanged)
        }
    }

    func testMalformedResponseMapsToInvalidResponseOrEndpointChanged() async throws {
        let fixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transport = IPCExchangeRecorder { _, _, _ in Data("not-json\n".utf8) }

        let stable = IPCClient(runtime: fixture.runtime, transport: transport, revalidateEndpoint: {})
        do {
            _ = try await stable.call(.health)
            XCTFail("expected invalid response")
        } catch {
            XCTAssertEqual(error as? IPCClientError, .invalidResponse)
        }

        let changed = IPCClient(
            runtime: fixture.runtime,
            transport: transport,
            revalidateEndpoint: { throw IPCDiscoveryError.identityChanged }
        )
        do {
            _ = try await changed.call(.health)
            XCTFail("expected endpoint change")
        } catch {
            XCTAssertEqual(error as? IPCClientError, .endpointChanged)
        }
    }

    func testEndpointChangeAfterValidResponseInvalidatesResult() async throws {
        let fixture = try IPCTestRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let transport = IPCExchangeRecorder { _, request, _ in
            let decoded = try Self.decodeRequest(request)
            return try Self.healthResponse(requestID: decoded.requestID, instanceID: decoded.instanceID)
        }
        let client = IPCClient(
            runtime: fixture.runtime,
            transport: transport,
            revalidateEndpoint: { throw IPCDiscoveryError.identityChanged }
        )

        do {
            _ = try await client.call(.health)
            XCTFail("expected endpoint change")
        } catch {
            XCTAssertEqual(error as? IPCClientError, .endpointChanged)
        }
    }

    private static func decodeRequest(_ data: Data) throws -> IPCWireRequest {
        guard case let .success(request) = IPCProtocol.decodeRequest(data) else { throw IPCFrameError.invalidFrame }
        return request
    }

    private static func healthResponse(requestID: String, instanceID: String) throws -> Data {
        try IPCProtocol.encodeResponse(IPCWireResponse(
            requestID: requestID,
            result: .object([
                IPCJSONField(key: "instance_id", value: .string(instanceID)),
                IPCJSONField(key: "state", value: .string("ready")),
            ])
        ))
    }
}

private final class IPCExchangeRecorder: IPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    let body: @Sendable (String, Data, IPCDeadlines) throws -> Data
    private var count = 0

    init(body: @escaping @Sendable (String, Data, IPCDeadlines) throws -> Data) {
        self.body = body
    }

    func exchange(socketPath: String, request: Data, deadlines: IPCDeadlines) throws -> Data {
        lock.lock()
        count += 1
        lock.unlock()
        return try body(socketPath, request, deadlines)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class IPCRevalidationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func revalidate() throws {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

struct IPCTestRuntimeFixture {
    let directory: URL
    let paths: IPCRuntimePaths
    let operations: IPCPOSIXOperations
    let runtime: IPCResolvedRuntime
    let deadlines = IPCDeadlines(connect: .milliseconds(125), read: .milliseconds(250), write: .milliseconds(375))

    init(socketMode: mode_t = mode_t(S_IFSOCK | 0o600), socketUserID: UInt32? = nil, socketInode: UInt64 = 91) throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("hgipc-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        paths = try IPCRuntimePaths(directory: directory.path)
        let metadata = try IPCMetadata(schemaVersion: 1, instanceID: "22222222-2222-4222-8222-222222222222", socketName: "runtime.sock").encode()
        try metadata.write(to: URL(fileURLWithPath: paths.metadataPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.metadataPath)

        operations = Self.operations(paths: paths, socketMode: socketMode, socketUserID: socketUserID, socketInode: socketInode)
        runtime = try IPCRuntimeDiscovery.resolve(directory.path, operations: operations)
    }

    static func operations(
        paths: IPCRuntimePaths,
        socketMode: mode_t = mode_t(S_IFSOCK | 0o600),
        socketUserID: UInt32? = nil,
        socketInode: UInt64 = 91
    ) -> IPCPOSIXOperations {
        var operations = IPCPOSIXOperations.live
        operations.lstat = { path in
            guard path == paths.socketPath else { return IPCPOSIXOperations.live.lstat(path) }
            var value = stat()
            value.st_mode = socketMode
            value.st_uid = uid_t(socketUserID ?? UInt32(geteuid()))
            value.st_dev = 77
            value.st_ino = socketInode
            return IPCPOSIXResult(value: value, error: 0)
        }
        return operations
    }
}
