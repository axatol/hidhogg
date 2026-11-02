import AppKit
import HidhoggDomain
import MacOSActions
import SwiftUI
import XCTest
@testable import HidhoggApp

@MainActor
final class ShortcutEditorLayoutTests: XCTestCase {
    func testShortcutEditorRendersSyntheticStatesAtNarrowAndWideSizes() async throws {
        let directory = URL(fileURLWithPath: "/Volumes/Data/tmp/hidhogg-bind01-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scenarios = [
            EditorScenario(
                name: "keyboard",
                shortcut: .keyboard(HidhoggDomain.KeyboardShortcut(keyCode: 8, modifiers: [.control, .shift]))
            ),
            EditorScenario(
                name: "mouse-command-click",
                shortcut: .mouseClick(MouseShortcut(button: .left, modifiers: [.command]))
            ),
            EditorScenario(
                name: "invalid",
                shortcut: .keyboard(HidhoggDomain.KeyboardShortcut(keyCode: UInt16.max))
            ),
            EditorScenario(name: "recording", shortcut: nil, startsRecording: true)
        ]

        for width in [CGFloat(460), 720] {
            for scenario in scenarios {
                try await capture(
                    scenario,
                    size: NSSize(width: width, height: 700),
                    directory: directory
                )
            }
        }
    }

    private func capture(_ scenario: EditorScenario, size: NSSize, directory: URL) async throws {
        let editor = ShortcutEditorView(
            initialInputShortcut: scenario.shortcut,
            allowsMouse: true,
            startsRecording: scenario.startsRecording,
            onCancel: {},
            onCommit: { _ in }
        )
        let hostingView = NSHostingView(
            rootView: editor
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: size)
        defer {
            window.contentView = nil
            window.close()
        }

        for _ in 0..<10 {
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(window.isVisible, "The editor fixture must remain hidden.")
        XCTAssertFalse(window.isKeyWindow, "The editor fixture must remain non-key.")
        XCTAssertEqual(hostingView.bounds.size, size)

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 100)

        let filename = "\(scenario.name)-\(Int(size.width))x\(Int(size.height)).png"
        try png.write(to: directory.appendingPathComponent(filename))
    }
}

private struct EditorScenario {
    let name: String
    let shortcut: InputShortcut?
    var startsRecording = false
}
