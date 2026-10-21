import Foundation

@MainActor
final class WakeRecoveryCoordinator {
    enum Outcome { case connected, retry, stop }

    typealias Delay = @MainActor (Duration) async throws -> Void

    private let delay: Delay
    private let report: @MainActor (DiagnosticCode, String) -> Void
    private var cleanupTask: Task<Bool, Never>?
    private var recoveryTask: Task<Void, Never>?
    private(set) var sleeping = false
    private var reconnect = false
    private var revision: UInt64 = 0

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
        let current = revision
        recoveryTask = Task { [weak self] in
            let cleaned = await cleanupTask.value
            guard let self, self.revision == current, !Task.isCancelled else { return }
            guard cleaned else {
                self.finish(code: .wakeReconnectCancelled, message: "Wake reconnect cancelled because sleep cleanup was not verified.")
                return
            }
            for (index, seconds) in [0, 1, 2, 4].enumerated() {
                do { try await self.delay(.seconds(seconds)) } catch { return }
                guard self.revision == current, !Task.isCancelled else { return }
                self.report(.wakeReconnectAttempt, "Attempting wake reconnect \(index + 1)/4.")
                let result = await attempt()
                guard self.revision == current, !Task.isCancelled else { return }
                switch result {
                case .connected:
                    self.finish(code: .wakeReconnectSucceeded, message: "Device connection restored; normal settings reconciliation continues.")
                    return
                case .stop:
                    self.finish(code: .wakeReconnectCancelled, message: "Wake reconnect stopped by a session safety condition.")
                    return
                case .retry:
                    continue
                }
            }
            self.finish(code: .wakeReconnectExhausted, message: "Wake reconnect exhausted its four receiver-readiness attempts.")
        }
    }

    func cancel() {
        revision &+= 1
        if reconnect {
            report(.wakeReconnectCancelled, "Wake reconnect cancelled by a newer lifecycle intent.")
        }
        reconnect = false
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func finish(code: DiagnosticCode, message: String) {
        reconnect = false
        recoveryTask = nil
        report(code, message)
    }
}
