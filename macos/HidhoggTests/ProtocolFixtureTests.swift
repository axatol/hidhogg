import Foundation
import XCTest
import HidhoggCore
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

    func testProfileRequestsUseStrictWireShapes() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let list = ProtocolV1.request(
            method: .profilesList,
            requestID: requestID,
            instanceID: instanceID
        )
        XCTAssertEqual(
            String(data: list, encoding: .utf8),
            "{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"method\":\"profiles.list\",\"params\":{\"instance_id\":\"\(instanceID)\"}}\n"
        )

        let activation = ProtocolV1.request(
            method: .profilesActivate,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile"
        )
        XCTAssertEqual(
            String(data: activation, encoding: .utf8),
            "{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"method\":\"profiles.activate\",\"params\":{\"instance_id\":\"\(instanceID)\",\"profile_id\":\"Work.Profile\"}}\n"
        )
        XCTAssertThrowsError(
            try ProtocolV1.profileRequest(
                method: .profilesActivate,
                requestID: requestID,
                instanceID: instanceID
            )
        ) { error in
            XCTAssertEqual(error as? ProtocolRequestValidationError, .invalidProfileID)
        }
        XCTAssertThrowsError(
            try ProtocolV1.profileRequest(
                method: .profilesActivate,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "unsafe\"profile"
            )
        ) { error in
            XCTAssertEqual(error as? ProtocolRequestValidationError, .invalidProfileID)
        }
        XCTAssertThrowsError(
            try ProtocolV1.profileRequest(
                method: .profilesList,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "unexpected"
            )
        ) { error in
            XCTAssertEqual(error as? ProtocolRequestValidationError, .unexpectedProfileID)
        }
    }

    func testConfigEditorRequestsUseExactEscapedShapesAndStayWithinFrameLimit() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)
        let escapedLabel = #"Copy "quoted"  Profile"#
        let cases: [(RuntimeMethod, Data, Set<String>)] = [
            (.configEditorSnapshot, try ProtocolV1.configEditorRequest(
                method: .configEditorSnapshot,
                requestID: requestID,
                instanceID: instanceID
            ), ["instance_id"]),
            (.configEditorProfileGet, try ProtocolV1.configEditorRequest(
                method: .configEditorProfileGet,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                sourceDigest: digest
            ), ["instance_id", "profile_id", "source_digest"]),
            (.configEditorProfileLabelSet, try ProtocolV1.configEditorRequest(
                method: .configEditorProfileLabelSet,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                expectedDigest: digest,
                label: escapedLabel
            ), ["instance_id", "profile_id", "expected_digest", "label"]),
            (.configEditorProfileCreate, try ProtocolV1.configEditorRequest(
                method: .configEditorProfileCreate,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Copy.Profile",
                expectedDigest: digest,
                label: escapedLabel
            ), ["instance_id", "profile_id", "expected_digest", "label"]),
            (.configEditorProfileDelete, try ProtocolV1.configEditorRequest(
                method: .configEditorProfileDelete,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                expectedDigest: digest
            ), ["instance_id", "profile_id", "expected_digest"])
        ]

        for (method, frame, expectedParameterKeys) in cases {
            XCTAssertLessThanOrEqual(frame.count, ProtocolV1.frameLimit)
            let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(frame.dropLast())) as? [String: Any])
            XCTAssertEqual(envelope["protocol_version"] as? Int, ProtocolV1.protocolVersion)
            XCTAssertEqual(envelope["request_id"] as? String, requestID)
            XCTAssertEqual(envelope["method"] as? String, method.rawValue)
            let params = try XCTUnwrap(envelope["params"] as? [String: Any])
            XCTAssertEqual(Set(params.keys), expectedParameterKeys)
            XCTAssertEqual(params["instance_id"] as? String, instanceID)
            if method == .configEditorProfileLabelSet || method == .configEditorProfileCreate {
                XCTAssertEqual(params["label"] as? String, escapedLabel)
            }
        }

        let explicitSource = try ProtocolV1.configEditorRequest(
            method: .configEditorProfileCreate,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Copy.Profile",
            expectedDigest: digest,
            label: "Copy",
            sourceProfileID: "Work.Profile"
        )
        let explicitParams = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(explicitSource.dropLast())) as? [String: Any])?["params"] as? [String: Any]
        )
        XCTAssertEqual(explicitParams["source_profile_id"] as? String, "Work.Profile")
    }

    func testConfigEditorRequestsRejectInvalidAndUnexpectedFields() {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)

        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorProfileGet,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            sourceDigest: digest.uppercased()
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidSourceDigest) }
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorProfileLabelSet,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            expectedDigest: digest,
            label: "\n"
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidLabel) }
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorProfileCreate,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Copy.Profile",
            expectedDigest: digest,
            label: "Copy",
            sourceProfileID: ""
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidProfileID) }
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorProfileDelete,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            expectedDigest: digest,
            label: "Unexpected"
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidFields) }
    }

    func testBlankPositionLabelsAreAllowedWithoutWeakeningProfileLabels() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)

        let frame = try ProtocolV1.configEditorRequest(
            method: .configEditorPositionLabelSet,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "work",
            positionID: "0_0",
            expectedDigest: digest,
            label: ""
        )
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: frame) as? [String: Any])
        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        XCTAssertEqual(params["label"] as? String, "")

        let response = try ResponseValidator.validateConfigEditorPosition(
            frame: configEditorSuccessFrame(requestID: requestID, result: [
                "instance_id": instanceID, "source_digest": digest,
                "profile_id": "work", "position_id": "0_0", "label": ""
            ]),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "work",
            expectedPositionID: "0_0"
        )
        XCTAssertEqual(response.label, "")
        XCTAssertFalse(ProfileValidation.isValidLabel(""))
        for invalid in [" ", "\n", "\u{200b}"] {
            XCTAssertFalse(ProfileValidation.isValidPositionLabel(invalid))
        }
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorProfileLabelSet,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "work",
            expectedDigest: digest,
            label: ""
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidLabel) }
    }

    func testConfigEditorPositionRequestsUseExactEscapedShapesAndRejectInvalidFields() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)
        let escapedLabel = #"Welcome "Now" \ Slot"#
        let cases: [(RuntimeMethod, Data, Set<String>)] = [
            (.configEditorPositionsList, try ProtocolV1.configEditorRequest(
                method: .configEditorPositionsList,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                sourceDigest: digest
            ), ["instance_id", "source_digest", "profile_id"]),
            (.configEditorPositionGet, try ProtocolV1.configEditorRequest(
                method: .configEditorPositionGet,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                positionID: "0_0",
                sourceDigest: digest
            ), ["instance_id", "source_digest", "profile_id", "position_id"]),
            (.configEditorPositionLabelSet, try ProtocolV1.configEditorRequest(
                method: .configEditorPositionLabelSet,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                positionID: "0_0",
                expectedDigest: digest,
                label: escapedLabel
            ), ["instance_id", "expected_digest", "profile_id", "position_id", "label"])
        ]

        for (method, frame, expectedKeys) in cases {
            XCTAssertLessThanOrEqual(frame.count, ProtocolV1.frameLimit)
            let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(frame.dropLast())) as? [String: Any])
            XCTAssertEqual(envelope["request_id"] as? String, requestID)
            XCTAssertEqual(envelope["method"] as? String, method.rawValue)
            let params = try XCTUnwrap(envelope["params"] as? [String: Any])
            XCTAssertEqual(Set(params.keys), expectedKeys)
            XCTAssertEqual(params["instance_id"] as? String, instanceID)
            if method == .configEditorPositionLabelSet {
                XCTAssertEqual(params["label"] as? String, escapedLabel)
            }
        }

        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorPositionGet,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            positionID: "bad position",
            sourceDigest: digest
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidPositionID) }
        for invalidPositionID in ["tile-0", "5_2"] {
            XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
                method: .configEditorPositionGet,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                positionID: invalidPositionID,
                sourceDigest: digest
            )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidPositionID) }
            XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
                method: .configEditorPositionLabelSet,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                positionID: invalidPositionID,
                expectedDigest: digest,
                label: "Updated"
            )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidPositionID) }
        }
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorPositionsList,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            positionID: "unexpected",
            sourceDigest: digest
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidFields) }
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorPositionLabelSet,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            positionID: "0_0",
            expectedDigest: digest.uppercased(),
            label: "Updated"
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidSourceDigest) }
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorPositionLabelSet,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            positionID: "0_0",
            expectedDigest: digest,
            label: "\n"
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidLabel) }
    }

    func testConfigEditorPositionPatchEncodesKeepSetResetAndClosedActions() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)
        let patch = ConfigurationPositionPatch(
            label: .set("Clock"),
            background: .set("#12345678"),
            labelAlignment: .reset,
            labelSize: .keep,
            notificationSources: .set(["Calendar", "Weather"]),
            action: .set(.execute(
                executable: "/usr/bin/example",
                arguments: ["--mode", "ordered"],
                timeoutSeconds: 10,
                gesture: .press
            ))
        )
        let frame = try ProtocolV1.configEditorRequest(
            method: .configEditorPositionPatch,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            positionID: "0_0",
            expectedDigest: digest,
            positionPatch: patch
        )
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(frame.dropLast())) as? [String: Any])
        XCTAssertLessThanOrEqual(frame.count, ProtocolV1.frameLimit)
        XCTAssertEqual(envelope["request_id"] as? String, requestID)
        XCTAssertEqual(envelope["method"] as? String, "config.editor.position.patch")
        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["instance_id", "expected_digest", "profile_id", "position_id", "patch"])
        let encoded = try XCTUnwrap(params["patch"] as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["label", "background", "label_alignment", "notification_sources", "action"])
        XCTAssertEqual(try XCTUnwrap(encoded["label"] as? [String: Any])["value"] as? String, "Clock")
        XCTAssertEqual(try XCTUnwrap(encoded["background"] as? [String: Any])["value"] as? String, "#12345678")
        XCTAssertEqual(try XCTUnwrap(encoded["label_alignment"] as? [String: Any])["op"] as? String, "reset")
        XCTAssertNil(encoded["label_size"])
        XCTAssertEqual(try XCTUnwrap(encoded["notification_sources"] as? [String: Any])["value"] as? [String], ["Calendar", "Weather"])
        let actionEdit = try XCTUnwrap(encoded["action"] as? [String: Any])
        XCTAssertEqual(actionEdit["op"] as? String, "set")
        let action = try XCTUnwrap(actionEdit["value"] as? [String: Any])
        XCTAssertEqual(Set(action.keys), ["type", "executable", "arguments", "timeout_seconds", "gesture"])
        XCTAssertEqual(action["type"] as? String, "execute")
        XCTAssertEqual(action["arguments"] as? [String], ["--mode", "ordered"])
        XCTAssertEqual(action["timeout_seconds"] as? Int, 10)
        XCTAssertEqual(action["gesture"] as? String, "press")

        let emptyPatchFrame = try ProtocolV1.configEditorRequest(
            method: .configEditorPositionPatch,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            positionID: "0_0",
            expectedDigest: digest,
            positionPatch: ConfigurationPositionPatch()
        )
        let emptyEnvelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(emptyPatchFrame.dropLast())) as? [String: Any]
        )
        let emptyParams = try XCTUnwrap(emptyEnvelope["params"] as? [String: Any])
        let emptyPatch = try XCTUnwrap(emptyParams["patch"] as? [String: Any])
        XCTAssertTrue(emptyPatch.isEmpty)

        let actions: [ConfiguredAction] = [
            .activateProfile(profileID: "Default", gesture: .release),
            .execute(executable: "/bin/true", arguments: [], timeoutSeconds: 1, gesture: .press),
            .typeText(text: "Ready", gesture: .release),
            .keyPress(key: "enter", gesture: .press),
            .execute(executable: "/bin/true", arguments: [], timeoutSeconds: 60, gesture: .release)
        ]
        let expectedTypes = ["activate_profile", "execute", "type_text", "key_press", "execute"]
        for (action, expectedType) in zip(actions, expectedTypes) {
            let actionPatch = ConfigurationPositionPatch(action: .set(action))
            let actionFrame = try ProtocolV1.configEditorRequest(
                method: .configEditorPositionPatch,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                positionID: "0_0",
                expectedDigest: digest,
                positionPatch: actionPatch
            )
            let actionEnvelope = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(actionFrame.dropLast())) as? [String: Any]
            )
            let actionParams = try XCTUnwrap(actionEnvelope["params"] as? [String: Any])
            let actionFields = try XCTUnwrap(actionParams["patch"] as? [String: Any])
            let edit = try XCTUnwrap(actionFields["action"] as? [String: Any])
            let value = try XCTUnwrap(edit["value"] as? [String: Any])
            XCTAssertEqual(value["type"] as? String, expectedType)
        }
    }

    func testConfigEditorPositionPatchRejectsInvalidValuesAndUnexpectedFields() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)
        let invalidPatches = [
            ConfigurationPositionPatch(background: .set("#123")),
            ConfigurationPositionPatch(labelAlignment: .set("top")),
            ConfigurationPositionPatch(labelSize: .set(33)),
            ConfigurationPositionPatch(notificationSources: .set([])),
            ConfigurationPositionPatch(notificationSources: .set(["Calendar", "Calendar"])),
            ConfigurationPositionPatch(action: .set(.typeText(text: "", gesture: .press))),
            ConfigurationPositionPatch(action: .set(.execute(
                executable: "/usr/bin/example",
                arguments: [],
                timeoutSeconds: 0,
                gesture: .press
            ))),
            ConfigurationPositionPatch(action: .set(.execute(
                executable: "/usr/bin/example",
                arguments: [],
                timeoutSeconds: 61,
                gesture: .press
            ))),
            ConfigurationPositionPatch(action: .set(.execute(
                executable: "relative/path",
                arguments: [],
                timeoutSeconds: 10,
                gesture: .release
            )))
        ]
        for patch in invalidPatches {
            XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
                method: .configEditorPositionPatch,
                requestID: requestID,
                instanceID: instanceID,
                profileID: "Work.Profile",
                positionID: "0_0",
                expectedDigest: digest,
                positionPatch: patch
            )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidPatch) }
        }
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorPositionPatch,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            positionID: "0_0",
            expectedDigest: digest
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidPatch) }

        let unexpectedPatch = ConfigurationPositionPatch(label: .reset)
        XCTAssertThrowsError(try ProtocolV1.configEditorRequest(
            method: .configEditorPositionGet,
            requestID: requestID,
            instanceID: instanceID,
            profileID: "Work.Profile",
            positionID: "0_0",
            sourceDigest: digest,
            positionPatch: unexpectedPatch
        )) { XCTAssertEqual($0 as? ProtocolRequestValidationError, .invalidFields) }
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

    func testConfigEditorResponsesAreTypedBoundAndStrict() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let otherInstanceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let digest = String(repeating: "a", count: 64)
        let snapshotResult: [String: Any] = [
            "instance_id": instanceID,
            "source_digest": digest,
            "revision": 2,
            "default_profile_id": "default",
            "current_profile_id": "Work.Profile",
            "profile_ids": ["default", "Work.Profile"]
        ]
        let snapshot = try ResponseValidator.validateConfigEditorSnapshot(
            frame: configEditorSuccessFrame(requestID: requestID, result: snapshotResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )
        XCTAssertEqual(snapshot.requestID, requestID)
        XCTAssertEqual(snapshot.instanceID, instanceID)
        XCTAssertEqual(snapshot.sourceDigest, digest)
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.defaultProfileID, "default")
        XCTAssertEqual(snapshot.currentProfileID, "Work.Profile")
        XCTAssertEqual(snapshot.profileIDs, ["default", "Work.Profile"])
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: configEditorSuccessFrame(requestID: requestID, result: snapshotResult),
            expectedRequestID: "22222222-2222-4222-8222-222222222222",
            expectedInstanceID: instanceID
        ))

        let profileResult: [String: Any] = [
            "instance_id": instanceID,
            "source_digest": digest,
            "profile_id": "Work.Profile",
            "label": "Work \"Compact\""
        ]
        let profile = try ResponseValidator.validateConfigEditorProfile(
            frame: configEditorSuccessFrame(requestID: requestID, result: profileResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        )
        XCTAssertEqual(profile.label, "Work \"Compact\"")

        let mutationResult: [String: Any] = [
            "instance_id": instanceID,
            "source_digest": digest,
            "file_commit": "committed",
            "reload_outcome": "changed",
            "revision": 3,
            "effect": "catalog",
            "reason": "none"
        ]
        let mutation = try ResponseValidator.validateConfigEditorMutation(
            frame: configEditorSuccessFrame(requestID: requestID, result: mutationResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            method: .configEditorProfileCreate
        )
        XCTAssertEqual(mutation.fileCommit, .committed)
        XCTAssertEqual(mutation.reloadOutcome, .changed)
        XCTAssertEqual(mutation.revision, 3)
        XCTAssertEqual(mutation.effect, .catalog)
        XCTAssertEqual(mutation.reason, .none)

        var wrongInstance = snapshotResult
        wrongInstance["instance_id"] = otherInstanceID
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: configEditorSuccessFrame(requestID: requestID, result: wrongInstance),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        ))
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorProfile(
            frame: configEditorSuccessFrame(requestID: requestID, result: profileResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: String(repeating: "b", count: 64),
            expectedProfileID: "Work.Profile"
        ))
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorProfile(
            frame: configEditorSuccessFrame(requestID: requestID, result: profileResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Other.Profile"
        ))

        var extraProfileField = profileResult
        extraProfileField["source_text"] = "complete profile"
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorProfile(
            frame: configEditorSuccessFrame(requestID: requestID, result: extraProfileField),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))
        let duplicateDigest = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"instance_id\":\"\(instanceID)\",\"source_digest\":\"\(digest)\",\"source_digest\":\"\(digest)\",\"profile_id\":\"Work.Profile\",\"label\":\"Work\"},\"error\":null}\n".utf8)
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorProfile(
            frame: duplicateDigest,
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))

        let staleFrame = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":null,\"error\":{\"code\":\"stale_source\",\"message\":\"configuration source changed; refresh and retry\"}}\n".utf8)
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: staleFrame,
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )) { error in
            XCTAssertEqual(
                error as? ResponseValidationError,
                .serverError(RuntimeError(code: "stale_source", message: "configuration source changed; refresh and retry"))
            )
        }
        let pathBearingErrorFrame = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":null,\"error\":{\"code\":\"stale_source\",\"message\":\"/private/config.toml changed\"}}\n".utf8)
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: pathBearingErrorFrame,
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )) { error in
            XCTAssertEqual(
                error as? ResponseValidationError,
                .serverError(RuntimeError(code: "stale_source", message: "configuration source changed; refresh and retry"))
            )
        }
    }

    func testConfigEditorErrorsNormalizeByCodeAndEnforceMessageBounds() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let makeFrame: (String, String) -> Data = { code, message in
            Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":null,\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}\n".utf8)
        }
        let coreErrors: [(code: String, message: String, safeMessage: String)] = [
            ("stale_source", "configuration source changed", "configuration source changed; refresh and retry"),
            ("stale_source", "/private/config.toml changed", "configuration source changed; refresh and retry"),
            ("profile_not_found", "profile was not found", "profile or position was not found"),
            ("profile_not_found", "profile or position was not found", "profile or position was not found"),
            ("reload_rejected", "configuration is unavailable", "configuration reload was rejected"),
            ("reload_rejected", "configuration reload was rejected", "configuration reload was rejected"),
            ("device_write_failed", "device update failed", "device update failed"),
            ("file_commit_failed", "configuration file could not be committed", "configuration edit could not be committed"),
            ("edit_invalid", "configuration edit is invalid", "configuration edit is invalid"),
            ("busy", "runtime is busy", "runtime is busy"),
            ("shutting_down", "runtime is not ready", "runtime is shutting down"),
        ]

        for item in coreErrors {
            XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
                frame: makeFrame(item.code, item.message),
                expectedRequestID: requestID,
                expectedInstanceID: instanceID
            )) { error in
                XCTAssertEqual(
                    error as? ResponseValidationError,
                    .serverError(RuntimeError(code: item.code, message: item.safeMessage))
                )
            }
        }

        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: makeFrame("stale_source", String(repeating: "x", count: 256)),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )) { error in
            XCTAssertEqual(
                error as? ResponseValidationError,
                .serverError(RuntimeError(code: "stale_source", message: "configuration source changed; refresh and retry"))
            )
        }
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: makeFrame("stale_source", String(repeating: "é", count: 128)),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )) { error in
            XCTAssertEqual(
                error as? ResponseValidationError,
                .serverError(RuntimeError(code: "stale_source", message: "configuration source changed; refresh and retry"))
            )
        }
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: makeFrame("stale_source", String(repeating: "x", count: 257)),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )) { XCTAssertEqual($0 as? ResponseValidationError, .invalidError) }
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: makeFrame("stale_source", String(repeating: "é", count: 129)),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )) { XCTAssertEqual($0 as? ResponseValidationError, .invalidError) }
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: makeFrame("unknown_error", "bounded message"),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )) { XCTAssertEqual($0 as? ResponseValidationError, .invalidError) }
        let invalidMessageType = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":null,\"error\":{\"code\":\"stale_source\",\"message\":1}}\n".utf8)
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorSnapshot(
            frame: invalidMessageType,
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )) { XCTAssertEqual($0 as? ResponseValidationError, .invalidError) }
    }

    func testConfigEditorPositionResponsesAreTypedBoundAndStrict() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)
        let coordinates = [
            "0_0", "1_0", "2_0", "3_0", "4_0",
            "0_1", "1_1", "2_1", "3_1", "4_1",
            "0_2", "1_2", "2_2", "3_2"
        ]
        let positionValues: [[String: Any]] = coordinates.map { coordinate in
            ["position_id": coordinate, "position": coordinate]
        }
        let positionsResult: [String: Any] = [
            "instance_id": instanceID,
            "source_digest": digest,
            "profile_id": "Work.Profile",
            "positions": positionValues
        ]
        let positions = try ResponseValidator.validateConfigEditorPositions(
            frame: configEditorSuccessFrame(requestID: requestID, result: positionsResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        )
        XCTAssertEqual(positions.requestID, requestID)
        XCTAssertEqual(positions.instanceID, instanceID)
        XCTAssertEqual(positions.sourceDigest, digest)
        XCTAssertEqual(positions.profileID, "Work.Profile")
        XCTAssertEqual(positions.positions.map(\.position), coordinates)
        XCTAssertEqual(positions.positions.first?.positionID, "0_0")

        var wrongDigest = positionsResult
        wrongDigest["source_digest"] = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPositions(
            frame: configEditorSuccessFrame(requestID: requestID, result: wrongDigest),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))
        var extraListField = positionsResult
        extraListField["source_text"] = "complete configuration"
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPositions(
            frame: configEditorSuccessFrame(requestID: requestID, result: extraListField),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))
        var duplicatePositionIDs = positionsResult
        duplicatePositionIDs["positions"] = positionValues.enumerated().map { index, value in
            var position = value
            if index == 1 {
                position["position_id"] = "0_0"
                position["position"] = "0_0"
            }
            return position
        }
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPositions(
            frame: configEditorSuccessFrame(requestID: requestID, result: duplicatePositionIDs),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))
        var mismatchedPositionID = positionsResult
        mismatchedPositionID["positions"] = positionValues.enumerated().map { index, value in
            var position = value
            if index == 0 { position["position_id"] = coordinates[1] }
            return position
        }
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPositions(
            frame: configEditorSuccessFrame(requestID: requestID, result: mismatchedPositionID),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))
        var arbitraryPositionID = positionsResult
        arbitraryPositionID["positions"] = positionValues.enumerated().map { index, value in
            var position = value
            if index == 0 { position["position_id"] = "tile-0" }
            return position
        }
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPositions(
            frame: configEditorSuccessFrame(requestID: requestID, result: arbitraryPositionID),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))
        var unsupportedCoordinate = positionsResult
        unsupportedCoordinate["positions"] = positionValues.enumerated().map { index, value in
            var position = value
            if index == 0 {
                position["position_id"] = "5_2"
                position["position"] = "5_2"
            }
            return position
        }
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPositions(
            frame: configEditorSuccessFrame(requestID: requestID, result: unsupportedCoordinate),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))
        let duplicatePositionFieldTail = (1..<coordinates.count).map { index in
            "{\"position_id\":\"\(coordinates[index])\",\"position\":\"\(coordinates[index])\"}"
        }.joined(separator: ",")
        let duplicatePositionField = Data(
            "{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"instance_id\":\"\(instanceID)\",\"source_digest\":\"\(digest)\",\"profile_id\":\"Work.Profile\",\"positions\":[{\"position_id\":\"0_0\",\"position_id\":\"0_0\",\"position\":\"0_0\"},\(duplicatePositionFieldTail)]},\"error\":null}\n".utf8
        )
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPositions(
            frame: duplicatePositionField,
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))
        var shortList = positionsResult
        shortList["positions"] = Array(positionValues.dropLast())
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPositions(
            frame: configEditorSuccessFrame(requestID: requestID, result: shortList),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile"
        ))

        let positionResult: [String: Any] = [
            "instance_id": instanceID,
            "source_digest": digest,
            "profile_id": "Work.Profile",
            "position_id": "0_0",
            "label": #"Welcome "Now" \ Slot"#
        ]
        let position = try ResponseValidator.validateConfigEditorPosition(
            frame: configEditorSuccessFrame(requestID: requestID, result: positionResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile",
            expectedPositionID: "0_0"
        )
        XCTAssertEqual(position.positionID, "0_0")
        XCTAssertEqual(position.label, #"Welcome "Now" \ Slot"#)
        let configuredPosition = try ResponseValidator.validateConfigEditorPosition(
            frame: configEditorSuccessFrame(requestID: requestID, result: [
                "instance_id": instanceID,
                "source_digest": digest,
                "profile_id": "Work.Profile",
                "position_id": "0_0",
                "label": "Ready",
                "background": "#1020a080",
                "label_alignment": "center",
                "label_size": 18,
                "notification_sources": ["Calendar"],
                "action": ["type": "key_press", "key": "enter", "gesture": "press"]
            ]),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile",
            expectedPositionID: "0_0"
        )
        XCTAssertEqual(configuredPosition.background, "#1020a080")
        XCTAssertEqual(configuredPosition.labelAlignment, "center")
        XCTAssertEqual(configuredPosition.labelSize, 18)
        XCTAssertEqual(configuredPosition.notificationSources, ["Calendar"])
        XCTAssertEqual(configuredPosition.action, .keyPress(key: "enter", gesture: .press))
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPosition(
            frame: configEditorSuccessFrame(requestID: requestID, result: positionResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile",
            expectedPositionID: "1_0"
        ))
        var extraPositionField = positionResult
        extraPositionField["position"] = "0_0"
        XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPosition(
            frame: configEditorSuccessFrame(requestID: requestID, result: extraPositionField),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            expectedSourceDigest: digest,
            expectedProfileID: "Work.Profile",
            expectedPositionID: "0_0"
        ))
        for invalidPositionID in ["tile-0", "5_2"] {
            var invalidPositionResult = positionResult
            invalidPositionResult["position_id"] = invalidPositionID
            XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPosition(
                frame: configEditorSuccessFrame(requestID: requestID, result: invalidPositionResult),
                expectedRequestID: requestID,
                expectedInstanceID: instanceID,
                expectedSourceDigest: digest,
                expectedProfileID: "Work.Profile",
                expectedPositionID: invalidPositionID
            ))
        }

        let mutationResult: [String: Any] = [
            "instance_id": instanceID,
            "source_digest": digest,
            "file_commit": "committed",
            "reload_outcome": "changed",
            "revision": 3,
            "effect": "display",
            "reason": "none"
        ]
        XCTAssertNoThrow(try ResponseValidator.validateConfigEditorMutation(
            frame: configEditorSuccessFrame(requestID: requestID, result: mutationResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            method: .configEditorPositionLabelSet
        ))
        XCTAssertNoThrow(try ResponseValidator.validateConfigEditorMutation(
            frame: configEditorSuccessFrame(requestID: requestID, result: mutationResult),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID,
            method: .configEditorPositionPatch
        ))
    }

    func testConfigEditorPositionResponsesDecodeEachClosedActionVariant() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let digest = String(repeating: "a", count: 64)
        let cases: [(ConfiguredAction, [String: Any])] = [
            (.activateProfile(profileID: "Work.Profile", gesture: .press), [
                "type": "activate_profile", "profile_id": "Work.Profile", "gesture": "press"
            ]),
            (.execute(executable: "/usr/bin/example", arguments: ["first", "second"], timeoutSeconds: 60, gesture: .release), [
                "type": "execute", "executable": "/usr/bin/example", "arguments": ["first", "second"],
                "timeout_seconds": 60, "gesture": "release"
            ]),
            (.typeText(text: "Ready", gesture: .press), [
                "type": "type_text", "text": "Ready", "gesture": "press"
            ]),
            (.keyPress(key: "enter", gesture: .release), [
                "type": "key_press", "key": "enter", "gesture": "release"
            ])
        ]
        for (expectedAction, actionFields) in cases {
            let result: [String: Any] = [
                "instance_id": instanceID,
                "source_digest": digest,
                "profile_id": "Work.Profile",
                "position_id": "0_0",
                "label": "Clock",
                "background": "#12345678",
                "label_alignment": "center",
                "label_size": 18,
                "notification_sources": ["Calendar"],
                "action": actionFields
            ]
            let response = try ResponseValidator.validateConfigEditorPosition(
                frame: configEditorSuccessFrame(requestID: requestID, result: result),
                expectedRequestID: requestID,
                expectedInstanceID: instanceID,
                expectedSourceDigest: digest,
                expectedProfileID: "Work.Profile",
                expectedPositionID: "0_0"
            )
            XCTAssertEqual(response.action, expectedAction)
            XCTAssertEqual(response.background, "#12345678")
        }

        let invalidActions: [[String: Any]] = [
            ["type": "type_text", "text": ""],
            ["type": "execute", "executable": "/usr/bin/example", "arguments": [], "timeout_seconds": 0],
            ["type": "execute", "executable": "relative/path", "arguments": [], "timeout_seconds": 10],
            ["type": "key_press", "key": "escape"]
        ]
        for action in invalidActions {
            let result: [String: Any] = [
                "instance_id": instanceID,
                "source_digest": digest,
                "profile_id": "Work.Profile",
                "position_id": "0_0",
                "label": "Clock",
                "background": "#12345678",
                "label_alignment": "center",
                "label_size": 18,
                "notification_sources": ["Calendar"],
                "action": action
            ]
            XCTAssertThrowsError(try ResponseValidator.validateConfigEditorPosition(
                frame: configEditorSuccessFrame(requestID: requestID, result: result),
                expectedRequestID: requestID,
                expectedInstanceID: instanceID,
                expectedSourceDigest: digest,
                expectedProfileID: "Work.Profile",
                expectedPositionID: "0_0"
            ))
        }
    }

    private func configEditorSuccessFrame(requestID: String, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "protocol_version": ProtocolV1.protocolVersion,
            "request_id": requestID,
            "result": result,
            "error": NSNull()
        ]
        var frame = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        frame.append(0x0a)
        return frame
    }

    func testProfileListSuccessAndFrameBoundsAreStrict() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let summaries = [
            ProfileSummary(id: "default", label: "Default", isDefault: true, isCurrent: true),
            ProfileSummary(id: "Work.Profile", label: "Work", isDefault: false, isCurrent: false)
        ]
        let response = try ResponseValidator.validateProfilesList(
            frame: profileListFrame(requestID: requestID, instanceID: instanceID, profiles: summaries),
            expectedRequestID: requestID,
            expectedInstanceID: instanceID
        )
        XCTAssertEqual(response.requestID, requestID)
        XCTAssertEqual(response.instanceID, instanceID)
        XCTAssertEqual(response.profiles, summaries)

        let maximum = (0..<31).map { index in
            ProfileSummary(
                id: "profile\(index)",
                label: "Profile \(index)",
                isDefault: index == 0,
                isCurrent: index == 0
            )
        }
        XCTAssertNoThrow(
            try ResponseValidator.validateProfilesList(
                frame: profileListFrame(requestID: requestID, instanceID: instanceID, profiles: maximum),
                expectedRequestID: requestID,
                expectedInstanceID: instanceID
            )
        )

        let empty = profileListFrame(requestID: requestID, instanceID: instanceID, profiles: [])
        XCTAssertThrowsError(
            try ResponseValidator.validateProfilesList(
                frame: empty,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID
            )
        )
        let overLimit = maximum + [
            ProfileSummary(id: "overflow", label: "Overflow", isDefault: false, isCurrent: false)
        ]
        XCTAssertThrowsError(
            try ResponseValidator.validateProfilesList(
                frame: profileListFrame(requestID: requestID, instanceID: instanceID, profiles: overLimit),
                expectedRequestID: requestID,
                expectedInstanceID: instanceID
            )
        )
    }

    func testVisibleLabelPredicateMatchesGoForSpacingMarks() {
        XCTAssertTrue(ProfileValidation.isValidLabel("\u{0903}"))
        XCTAssertFalse(ProfileValidation.isValidLabel("\u{0301}"))
    }

    func testProfileActivationAcceptsChangedStatesAndEchoesRequest() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        for changed in [true, false] {
            let response = try ResponseValidator.validateProfileActivation(
                frame: profileActivationFrame(
                    requestID: requestID,
                    profileID: "Work.Profile",
                    changed: changed
                ),
                expectedRequestID: requestID,
                expectedProfileID: "Work.Profile"
            )
            XCTAssertEqual(response.requestID, requestID)
            XCTAssertEqual(response.profileID, "Work.Profile")
            XCTAssertEqual(response.changed, changed)
        }
    }

    func testProfileServerErrorsAndMalformedResultsAreRejected() throws {
        let requestID = "11111111-1111-4111-8111-111111111111"
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let errorCases = [
            ("profile_not_found", "requested profile does not exist"),
            ("activation_failed", "profile activation failed"),
            ("device_write_failed", "device write failed"),
            ("shutting_down", "runtime is shutting down"),
            ("busy", "runtime is busy")
        ]
        for (code, message) in errorCases {
            let frame = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":null,\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}\n".utf8)
            XCTAssertThrowsError(
                try ResponseValidator.validateProfileActivation(
                    frame: frame,
                    expectedRequestID: requestID,
                    expectedProfileID: "Work.Profile"
                )
            ) { error in
                XCTAssertEqual(error as? ResponseValidationError, .serverError(RuntimeError(code: code, message: message)))
            }
        }

        let unknownError = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":null,\"error\":{\"code\":\"not_allowed\",\"message\":\"no\"}}\n".utf8)
        XCTAssertThrowsError(
            try ResponseValidator.validateProfileActivation(
                frame: unknownError,
                expectedRequestID: requestID,
                expectedProfileID: "Work.Profile"
            )
        ) { error in
            XCTAssertEqual(error as? ResponseValidationError, .invalidError)
        }

        let validProfiles = [
            ProfileSummary(id: "default", label: "Default", isDefault: true, isCurrent: true),
            ProfileSummary(id: "Work.Profile", label: "Work", isDefault: false, isCurrent: false)
        ]
        let malformedLists = [
            profileListFrame(requestID: requestID, instanceID: instanceID, profiles: [
                ProfileSummary(id: "default", label: "Default", isDefault: false, isCurrent: true),
                ProfileSummary(id: "Work.Profile", label: "Work", isDefault: false, isCurrent: false)
            ]),
            profileListFrame(requestID: requestID, instanceID: instanceID, profiles: [
                ProfileSummary(id: "default", label: "Default", isDefault: true, isCurrent: false),
                ProfileSummary(id: "Work.Profile", label: "Work", isDefault: false, isCurrent: false)
            ]),
            Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"instance_id\":\"\(instanceID)\",\"profiles\":[{\"id\":\"default\",\"label\":\"Default\",\"is_default\":true,\"is_current\":true,\"extra\":true},{\"id\":\"Work.Profile\",\"label\":\"Work\",\"is_default\":false,\"is_current\":false}]},\"error\":null}\n".utf8),
            Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"instance_id\":\"\(instanceID)\",\"profiles\":[{\"id\":1,\"label\":\"Default\",\"is_default\":true,\"is_current\":true}]},\"error\":null}\n".utf8)
        ]
        for frame in malformedLists {
            XCTAssertThrowsError(
                try ResponseValidator.validateProfilesList(
                    frame: frame,
                    expectedRequestID: requestID,
                    expectedInstanceID: instanceID
                )
            )
        }

        let duplicateIDs = profileListFrame(requestID: requestID, instanceID: instanceID, profiles: validProfiles.map {
            ProfileSummary(id: "default", label: $0.label, isDefault: $0.isDefault, isCurrent: $0.isCurrent)
        })
        XCTAssertThrowsError(
            try ResponseValidator.validateProfilesList(
                frame: duplicateIDs,
                expectedRequestID: requestID,
                expectedInstanceID: instanceID
            )
        )

        let wrongProfileID = profileActivationFrame(requestID: requestID, profileID: "default", changed: true)
        XCTAssertThrowsError(
            try ResponseValidator.validateProfileActivation(
                frame: wrongProfileID,
                expectedRequestID: requestID,
                expectedProfileID: "Work.Profile"
            )
        )
        let activationExtra = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"profile_id\":\"Work.Profile\",\"changed\":true,\"extra\":false},\"error\":null}\n".utf8)
        XCTAssertThrowsError(
            try ResponseValidator.validateProfileActivation(
                frame: activationExtra,
                expectedRequestID: requestID,
                expectedProfileID: "Work.Profile"
            )
        )
        let activationWrongType = Data("{\"protocol_version\":1,\"request_id\":\"\(requestID)\",\"result\":{\"profile_id\":\"Work.Profile\",\"changed\":1},\"error\":null}\n".utf8)
        XCTAssertThrowsError(
            try ResponseValidator.validateProfileActivation(
                frame: activationWrongType,
                expectedRequestID: requestID,
                expectedProfileID: "Work.Profile"
            )
        )
    }

    private func profileListFrame(
        requestID: String,
        instanceID: String,
        profiles: [ProfileSummary]
    ) -> Data {
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
    static let value = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
    static let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    func makeUUID() -> UUID { Self.value }
}
