import HidhoggDomain
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class ShortcutEditorDraftTests: XCTestCase {
    func testTokenEditParsesKeyboardAndMouseShortcuts() {
        var draft = ShortcutEditorDraft(initialShortcut: nil, allowsMouse: true)

        draft.updateRepresentation("${ctrl}+${shift}+C")

        XCTAssertEqual(
            draft.selectedShortcut,
            .keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.control, .shift]))
        )
        XCTAssertTrue(draft.canApply)
        XCTAssertNil(draft.parseError)

        draft.updateRepresentation("${cmd}+${mouse.left}")

        XCTAssertEqual(
            draft.selectedShortcut,
            .mouseClick(MouseShortcut(button: .left, modifiers: [.command]))
        )
        XCTAssertTrue(draft.canApply)
        XCTAssertNil(draft.parseError)
    }

    func testInvalidTokenStaysEditableAndDisablesApply() {
        var draft = ShortcutEditorDraft(initialShortcut: nil, allowsMouse: true)
        let invalidToken = "${ctrl}+${mouse.unknown}"

        draft.updateRepresentation(invalidToken)

        XCTAssertEqual(draft.representation, invalidToken)
        XCTAssertNil(draft.selectedShortcut)
        XCTAssertNotNil(draft.parseError)
        XCTAssertFalse(draft.canApply)
    }

    func testKeyboardOnlyDraftRejectsMouseToken() {
        var draft = ShortcutEditorDraft(initialShortcut: nil, allowsMouse: false)

        draft.updateRepresentation("${mouse.left}")

        XCTAssertEqual(draft.parseError, "Mouse shortcuts are unavailable in this editor.")
        XCTAssertFalse(draft.canApply)
    }

    func testModifierTogglesUpdateAndRemoveModifiersInTheToken() throws {
        var draft = ShortcutEditorDraft(
            initialShortcut: .keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.control])),
            allowsMouse: true
        )

        draft.toggleModifier(.shift)

        let withShift = InputShortcut.keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.control, .shift]))
        XCTAssertEqual(draft.selectedShortcut, withShift)
        XCTAssertEqual(draft.canonicalRepresentation, try ShortcutSender.format(withShift))

        draft.toggleModifier(.control)

        let withoutControl = InputShortcut.keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.shift]))
        XCTAssertEqual(draft.selectedShortcut, withoutControl)
        XCTAssertFalse(draft.isModifierSelected(.control))
        XCTAssertTrue(draft.isModifierSelected(.shift))
        XCTAssertEqual(draft.canonicalRepresentation, try ShortcutSender.format(withoutControl))
    }

    func testModifiersCanBeSelectedBeforeAKeyOrMouseTrigger() throws {
        var draft = ShortcutEditorDraft(initialShortcut: nil, allowsMouse: true)

        draft.toggleModifier(.command)

        XCTAssertTrue(draft.isModifierSelected(.command))
        XCTAssertNil(draft.trigger)
        XCTAssertFalse(draft.canApply)
        XCTAssertNil(draft.parseError)

        draft.select(.mouseClick(MouseShortcut(button: .left, modifiers: draft.orderedModifiers)))

        let shortcut = InputShortcut.mouseClick(MouseShortcut(button: .left, modifiers: [.command]))
        XCTAssertEqual(draft.selectedShortcut, shortcut)
        XCTAssertTrue(draft.canApply)
        XCTAssertEqual(draft.canonicalRepresentation, try ShortcutSender.format(shortcut))

        draft.removeTrigger()

        XCTAssertNil(draft.trigger)
        XCTAssertTrue(draft.isModifierSelected(.command))
        XCTAssertFalse(draft.canApply)
    }

    func testSelectingRecordedInputOnlyChangesTheLocalDraft() {
        var draft = ShortcutEditorDraft(initialShortcut: nil, allowsMouse: true)
        let recordedInput = InputShortcut.mouseClick(MouseShortcut(button: .right, modifiers: [.option]))

        draft.select(recordedInput)

        XCTAssertEqual(draft.selectedShortcut, recordedInput)
        XCTAssertEqual(draft.canonicalRepresentation, try? ShortcutSender.format(recordedInput))
        XCTAssertTrue(draft.canApply)
    }
}
