import Foundation
import XCTest
@testable import HidhoggCore

final class ConfigurationBoundaryTests: XCTestCase {
    func testRequiredRootFieldsRejectMissingAndWrongTypes() {
        let requiredFields = ["schema_version", "adapter", "brightness", "default_profile_id", "profiles"]
        for field in requiredFields {
            assertDiagnostic(
                document(omittedRootKeys: [field]),
                category: .missingKey,
                key: field
            )
        }

        let wrongTypes: [(field: String, value: String)] = [
            ("schema_version", tomlString("4")),
            ("adapter", "80"),
            ("brightness", tomlString("80")),
            ("default_profile_id", "4"),
            ("profiles", "1"),
        ]
        for testCase in wrongTypes {
            assertDiagnostic(
                document(rootValues: [testCase.field: testCase.value]),
                category: .decode,
                key: testCase.field
            )
        }
    }

    func testProfileLabelIsRequiredAndMustBeAString() {
        assertDiagnostic(
            document(profileBlocks: "[profiles.\"default\"]"),
            category: .missingKey,
            key: #"profiles["default"].label"#
        )
        assertDiagnostic(
            document(profileBlocks: "[profiles.\"default\"]\nlabel = 4"),
            category: .decode,
            key: #"profiles["default"].label"#
        )
    }

    func testOnlySchemaVersionFourIsAccepted() {
        for version in [1, 2, 3] {
            assertDiagnostic(
                document(rootValues: ["schema_version": String(version)]),
                category: .schemaVersion,
                key: "schema_version"
            )
        }
    }

    func testAdapterBrightnessAndIdleTimeoutBoundaries() throws {
        let supportedAdapter = try decode(document())
        XCTAssertEqual(supportedAdapter.adapter, "ulanzi.d200x")

        assertDiagnostic(
            document(rootValues: ["adapter": tomlString("unsupported.adapter")]),
            category: .validation,
            key: "adapter"
        )

        for value in [0, 100] {
            let configuration = try decode(document(rootValues: ["brightness": String(value)]))
            XCTAssertEqual(configuration.brightness, value)
        }
        for value in [-1, 101] {
            assertDiagnostic(
                document(rootValues: ["brightness": String(value)]),
                category: .validation,
                key: "brightness"
            )
        }

        for value in [0, 86_400] {
            let configuration = try decode(document(rootValues: ["idle_timeout_seconds": String(value)]))
            XCTAssertEqual(configuration.idleTimeoutSeconds, value)
        }
        XCTAssertEqual(try decode(document()).idleTimeoutSeconds, 300)
        for value in [-1, 86_401] {
            assertDiagnostic(
                document(rootValues: ["idle_timeout_seconds": String(value)]),
                category: .validation,
                key: "idle_timeout_seconds"
            )
        }
    }

    func testProfileCountBoundariesAndExactDefaultResolution() throws {
        for count in [1, 31] {
            let ids = profileIDs(count: count)
            let configuration = try decode(document(profileIDs: ids))
            XCTAssertEqual(configuration.profiles.count, count)
            XCTAssertEqual(configuration.profiles.first?.id, "default")
        }

        assertDiagnostic(
            document(rootValues: ["profiles": "{}"]),
            category: .validation,
            key: "default_profile_id"
        )
        assertDiagnostic(
            document(profileIDs: profileIDs(count: 32)),
            category: .validation,
            key: "profiles"
        )

        let caseDistinctDefault = try decode(document(
            rootValues: ["default_profile_id": tomlString("Default")],
            profileIDs: ["default", "Default"]
        ))
        XCTAssertEqual(caseDistinctDefault.defaultProfileID, "Default")
        XCTAssertEqual(caseDistinctDefault.profiles.first?.id, "Default")

        assertDiagnostic(
            document(rootValues: ["default_profile_id": tomlString("DEFAULT")]),
            category: .validation,
            key: "default_profile_id"
        )
    }

    func testProfileIDsUseASCIIStableIDRulesAndAllowSixtyFourCharacters() throws {
        let validIDs = ["A", "9profile", String(repeating: "a", count: 64)]
        for id in validIDs {
            let configuration = try decode(document(profileIDs: ["default", id]))
            XCTAssertNotNil(configuration.profile(id: id))
        }

        let invalidIDs = ["bad id", "éclair", "-leading", ".leading", "_leading", String(repeating: "a", count: 65)]
        for id in invalidIDs {
            assertDiagnostic(
                document(profileIDs: ["default", id]),
                category: .validation,
                key: "profiles[\(tomlString(id))]"
            )
        }
    }

    func testNotificationSourceOmissionAndCountBoundariesNormalizePrecisely() throws {
        let omitted = try decode(document())
        XCTAssertNil(omitted.profiles[0].positions[0].notificationSources)

        let maximumSources = ["Source", "source", String(repeating: "n", count: 64)] +
            (3..<16).map { "source\($0)" }
        let accepted = try decode(document(positionValues: [
            "notification_sources": tomlArray(maximumSources),
        ]))
        XCTAssertEqual(accepted.profiles[0].positions[0].notificationSources, maximumSources)

        assertDiagnostic(
            document(positionValues: ["notification_sources": "[]"]),
            category: .validation,
            key: #"profiles["default"].positions["0_0"].notification_sources"#
        )
        assertDiagnostic(
            document(positionValues: ["notification_sources": tomlArray(maximumSources + ["overflow"])]),
            category: .validation,
            key: #"profiles["default"].positions["0_0"].notification_sources"#
        )
    }

    func testNotificationSourceIDsAreASCIIAndUniqueByExactCase() throws {
        let caseDistinctSources = ["Source", "source"]
        let configuration = try decode(document(positionValues: [
            "notification_sources": tomlArray(caseDistinctSources),
        ]))
        XCTAssertEqual(configuration.profiles[0].positions[0].notificationSources, caseDistinctSources)

        assertDiagnostic(
            document(positionValues: ["notification_sources": tomlArray(["Source", "Source"])]),
            category: .validation,
            key: #"profiles["default"].positions["0_0"].notification_sources[1]"#
        )

        for id in ["éclair", "-leading", String(repeating: "s", count: 65)] {
            assertDiagnostic(
                document(positionValues: ["notification_sources": tomlArray([id])]),
                category: .validation,
                key: #"profiles["default"].positions["0_0"].notification_sources[0]"#
            )
        }
    }

    func testExecuteDefaultsLiteralArgumentsAndTimeoutBoundariesNormalize() throws {
        let defaults = try decode(document(positionValues: ["action": executeAction()]))
        XCTAssertEqual(
            defaults.profiles[0].positions[0].action,
            .execute(executable: "/bin/echo", arguments: [], timeoutSeconds: 10, gesture: .release)
        )

        let literalArguments = ["two words", "$HOME", "--flag=one", "quote\"value", "é"]
        let literals = try decode(document(positionValues: [
            "action": executeAction(arguments: literalArguments),
        ]))
        XCTAssertEqual(
            literals.profiles[0].positions[0].action,
            .execute(executable: "/bin/echo", arguments: literalArguments, timeoutSeconds: 10, gesture: .release)
        )

        for timeout in [1, 60] {
            let configuration = try decode(document(positionValues: [
                "action": executeAction(timeout: timeout),
            ]))
            XCTAssertEqual(
                configuration.profiles[0].positions[0].action,
                .execute(executable: "/bin/echo", arguments: [], timeoutSeconds: timeout, gesture: .release)
            )
        }

        for timeout in [0, 61] {
            assertDiagnostic(
                document(positionValues: ["action": executeAction(timeout: timeout)]),
                category: .validation,
                key: #"profiles["default"].positions["0_0"].action.timeout_seconds"#
            )
        }
    }

    func testExecuteArgumentCountAndUTF8ByteLimits() throws {
        let maximumCountArguments = Array(repeating: "x", count: 32)
        let maximumCount = try decode(document(positionValues: [
            "action": executeAction(arguments: maximumCountArguments),
        ]))
        XCTAssertEqual(
            maximumCount.profiles[0].positions[0].action,
            .execute(executable: "/bin/echo", arguments: maximumCountArguments, timeoutSeconds: 10, gesture: .release)
        )

        assertDiagnostic(
            document(positionValues: ["action": executeAction(arguments: Array(repeating: "x", count: 33))]),
            category: .validation,
            key: #"profiles["default"].positions["0_0"].action.arguments"#
        )

        let maximumArgument = String(repeating: "é", count: 512)
        let acceptedArgument = try decode(document(positionValues: [
            "action": executeAction(arguments: [maximumArgument]),
        ]))
        XCTAssertEqual(
            acceptedArgument.profiles[0].positions[0].action,
            .execute(executable: "/bin/echo", arguments: [maximumArgument], timeoutSeconds: 10, gesture: .release)
        )
        let oversizedArgument = maximumArgument + "a"
        assertDiagnostic(
            document(positionValues: ["action": executeAction(arguments: [oversizedArgument])]),
            category: .validation,
            key: #"profiles["default"].positions["0_0"].action.arguments[0]"#
        )

        let exactAggregate = Array(repeating: maximumArgument, count: 8)
        let acceptedAggregate = try decode(document(positionValues: [
            "action": executeAction(arguments: exactAggregate),
        ]))
        XCTAssertEqual(
            acceptedAggregate.profiles[0].positions[0].action,
            .execute(executable: "/bin/echo", arguments: exactAggregate, timeoutSeconds: 10, gesture: .release)
        )
        assertDiagnostic(
            document(positionValues: ["action": executeAction(arguments: exactAggregate + ["a"])]),
            category: .validation,
            key: #"profiles["default"].positions["0_0"].action.arguments"#
        )
        assertDiagnostic(
            document(positionValues: ["action": executeAction(arguments: ["contains\u{0}nul"])]),
            category: .validation,
            key: #"profiles["default"].positions["0_0"].action.arguments[0]"#
        )
    }

    func testExecuteRequiresAbsoluteNulFreePathAndMatchesPOSIXLeadingSlash() throws {
        for executable in ["", "bin/echo", "/bin/\u{0}echo"] {
            assertDiagnostic(
                document(positionValues: ["action": executeAction(executable: executable)]),
                category: .validation,
                key: #"profiles["default"].positions["0_0"].action.executable"#
            )
        }

        let combiningPath = "/\u{0301}tool"
        let configuration = try decode(document(positionValues: [
            "action": executeAction(executable: combiningPath),
        ]))
        guard case .execute(let executable, let arguments, let timeout, let gesture)? =
                configuration.profiles[0].positions[0].action else {
            return XCTFail("combining-scalar absolute path did not decode as an execute action")
        }
        XCTAssertEqual(Array(executable.utf8), Array(combiningPath.utf8))
        XCTAssertEqual(arguments, [])
        XCTAssertEqual(timeout, 10)
        XCTAssertEqual(gesture, .release)
    }

    private func decode(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> HidhoggConfiguration {
        do {
            return try HidhoggConfigurationDecoder.decode(Data(source.utf8))
        } catch {
            XCTFail("configuration decode failed: \(error)", file: file, line: line)
            throw error
        }
    }

    private func assertDiagnostic(
        _ source: String,
        category: ConfigurationDiagnosticCategory,
        key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try HidhoggConfigurationDecoder.decode(Data(source.utf8))
            XCTFail("configuration unexpectedly decoded", file: file, line: line)
        } catch let diagnostic as ConfigurationDiagnostic {
            XCTAssertEqual(diagnostic.category, category, file: file, line: line)
            XCTAssertEqual(diagnostic.key, key, file: file, line: line)
        } catch {
            XCTFail("unexpected diagnostic type: \(error)", file: file, line: line)
        }
    }

    private func document(
        rootValues: [String: String] = [:],
        omittedRootKeys: Set<String> = [],
        profileIDs: [String] = ["default"],
        profileBlocks: String? = nil,
        positionValues: [String: String] = [:]
    ) -> String {
        let defaults = [
            "schema_version": "4",
            "adapter": tomlString("ulanzi.d200x"),
            "brightness": "80",
            "default_profile_id": tomlString("default"),
        ]
        let rootOrder = ["schema_version", "adapter", "brightness", "idle_timeout_seconds", "default_profile_id", "profiles"]
        let rootLines = rootOrder.compactMap { key -> String? in
            guard !omittedRootKeys.contains(key) else { return nil }
            guard let value = rootValues[key] ?? defaults[key] else { return nil }
            return "\(key) = \(value)"
        }

        let profileText: String
        if omittedRootKeys.contains("profiles") || rootValues["profiles"] != nil {
            profileText = ""
        } else if let profileBlocks {
            profileText = profileBlocks
        } else {
            profileText = profileIDs.map { id in
                var lines = ["[profiles.\(tomlString(id))]", "label = \(tomlString("Profile"))"]
                if id == "default", !positionValues.isEmpty {
                    lines.append("")
                    lines.append("[profiles.\(tomlString(id)).positions.\"0_0\"]")
                    lines.append(contentsOf: positionValues.keys.sorted().map { "\($0) = \(positionValues[$0]!)" })
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }

        return ([rootLines.joined(separator: "\n"), profileText].filter { !$0.isEmpty }).joined(separator: "\n\n") + "\n"
    }

    private func profileIDs(count: Int) -> [String] {
        ["default"] + (1..<count).map { String(format: "profile-%02d", $0) }
    }

    private func executeAction(executable: String = "/bin/echo", arguments: [String]? = nil, timeout: Int? = nil) -> String {
        var fields = ["type = \"execute\"", "executable = \(tomlString(executable))"]
        if let arguments { fields.append("arguments = \(tomlArray(arguments))") }
        if let timeout { fields.append("timeout_seconds = \(timeout)") }
        return "{ \(fields.joined(separator: ", ")) }"
    }

    private func tomlArray(_ values: [String]) -> String {
        "[\(values.map(tomlString).joined(separator: ", "))]"
    }

    private func tomlString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0..<0x20, 0x7F:
                let hex = String(scalar.value, radix: 16).uppercased()
                result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: result += String(scalar)
            }
        }
        return result + "\""
    }
}
