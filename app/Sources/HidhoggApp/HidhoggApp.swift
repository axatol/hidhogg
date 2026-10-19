import SwiftUI

@main
struct HidhoggApp: App {
    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
    }
}
