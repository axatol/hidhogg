import AppKit
import SwiftUI

struct D200XSavedScreensaverPreview: View {
    @ObservedObject var store: D200XScreensaverPreviewStore
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Screensaver preview", isExpanded: $isExpanded) {
            if let data = store.image, let image = NSImage(data: data) {
                D200XScreensaverLayoutGuide(image: image)
                    .accessibilityLabel("Last screensaver image sent by HidHogg")
            } else {
                Text("Send an image to retain its preview here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let message = store.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }
}
