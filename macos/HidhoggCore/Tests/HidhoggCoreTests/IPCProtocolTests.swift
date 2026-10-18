import Foundation
import XCTest
@testable import HidhoggCore

final class IPCProtocolTests: XCTestCase {
    private let instanceID = "11111111-1111-4111-8111-111111111111"
    private let requestID = "22222222-2222-4222-8222-222222222222"
    private let digest = String(repeating: "a", count: 64)

    func testJSONNumbersRetainExactIntegerLexemes() throws {
        for spelling in ["1", "-1", "9223372036854775807"] {
            let value = try IPCJSONCodec.decode(Data(spelling.utf8))
            XCTAssertEqual(value.integerValue.map(String.init), spelling)
        }
        for spelling in ["1.0", "1e0", "9223372036854775808", "-9223372036854775809"] {
            let value = try IPCJSONCodec.decode(Data(spelling.utf8))
            XCTAssertNil(value.integerValue, spelling)
        }
        XCTAssertThrowsError(try IPCJSONCodec.decode(Data("01".utf8)))
    }

    func testDuplicateKeysAreRejectedAtEveryDepthByDecodedBytes() throws {
        for json in [
            #"{"outer":{"value":1,"value":2}}"#,
            #"{"outer":{"value":1,"\u0076alue":2}}"#,
        ] {
            XCTAssertThrowsError(try IPCJSONCodec.decode(Data(json.utf8))) { error in
                XCTAssertEqual(error as? IPCJSONError, .duplicateKey)
            }
        }

        let distinctCanonicalForms = #"{"é":1,"é":2}"#
        let value = try IPCJSONCodec.decode(Data(distinctCanonicalForms.utf8))
        XCTAssertEqual(value.objectFields?.count, 2)
    }

    func testJSONRejectsInvalidUTF8AndUnpairedSurrogates() {
        XCTAssertThrowsError(try IPCJSONCodec.decode(Data([0x22, 0xff, 0x22]))) { error in
            XCTAssertEqual(error as? IPCJSONError, .invalidUTF8)
        }
        XCTAssertThrowsError(try IPCJSONCodec.decode(Data(#""\ud800""#.utf8)))
        XCTAssertThrowsError(try IPCJSONCodec.decode(Data(#""\udc00""#.utf8)))
    }

    func testJSONNestingLimitAccepts512AndRejects513Levels() throws {
        let atLimit = String(repeating: "[", count: 512) + "0" + String(repeating: "]", count: 512)
        XCTAssertNoThrow(try IPCJSONCodec.decode(Data(atLimit.utf8)))

        let overLimit = String(repeating: "[", count: 513) + "0" + String(repeating: "]", count: 513)
        XCTAssertThrowsError(try IPCJSONCodec.decode(Data(overLimit.utf8))) { error in
            XCTAssertEqual(error as? IPCJSONError, .nestingLimit)
        }
    }

    func testFirstLFFramingIncludesTerminatorAndIgnoresLaterBytes() throws {
        let exact = Data(repeating: 0x61, count: IPCProtocol.maximumFrameBytes - 1) + Data([0x0a]) + Data("ignored".utf8)
        XCTAssertEqual(try IPCProtocol.firstFrame(in: exact).count, IPCProtocol.maximumFrameBytes)
        let oversized = Data(repeating: 0x61, count: IPCProtocol.maximumFrameBytes) + Data([0x0a])
        XCTAssertThrowsError(try IPCProtocol.firstFrame(in: oversized)) { error in
            XCTAssertEqual(error as? IPCFrameError, .tooLarge)
        }
        XCTAssertThrowsError(try IPCProtocol.firstFrame(in: Data("partial".utf8))) { error in
            XCTAssertEqual(error as? IPCFrameError, .incomplete)
        }
    }

    func testRequestValidationPreservesProtocolPrecedenceAndClosedParams() throws {
        let wrongVersion = request(version: "1.0", method: "health", params: #"{"instance_id":"\#(instanceID)"}"#)
        XCTAssertEqual(try failure(for: wrongVersion).code, "unsupported_version")

        let unknownMethod = request(version: "1", method: "future.method", params: #"{"instance_id":"\#(instanceID)"}"#)
        XCTAssertEqual(try failure(for: unknownMethod).code, "unknown_method")

        let extraField = request(version: "1", method: "health", params: #"{"instance_id":"\#(instanceID)","unexpected":true}"#)
        XCTAssertEqual(try failure(for: extraField).code, "invalid_envelope")

        let duplicateNested = request(
            version: "1",
            method: "config.editor.position.patch",
            params: #"{"instance_id":"\#(instanceID)","expected_digest":"\#(digest)","profile_id":"default","position_id":"0_0","patch":{"label":{"op":"reset","op":"set"}}}"#
        )
        XCTAssertEqual(try failure(for: duplicateNested).code, "invalid_envelope")

        let malformed = Data("{not json}\n".utf8)
        XCTAssertEqual(try failure(for: malformed).code, "invalid_json")
    }

    func testPatchAcceptsEmptyKeepAndTypedResetOrSetOnly() throws {
        let emptyPatch = request(
            version: "1", method: "config.editor.position.patch",
            params: #"{"instance_id":"\#(instanceID)","expected_digest":"\#(digest)","profile_id":"default","position_id":"0_0","patch":{}}"#
        )
        guard case .success(let parsed) = IPCProtocol.decodeRequest(emptyPatch) else {
            return XCTFail("empty patch should be a valid no-op")
        }
        XCTAssertEqual(parsed.method, .editorPositionPatch)

        let malformedOperations = [
            #"{"label":{"op":"set"}}"#,
            #"{"label":{"op":"reset","value":"x"}}"#,
            #"{"label":null}"#,
            #"{"label":{"op":"set","value":"x","extra":1}}"#,
            #"{"position":"0_0"}"#,
            #"{"action":{"op":"set","value":{"type":"execute","executable":"/bin/true","text":"leak"}}}"#,
        ]
        for patch in malformedOperations {
            let frame = request(
                version: "1", method: "config.editor.position.patch",
                params: #"{"instance_id":"\#(instanceID)","expected_digest":"\#(digest)","profile_id":"default","position_id":"0_0","patch":\#(patch)}"#
            )
            XCTAssertEqual(try failure(for: frame).code, "invalid_envelope", patch)
        }
    }

    func testCommandEncodingUsesClosedTypedPatchAndLF() throws {
        let patch = ConfigurationPositionPatch(
            label: .set("Launch"),
            background: .reset,
            action: .set(.activateProfile(profileID: "other", gesture: .press))
        )
        let frame = try IPCProtocol.encodeRequest(
            requestID: requestID,
            command: .editorPatchPosition(expectedDigest: digest, profileID: "default", positionID: "0_0", patch: patch),
            instanceID: instanceID
        )
        XCTAssertEqual(frame.last, 0x0a)
        guard case .success(let request) = IPCProtocol.decodeRequest(frame) else {
            return XCTFail("encoded typed request should decode")
        }
        XCTAssertEqual(request.method, .editorPositionPatch)
        XCTAssertEqual(request.instanceID, instanceID)
        XCTAssertEqual(request.params.value(for: "patch")?.objectFields?.count, 3)
    }

    private func failure(for frame: Data, file: StaticString = #filePath, line: UInt = #line) throws -> IPCProtocolFailure {
        guard case .failure(let failure) = IPCProtocol.decodeRequest(frame) else {
            XCTFail("expected protocol rejection", file: file, line: line)
            throw IPCFrameError.invalidFrame
        }
        return failure
    }

    private func request(version: String, method: String, params: String) -> Data {
        Data("{\"protocol_version\":\(version),\"request_id\":\"\(requestID)\",\"method\":\"\(method)\",\"params\":\(params)}\n".utf8)
    }
}
