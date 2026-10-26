import Foundation
import Darwin
import Testing
@testable import HidhoggAutomation

struct LocalAutomationServerTests {
    @Test func syntheticEndpointRoundTripsAndHasPrivatePermissions() async throws {
        let fixture = SocketFixture()
        defer { fixture.remove() }
        let server = LocalAutomationServer()
        try await server.start(socketURL: fixture.socketURL) { request in
            .success(requestID: request.requestID, result: .object(["status": .string("synthetic")]))
        }
        let request = AutomationRequest(method: .status)
        do {
            let response = try await Task.detached { try LocalAutomationClient.send(request, socketURL: fixture.socketURL) }.value
            #expect(response.result == .object(["status": .string("synthetic")]))
            var directory = stat()
            var socket = stat()
            #expect(lstat(fixture.directory.path, &directory) == 0)
            #expect(directory.st_mode & 0o777 == 0o700)
            #expect(lstat(fixture.socketURL.path, &socket) == 0)
            #expect(socket.st_mode & 0o777 == 0o600)
            #expect(socket.st_uid == getuid())
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.socketURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func existingSymlinkAndUnsafeDirectoryAreRejectedWithoutRemoval() async throws {
        let fixture = SocketFixture()
        defer { fixture.remove() }
        #expect(mkdir(fixture.directory.path, 0o700) == 0)
        try FileManager.default.createSymbolicLink(atPath: fixture.socketURL.path, withDestinationPath: "missing-synthetic-target")
        let server = LocalAutomationServer()
        await #expect(throws: LocalAutomationError.endpointExists) {
            try await server.start(socketURL: fixture.socketURL) { .success(requestID: $0.requestID) }
        }
        var info = stat()
        #expect(lstat(fixture.socketURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFLNK)
        try FileManager.default.removeItem(at: fixture.socketURL)
        #expect(chmod(fixture.directory.path, 0o755) == 0)
        await #expect(throws: LocalAutomationError.unsafePath) {
            try await server.start(socketURL: fixture.socketURL) { .success(requestID: $0.requestID) }
        }
        await server.stop()
    }

    @Test func stopPreservesAReplacementAtTheSocketPath() async throws {
        let fixture = SocketFixture()
        defer { fixture.remove() }
        let server = LocalAutomationServer()
        try await server.start(socketURL: fixture.socketURL) { .success(requestID: $0.requestID) }
        #expect(unlink(fixture.socketURL.path) == 0)
        try Data("replacement".utf8).write(to: fixture.socketURL)
        await server.stop()
        #expect(try Data(contentsOf: fixture.socketURL) == Data("replacement".utf8))
    }
}

private struct SocketFixture: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hidhogg-test-\(UUID().uuidString.prefix(12))", isDirectory: true)
    var socketURL: URL { directory.appendingPathComponent("a.sock") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
