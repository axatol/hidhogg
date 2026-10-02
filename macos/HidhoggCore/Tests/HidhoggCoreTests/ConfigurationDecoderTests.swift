import Foundation
import XCTest
@testable import HidhoggCore

final class ConfigurationDecoderTests: XCTestCase {
    func testSparseProfilesNormalizeToDefaultFirstFourteenPositionLayout() throws {
        let configuration = try decode(document(body: #"""
        [profiles.zeta]
        label = "Zeta"
        positions = { "1_0" = { label = "Second" }, "0_0" = {} }

        [profiles.default]
        label = "Default"
        """#))

        XCTAssertEqual(configuration.idleTimeoutSeconds, 300)
        XCTAssertEqual(configuration.profiles.map(\.id), ["default", "zeta"])
        for profile in configuration.profiles {
            XCTAssertEqual(profile.positions.map(\.position), HidhoggConfiguration.supportedPositions.map(\.name))
            XCTAssertEqual(profile.positions.count, 14)
            XCTAssertEqual(profile.positions[0].background, "#000000")
            XCTAssertEqual(profile.positions[0].labelAlignment, "bottom")
            XCTAssertEqual(profile.positions[0].labelSize, 10)
        }
        XCTAssertEqual(configuration.profile(id: "default")?.position(named: "3_2")?.id, "3_2")
    }

    func testTOML11EscapesOptionalSecondsAndMultilineNestedInlineTables() throws {
        let tree = try Toml.Annotated(parsing: #"""
        "\x61" = "\e\x42"
        local = 07:32
        """#).typedTree()
        guard case .table(let entries) = tree else { return XCTFail("typed TOML root was not a table") }
        XCTAssertEqual(entries.first(where: { $0.key == "a" })?.value, .string("\u{1B}B"))
        XCTAssertEqual(entries.first(where: { $0.key == "local" })?.value, .localTime(.init(hour: 7, minute: 32, second: 0)))

        let toml = #"""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        default_profile_id = "default"
        profiles = {
          default = {
            label = "Default",
            positions = {
              "0_0" = {
                action = {
                  type = "execute",
                  executable = "/bin/echo",
                  arguments = ["A\e\x42"],
                },
              },
            },
          },
        }
        """#
        let configuration = try decode(toml)
        guard case .execute(let executable, let arguments, let timeout, let gesture)? = configuration.profiles[0].positions[0].action else {
            return XCTFail("multiline inline action did not decode as execute")
        }
        XCTAssertEqual(executable, "/bin/echo")
        XCTAssertEqual(arguments, ["A\u{1B}B"])
        XCTAssertEqual(timeout, 10)
        XCTAssertEqual(gesture, .release)
    }

    func testOmittedAndExplicitDefaultsRemainDistinct() throws {
        let omitted = try decode(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/bin/echo" } } }
        """#))
        guard case .execute(_, let arguments, let timeout, let gesture)? = omitted.profiles[0].positions[0].action else {
            return XCTFail("omitted execute fields did not decode")
        }
        XCTAssertEqual(arguments, [])
        XCTAssertEqual(timeout, 10)
        XCTAssertEqual(gesture, .release)
        XCTAssertNil(omitted.profiles[0].positions[0].notificationSources)

        let explicit = try decode(document(idleTimeout: "0", body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { label_alignment = "center", label_size = 8, notification_sources = ["Source", "source"] } }
        """#))
        XCTAssertEqual(explicit.idleTimeoutSeconds, 0)
        XCTAssertEqual(explicit.profiles[0].positions[0].labelAlignment, "center")
        XCTAssertEqual(explicit.profiles[0].positions[0].labelSize, 8)
        XCTAssertEqual(explicit.profiles[0].positions[0].notificationSources, ["Source", "source"])
    }

    func testAllActionVariantsAndForwardProfileReference() throws {
        let text = String(repeating: "😀", count: 32)
        let configuration = try decode(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = {
          "0_0" = { action = { type = "activate_profile", profile_id = "later" } },
          "1_0" = { action = { type = "execute", executable = "/bin/echo", arguments = ["one", "two"], timeout_seconds = 1, gesture = "press" } },
          "2_0" = { action = { type = "type_text", text = "\#(text)" } },
          "3_0" = { action = { type = "key_press", key = "enter" } },
        }

        [profiles.later]
        label = "Later"
        """#))

        XCTAssertEqual(configuration.profiles.map(\.id), ["default", "later"])
        XCTAssertEqual(configuration.profiles[0].positions[0].action, .activateProfile(profileID: "later", gesture: .release))
        XCTAssertEqual(configuration.profiles[0].positions[1].action, .execute(executable: "/bin/echo", arguments: ["one", "two"], timeoutSeconds: 1, gesture: .press))
        XCTAssertEqual(configuration.profiles[0].positions[2].action, .typeText(text: text, gesture: .release))
        XCTAssertEqual(configuration.profiles[0].positions[3].action, .keyPress(key: "enter", gesture: .release))
    }

    func testStrictFailuresAndSafeDiagnostics() {
        assertFailure(document(extra: "unknown = true"), category: .unknownKey, key: "unknown")
        assertFailure(document(extra: "version = 3"), category: .unknownKey, key: "version")
        let obsoletePages = diagnostic(document(extra: "pages = []"))
        XCTAssertEqual(obsoletePages?.category, .unknownKey)
        XCTAssertEqual(obsoletePages?.key, "pages")
        XCTAssertEqual(obsoletePages?.detail, "pages is obsolete; use profiles")
        assertFailure(document(extra: "schema_version = 4"), category: .decode)
        assertFailure(document(brightness: #""x""#), category: .decode, key: "brightness")
        assertFailure(document(schemaVersion: "3"), category: .schemaVersion, key: "schema_version")
        assertFailure(document(body: "[profiles.default]\n"), category: .missingKey, key: #"profiles["default"].label"#)

        let secret = "synthetic-secret-marker"
        let diagnostic = diagnostic(document(brightness: #""synthetic-secret-marker""#))
        XCTAssertEqual(diagnostic?.category, .decode)
        XCTAssertFalse(diagnostic?.description.contains(secret) ?? false)
        XCTAssertFalse(diagnostic?.safeProjection().detail.contains(secret) ?? false)
    }

    func testExplicitEmptyAndForbiddenActionFieldsAreRejected() {
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { label_alignment = "" } }
        """#), category: .validation, key: #"profiles["default"].positions["0_0"].label_alignment"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { label_size = 0 } }
        """#), category: .validation, key: #"profiles["default"].positions["0_0"].label_size"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/bin/echo", timeout_seconds = 0 } } }
        """#), category: .validation, key: #"profiles["default"].positions["0_0"].action.timeout_seconds"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "activate_profile", profile_id = "default", arguments = [] } } }
        """#), category: .validation, key: #"profiles["default"].positions["0_0"].action.arguments"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { notification_sources = [] } }
        """#), category: .validation, key: #"profiles["default"].positions["0_0"].notification_sources"#)

        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/bin/echo", gesture = "" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.gesture"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/bin/echo", gesture = "hold" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.gesture"#)

        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/bin/echo", text = "" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.text"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "type_text", text = "ok", key = "enter" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.key"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "key_press", key = "enter", profile_id = "default" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.profile_id"#)
    }

    func testAppearanceDefaultsAndStrictValueBoundaries() throws {
        for background in ["#102030", "#a1b2c3ff"] {
            let configuration = try decode(document(body: """
            [profiles.default]
            label = "Default"
            positions = { "0_0" = { background = "\(background)", label_alignment = "center", label_size = 32 } }
            """))
            XCTAssertEqual(configuration.profiles[0].positions[0].background, background)
            XCTAssertEqual(configuration.profiles[0].positions[0].labelAlignment, "center")
            XCTAssertEqual(configuration.profiles[0].positions[0].labelSize, 32)
        }

        for background in ["", "#fff", "#11223g", "#102030ff00"] {
            assertFailure(document(body: """
            [profiles.default]
            label = "Default"
            positions = { "0_0" = { background = "\(background)" } }
            """), category: .validation,
                          key: #"profiles["default"].positions["0_0"].background"#)
        }
        for alignment in ["", "top", "CENTER"] {
            assertFailure(document(body: """
            [profiles.default]
            label = "Default"
            positions = { "0_0" = { label_alignment = "\(alignment)" } }
            """), category: .validation,
                          key: #"profiles["default"].positions["0_0"].label_alignment"#)
        }
        for labelSize in [-1, 0, 7, 33] {
            assertFailure(document(body: """
            [profiles.default]
            label = "Default"
            positions = { "0_0" = { label_size = \(labelSize) } }
            """), category: .validation,
                          key: #"profiles["default"].positions["0_0"].label_size"#)
        }
    }

    func testWrongTOMLTypesAreRejectedAtPositionAndActionFields() {
        let positionTypes: [(field: String, value: String)] = [
            ("label", "4"),
            ("background", "4"),
            ("notification_sources", "1"),
            ("notification_sources", "[1]"),
            ("label_alignment", "false"),
            ("label_size", #""10""#),
        ]
        for testCase in positionTypes {
            assertFailure(document(body: """
            [profiles.default]
            label = "Default"
            positions = { "0_0" = { \(testCase.field) = \(testCase.value) } }
            """), category: .decode,
                          key: #"profiles["default"].positions["0_0"].\#(testCase.field)"#)
        }

        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = 4 } }
        """#), category: .decode,
                      key: #"profiles["default"].positions["0_0"].action"#)

        let actionTypes: [(field: String, value: String)] = [
            ("type", "4"),
            ("gesture", "4"),
            ("profile_id", "false"),
            ("executable", "4"),
            ("arguments", "1"),
            ("arguments", "[1]"),
            ("timeout_seconds", #""10""#),
            ("text", "[]"),
            ("key", "true"),
        ]
        for testCase in actionTypes {
            var fields = ["type = \"execute\"", "executable = \"/bin/echo\""]
            if testCase.field == "type" { fields.removeFirst() }
            if testCase.field == "executable" { fields.remove(at: 1) }
            fields.append("\(testCase.field) = \(testCase.value)")
            let action = fields.joined(separator: ", ")
            assertFailure(document(body: """
            [profiles.default]
            label = "Default"
            positions = { "0_0" = { action = { \(action) } } }
            """), category: .decode,
                          key: #"profiles["default"].positions["0_0"].action.\#(testCase.field)"#)
        }
    }

    func testActionLiteralTargetAndPayloadFailuresAreStrict() {
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "open", executable = "/bin/echo" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.type"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "activate_profile", profile_id = "missing" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.profile_id"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "type_text", text = "" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.text"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "type_text", text = "a\u0000b" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.text"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "key_press", key = "Enter" } } }
        """#), category: .validation,
                      key: #"profiles["default"].positions["0_0"].action.key"#)
    }

    func testIndexedDiagnosticPathsAndUnicodeVisibilityRules() throws {
        let duplicateSources = diagnostic(document(body: #"""
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { notification_sources = ["Source", "Source"] } }
        """#))
        XCTAssertEqual(duplicateSources?.category, .validation)
        XCTAssertEqual(duplicateSources?.key, #"profiles["default"].positions["0_0"].notification_sources[1]"#)
        XCTAssertEqual(duplicateSources?.line, 0)
        XCTAssertEqual(duplicateSources?.column, 0)

        let visibleWithMarks = try decode(document(body: "[profiles.default]\nlabel = \"A\u{0301}\u{E000}\""))
        XCTAssertEqual(visibleWithMarks.profiles[0].label, "A\u{0301}\u{E000}")

        assertFailure(document(body: "[profiles.default]\nlabel = \"A\u{200D}\""),
                      category: .validation, key: #"profiles["default"].label"#)
    }

    func testEveryActionVariantRejectsAllForeignFieldsByPresence() {
        let cases: [(type: String, allowed: String, field: String, value: String)] = [
            ("activate_profile", #"profile_id = "default""#, "executable", "\"\""),
            ("activate_profile", #"profile_id = "default""#, "arguments", "[]"),
            ("activate_profile", #"profile_id = "default""#, "timeout_seconds", "0"),
            ("activate_profile", #"profile_id = "default""#, "text", "\"\""),
            ("activate_profile", #"profile_id = "default""#, "key", "\"\""),
            ("execute", #"executable = "/bin/echo""#, "profile_id", "\"\""),
            ("execute", #"executable = "/bin/echo""#, "text", "\"\""),
            ("execute", #"executable = "/bin/echo""#, "key", "\"\""),
            ("type_text", #"text = "ok""#, "profile_id", "\"\""),
            ("type_text", #"text = "ok""#, "executable", "\"\""),
            ("type_text", #"text = "ok""#, "arguments", "[]"),
            ("type_text", #"text = "ok""#, "timeout_seconds", "0"),
            ("type_text", #"text = "ok""#, "key", "\"\""),
            ("key_press", #"key = "enter""#, "profile_id", "\"\""),
            ("key_press", #"key = "enter""#, "executable", "\"\""),
            ("key_press", #"key = "enter""#, "arguments", "[]"),
            ("key_press", #"key = "enter""#, "timeout_seconds", "0"),
            ("key_press", #"key = "enter""#, "text", "\"\""),
        ]

        for testCase in cases {
            let action = "type = \"\(testCase.type)\", \(testCase.allowed), \(testCase.field) = \(testCase.value)"
            assertFailure(document(body: """
            [profiles.default]
            label = "Default"
            positions = { "0_0" = { action = { \(action) } } }
            """), category: .validation,
                          key: #"profiles["default"].positions["0_0"].action.\#(testCase.field)"#)
        }
    }

    func testExecutablePathUsesLeadingPOSIXByte() throws {
        let path = "/\u{0301}tool"
        let configuration = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "\(path)" } } }
        """))

        XCTAssertEqual(configuration.profiles[0].positions[0].action,
                       .execute(executable: path, arguments: [], timeoutSeconds: 10, gesture: .release))
    }

    func testNormalizedEqualityAndProfileLookupUseExactUTF8Identity() throws {
        let precomposed = "é"
        let decomposed = "e\u{0301}"

        let composedProfileLabel = try decode(document(body: "[profiles.default]\nlabel = \"\(precomposed)\""))
        let decomposedProfileLabel = try decode(document(body: "[profiles.default]\nlabel = \"\(decomposed)\""))
        XCTAssertNotEqual(composedProfileLabel, decomposedProfileLabel)

        let composedPositionLabel = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { label = "\(precomposed)" } }
        """))
        let decomposedPositionLabel = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { label = "\(decomposed)" } }
        """))
        XCTAssertNotEqual(composedPositionLabel, decomposedPositionLabel)

        let composedText = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "type_text", text = "\(precomposed)" } } }
        """))
        let decomposedText = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "type_text", text = "\(decomposed)" } } }
        """))
        XCTAssertNotEqual(composedText, decomposedText)

        let composedExecutable = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/\(precomposed)" } } }
        """))
        let decomposedExecutable = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/\(decomposed)" } } }
        """))
        XCTAssertNotEqual(composedExecutable, decomposedExecutable)

        let composedArgument = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/bin/echo", arguments = ["\(precomposed)"] } } }
        """))
        let decomposedArgument = try decode(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "execute", executable = "/bin/echo", arguments = ["\(decomposed)"] } } }
        """))
        XCTAssertNotEqual(composedArgument, decomposedArgument)

        let profile = try decode(document(body: #"""
        [profiles.default]
        label = "Default"

        [profiles.Kelvin]
        label = "Kelvin"
        """#))
        XCTAssertNotNil(profile.profile(id: "Kelvin"))
        XCTAssertNil(profile.profile(id: "\u{212A}elvin"))
    }

    func testQuotedTOMLKeysRetainDistinctUTF8Spellings() throws {
        let composed = "é"
        let decomposed = "e\u{0301}"
        XCTAssertNotEqual(ExactTomlKey(composed), ExactTomlKey(decomposed))
        XCTAssertNotEqual(Toml.TypedValue.string(composed), .string(decomposed))

        let tree = try Toml.Annotated(parsing: "\"\(composed)\" = 1\n\"\(decomposed)\" = 2\n").typedTree()
        guard case .table(let entries) = tree else { return XCTFail("typed TOML root was not a table") }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { Array($0.key.utf8) }, [Array(composed.utf8), Array(decomposed.utf8)])
        XCTAssertNotEqual(tree, .table([(composed, .integer(1))]))

        let profiles = diagnostic(document(body: #"""
        [profiles.default]
        label = "Default"

        [profiles.K]
        label = "Kay"

        [profiles."K"]
        label = "Kelvin"
        """#))
        XCTAssertEqual(profiles?.category, .validation)
        XCTAssertEqual(profiles?.key, #"profiles["K"]"#)
        XCTAssertFalse(profiles?.description.contains("Kelvin") ?? false)
    }

    func testUnicodeScalarAndUTF16Limits() throws {
        let emojiLabel = String(repeating: "😀", count: 64)
        let valid = try decode(document(body: "[profiles.default]\nlabel = \"\(emojiLabel)\""))
        XCTAssertEqual(valid.profiles[0].label.unicodeScalars.count, 64)

        let tooManyLabelScalars = String(repeating: "😀", count: 65)
        assertFailure(document(body: "[profiles.default]\nlabel = \"\(tooManyLabelScalars)\""), category: .validation,
                      key: #"profiles["default"].label"#)
        assertFailure(document(body: #"""
        [profiles.default]
        label = " \t "
        """#), category: .validation, key: #"profiles["default"].label"#)
        assertFailure(document(body: "[profiles.default]\nlabel = \"\u{0301}\""), category: .validation,
                      key: #"profiles["default"].label"#)

        let tooLongText = String(repeating: "😀", count: 33)
        assertFailure(document(body: """
        [profiles.default]
        label = "Default"
        positions = { "0_0" = { action = { type = "type_text", text = "\(tooLongText)" } } }
        """), category: .validation, key: #"profiles["default"].positions["0_0"].action.text"#)
    }

    func testInvalidUTF8AndPreciseSafeLocation() {
        let invalidUTF8 = Data([0x73, 0x63, 0x68, 0x65, 0x6D, 0x61, 0x5F, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E, 0x20, 0x3D, 0x20, 0xFF])
        XCTAssertEqual(diagnostic(invalidUTF8)?.category, .decode)

        let error = diagnostic(document(extra: "unknown = \"value\""))
        XCTAssertEqual(error?.category, .unknownKey)
        XCTAssertEqual(error?.line, 5)
        XCTAssertEqual(error?.column, 1)
        XCTAssertLessThanOrEqual(error?.key.utf8.count ?? 0, 160)
        XCTAssertLessThanOrEqual(error?.detail.utf8.count ?? 0, 160)

        let outOfRange = ConfigurationDiagnostic.make(.decode, location: SourceLocation(line: 1_000_001, column: 1))
        XCTAssertEqual(outOfRange.line, 0)
        XCTAssertEqual(outOfRange.column, 0)
        let longKey = ConfigurationDiagnostic.make(.validation, key: String(repeating: "k", count: 200))
        XCTAssertLessThanOrEqual(longKey.key.utf8.count, 160)

        let malformed = diagnostic(document(extra: #"malformed = "synthetic-secret-marker\q""#))
        XCTAssertEqual(malformed?.category, .decode)
        XCTAssertGreaterThan(malformed?.line ?? 0, 0)
        XCTAssertGreaterThan(malformed?.column ?? 0, 0)
        XCTAssertFalse(malformed?.description.contains("synthetic-secret-marker") ?? false)
    }

    func testInlineDiagnosticsUseUTF8ByteColumnsAndFullPaths() {
        let wrongType = #"""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        idle_timeout_seconds = 300
        default_profile_id = "default"
        profiles = { default = { label = "Café", positions = { "0_0" = { label = "é", action = { type = "type_text", text = 123 } } } } }
        """#
        let typeError = diagnostic(wrongType)
        XCTAssertEqual(typeError?.category, .decode)
        XCTAssertEqual(typeError?.key, #"profiles["default"].positions["0_0"].action.text"#)
        XCTAssertEqual(typeError?.line, 6)
        XCTAssertEqual(typeError?.column, 119)

        let unknownKey = #"""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        idle_timeout_seconds = 300
        default_profile_id = "default"
        profiles = { default = { label = "Café", positions = { "0_0" = { label = "é", action = { type = "type_text", text = "ok", mystery = true } } } } }
        """#
        let unknownError = diagnostic(unknownKey)
        XCTAssertEqual(unknownError?.category, .unknownKey)
        XCTAssertEqual(unknownError?.key, #"profiles["default"].positions["0_0"].action.mystery"#)
        XCTAssertEqual(unknownError?.line, 6)
        XCTAssertEqual(unknownError?.column, 125)
    }

    func testHeaderDiagnosticsUseDeclaredPathsAndIdentifierColumns() {
        let explicitUnknown = #"""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        idle_timeout_seconds = 300
        default_profile_id = "default"
        [unknown]
        child = 1

        [profiles.default]
        label = "Default"
        """#
        let explicitError = diagnostic(explicitUnknown)
        XCTAssertEqual(explicitError?.category, .unknownKey)
        XCTAssertEqual(explicitError?.key, "unknown")
        XCTAssertEqual(explicitError?.line, 6)
        XCTAssertEqual(explicitError?.column, 2)

        let implicitUnknown = #"""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        idle_timeout_seconds = 300
        default_profile_id = "default"
        [unknown.child]
        value = 1

        [profiles.default]
        label = "Default"
        """#
        let implicitError = diagnostic(implicitUnknown)
        XCTAssertEqual(implicitError?.category, .unknownKey)
        XCTAssertEqual(implicitError?.key, "unknown.child")
        XCTAssertEqual(implicitError?.line, 6)
        XCTAssertEqual(implicitError?.column, 2)

        let tableInsteadOfInteger = #"""
        schema_version = 4
        adapter = "ulanzi.d200x"
        [brightness]
        value = 80
        idle_timeout_seconds = 300
        default_profile_id = "default"

        [profiles.default]
        label = "Default"
        """#
        let typeError = diagnostic(tableInsteadOfInteger)
        XCTAssertEqual(typeError?.category, .decode)
        XCTAssertEqual(typeError?.key, "brightness")
        XCTAssertEqual(typeError?.line, 3)
        XCTAssertEqual(typeError?.column, 2)
    }

    func testDottedUnknownDiagnosticsKeepTheDeclaredFieldPath() {
        let rootDotted = #"""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        idle_timeout_seconds = 300
        default_profile_id = "default"
        unknown.child = true

        [profiles.default]
        label = "Default"
        """#
        let rootError = diagnostic(rootDotted)
        XCTAssertEqual(rootError?.category, .unknownKey)
        XCTAssertEqual(rootError?.key, "unknown.child")
        XCTAssertEqual(rootError?.line, 6)
        XCTAssertEqual(rootError?.column, 1)

        let inlineDotted = #"""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        idle_timeout_seconds = 300
        default_profile_id = "default"
        profiles = { default = { label = "Default", positions = { "0_0" = { action = { type = "type_text", text = "ok", mystery.extra = true } } } } }
        """#
        let inlineError = diagnostic(inlineDotted)
        XCTAssertEqual(inlineError?.category, .unknownKey)
        XCTAssertEqual(inlineError?.key, #"profiles["default"].positions["0_0"].action.mystery.extra"#)
        XCTAssertEqual(inlineError?.line, 6)
        XCTAssertGreaterThan(inlineError?.column ?? 0, 0)
    }

    private func decode(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> HidhoggConfiguration {
        do {
            return try HidhoggConfigurationDecoder.decode(Data(source.utf8))
        } catch {
            XCTFail("configuration decode failed: \(error)", file: file, line: line)
            throw error
        }
    }

    private func diagnostic(_ source: String) -> ConfigurationDiagnostic? {
        diagnostic(Data(source.utf8))
    }

    private func diagnostic(_ data: Data) -> ConfigurationDiagnostic? {
        do {
            _ = try HidhoggConfigurationDecoder.decode(data)
            return nil
        } catch {
            return error as? ConfigurationDiagnostic
        }
    }

    private func assertFailure(
        _ source: String,
        category: ConfigurationDiagnosticCategory,
        key: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let error = diagnostic(source)
        XCTAssertEqual(error?.category, category, file: file, line: line)
        if let key { XCTAssertEqual(error?.key, key, file: file, line: line) }
    }

    private func document(
        schemaVersion: String = "4",
        brightness: String = "80",
        idleTimeout: String? = nil,
        body: String = "[profiles.default]\nlabel = \"Default\"",
        extra: String = ""
    ) -> String {
        """
        schema_version = \(schemaVersion)
        adapter = "ulanzi.d200x"
        brightness = \(brightness)
        \(idleTimeout.map { "idle_timeout_seconds = \($0)\n" } ?? "")default_profile_id = "default"
        \(extra)

        \(body)
        """
    }
}
