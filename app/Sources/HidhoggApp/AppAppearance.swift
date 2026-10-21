import SwiftUI
import AppKit

enum AppAppearance {
    static let accent = Color(red: 0.76, green: 0.57, blue: 0.27)

    @MainActor static let icon: NSImage = {
        if let url = Bundle.main.url(forResource: "Hidhogg", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    }()
}
