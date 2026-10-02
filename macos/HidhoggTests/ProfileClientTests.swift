import Darwin
import Foundation
import XCTest
@testable import Hidhogg

final class ProfileClientTests: XCTestCase {
    private let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let listRequestID = "11111111-1111-4111-8111-111111111111"
    private let activationRequestID = "22222222-2222-4222-8222-222222222222"

    func testListAndActivationUseOneFreshExchangePerRequest() throws {
        let endpoint = try makeSocketEndpoint()
        defer { endpoint.cleanup() }
        let profiles = [
            ProfileSummary(id: "default", label: "Default", isDefault: true, isCurrent: true),
            ProfileSummary(id: "Work.Profile", label: "Work", isDefault: false, isCurrent: false)
        ]
        let transport = RecordingProfileTransport(responses: [
            profileListFrame(requestID: listRequestID, instanceID: instanceID, profiles: profiles),
            profileActivationFrame(requestID: activationRequestID, profileID: "Work.Profile", changed: true)
        ])
        let client = try ProfileClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: transport,
            phaseTimeoutNanoseconds: 7
        )

        let list = try client.listProfiles(requestID: listRequestID)
        let activation = try client.activateProfile(profileID: "Work.Profile", requestID: activationRequestID)

        XCTAssertEqual(list.profiles, profiles)
        XCTAssertEqual(activation, ProfileActivationResponse(requestID: activationRequestID, profileID: "Work.Profile", changed: true))
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.socketPaths, [endpoint.socket.path, endpoint.socket.path])
        XCTAssertEqual(transport.timeouts, [7, 7])
        XCTAssertEqual(
            String(data: transport.requests[0], encoding: .utf8),
            "{\"protocol_version\":1,\"request_id\":\"\(listRequestID)\",\"method\":\"profiles.list\",\"params\":{\"instance_id\":\"\(instanceID)\"}}\n"
        )
        XCTAssertEqual(
            String(data: transport.requests[1], encoding: .utf8),
            "{\"protocol_version\":1,\"request_id\":\"\(activationRequestID)\",\"method\":\"profiles.activate\",\"params\":{\"instance_id\":\"\(instanceID)\",\"profile_id\":\"Work.Profile\"}}\n"
        )
    }

    func testActivationChangedFalseIsReturnedWithoutRetry() throws {
        let endpoint = try makeSocketEndpoint()
        defer { endpoint.cleanup() }
        let transport = RecordingProfileTransport(
            responses: [profileActivationFrame(requestID: activationRequestID, profileID: "default", changed: false)]
        )
        let client = try ProfileClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: transport
        )

        let result = try client.activateProfile(profileID: "default", requestID: activationRequestID)

        XCTAssertFalse(result.changed)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDisplayHostStateSetUsesExactParamsAndBindsTheTypedReply() throws {
        let endpoint = try makeSocketEndpoint()
        defer { endpoint.cleanup() }
        let requestID = "33333333-3333-4333-8333-333333333333"
        let response = Data(
            """
            {"protocol_version":1,"request_id":"\(requestID)","result":{"instance_id":"\(instanceID)","display_awake":false,"changed":true},"error":null}

            """.utf8
        )
        let transport = RecordingProfileTransport(responses: [response])
        let client = try UnixSocketClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: transport
        )

        let result = try client.setDisplayHostState(displayAwake: false, requestID: requestID)

        XCTAssertEqual(
            result,
            DisplayHostStateResponse(
                requestID: requestID,
                instanceID: instanceID,
                displayAwake: false,
                changed: true
            )
        )
        XCTAssertEqual(transport.requests.count, 1)
        let requestObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: transport.requests[0]) as? [String: Any]
        )
        XCTAssertEqual(requestObject["method"] as? String, "display.host_state.set")
        let params = try XCTUnwrap(requestObject["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["instance_id", "display_awake"])
        XCTAssertEqual(params["instance_id"] as? String, instanceID)
        XCTAssertEqual(params["display_awake"] as? Bool, false)
    }

    func testDisplayHostStateSetRejectsAnotherRuntimeInstanceWithoutRetry() throws {
        let endpoint = try makeSocketEndpoint()
        defer { endpoint.cleanup() }
        let requestID = "44444444-4444-4444-8444-444444444444"
        let foreignInstanceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let transport = RecordingProfileTransport(responses: [
            Data(
                """
                {"protocol_version":1,"request_id":"\(requestID)","result":{"instance_id":"\(foreignInstanceID)","display_awake":true,"changed":true},"error":null}

                """.utf8
            )
        ])
        let client = try UnixSocketClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: transport
        )

        XCTAssertThrowsError(try client.setDisplayHostState(displayAwake: true, requestID: requestID)) { error in
            XCTAssertEqual(
                error as? UnixSocketClientError,
                .response(.invalidResult)
            )
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testServerErrorsAndMalformedResultsAreSurfacedStrictly() throws {
        let endpoint = try makeSocketEndpoint()
        defer { endpoint.cleanup() }
        let serverErrorTransport = RecordingProfileTransport(responses: [
            Data("{\"protocol_version\":1,\"request_id\":\"\(activationRequestID)\",\"result\":null,\"error\":{\"code\":\"device_write_failed\",\"message\":\"device write failed\"}}\n".utf8)
        ])
        let serverErrorClient = try ProfileClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: serverErrorTransport
        )
        XCTAssertThrowsError(
            try serverErrorClient.activateProfile(profileID: "Work.Profile", requestID: activationRequestID)
        ) { error in
            XCTAssertEqual(
                error as? UnixSocketClientError,
                .response(.serverError(RuntimeError(code: "device_write_failed", message: "device write failed")))
            )
        }
        XCTAssertEqual(serverErrorTransport.requests.count, 1)

        let malformedTransport = RecordingProfileTransport(responses: [
            Data("{\"protocol_version\":1,\"request_id\":\"\(listRequestID)\",\"result\":{\"instance_id\":\"\(instanceID)\",\"profiles\":[{\"id\":\"default\",\"label\":\"Default\",\"is_default\":true,\"is_current\":true,\"extra\":true}]},\"error\":null}\n".utf8)
        ])
        let malformedClient = try ProfileClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: malformedTransport
        )
        XCTAssertThrowsError(
            try malformedClient.listProfiles(requestID: listRequestID)
        ) { error in
            XCTAssertEqual(error as? UnixSocketClientError, .response(.invalidResult))
        }
        XCTAssertEqual(malformedTransport.requests.count, 1)
    }

    func testReplacementUsesTheNewEndpointAndDoesNotReuseTheOldGeneration() throws {
        let oldEndpoint = try makeSocketEndpoint()
        let newEndpoint = try makeSocketEndpoint()
        defer {
            oldEndpoint.cleanup()
            newEndpoint.cleanup()
        }
        let oldTransport = RecordingProfileTransport(responses: [
            profileListFrame(
                requestID: listRequestID,
                instanceID: instanceID,
                profiles: [ProfileSummary(id: "default", label: "Old", isDefault: true, isCurrent: true)]
            )
        ])
        let newInstanceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let newTransport = RecordingProfileTransport(responses: [
            profileListFrame(
                requestID: listRequestID,
                instanceID: newInstanceID,
                profiles: [ProfileSummary(id: "default", label: "New", isDefault: true, isCurrent: true)]
            )
        ])
        let oldClient = try ProfileClient(
            socketPath: oldEndpoint.socket.path,
            instanceID: instanceID,
            transport: oldTransport
        )
        let newClient = try ProfileClient(
            socketPath: newEndpoint.socket.path,
            instanceID: newInstanceID,
            transport: newTransport
        )

        XCTAssertEqual(try oldClient.listProfiles(requestID: listRequestID).instanceID, instanceID)
        XCTAssertEqual(try newClient.listProfiles(requestID: listRequestID).instanceID, newInstanceID)
        XCTAssertEqual(oldTransport.socketPaths, [oldEndpoint.socket.path])
        XCTAssertEqual(newTransport.socketPaths, [newEndpoint.socket.path])
        XCTAssertNotEqual(oldEndpoint.socket.path, newEndpoint.socket.path)
    }

    func testConfigEditorClientUsesTypedResponsesAndOmitsCurrentSourceProfile() throws {
        let endpoint = try makeSocketEndpoint()
        defer { endpoint.cleanup() }
        let requestIDs = [
            "11111111-1111-4111-8111-111111111111",
            "22222222-2222-4222-8222-222222222222",
            "33333333-3333-4333-8333-333333333333",
            "44444444-4444-4444-8444-444444444444",
            "55555555-5555-4555-8555-555555555555"
        ]
        let digest = String(repeating: "a", count: 64)
        let resultDigest = String(repeating: "b", count: 64)
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let transport = RecordingProfileTransport(responses: [
            try configEditorFrame(requestID: requestIDs[0], instanceID: instanceID, result: [
                "source_digest": digest,
                "revision": 2,
                "default_profile_id": "default",
                "current_profile_id": "Work.Profile",
                "profile_ids": ["default", "Work.Profile"]
            ]),
            try configEditorFrame(requestID: requestIDs[1], instanceID: instanceID, result: [
                "source_digest": digest,
                "profile_id": "Work.Profile",
                "label": "Work"
            ]),
            try configEditorFrame(requestID: requestIDs[2], instanceID: instanceID, result: editorMutationResult(digest: resultDigest, revision: 3)),
            try configEditorFrame(requestID: requestIDs[3], instanceID: instanceID, result: editorMutationResult(digest: resultDigest, revision: 4)),
            try configEditorFrame(requestID: requestIDs[4], instanceID: instanceID, result: editorMutationResult(digest: resultDigest, revision: 5))
        ])
        let client = try ConfigEditorClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: transport,
            phaseTimeoutNanoseconds: 9
        )

        let snapshot = try client.configEditorSnapshot(requestID: requestIDs[0])
        let profile = try client.configEditorProfile(
            profileID: "Work.Profile",
            sourceDigest: digest,
            requestID: requestIDs[1]
        )
        let label = #"Copy "quoted" \ Profile"#
        let labelResult = try client.setConfigEditorProfileLabel(
            profileID: "Work.Profile",
            label: label,
            expectedDigest: digest,
            requestID: requestIDs[2]
        )
        let createResult = try client.createConfigEditorProfile(
            profileID: "Copy.Profile",
            label: "Copy",
            expectedDigest: digest,
            requestID: requestIDs[3]
        )
        let deleteResult = try client.deleteConfigEditorProfile(
            profileID: "Copy.Profile",
            expectedDigest: digest,
            requestID: requestIDs[4]
        )

        XCTAssertEqual(snapshot.instanceID, instanceID)
        XCTAssertEqual(snapshot.currentProfileID, "Work.Profile")
        XCTAssertEqual(profile.label, "Work")
        XCTAssertEqual(labelResult.fileCommit, .committed)
        XCTAssertEqual(createResult.revision, 4)
        XCTAssertEqual(deleteResult.revision, 5)
        XCTAssertEqual(transport.requests.count, 5)
        XCTAssertEqual(transport.socketPaths, Array(repeating: endpoint.socket.path, count: 5))
        XCTAssertEqual(transport.timeouts, Array(repeating: 9, count: 5))

        let envelopes = try transport.requests.map { frame -> [String: Any] in
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(frame.dropLast())) as? [String: Any])
        }
        XCTAssertEqual(envelopes.compactMap { $0["request_id"] as? String }, requestIDs)
        XCTAssertEqual(envelopes.compactMap { $0["method"] as? String }, [
            RuntimeMethod.configEditorSnapshot.rawValue,
            RuntimeMethod.configEditorProfileGet.rawValue,
            RuntimeMethod.configEditorProfileLabelSet.rawValue,
            RuntimeMethod.configEditorProfileCreate.rawValue,
            RuntimeMethod.configEditorProfileDelete.rawValue
        ])
        let labelParams = try XCTUnwrap(envelopes[2]["params"] as? [String: Any])
        XCTAssertEqual(labelParams["label"] as? String, label)
        let createParams = try XCTUnwrap(envelopes[3]["params"] as? [String: Any])
        XCTAssertNil(createParams["source_profile_id"])
    }

    func testConfigEditorPositionClientUsesCoordinateIDsAndTypedResponses() throws {
        let endpoint = try makeSocketEndpoint()
        defer { endpoint.cleanup() }
        let requestIDs = [
            "66666666-6666-4666-8666-666666666666",
            "77777777-7777-4777-8777-777777777777",
            "88888888-8888-4888-8888-888888888888"
        ]
        let digest = String(repeating: "a", count: 64)
        let resultDigest = String(repeating: "b", count: 64)
        let coordinates = [
            "0_0", "1_0", "2_0", "3_0", "4_0",
            "0_1", "1_1", "2_1", "3_1", "4_1",
            "0_2", "1_2", "2_2", "3_2"
        ]
        let positionSummaries: [[String: Any]] = coordinates.map { coordinate in
            ["position_id": coordinate, "position": coordinate]
        }
        let positionID = "0_0"
        let label = #"Welcome "Now" \ Slot"#
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let transport = RecordingProfileTransport(responses: [
            try configEditorFrame(requestID: requestIDs[0], instanceID: instanceID, result: [
                "source_digest": digest,
                "profile_id": "Work.Profile",
                "positions": positionSummaries
            ]),
            try configEditorFrame(requestID: requestIDs[1], instanceID: instanceID, result: [
                "source_digest": digest,
                "profile_id": "Work.Profile",
                "position_id": positionID,
                "label": label
            ]),
            try configEditorFrame(requestID: requestIDs[2], instanceID: instanceID, result: editorMutationResult(digest: resultDigest, revision: 6))
        ])
        let client = try ConfigEditorClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: transport,
            phaseTimeoutNanoseconds: 9
        )

        let positions = try client.configEditorPositions(
            profileID: "Work.Profile",
            sourceDigest: digest,
            requestID: requestIDs[0]
        )
        let position = try client.configEditorPosition(
            profileID: "Work.Profile",
            positionID: positionID,
            sourceDigest: digest,
            requestID: requestIDs[1]
        )
        let mutation = try client.setConfigEditorPositionLabel(
            profileID: "Work.Profile",
            positionID: positionID,
            label: label,
            expectedDigest: digest,
            requestID: requestIDs[2]
        )

        XCTAssertEqual(positions.instanceID, instanceID)
        XCTAssertEqual(positions.sourceDigest, digest)
        XCTAssertEqual(positions.profileID, "Work.Profile")
        XCTAssertEqual(positions.positions.map(\.position), coordinates)
        XCTAssertEqual(positions.positions.map(\.positionID), coordinates)
        XCTAssertEqual(position.positionID, positionID)
        XCTAssertEqual(position.label, label)
        XCTAssertEqual(mutation.sourceDigest, resultDigest)
        XCTAssertEqual(mutation.revision, 6)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.socketPaths, Array(repeating: endpoint.socket.path, count: 3))
        XCTAssertEqual(transport.timeouts, Array(repeating: 9, count: 3))

        let envelopes = try transport.requests.map { frame -> [String: Any] in
            XCTAssertLessThanOrEqual(frame.count, ProtocolV1.frameLimit)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(frame.dropLast())) as? [String: Any])
        }
        XCTAssertEqual(envelopes.compactMap { $0["request_id"] as? String }, requestIDs)
        XCTAssertEqual(envelopes.compactMap { $0["method"] as? String }, [
            RuntimeMethod.configEditorPositionsList.rawValue,
            RuntimeMethod.configEditorPositionGet.rawValue,
            RuntimeMethod.configEditorPositionLabelSet.rawValue
        ])
        let listParams = try XCTUnwrap(envelopes[0]["params"] as? [String: Any])
        XCTAssertEqual(Set(listParams.keys), ["instance_id", "profile_id", "source_digest"])
        let detailParams = try XCTUnwrap(envelopes[1]["params"] as? [String: Any])
        XCTAssertEqual(Set(detailParams.keys), ["instance_id", "profile_id", "position_id", "source_digest"])
        XCTAssertEqual(detailParams["position_id"] as? String, positionID)
        let mutationParams = try XCTUnwrap(envelopes[2]["params"] as? [String: Any])
        XCTAssertEqual(Set(mutationParams.keys), ["instance_id", "profile_id", "position_id", "expected_digest", "label"])
        XCTAssertEqual(mutationParams["position_id"] as? String, positionID)
        XCTAssertEqual(mutationParams["label"] as? String, label)
    }

    func testConfigEditorClientRejectsInvalidRequestBeforeTransport() throws {
        let endpoint = try makeSocketEndpoint()
        defer { endpoint.cleanup() }
        let transport = RecordingProfileTransport(responses: [])
        let client = try ConfigEditorClient(
            socketPath: endpoint.socket.path,
            instanceID: instanceID,
            transport: transport
        )

        XCTAssertThrowsError(try client.configEditorProfile(
            profileID: "bad profile",
            sourceDigest: String(repeating: "a", count: 64),
            requestID: listRequestID
        )) { error in
            XCTAssertEqual(error as? UnixSocketClientError, .invalidRequest)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    private func configEditorFrame(
        requestID: String,
        instanceID: String,
        result: [String: Any]
    ) throws -> Data {
        var resultFields = result
        resultFields["instance_id"] = instanceID
        let envelope: [String: Any] = [
            "protocol_version": ProtocolV1.protocolVersion,
            "request_id": requestID,
            "result": resultFields,
            "error": NSNull()
        ]
        var frame = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        frame.append(0x0a)
        return frame
    }

    private func editorMutationResult(digest: String, revision: UInt64) -> [String: Any] {
        [
            "source_digest": digest,
            "file_commit": "committed",
            "reload_outcome": "changed",
            "revision": revision,
            "effect": "catalog",
            "reason": "none"
        ]
    }

    private func profileListFrame(requestID: String, instanceID: String, profiles: [ProfileSummary]) -> Data {
        let encodedProfiles = profiles.map { profile in
            let defaultValue = profile.isDefault ? "true" : "false"
            let currentValue = profile.isCurrent ? "true" : "false"
            return "{\"id\":\"\(profile.id)\",\"label\":\"\(profile.label)\",\"is_default\":\(defaultValue),\"is_current\":\(currentValue)}"
        }.joined(separator: ",")
        return Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"instance_id\":\"\(instanceID)\",\"profiles\":[\(encodedProfiles)]},\"error\":null}\n".utf8)
    }

    private func profileActivationFrame(requestID: String, profileID: String, changed: Bool) -> Data {
        let changedValue = changed ? "true" : "false"
        return Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"profile_id\":\"\(profileID)\",\"changed\":\(changedValue)},\"error\":null}\n".utf8)
    }

    private func makeSocketEndpoint() throws -> TestSocketEndpoint {
        let directory = URL(fileURLWithPath: "/private/tmp/hidhogg-profile-client-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let socket = directory.appendingPathComponent("runtime.sock")
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw UnixSocketClientError.systemCall("socket", errno)
        }
        do {
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socket.path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                for offset in 0..<rawBuffer.count {
                    rawBuffer[offset] = 0
                }
                for (offset, byte) in pathBytes.enumerated() where offset < rawBuffer.count - 1 {
                    rawBuffer[offset] = byte
                }
            }
            let bindResult = withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0, Darwin.chmod(socket.path, mode_t(0o600)) == 0 else {
                throw UnixSocketClientError.systemCall("bind", errno)
            }
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return TestSocketEndpoint(directory: directory, socket: socket, descriptor: descriptor)
    }
}

private struct TestSocketEndpoint {
    let directory: URL
    let socket: URL
    let descriptor: Int32

    func cleanup() {
        _ = Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class RecordingProfileTransport: @unchecked Sendable, SocketTransport {
    private let lock = NSLock()
    private var pendingResponses: [Data]
    private(set) var requests: [Data] = []
    private(set) var socketPaths: [String] = []
    private(set) var timeouts: [UInt64] = []

    init(responses: [Data]) {
        pendingResponses = responses
    }

    func exchange(request: Data, socketPath: String, timeoutNanoseconds: UInt64) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        socketPaths.append(socketPath)
        timeouts.append(timeoutNanoseconds)
        guard !pendingResponses.isEmpty else {
            throw UnixSocketClientError.connectionClosed
        }
        return pendingResponses.removeFirst()
    }
}
