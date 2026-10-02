import Foundation
import XCTest
@testable import HidhoggCore

final class ConfigurationEditingTests: XCTestCase {
    func testProfileLabelEditPreservesOtherBytesAndIsExactNoOp() throws {
        for lineEnding in ["\n", "\r\n"] {
            let source = Data(expandedSource.replacingOccurrences(of: "\n", with: lineEnding).utf8)
            let expected = Data(String(decoding: source, as: UTF8.self)
                .replacingOccurrences(of: "label  =  \"Default\"", with: "label  =  \"Home\"")
                .utf8)

            let edited = try ConfigurationEditor.setProfileLabel(in: source, profileID: "default", label: "Home")
            XCTAssertEqual(edited, expected)
            XCTAssertEqual(try ConfigurationEditor.setProfileLabel(in: edited, profileID: "default", label: "Home"), edited)
        }
    }

    func testPositionPatchChangesAppearanceAndResetsOptionalSources() throws {
        let source = inlineSource(profiles: #"""
        default = {
          label = "Default",
          positions = {
            "0_0" = {
              label = 'Clock',
              background = "#102030",
              notification_sources = ["system.weather"],
              label_alignment = "bottom",
              label_size = 10,
            },
            "1_0" = { label = "Keep" },
          },
        },
        other = { label = "Other" },
        """#)
        let patch = ConfigurationPositionPatch(
            label: .set("Control Clock"),
            background: .set("#A0B1C2"),
            labelAlignment: .set("center"),
            labelSize: .set(18),
            notificationSources: .reset
        )

        let edited = try ConfigurationEditor.patchPosition(in: source, profileID: "default", coordinate: "0_0", patch: patch)
        let decoded = try HidhoggConfigurationDecoder.decode(edited)
        let position = try XCTUnwrap(decoded.profile(id: "default")?.position(named: "0_0"))
        XCTAssertEqual(position.label, "Control Clock")
        XCTAssertEqual(position.background, "#A0B1C2")
        XCTAssertEqual(position.labelAlignment, "center")
        XCTAssertEqual(position.labelSize, 18)
        XCTAssertNil(position.notificationSources)
        XCTAssertEqual(decoded.profile(id: "default")?.position(named: "1_0")?.label, "Keep")
    }

    func testExpandedAppearancePatchPreservesCRLFCommentsAndOrder() throws {
        let sourceText = expandedSource.replacingOccurrences(
                of: "positions = { \"3_2\" = { label = \"Wide\", background = \"#102030\", notification_sources = [\"system.weather\"], label_alignment = \"center\", label_size = 18 } }",
                with: "positions = { \"3_2\" = { label = 'Wide', background = \"#102030\", notification_sources = [\"system.weather\"], label_alignment = \"center\", label_size = 18 } } # preserve this note"
            )
        let source = Data(sourceText.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let expected = Data(String(decoding: source, as: UTF8.self)
            .replacingOccurrences(of: "label = 'Wide'", with: "label = \"Updated Wide\"")
            .replacingOccurrences(of: "background = \"#102030\"", with: "background = \"#A0B0C0\"")
            .replacingOccurrences(
                of: "notification_sources = [\"system.weather\"]",
                with: "notification_sources = [\"system.weather\", \"system.calendar\"]"
            )
            .utf8)

        let edited = try ConfigurationEditor.patchPosition(
            in: source,
            profileID: "other",
            coordinate: "3_2",
            patch: ConfigurationPositionPatch(
                label: .set("Updated Wide"),
                background: .set("#A0B0C0"),
                notificationSources: .set(["system.weather", "system.calendar"])
            )
        )
        XCTAssertEqual(edited, expected)
        XCTAssertFalse(String(decoding: edited, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let decoded = try HidhoggConfigurationDecoder.decode(edited)
        XCTAssertEqual(decoded.profile(id: "other")?.position(named: "3_2")?.notificationSources,
                       ["system.weather", "system.calendar"])
    }

    func testSparsePositionPatchMaterializesOnlyRequestedCoordinate() throws {
        let source = inlineSource(profiles: #"default = { label = "Default", positions = { "1_0" = { label = "Keep" } } }, other = { label = "Other" }"#)
        let edited = try ConfigurationEditor.patchPosition(
            in: source,
            profileID: "default",
            coordinate: "3_2",
            patch: ConfigurationPositionPatch(label: .set("Wide"), background: .set("#102030"))
        )
        let decoded = try HidhoggConfigurationDecoder.decode(edited)
        XCTAssertEqual(decoded.profile(id: "default")?.position(named: "3_2")?.label, "Wide")
        XCTAssertEqual(decoded.profile(id: "default")?.position(named: "3_2")?.background, "#102030")
        XCTAssertEqual(decoded.profile(id: "default")?.position(named: "1_0")?.label, "Keep")
        XCTAssertFalse(String(decoding: edited, as: UTF8.self).contains("\"0_0\""))
    }

    func testBlankSemanticPositionLabelNoOpDoesNotMaterializeSparseTile() throws {
        let source = inlineSource(profiles: #"default = { label = "Default" }, other = { label = "Other" }"#)
        let edited = try ConfigurationEditor.patchPosition(
            in: source,
            profileID: "default",
            coordinate: "0_0",
            patch: ConfigurationPositionPatch(label: .set(""))
        )
        XCTAssertEqual(edited, source)
    }

    func testDottedInlineEntriesCanBeSetResetAndActionReplaced() throws {
        let source = inlineSource(profiles: #"""
        default = {
          label = "Default",
          positions."0_0".label = "Clock",
          positions."0_0".action.type = "type_text",
          positions."0_0".action.text = "Old text",
          positions."1_0".label = "Keep",
        },
        other = { label = "Other" },
        """#)

        let edited = try ConfigurationEditor.patchPosition(
            in: source,
            profileID: "default",
            coordinate: "0_0",
            patch: ConfigurationPositionPatch(
                background: .set("#123456"),
                action: .set(.execute(executable: "/usr/bin/printf", arguments: [], timeoutSeconds: 10, gesture: .release))
            )
        )
        let text = String(decoding: edited, as: UTF8.self)
        XCTAssertTrue(text.contains("positions.0_0.background = \"#123456\""))
        XCTAssertTrue(text.contains("positions.0_0.action.executable = \"/usr/bin/printf\""))
        XCTAssertFalse(text.contains("action.text"))
        let decoded = try HidhoggConfigurationDecoder.decode(edited)
        XCTAssertEqual(decoded.profile(id: "default")?.position(named: "0_0")?.background, "#123456")
        XCTAssertEqual(decoded.profile(id: "default")?.position(named: "1_0")?.label, "Keep")
        XCTAssertEqual(
            decoded.profile(id: "default")?.position(named: "0_0")?.action,
            .execute(executable: "/usr/bin/printf", arguments: [], timeoutSeconds: 10, gesture: .release)
        )

        let reset = try ConfigurationEditor.patchPosition(
            in: edited,
            profileID: "default",
            coordinate: "0_0",
            patch: ConfigurationPositionPatch(label: .reset, action: .reset)
        )
        let resetText = String(decoding: reset, as: UTF8.self)
        XCTAssertFalse(resetText.contains("positions.\"0_0\".label"))
        XCTAssertFalse(resetText.contains("positions.\"0_0\".action"))
        XCTAssertEqual(try HidhoggConfigurationDecoder.decode(reset).profile(id: "default")?.position(named: "0_0")?.label, "")
    }

    func testTrailingCommaMultilineActionEditPreservesUnchangedGestureAndTrivia() throws {
        let source = inlineSource(profiles: #"""
        default = {
          label = "Default",
          positions = {
            "0_0" = {
              label = "Clock",
              action = {
                type = "type_text",
                gesture = 'press',
                text = "Old",
              },
            },
          },
        },
        other = { label = "Other" },
        """#)

        let edited = try ConfigurationEditor.patchPosition(
            in: source,
            profileID: "default",
            coordinate: "0_0",
            patch: ConfigurationPositionPatch(
                action: .set(.execute(executable: "/usr/bin/printf", arguments: [], timeoutSeconds: 10, gesture: .press))
            )
        )
        let text = String(decoding: edited, as: UTF8.self)
        XCTAssertTrue(text.contains("gesture = 'press'"))
        XCTAssertFalse(text.contains("text = \"Old\""))
        XCTAssertTrue(text.contains("executable = \"/usr/bin/printf\""))
        XCTAssertFalse(text.contains("arguments ="))
        XCTAssertFalse(text.contains("timeout_seconds ="))
        XCTAssertTrue(text.contains("\"0_0\" = {\n      label = \"Clock\","))
        let decoded = try HidhoggConfigurationDecoder.decode(edited)
        XCTAssertEqual(
            decoded.profile(id: "default")?.position(named: "0_0")?.action,
            .execute(executable: "/usr/bin/printf", arguments: [], timeoutSeconds: 10, gesture: .press)
        )
    }

    func testExecuteWithOmittedDefaultsCanChangeVariant() throws {
        let source = inlineSource(profiles: #"default = { label = "Default", positions = { "0_0" = { action = { type = "execute", executable = "/usr/bin/printf" } } } }, other = { label = "Other" }"#)
        let edited = try ConfigurationEditor.patchPosition(
            in: source,
            profileID: "default",
            coordinate: "0_0",
            patch: ConfigurationPositionPatch(action: .set(.typeText(text: "Done", gesture: .release)))
        )
        let decoded = try HidhoggConfigurationDecoder.decode(edited)
        XCTAssertEqual(decoded.profile(id: "default")?.position(named: "0_0")?.action, .typeText(text: "Done", gesture: .release))
        let text = String(decoding: edited, as: UTF8.self)
        XCTAssertFalse(text.contains("executable"))
        XCTAssertFalse(text.contains("arguments"))
        XCTAssertFalse(text.contains("timeout_seconds"))
    }

    func testEveryActionVariantCanReplaceEveryExistingVariant() throws {
        let existing: [(String, ConfiguredAction)] = [
            ("type = \"activate_profile\", profile_id = \"other\"", .activateProfile(profileID: "other", gesture: .release)),
            ("type = \"execute\", executable = \"/usr/bin/printf\"", .execute(executable: "/usr/bin/printf", arguments: [], timeoutSeconds: 10, gesture: .release)),
            ("type = \"type_text\", text = \"Old\"", .typeText(text: "Old", gesture: .release)),
            ("type = \"key_press\", key = \"enter\"", .keyPress(key: "enter", gesture: .release)),
        ]
        let desired: [ConfiguredAction] = [
            .activateProfile(profileID: "other", gesture: .release),
            .execute(executable: "/usr/bin/printf", arguments: ["one"], timeoutSeconds: 7, gesture: .press),
            .typeText(text: "New", gesture: .press),
            .keyPress(key: "enter", gesture: .press),
        ]

        for (sourceAction, original) in existing {
            for target in desired {
                let source = inlineSource(profiles: #"default = { label = "Default", positions = { "0_0" = { action = { \#(sourceAction) } } } }, other = { label = "Other" }"#)
                let edited = try ConfigurationEditor.patchPosition(
                    in: source,
                    profileID: "default",
                    coordinate: "0_0",
                    patch: ConfigurationPositionPatch(action: .set(target))
                )
                let decoded = try HidhoggConfigurationDecoder.decode(edited)
                XCTAssertEqual(
                    decoded.profile(id: "default")?.position(named: "0_0")?.action,
                    target,
                    "replacement from \(original) to \(target)"
                )
                if original == target { XCTAssertEqual(edited, source) }
            }
        }
    }

    func testActionResetRemovesExpandedActionTable() throws {
        let source = Data("""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        default_profile_id = "default"

        [profiles.default]
        label = "Default"

        [profiles.default.positions."0_0"]
        label = "Clock"

        [profiles.default.positions."0_0".action]
        type = "type_text"
        text = "Old"

        [profiles.other]
        label = "Other"
        """.utf8)
        let edited = try ConfigurationEditor.patchPosition(
            in: source,
            profileID: "default",
            coordinate: "0_0",
            patch: ConfigurationPositionPatch(action: .reset)
        )
        let text = String(decoding: edited, as: UTF8.self)
        XCTAssertFalse(text.contains(".action]"))
        XCTAssertFalse(text.contains("text = \"Old\""))
        XCTAssertEqual(try HidhoggConfigurationDecoder.decode(edited).profile(id: "default")?.position(named: "0_0")?.action, nil)
    }

    func testCloneAppendsCanonicalSparseSemanticCopyForLFAndCRLF() throws {
        for lineEnding in ["\n", "\r\n"] {
            let source = Data(expandedSource.replacingOccurrences(of: "\n", with: lineEnding).utf8)
            let before = try HidhoggConfigurationDecoder.decode(source)
            let sourceProfile = try XCTUnwrap(before.profile(id: "other"))
            let withEOFComment = Data((String(decoding: source, as: UTF8.self) + "# EOF comment").utf8)

            let edited = try ConfigurationEditor.cloneProfile(
                in: withEOFComment,
                sourceID: "other",
                newID: "copy.with.dots",
                label: "Copy"
            )
            let original = String(decoding: withEOFComment, as: UTF8.self)
            let result = String(decoding: edited, as: UTF8.self)
            XCTAssertTrue(result.hasPrefix(original))
            XCTAssertFalse(result.dropFirst(original.count).contains("EOF comment"))
            XCTAssertTrue(result.contains("[profiles.\"copy.with.dots\"]"))
            XCTAssertFalse(result.contains("[profiles.\"copy.with.dots\"].positions.\"0_0\"]"))
            XCTAssertFalse(result.contains("[profiles.\"copy.with.dots\".positions.\"0_0\"]"))

            let after = try HidhoggConfigurationDecoder.decode(edited)
            let clone = try XCTUnwrap(after.profile(id: "copy.with.dots"))
            XCTAssertEqual(clone.label, "Copy")
            XCTAssertEqual(clone.positions, sourceProfile.positions)
            if lineEnding == "\r\n" {
                XCTAssertFalse(result.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            }
        }
    }

    func testInlineProfilesCloneInsertsOnlyNewEntry() throws {
        let source = inlineSource(profiles: #"default = { label = "Default" }, other = { label = "Other" }"#)
        let original = String(decoding: source, as: UTF8.self)
        let edited = try ConfigurationEditor.cloneProfile(in: source, sourceID: "other", newID: "copy", label: "Copy")
        let result = String(decoding: edited, as: UTF8.self)
        XCTAssertTrue(result.contains("other = { label = \"Other\" }"))
        XCTAssertTrue(result.contains("copy = { label = \"Copy\" }"))
        let expected = original.replacingOccurrences(
            of: "other = { label = \"Other\" }\n}",
            with: "other = { label = \"Other\" },\ncopy = { label = \"Copy\" }\n}"
        )
        XCTAssertEqual(result, expected)
        let decoded = try HidhoggConfigurationDecoder.decode(edited)
        XCTAssertEqual(decoded.profile(id: "copy")?.positions.count, 14)
        XCTAssertFalse(result.contains("positions"))
    }

    func testClonePreservesActionVariantsAndConfiguredStyle() throws {
        let source = inlineSource(profiles: #"""
        default = {
          label = "Default",
          positions = {
            "0_0" = { action = { type = "activate_profile", profile_id = "other" } },
            "1_0" = { action = { type = "execute", executable = "/usr/bin/printf", arguments = ["one"], timeout_seconds = 7, gesture = "press" } },
            "2_0" = { action = { type = "type_text", text = "Text", gesture = "press" } },
            "3_0" = { action = { type = "key_press", key = "enter" } },
            "3_2" = { label = "Wide", background = "#102030", notification_sources = ["system.weather"], label_alignment = "center", label_size = 18 },
          },
        },
        other = { label = "Other" },
        """#)
        let before = try HidhoggConfigurationDecoder.decode(source)
        let originalProfile = try XCTUnwrap(before.profile(id: "default"))
        let edited = try ConfigurationEditor.cloneProfile(in: source, sourceID: "default", newID: "copy", label: "Copy")
        let after = try HidhoggConfigurationDecoder.decode(edited)
        let clone = try XCTUnwrap(after.profile(id: "copy"))
        XCTAssertEqual(clone.label, "Copy")
        XCTAssertEqual(clone.positions, originalProfile.positions)
    }

    func testDeleteProfilePreservesUnrelatedSourceAndDottedInlineProfile() throws {
        let source = inlineSource(profiles: #"default = { label = "Default" }, "remove.me" = { label = "Remove", positions."0_0".label = "Dotted" }, keep = { label = "Keep" }"#)
        let edited = try ConfigurationEditor.deleteProfile(in: source, profileID: "remove.me", currentProfileID: "default")
        let text = String(decoding: edited, as: UTF8.self)
        XCTAssertFalse(text.contains("remove.me"))
        XCTAssertTrue(text.contains("default = { label = \"Default\" }"))
        XCTAssertTrue(text.contains("keep = { label = \"Keep\" }"))
        let decoded = try HidhoggConfigurationDecoder.decode(edited)
        XCTAssertEqual(decoded.profiles.map(\.id), ["default", "keep"])
    }

    func testDeleteExpandedProfilePreservesCRLFOutsideAttachedBlock() throws {
        let sourceText = expandedSource
            .replacingOccurrences(of: "[profiles.other]", with: "# DELETE WITH PROFILE\n[profiles.other]")
            + "\n[profiles.third]\nlabel = \"Third\"\n# KEEP AT EOF"
        let source = Data(sourceText.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let targetStart = try XCTUnwrap(sourceText.range(of: "# DELETE WITH PROFILE")).lowerBound
        let prefix = Data(sourceText[..<targetStart].replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let edited = try ConfigurationEditor.deleteProfile(in: source, profileID: "other", currentProfileID: "default")
        XCTAssertTrue(edited.starts(with: prefix))
        let result = String(decoding: edited, as: UTF8.self)
        XCTAssertFalse(result.contains("DELETE WITH PROFILE"))
        XCTAssertFalse(result.contains("[profiles.other]"))
        XCTAssertTrue(result.contains("[profiles.third]"))
        XCTAssertTrue(result.contains("# KEEP AT EOF"))
        XCTAssertFalse(result.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertNil(try HidhoggConfigurationDecoder.decode(edited).profile(id: "other"))
    }

    func testDeleteProfileGuardsLastDefaultCurrentAndSelfReference() throws {
        let single = Data("""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        default_profile_id = "default"
        [profiles.default]
        label = "Default"
        """.utf8)
        XCTAssertThrowsError(try ConfigurationEditor.deleteProfile(in: single, profileID: "default", currentProfileID: "default"))

        let plain = inlineSource(profiles: #"default = { label = "Default" }, other = { label = "Other" }"#)
        XCTAssertThrowsError(try ConfigurationEditor.deleteProfile(in: plain, profileID: "default", currentProfileID: "other"))
        XCTAssertThrowsError(try ConfigurationEditor.deleteProfile(in: plain, profileID: "other", currentProfileID: "other"))
        XCTAssertThrowsError(try ConfigurationEditor.deleteProfile(in: plain, profileID: "other", currentProfileID: "missing"))

        let externalReference = inlineSource(profiles: #"default = { label = "Default", positions = { "0_0" = { action = { type = "activate_profile", profile_id = "other" } } } }, other = { label = "Other" }"#)
        XCTAssertThrowsError(try ConfigurationEditor.deleteProfile(in: externalReference, profileID: "other", currentProfileID: "default"))
        let selfReference = inlineSource(profiles: #"default = { label = "Default" }, other = { label = "Other", positions = { "0_0" = { action = { type = "activate_profile", profile_id = "other" } } } }"#)
        XCTAssertThrowsError(try ConfigurationEditor.deleteProfile(in: selfReference, profileID: "other", currentProfileID: "default"))
    }

    private var expandedSource: String {
        """
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        default_profile_id = "default"

        [profiles.default]
        label  =  "Default"  # Keep this note.
        positions = { "0_0" = { label = "Clock" } }

        [profiles.other]
        label = "Other"
        positions = { "3_2" = { label = "Wide", background = "#102030", notification_sources = ["system.weather"], label_alignment = "center", label_size = 18 } }
        """
    }

    private func inlineSource(profiles: String) -> Data {
        Data("""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        default_profile_id = "default"
        profiles = {
        \(profiles)
        }
        """.utf8)
    }
}
