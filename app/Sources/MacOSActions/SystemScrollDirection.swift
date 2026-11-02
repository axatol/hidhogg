import Foundation

public enum SystemScrollDirection {
    public static func naturalScrollingEnabled() -> Bool {
        // An absent preference is treated as natural scrolling.
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }
}
