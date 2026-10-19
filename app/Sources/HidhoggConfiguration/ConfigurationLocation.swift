import Foundation

public enum ConfigurationLocation {
    public static func url(xdgConfigHome: String?, home: URL) -> URL {
        let base: URL

        if let xdgConfigHome, !xdgConfigHome.isEmpty, xdgConfigHome.hasPrefix("/") {
            base = URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".config", isDirectory: true)
        }

        return base
            .appendingPathComponent("hidhogg", isDirectory: true)
            .appendingPathComponent("config.toml")
            .standardizedFileURL
    }
}
