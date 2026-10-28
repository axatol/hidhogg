import AppKit

@MainActor
protocol KeyboardActivityMonitoring: AnyObject {
    func start(onActivity: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
final class NoopKeyboardActivityMonitor: KeyboardActivityMonitoring {
    func start(onActivity: @escaping @MainActor () -> Void) {}

    func stop() {}
}

@MainActor
final class AppKitKeyboardActivityMonitor: KeyboardActivityMonitoring {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start(onActivity: @escaping @MainActor () -> Void) {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in
            Task { @MainActor in onActivity() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Task { @MainActor in onActivity() }
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}
