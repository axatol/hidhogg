import AppKit
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class ShortcutCaptureTests: XCTestCase {
    func testPerformKeyEquivalentFallsThroughWhenViewIsUnattached() throws {
        let view = ShortcutCaptureNSView()
        var captured = [KeyboardShortcut]()
        view.onCapture = { captured.append($0) }
        let event = try keyEvent(keyCode: 21, modifiers: [.control, .shift, .command])

        XCTAssertFalse(view.performKeyEquivalent(with: event))
        XCTAssertTrue(captured.isEmpty)
    }

    func testPerformKeyEquivalentCapturesOnlyOnceWhenViewIsFirstResponder() throws {
        let view = FirstResponderShortcutCaptureNSView()
        var captured = [KeyboardShortcut]()
        view.onCapture = { captured.append($0) }
        let event = try keyEvent(keyCode: 21, modifiers: [.control, .shift, .command])

        XCTAssertTrue(view.performKeyEquivalent(with: event))
        view.keyDown(with: event)

        XCTAssertEqual(captured, [.init(keyCode: 21, modifiers: [.control, .shift, .command])])
    }

    func testKeyDownCapturesReservedCombinationOnceWithoutPostingEvents() throws {
        let view = ShortcutCaptureNSView()
        var captured = [KeyboardShortcut]()
        view.onCapture = { captured.append($0) }
        let event = try keyEvent(keyCode: 21, modifiers: [.control, .shift, .command])

        view.keyDown(with: event)
        view.keyDown(with: event)

        XCTAssertEqual(captured, [.init(keyCode: 21, modifiers: [.control, .shift, .command])])
    }

    func testRepeatedKeyDownDoesNotCapture() throws {
        let view = ShortcutCaptureNSView()
        var captured = [KeyboardShortcut]()
        view.onCapture = { captured.append($0) }
        let event = try keyEvent(keyCode: 21, modifiers: [.command], isARepeat: true)

        view.keyDown(with: event)

        XCTAssertTrue(captured.isEmpty)
    }

    func testManualCommitUpdatesBindingAndCancelPreservesExistingBinding() {
        let existing = KeyboardShortcut(keyCode: 123, modifiers: [.command])
        let selected = KeyboardShortcut(keyCode: 21, modifiers: [.control, .shift, .command])
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in
            XCTFail("Manual selection must not post keyboard events")
        })
        let model = makeModel(sender: sender)
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(existing)
        model.updateDraft(configuration)

        model.beginRecording(for: .back)
        model.cancelRecording()

        XCTAssertEqual(model.document.draft, configuration)
        XCTAssertNil(model.recordingTarget)

        model.beginRecording(for: .back)
        model.completeRecording(selected)

        XCTAssertEqual(model.document.draft.mouse?.binding(for: .back, application: nil), .key(selected))
        XCTAssertNil(model.recordingTarget)
    }

    private func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "4",
            charactersIgnoringModifiers: "4",
            isARepeat: isARepeat,
            keyCode: keyCode
        ))
    }

    private func makeModel(sender: ShortcutSender) -> AppModel {
        let url = URL(fileURLWithPath: "/tmp/hidhogg-shortcut-capture-test.toml")
        return AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: NoopBindingSession(),
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
    }
}

private struct NoopBindingSession: BindingSession {
    let events = AsyncStream<BoltEvent> { $0.finish() }

    func discover() async {}
    func enable() async {}
    func disable() async {}
    func stop() async {}

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }
}

@MainActor
private final class FirstResponderShortcutCaptureNSView: ShortcutCaptureNSView {
    override var isCaptureFirstResponder: Bool { true }
}
