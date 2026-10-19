import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI

@MainActor
struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (HidhoggDomain.KeyboardShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        Task { @MainActor [weak view] in view?.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
    }
}

@MainActor
final class ShortcutCaptureNSView: NSView {
    var onCapture: ((HidhoggDomain.KeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.isEmpty {
            onCancel?()
            return
        }
        guard let shortcut = ShortcutSender.from(event: event) else {
            NSSound.beep()
            return
        }
        onCapture?(shortcut)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        "Press a key combination · Escape cancels".draw(
            at: NSPoint(x: 10, y: 7),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }
}
