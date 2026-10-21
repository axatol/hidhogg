import AppKit
import Combine

@MainActor
final class RestartCoordinator: ObservableObject {
    @Published private(set) var inProgress = false

    private let cleanup: @MainActor () async -> Bool
    private let launch: @MainActor () async throws -> Void
    private let beginRestart: @MainActor () -> Bool
    private let cancelRestart: @MainActor () -> Void
    private let releaseOwnership: @MainActor () throws -> Void
    private let reacquireOwnership: @MainActor () throws -> Bool
    private let isOwner: @MainActor () -> Bool
    private let terminate: @MainActor () -> Void
    private let reportError: @MainActor (String) -> Void

    init(
        cleanup: @escaping @MainActor () async -> Bool,
        launch: @escaping @MainActor () async throws -> Void = {
            try await RestartCoordinator.launchFreshApplication()
        },
        beginRestart: @escaping @MainActor () -> Bool = { true },
        cancelRestart: @escaping @MainActor () -> Void = {},
        releaseOwnership: @escaping @MainActor () throws -> Void = {},
        reacquireOwnership: @escaping @MainActor () throws -> Bool = { true },
        isOwner: @escaping @MainActor () -> Bool = { true },
        terminate: @escaping @MainActor () -> Void,
        reportError: @escaping @MainActor (String) -> Void
    ) {
        self.cleanup = cleanup
        self.launch = launch
        self.beginRestart = beginRestart
        self.cancelRestart = cancelRestart
        self.releaseOwnership = releaseOwnership
        self.reacquireOwnership = reacquireOwnership
        self.isOwner = isOwner
        self.terminate = terminate
        self.reportError = reportError
    }

    func requestRestart() {
        guard !inProgress, isOwner() else { return }
        inProgress = true
        guard beginRestart() else {
            inProgress = false
            return
        }
        Task { @MainActor [weak self] in
            await self?.restart()
        }
    }

    static func launchFreshApplication() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        try await BoundedApplicationLaunch.wait(timeout: .seconds(10)) { complete in
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, error in
                let result: Result<Void, Error>
                if let error {
                    result = .failure(error)
                } else if let application, application.processIdentifier != currentProcessID {
                    result = .success(())
                } else {
                    result = .failure(RestartFailure.existingInstanceReturned)
                }
                Task { @MainActor in complete(result) }
            }
        }
    }

    private func restart() async {
        guard await cleanup() else {
            fail("Restart stopped. Review configuration and device errors before retrying.")
            return
        }

        do {
            try releaseOwnership()
        } catch {
            recoverAfterLaunchFailure(error.localizedDescription)
            return
        }

        do {
            try await launch()
        } catch {
            recoverAfterLaunchFailure(error.localizedDescription)
            return
        }

        terminate()
    }

    private func recoverAfterLaunchFailure(_ message: String) {
        do {
            if try reacquireOwnership() {
                fail(message)
                return
            }
        } catch {
            reportError("Restart failed and application ownership could not be verified. Hidhogg will quit.")
            terminate()
            return
        }
        reportError(message)
        terminate()
    }

    private func fail(_ message: String) {
        guard isOwner() else {
            reportError(message)
            terminate()
            return
        }
        inProgress = false
        cancelRestart()
        reportError(message)
    }
}

@MainActor
enum BoundedApplicationLaunch {
    static func wait(
        timeout: Duration,
        start: (@escaping @MainActor (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        let attempt = Attempt()
        try await withCheckedThrowingContinuation { continuation in
            attempt.continuation = continuation
            attempt.deadline = Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                attempt.complete(.failure(RestartFailure.launchTimedOut))
            }
            start { result in attempt.complete(result) }
        }
    }

    private final class Attempt {
        var continuation: CheckedContinuation<Void, Error>?
        var deadline: Task<Void, Never>?

        func complete(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel()
            deadline = nil
            continuation.resume(with: result)
        }
    }
}

enum RestartFailure: LocalizedError {
    case existingInstanceReturned
    case launchTimedOut

    var errorDescription: String? {
        switch self {
        case .existingInstanceReturned: "macOS returned the current Hidhogg process instead of launching a fresh instance."
        case .launchTimedOut: "macOS did not finish launching Hidhogg within 10 seconds."
        }
    }
}
