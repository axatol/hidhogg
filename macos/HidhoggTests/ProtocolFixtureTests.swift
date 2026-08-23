import Foundation
import XCTest
@testable import Hidhogg

final class ProtocolFixtureTests: XCTestCase {
    func testStaticFixtureResponsesUseTheSwiftStrictValidator() throws {
        let root = try fixtureRoot()
        let manifestData = try Data(contentsOf: root.appendingPathComponent("cases.json"))
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let cases = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        let expectedInstanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

        for fixtureCase in cases {
            let id = try XCTUnwrap(fixtureCase["id"] as? String)
            let requestPath = try XCTUnwrap(fixtureCase["request"] as? String)
            let responsePath = try XCTUnwrap(fixtureCase["response"] as? String)
            let requestData = try Data(contentsOf: root.appendingPathComponent(requestPath))
            let responseData = try Data(contentsOf: root.appendingPathComponent(responsePath))
            let method: RuntimeMethod = id == "status.success" ? .status : .health
            let expectedRequestID = id == "envelope.duplicate-key"
                ? nil
                : requestIDFromFixture(requestData)

            do {
                _ = try ResponseValidator.validate(
                    frame: responseData,
                    expectedRequestID: expectedRequestID,
                    method: method,
                    expectedInstanceID: expectedInstanceID
                )
                XCTAssertTrue(
                    id == "health.success" || id == "status.success",
                    "unexpected success fixture: \(id)"
                )
            } catch ResponseValidationError.serverError {
                XCTAssertNotEqual(id, "health.success")
                XCTAssertNotEqual(id, "status.success")
            }
        }
    }

    func testDuplicateAndUnknownResponseFieldsAreRejected() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let duplicate = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"request_id\":\"\(requestID)\",\"result\":{\"instance_id\":\"\(instanceID)\",\"state\":\"ready\"},\"error\":null}\n".utf8)
        let unknown = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"instance_id\":\"\(instanceID)\",\"state\":\"ready\",\"extra\":true},\"error\":null}\n".utf8)

        XCTAssertThrowsError(try ResponseValidator.validate(frame: duplicate, expectedRequestID: requestID, method: .health, expectedInstanceID: instanceID))
        XCTAssertThrowsError(try ResponseValidator.validate(frame: unknown, expectedRequestID: requestID, method: .health, expectedInstanceID: instanceID))
    }

    func testGeneratedStrictResponseMutationFamiliesAreRejected() throws {
        let root = try fixtureRoot()
        let manifestData = try Data(contentsOf: root.appendingPathComponent("cases.json"))
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let generatedCases = try XCTUnwrap(manifest["generated_cases"] as? [[String: Any]])
        let selectedIDs: Set<String> = ["response.strict-success", "response.strict-error"]
        let expectedInstanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        var observedIDs = Set<String>()

        for generatedCase in generatedCases {
            let id = try XCTUnwrap(generatedCase["id"] as? String)
            guard selectedIDs.contains(id) else { continue }
            observedIDs.insert(id)
            let generator = try XCTUnwrap(generatedCase["generator"] as? [String: Any])
            let basePath = try XCTUnwrap(generator["base"] as? String)
            let mutationNames = try XCTUnwrap(generator["mutations"] as? [String])
            let base = try XCTUnwrap(String(data: Data(contentsOf: root.appendingPathComponent(basePath)), encoding: .utf8))
            let expectedRequestID = requestIDFromFixture(Data(base.utf8))

            for mutationName in mutationNames {
                let variants = try responseMutationVariants(
                    base: base,
                    mutation: mutationName,
                    expectedInstanceID: expectedInstanceID
                )
                XCTAssertFalse(variants.isEmpty, "mutation family produced no variants: \(id).\(mutationName)")
                for variant in variants {
                    do {
                        _ = try ResponseValidator.validate(
                            frame: Data(variant.frame.utf8),
                            expectedRequestID: expectedRequestID,
                            method: .health,
                            expectedInstanceID: expectedInstanceID
                        )
                        XCTFail("accepted strict response mutation \(id).\(variant.label)")
                    } catch let error as ResponseValidationError {
                        if case .serverError = error {
                            XCTFail("accepted strict response mutation \(id).\(variant.label) as a server error")
                        }
                    } catch {
                        XCTFail("unexpected validator error for \(id).\(variant.label): \(error)")
                    }
                }
            }
        }

        XCTAssertEqual(observedIDs, selectedIDs)
    }

    private func responseMutationVariants(
        base: String,
        mutation: String,
        expectedInstanceID: String
    ) throws -> [ResponseMutationVariant] {
        let wrongInstanceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let wrongRequestID = "22222222-2222-4222-8222-222222222222"
        let requestID = try XCTUnwrap(requestIDFromFixture(Data(base.utf8)))
        let isSuccess = base.contains("\"result\":{\"")
        let variants: [(String, String)]

        switch mutation {
        case "missing_each_field":
            if isSuccess {
                variants = [
                    ("protocol_version", try replacing(base, "\"protocol_version\":1,", with: "")),
                    ("request_id", try replacing(base, "\"request_id\":\"\(requestID)\",", with: "")),
                    ("result", try replacing(base, "\"result\":{\"instance_id\":\"\(expectedInstanceID)\",\"state\":\"ready\"},", with: "")),
                    ("error", try replacing(base, ",\"error\":null", with: "")),
                    ("instance_id", try replacing(base, "\"instance_id\":\"\(expectedInstanceID)\",", with: "")),
                    ("state", try replacing(base, ",\"state\":\"ready\"", with: ""))
                ]
            } else {
                variants = [
                    ("protocol_version", try replacing(base, "\"protocol_version\":1,", with: "")),
                    ("request_id", try replacing(base, "\"request_id\":\"\(requestID)\",", with: "")),
                    ("result", try replacing(base, "\"result\":null,", with: "")),
                    ("error", try replacing(base, ",\"error\":{\"code\":\"unknown_method\",\"message\":\"request method is not supported\"}", with: "")),
                    ("code", try replacing(base, "\"code\":\"unknown_method\",", with: "")),
                    ("message", try replacing(base, ",\"message\":\"request method is not supported\"", with: ""))
                ]
            }
        case "duplicate_each_key":
            var duplicateVariants = [
                ("protocol_version", try replacing(base, "\"protocol_version\":1,", with: "\"protocol_version\":1,\"protocol_version\":1,")),
                ("request_id", try replacing(base, "\"request_id\":\"\(requestID)\",", with: "\"request_id\":\"\(requestID)\",\"request_id\":\"\(requestID)\",")),
                ("result", try replacing(base, "\"result\":", with: "\"result\":null,\"result\":")),
                ("error", try replacing(base, "\"error\":", with: "\"error\":null,\"error\":"))
            ]
            if isSuccess {
                duplicateVariants.append(("instance_id", try replacing(base, "\"instance_id\":\"\(expectedInstanceID)\",", with: "\"instance_id\":\"\(expectedInstanceID)\",\"instance_id\":\"\(expectedInstanceID)\",")))
                duplicateVariants.append(("state", try replacing(base, "\"state\":\"ready\"", with: "\"state\":\"ready\",\"state\":\"ready\"")))
            } else {
                duplicateVariants.append(("code", try replacing(base, "\"code\":\"unknown_method\",", with: "\"code\":\"unknown_method\",\"code\":\"unknown_method\",")))
                duplicateVariants.append(("message", try replacing(base, "\"message\":\"request method is not supported\"", with: "\"message\":\"request method is not supported\",\"message\":\"request method is not supported\"")))
            }
            variants = duplicateVariants
        case "unknown_each_depth":
            let nestedTarget = isSuccess
                ? "\"state\":\"ready\""
                : "\"message\":\"request method is not supported\""
            let nestedReplacement = isSuccess
                ? "\"state\":\"ready\",\"unknown\":true"
                : "\"message\":\"request method is not supported\",\"unknown\":true"
            variants = [
                ("top_level", try replacing(base, ",\"error\":", with: ",\"unknown\":true,\"error\":")),
                ("nested", try replacing(base, nestedTarget, with: nestedReplacement))
            ]
        case "wrong_type_each_field":
            var wrongTypeVariants = [
                ("protocol_version", try replacing(base, "\"protocol_version\":1", with: "\"protocol_version\":\"1\"")),
                ("request_id", try replacing(base, "\"request_id\":\"\(requestID)\"", with: "\"request_id\":1"))
            ]
            if isSuccess {
                wrongTypeVariants.append(("result", try replacing(base, "\"result\":{\"instance_id\":\"\(expectedInstanceID)\",\"state\":\"ready\"}", with: "\"result\":[]")))
                wrongTypeVariants.append(("error", try replacing(base, "\"error\":null", with: "\"error\":false")))
                wrongTypeVariants.append(("instance_id", try replacing(base, "\"instance_id\":\"\(expectedInstanceID)\"", with: "\"instance_id\":1")))
                wrongTypeVariants.append(("state", try replacing(base, "\"state\":\"ready\"", with: "\"state\":true")))
            } else {
                wrongTypeVariants.append(("result", try replacing(base, "\"result\":null", with: "\"result\":[]")))
                wrongTypeVariants.append(("error", try replacing(base, "\"error\":{\"code\":\"unknown_method\",\"message\":\"request method is not supported\"}", with: "\"error\":false")))
                wrongTypeVariants.append(("code", try replacing(base, "\"code\":\"unknown_method\"", with: "\"code\":1")))
                wrongTypeVariants.append(("message", try replacing(base, "\"message\":\"request method is not supported\"", with: "\"message\":true")))
            }
            variants = wrongTypeVariants
        case "wrong_request_id":
            variants = [("request_id", try replacing(base, requestIDFromFixture(Data(base.utf8))!, with: wrongRequestID))]
        case "wrong_instance_id":
            variants = [("instance_id", try replacing(base, expectedInstanceID, with: wrongInstanceID))]
        case "wrong_state":
            variants = [("state", try replacing(base, "\"state\":\"ready\"", with: "\"state\":\"starting\""))]
        case "both_result_and_error":
            variants = [("result_and_error", try replacing(base, "\"error\":null", with: "\"error\":{\"code\":\"internal\",\"message\":\"failure\"}"))]
        case "both_null":
            variants = [("result_and_error", try replacing(base, "\"result\":{\"instance_id\":\"\(expectedInstanceID)\",\"state\":\"ready\"}", with: "\"result\":null"))]
        case "unknown_error_code":
            variants = [("code", try replacing(base, "\"code\":\"unknown_method\"", with: "\"code\":\"not-allowed\""))]
        case "message_257_bytes":
            variants = [("message", try replacing(base, "\"message\":\"request method is not supported\"", with: "\"message\":\"\(String(repeating: "m", count: 257))\""))]
        case "non_null_result":
            variants = [("result", try replacing(base, "\"result\":null", with: "\"result\":{\"instance_id\":\"\(expectedInstanceID)\",\"state\":\"ready\"}"))]
        default:
            throw NSError(domain: "HidhoggTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "unsupported response mutation \(mutation)"])
        }

        return variants.map { ResponseMutationVariant(label: $0.0, frame: $0.1) }
    }

    private func replacing(_ value: String, _ target: String, with replacement: String) throws -> String {
        guard let range = value.range(of: target) else {
            throw NSError(domain: "HidhoggTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "fixture mutation target missing"])
        }
        return value.replacingCharacters(in: range, with: replacement)
    }

    private func requestIDFromFixture(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = object["request_id"] as? String else {
            return nil
        }
        return requestID
    }

    private func fixtureRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let fixtureRoot = candidate.appendingPathComponent("api/protocol/v1", isDirectory: true)
            if FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent("cases.json").path) {
                return fixtureRoot
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(domain: "HidhoggTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "shared protocol fixtures were not found"])
    }
}

private struct ResponseMutationVariant {
    let label: String
    let frame: String
}

final class OutputTailTests: XCTestCase {
    func testTailRetainsOnlyTheNewestBytes() {
        let tail = OutputTail(capacity: 4)
        tail.append(Data("abcd".utf8))
        tail.append(Data("ef".utf8))
        XCTAssertEqual(tail.data, Data("cdef".utf8))
    }

    func testOutputDrainerKeepsStdoutAndStderrSeparate() throws {
        let standardOutput = Pipe()
        let standardError = Pipe()
        let stdoutTail = OutputTail()
        let stderrTail = OutputTail()
        let drainer = OutputDrainer(
            standardOutput: standardOutput.fileHandleForReading,
            standardError: standardError.fileHandleForReading,
            standardOutputTail: stdoutTail,
            standardErrorTail: stderrTail
        )
        drainer.start()
        defer { drainer.stop() }

        try standardOutput.fileHandleForWriting.write(contentsOf: Data("stdout".utf8))
        try standardError.fileHandleForWriting.write(contentsOf: Data("stderr".utf8))
        for _ in 0..<100 where stdoutTail.data.isEmpty || stderrTail.data.isEmpty {
            Thread.sleep(forTimeInterval: 0.001)
        }

        XCTAssertEqual(stdoutTail.text, "stdout")
        XCTAssertEqual(stderrTail.text, "stderr")
        XCTAssertEqual(OutputTail().capacity, 65_536)
    }

    func testFoundationLauncherDrainsBothPipesPastPipeCapacity() throws {
        let stdoutTail = OutputTail()
        let stderrTail = OutputTail()
        let script = #"/usr/bin/awk 'BEGIN { for (i = 0; i < 70000; i++) printf "o" }'; /usr/bin/awk 'BEGIN { for (i = 0; i < 70000; i++) printf "e" }' >&2"#
        let process = try FoundationProcessLauncher().launch(
            request: LaunchRequest(executablePath: "/bin/sh", arguments: ["-c", script]),
            standardOutputTail: stdoutTail,
            standardErrorTail: stderrTail
        )

        for _ in 0..<500 {
            if !process.isRunning,
               stdoutTail.data.count == 65_536,
               stderrTail.data.count == 65_536 {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.forceTerminate()
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(stdoutTail.data, Data(repeating: 0x6f, count: 65_536))
        XCTAssertEqual(stderrTail.data, Data(repeating: 0x65, count: 65_536))
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
            try? PathSecurity.removeMatchingGeneration(
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
    static let value = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
    static let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    func makeUUID() -> UUID { Self.value }
}
