import AppKit
import HidhoggDomain
import MacOSActions

@MainActor
final class InputShortcutCaptureNSView: NSView {
    var allowsMouse = false
    var onCapture: ((InputShortcut) -> Void)?
    var onCancel: (() -> Void)?

    private var isCaptureArmed = false
    private var didFinishCapture = false
    private weak var lastHandledEvent: NSEvent?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            isCaptureArmed = false
            return
        }

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.armCapture()
        }
    }

    func armCapture() {
        guard !didFinishCapture, let window else { return }
        let becameFirstResponder = window.makeFirstResponder(self)
        isCaptureArmed = becameFirstResponder && window.firstResponder === self
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCaptureFirstResponder else { return false }
        return handleKeyDown(event)
    }

    override func keyDown(with event: NSEvent) {
        guard handleKeyDown(event) else {
            NSSound.beep()
            return
        }
    }

    override func mouseDown(with event: NSEvent) {
        handleMouseDown(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        handleMouseDown(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        handleMouseDown(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let message = allowsMouse
            ? "Press a key combination or click a mouse button · Escape cancels"
            : "Press a key combination · Escape cancels"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let textRect = bounds.insetBy(dx: 10, dy: 4)
        NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
        ).draw(in: textRect)
    }

    private var isCaptureFirstResponder: Bool {
        window?.firstResponder === self
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isCaptureFirstResponder, event.type == .keyDown else { return false }
        if event.isARepeat || event === lastHandledEvent { return true }
        guard isCaptureArmed else { return didFinishCapture }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.isEmpty {
            lastHandledEvent = event
            finishCapture()
            onCancel?()
            return true
        }

        guard let shortcut = ShortcutSender.inputShortcut(from: event) else { return false }
        lastHandledEvent = event
        finishCapture()
        onCapture?(shortcut)
        return true
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard isCaptureArmed, isCaptureFirstResponder, allowsMouse,
              let window, event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let shortcut = ShortcutSender.inputShortcut(from: event) else { return }
        lastHandledEvent = event
        finishCapture()
        onCapture?(shortcut)
    }

    private func finishCapture() {
        isCaptureArmed = false
        didFinishCapture = true
    }
}
