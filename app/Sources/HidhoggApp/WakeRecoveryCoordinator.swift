import Foundation

@MainActor
final class WakeRecoveryCoordinator {
    enum Outcome { case connected, retry, stop }

    typealias Delay = @MainActor (Duration) async throws -> Void

    private enum RecoveryKind { case wake, connection }

    private let delay: Delay
    private let report: @MainActor (DiagnosticCode, String) -> Void
    private var cleanupTask: Task<Bool, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryKind: RecoveryKind?
    private var awaitingAttemptResult = false
    private(set) var sleeping = false
    private var reconnect = false
    private var revision: UInt64 = 0

    var isRecovering: Bool { recoveryTask != nil }

    init(
        delay: @escaping Delay = { try await Task.sleep(for: $0) },
        report: @escaping @MainActor (DiagnosticCode, String) -> Void
    ) {
        self.delay = delay
        self.report = report
    }

    isolated deinit { recoveryTask?.cancel() }

    func sleep(reconnect: Bool, cleanup: @escaping @MainActor () async -> Bool) {
        guard !sleeping else { return }
        cancel()
        sleeping = true
        self.reconnect = reconnect
        recoveryKind = reconnect ? .wake : nil
        report(.systemSleep, "System sleep received; stopping the device session.")
        let previous = cleanupTask
        cleanupTask = Task {
            if let previous { _ = await previous.value }
            return await cleanup()
        }
    }

    func wake(attempt: @escaping @MainActor () async -> Outcome) {
        guard sleeping else { return }
        sleeping = false
        report(.systemWake, "System wake received.")
        guard reconnect, let cleanupTask else { return }
        startRecovery(kind: .wake, firstDelay: .zero, cleanupTask: cleanupTask, attempt: attempt)
    }

    func retry(attempt: @escaping @MainActor () async -> Outcome) {
        guard !sleeping else { return }
        reconnect = true
        startRecovery(kind: .connection, firstDelay: .seconds(1), cleanupTask: nil, attempt: attempt)
    }

    func connectionRestored() {
        guard recoveryTask != nil, !awaitingAttemptResult else { return }
        finish(code: successCode, message: successMessage)
    }

    func cancel() {
        revision &+= 1
        if reconnect {
            report(cancelledCode, "Automatic reconnect cancelled by a newer lifecycle intent.")
        }
        reconnect = false
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryKind = nil
        awaitingAttemptResult = false
    }

    private func startRecovery(
        kind: RecoveryKind,
        firstDelay: Duration,
        cleanupTask: Task<Bool, Never>?,
        attempt: @escaping @MainActor () async -> Outcome
    ) {
        guard recoveryTask == nil else { return }
        revision &+= 1
        let current = revision
        recoveryKind = kind
        reconnect = true
        recoveryTask = Task { [weak self] in
            if let cleanupTask { _ = await cleanupTask.value }

            var attemptIndex = 0
            var nextDelay = firstDelay
            var nextRetrySeconds = kind == .wake ? 1 : 2
            while !Task.isCancelled, self?.revision == current {
                guard let wait = self?.delay else { return }
                do { try await wait(nextDelay) } catch {
                    guard !Task.isCancelled, self?.revision == current else { return }
                    if let self {
                        self.finish(code: self.cancelledCode, message: "Automatic reconnect delay failed.")
                    }
                    return
                }
                await Task.yield()
                guard !Task.isCancelled, self?.revision == current else { return }

                let attemptCode = self?.attemptCode
                let attemptMessage = self?.attemptMessage(index: attemptIndex + 1)
                if let attemptCode, let attemptMessage { self?.report(attemptCode, attemptMessage) }

                self?.awaitingAttemptResult = true
                let result = await attempt()
                guard !Task.isCancelled, self?.revision == current else { return }
                self?.awaitingAttemptResult = false
                switch result {
                case .connected:
                    guard let self else { return }
                    self.finish(code: self.successCode, message: self.successMessage)
                    return
                case .stop:
                    guard let self else { return }
                    self.finish(code: self.cancelledCode, message: "Automatic reconnect stopped by a session safety condition.")
                    return
                case .retry:
                    attemptIndex += 1
                    nextDelay = .seconds(nextRetrySeconds)
                    nextRetrySeconds = min(30, nextRetrySeconds * 2)
                }
            }
        }
    }

    private var attemptCode: DiagnosticCode {
        switch recoveryKind {
        case .wake: .wakeReconnectAttempt
        case .connection, nil: .connectionReconnectAttempt
        }
    }

    private func attemptMessage(index: Int) -> String {
        switch recoveryKind {
        case .wake: "Attempting wake reconnect \(index)."
        case .connection, nil: "Attempting device reconnect \(index)."
        }
    }

    private var successCode: DiagnosticCode {
        switch recoveryKind {
        case .wake: .wakeReconnectSucceeded
        case .connection, nil: .connectionReconnectSucceeded
        }
    }

    private var successMessage: String {
        switch recoveryKind {
        case .wake: "Device connection restored; normal settings reconciliation continues."
        case .connection, nil: "Device connection restored; normal settings reconciliation continues."
        }
    }

    private var cancelledCode: DiagnosticCode {
        switch recoveryKind {
        case .wake: .wakeReconnectCancelled
        case .connection, nil: .connectionReconnectCancelled
        }
    }

    private func finish(code: DiagnosticCode, message: String) {
        revision &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        reconnect = false
        recoveryKind = nil
        awaitingAttemptResult = false
        report(code, message)
    }
}
