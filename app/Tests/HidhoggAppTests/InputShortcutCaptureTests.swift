import AppKit
import HidhoggDomain
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class InputShortcutCaptureTests: XCTestCase {
    func testPreArmClickIsIgnoredAndCaptureCompletesOnce() throws {
        let capture = makeCapture(allowsMouse: true)
        var captured = [InputShortcut]()
        capture.captureView.onCapture = { captured.append($0) }
        let event = try mouseEvent(window: capture.window, location: NSPoint(x: 20, y: 20))

        capture.captureView.mouseDown(with: event)
        XCTAssertTrue(captured.isEmpty)

        capture.captureView.armCapture()
        XCTAssertTrue(capture.window.firstResponder === capture.captureView)
        capture.captureView.mouseDown(with: event)
        capture.captureView.mouseDown(with: event)

        XCTAssertEqual(captured, [.mouseClick(MouseShortcut(button: .left))])
    }

    func testMouseCaptureRequiresAllowedFocusedSurfaceAndInBoundsEvent() throws {
        let capture = makeCapture(allowsMouse: true)
        var captured = [InputShortcut]()
        capture.captureView.onCapture = { captured.append($0) }
        capture.captureView.armCapture()

        let inside = try mouseEvent(window: capture.window, location: NSPoint(x: 20, y: 20))
        XCTAssertTrue(capture.window.makeFirstResponder(capture.textField))
        capture.captureView.mouseDown(with: inside)
        XCTAssertTrue(captured.isEmpty)

        capture.captureView.armCapture()
        let outside = try mouseEvent(window: capture.window, location: NSPoint(x: 160, y: 90))
        capture.captureView.mouseDown(with: outside)
        XCTAssertTrue(captured.isEmpty)

        let otherWindow = makeWindow()
        let foreignEvent = try mouseEvent(window: otherWindow, location: NSPoint(x: 20, y: 20))
        capture.captureView.mouseDown(with: foreignEvent)
        XCTAssertTrue(captured.isEmpty)
    }

    func testMouseCaptureIsRejectedWhenMouseInputIsDisabled() throws {
        let capture = makeCapture(allowsMouse: false)
        var captured = [InputShortcut]()
        capture.captureView.onCapture = { captured.append($0) }
        capture.captureView.armCapture()
        let event = try mouseEvent(window: capture.window, location: NSPoint(x: 20, y: 20))

        capture.captureView.mouseDown(with: event)

        XCTAssertTrue(captured.isEmpty)
    }

    func testRepeatedKeysAreIgnoredAndAKeyIsCapturedOnce() throws {
        let capture = makeCapture(allowsMouse: true)
        var captured = [InputShortcut]()
        capture.captureView.onCapture = { captured.append($0) }
        capture.captureView.armCapture()
        let repeated = try keyEvent(window: capture.window, isARepeat: true)

        capture.captureView.keyDown(with: repeated)
        XCTAssertTrue(captured.isEmpty)

        let event = try keyEvent(window: capture.window)
        XCTAssertTrue(capture.captureView.performKeyEquivalent(with: event))
        capture.captureView.keyDown(with: event)

        XCTAssertEqual(captured, [.keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.command]))])
    }

    func testEscapeCancelsCaptureWithoutReturningAShortcut() throws {
        let capture = makeCapture(allowsMouse: true)
        var captured = [InputShortcut]()
        var cancelCount = 0
        capture.captureView.onCapture = { captured.append($0) }
        capture.captureView.onCancel = { cancelCount += 1 }
        capture.captureView.armCapture()
        let event = try keyEvent(window: capture.window, keyCode: 53, modifiers: [])

        XCTAssertTrue(capture.captureView.performKeyEquivalent(with: event))
        capture.captureView.keyDown(with: event)

        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(cancelCount, 1)
    }

    private func makeCapture(allowsMouse: Bool) -> (window: NSWindow, captureView: InputShortcutCaptureNSView, textField: NSTextField) {
        let window = makeWindow()
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let captureView = InputShortcutCaptureNSView(frame: NSRect(x: 10, y: 10, width: 100, height: 40))
        let textField = NSTextField(frame: NSRect(x: 120, y: 70, width: 70, height: 24))
        captureView.allowsMouse = allowsMouse
        contentView.addSubview(captureView)
        contentView.addSubview(textField)
        window.contentView = contentView
        return (window, captureView, textField)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
    }

    private func mouseEvent(window: NSWindow, location: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func keyEvent(
        window: NSWindow,
        keyCode: UInt16 = 8,
        modifiers: NSEvent.ModifierFlags = [.command],
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: isARepeat,
            keyCode: keyCode
        ))
    }
}
