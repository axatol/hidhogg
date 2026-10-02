import AppKit
import UniformTypeIdentifiers

enum ApplicationBundleSelection: Equatable {
    case cancelled
    case selected(String)
    case invalid
}

@MainActor
enum ApplicationBundlePicker {
    static func choose() -> ApplicationBundleSelection {
        let panel = NSOpenPanel()
        configure(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        guard let bundleIdentifier = bundleIdentifier(at: url) else { return .invalid }
        return .selected(bundleIdentifier)
    }

    static func configure(_ panel: NSOpenPanel) {
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
    }

    static func bundleIdentifier(at url: URL) -> String? {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
              ProfileMappingPreferences.isValidIdentifier(bundleIdentifier) else {
            return nil
        }
        return bundleIdentifier
    }
}
