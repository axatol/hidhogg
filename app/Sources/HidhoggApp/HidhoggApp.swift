import SwiftUI
import AppKit

@main
struct HidhoggApp: App {
    @NSApplicationDelegateAdaptor(HidhoggAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(model)
                .onAppear { appDelegate.model = model }
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
    }
}

@MainActor
final class HidhoggAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.prepareForLifecycleStop()
        Task {
            await model.stopForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
