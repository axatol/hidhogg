import SwiftUI
import AppKit

enum AppAppearance {
    static let accent = Color(red: 0.76, green: 0.57, blue: 0.27)
    static let sidebarSelection = Color(red: 143.0 / 255.0, green: 101.0 / 255.0, blue: 31.0 / 255.0)

    @MainActor static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "Hidhogg", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    }()
}
