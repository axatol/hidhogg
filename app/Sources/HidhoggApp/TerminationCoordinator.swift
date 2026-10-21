import AppKit
import Combine

@MainActor
final class TerminationCoordinator: ObservableObject {
    private enum State {
        case idle
        case quitting
        case restarting
        case readyToTerminate
    }

    private var state = State.idle

    private let prepareForQuit: @MainActor () -> Void
    private let cleanupForQuit: @MainActor () async -> Bool
    private let cancelQuit: @MainActor () -> Void
    private let terminate: @MainActor () -> Void

    init(
        prepareForQuit: @escaping @MainActor () -> Void,
        cleanupForQuit: @escaping @MainActor () async -> Bool,
        cancelQuit: @escaping @MainActor () -> Void = {},
        terminate: @escaping @MainActor () -> Void
    ) {
        self.prepareForQuit = prepareForQuit
        self.cleanupForQuit = cleanupForQuit
        self.cancelQuit = cancelQuit
        self.terminate = terminate
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        switch state {
        case .readyToTerminate:
            return .terminateNow
        case .quitting, .restarting:
            return .terminateCancel
        case .idle:
            state = .quitting
            prepareForQuit()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cleanupSucceeded = await self.cleanupForQuit()
                guard case .quitting = self.state else { return }
                guard cleanupSucceeded else {
                    self.state = .idle
                    self.cancelQuit()
                    return
                }
                self.state = .readyToTerminate
                DispatchQueue.main.async { [weak self] in
                    self?.terminate()
                }
            }
            return .terminateCancel
        }
    }

    func beginRestart() -> Bool {
        guard case .idle = state else { return false }
        state = .restarting
        return true
    }

    func cancelRestart() {
        guard case .restarting = state else { return }
        state = .idle
    }

    func terminateAfterVerifiedRestart() {
        guard case .restarting = state else { return }
        state = .readyToTerminate
        DispatchQueue.main.async { [weak self] in
            self?.terminate()
        }
    }
}
