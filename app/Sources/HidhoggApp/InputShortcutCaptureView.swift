import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI

@MainActor
struct InputShortcutCaptureView: NSViewRepresentable {
    let allowsMouse: Bool
    let onCapture: (InputShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> InputShortcutCaptureNSView {
        let view = InputShortcutCaptureNSView()
        view.allowsMouse = allowsMouse
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: InputShortcutCaptureNSView, context: Context) {
        view.allowsMouse = allowsMouse
        view.onCapture = onCapture
        view.onCancel = onCancel
    }
}
