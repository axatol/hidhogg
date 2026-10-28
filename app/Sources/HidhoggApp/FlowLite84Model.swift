import Combine
import Foundation
import LofreeFlowLite84

@MainActor
final class FlowLite84Model: ObservableObject {
    @Published private(set) var status: FlowLite84ConnectionStatus = .disconnected
    @Published private(set) var snapshot: FlowLite84Snapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var connectionRequested = false

    var onDiagnostic: ((DiagnosticEvent) -> Void)?

    private var session: (any FlowLite84SessionProtocol)?
    private var eventTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var sessionEpoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var operationRevision: UInt64 = 0
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?
    private var isSleeping = false
    private var isSuspended = false
    private var isReleasingSession = false
    private var isStopped = false
    private var hasExplicitConnectionIntent = false
    private let keyboardActivityMonitor: any KeyboardActivityMonitoring
    private let monotonicNow: @MainActor () -> ContinuousClock.Instant
    private var isMonitoringKeyboardActivity = false
    private var latestSuccessfulSnapshotAt: ContinuousClock.Instant?
    private var latestAutomaticBatteryRefreshAttemptAt: ContinuousClock.Instant?

    init(
        session: (any FlowLite84SessionProtocol)? = nil,
        keyboardActivityMonitor: (any KeyboardActivityMonitoring)? = nil,
        monotonicNow: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.session = session
        self.keyboardActivityMonitor = keyboardActivityMonitor ?? NoopKeyboardActivityMonitor()
        self.monotonicNow = monotonicNow
        if session != nil { sessionEpoch = 1 }
    }

    isolated deinit {
        eventTask?.cancel()
        keyboardActivityMonitor.stop()
    }

    var isConnected: Bool {
        if case .connected = status { true } else { false }
    }

    var isKeyboardOnline: Bool {
        isConnected && snapshot?.online == true
    }

    var isBusy: Bool {
        if case .connecting = status { return true }
        if case .disconnecting = status { return true }
        return activeOperationID != nil || isRefreshing
    }

    var connectionTitle: String {
        switch status {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting"
        case .failed: "Failed"
        }
    }

    var batteryText: String {
        guard let battery = snapshot?.battery else { return "Unavailable" }
        let level = battery.reportedLevel.flatMap { $0 <= 100 ? "Reported level \($0)" : nil }
            ?? "Reported level unavailable"
        let charging: String = switch battery.charging {
        case .some(true): "Charging"
        case .some(false): "Not charging"
        case .none: "Charging state unavailable"
        }
        return isConnected ? "\(level) · \(charging)" : "Last reported: \(level) · \(charging)"
    }

    func connect() {
        guard !isStopped, !isSleeping, !isSuspended else { return }
        hasExplicitConnectionIntent = true
        guard session != nil else {
            let message = "Flow Lite84 receiver session is unavailable."
            status = .failed(.unavailable)
            fail(message)
            return
        }
        connectionRequested = true
        guard !isConnected, !isBusy else { return }
        startConnection()
    }

    func connectOnLaunch() {
        guard !hasExplicitConnectionIntent, session != nil else { return }
        connect()
    }

    func refresh() {
        guard !isStopped, !isSleeping, !isSuspended,
              connectionRequested, isConnected, !isBusy,
              session != nil else { return }

        beginRefresh(batteryOnly: false)
    }

    private func beginRefresh(batteryOnly: Bool) {
        guard let session else { return }
        nextOperationID &+= 1
        let operationID = nextOperationID
        let revision = operationRevision
        activeOperationID = operationID
        isRefreshing = true
        errorMessage = nil
        operationTask = Task { @MainActor [weak self] in
            do {
                if batteryOnly {
                    try await session.refreshBattery()
                } else {
                    try await session.refresh()
                }
            } catch let failure as FlowLite84Failure {
                guard let self, self.operationRevision == revision else {
                    self?.finishOperation(operationID)
                    return
                }
                self.fail(failure.userMessage)
            } catch {
                guard let self, self.operationRevision == revision else {
                    self?.finishOperation(operationID)
                    return
                }
                self.fail("The Flow Lite84 status could not be refreshed.")
            }
            self?.finishOperation(operationID)
        }
    }

    func disconnect() {
        hasExplicitConnectionIntent = true
        connectionRequested = false
        errorMessage = nil
        releaseSession()
    }

    func sleep() {
        guard !isSleeping else { return }
        isSleeping = true
        releaseSession()
    }

    func wake() {
        guard isSleeping else { return }
        isSleeping = false
        scheduleConnectionAfterLifecycle()
    }

    func setSuspended(_ suspended: Bool) {
        guard !isStopped, isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            if !isSleeping { releaseSession() }
        } else {
            scheduleConnectionAfterLifecycle()
        }
    }

    func stop() async {
        guard !isStopped else {
            if let lifecycleTask { await lifecycleTask.value }
            return
        }
        isStopped = true
        isSleeping = true
        connectionRequested = false
        releaseSession()
        if let lifecycleTask { await lifecycleTask.value }
        eventTask?.cancel()
        eventTask = nil
        sessionEpoch &+= 1
    }

    private func startConnection() {
        guard !isStopped, !isSleeping, !isSuspended,
              connectionRequested, !isConnected, !isBusy,
              let target = session else { return }
        observeEvents(from: target)

        nextOperationID &+= 1
        let operationID = nextOperationID
        let revision = operationRevision
        activeOperationID = operationID
        status = .connecting
        errorMessage = nil
        reportStatus("Connecting to Lofree Flow Lite84.")
        operationTask = Task { @MainActor [weak self] in
            do {
                try await target.connect()
            } catch let failure as FlowLite84Failure {
                guard let self, self.operationRevision == revision else {
                    self?.finishOperation(operationID)
                    return
                }
                self.status = .failed(failure)
                self.fail(failure.userMessage)
            } catch {
                guard let self, self.operationRevision == revision else {
                    self?.finishOperation(operationID)
                    return
                }
                self.status = .disconnected
                self.fail("The Flow Lite84 receiver could not be connected.")
            }
            self?.finishOperation(operationID)
        }
    }

    private func observeEvents(from session: any FlowLite84SessionProtocol) {
        guard eventTask == nil else { return }
        let expectedEpoch = sessionEpoch
        eventTask = Task { @MainActor [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled, self.sessionEpoch == expectedEpoch else { return }
                self.receive(event)
            }
            guard let self, self.sessionEpoch == expectedEpoch else { return }
            self.eventTask = nil
        }
    }

    private func receive(_ event: FlowLite84Event) {
        switch event {
        case .status(let next, let eventGeneration):
            guard eventGeneration >= generation else { return }
            generation = eventGeneration
            if case .connected = next,
               (!connectionRequested || isSleeping || isSuspended || isStopped) { return }
            if case .connecting = next,
               (!connectionRequested || isSleeping || isSuspended || isStopped) { return }
            if case .disconnected = next, case .disconnecting = status { return }
            if case .failed = next,
               (!connectionRequested || isSleeping || isSuspended || isStopped) { return }

            status = next
            switch next {
            case .connected:
                errorMessage = nil
                startObservingKeyboardActivity()
                reportStatus("Connected to Lofree Flow Lite84.")
            case .connecting:
                stopObservingKeyboardActivity()
                reportStatus("Connecting to Lofree Flow Lite84.")
            case .disconnecting:
                stopObservingKeyboardActivity()
                reportStatus("Disconnecting from Lofree Flow Lite84.")
            case .disconnected:
                stopObservingKeyboardActivity()
                if isRefreshing { operationRevision &+= 1 }
                isRefreshing = false
                reportStatus("Disconnected from Lofree Flow Lite84.")
            case .failed(let failure):
                stopObservingKeyboardActivity()
                if activeOperationID != nil { operationRevision &+= 1 }
                isRefreshing = false
                fail(failure.userMessage)
            }
        case .snapshot(let next, let eventGeneration):
            guard eventGeneration >= generation else { return }
            generation = eventGeneration
            guard connectionRequested, isConnected,
                  !isSleeping, !isSuspended, !isStopped else { return }
            snapshot = next
            latestSuccessfulSnapshotAt = monotonicNow()
        }
    }

    private func releaseSession() {
        stopObservingKeyboardActivity()
        guard let session else {
            status = .disconnected
            isRefreshing = false
            return
        }
        guard !isReleasingSession else { return }

        isReleasingSession = true
        operationRevision &+= 1
        isRefreshing = false
        let pendingOperation = operationTask
        pendingOperation?.cancel()
        status = .disconnecting
        reportStatus("Disconnecting from Lofree Flow Lite84.")
        let previousLifecycle = lifecycleTask
        let expectedSessionEpoch = sessionEpoch
        lifecycleTask = Task { @MainActor [weak self] in
            if let previousLifecycle { await previousLifecycle.value }
            if let pendingOperation { await pendingOperation.value }
            await session.disconnect()
            guard let self, self.sessionEpoch == expectedSessionEpoch else { return }
            self.isReleasingSession = false
            self.status = .disconnected
            self.isRefreshing = false
            self.reportStatus("Disconnected from Lofree Flow Lite84.")
        }
    }

    private func scheduleConnectionAfterLifecycle() {
        guard !isStopped, connectionRequested, !isSleeping, !isSuspended else { return }
        let previousLifecycle = lifecycleTask
        let expectedSessionEpoch = sessionEpoch
        lifecycleTask = Task { @MainActor [weak self] in
            if let previousLifecycle { await previousLifecycle.value }
            guard let self, self.sessionEpoch == expectedSessionEpoch,
                  !self.isStopped, self.connectionRequested,
                  !self.isSleeping, !self.isSuspended else { return }
            self.startConnection()
        }
    }

    private func finishOperation(_ operationID: UInt64) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        operationTask = nil
        isRefreshing = false
    }

    private func startObservingKeyboardActivity() {
        guard !isMonitoringKeyboardActivity, connectionRequested,
              isConnected, !isSleeping, !isSuspended, !isStopped else { return }
        isMonitoringKeyboardActivity = true
        keyboardActivityMonitor.start { [weak self] in
            self?.keyboardActivityDetected()
        }
    }

    private func stopObservingKeyboardActivity() {
        guard isMonitoringKeyboardActivity else { return }
        isMonitoringKeyboardActivity = false
        keyboardActivityMonitor.stop()
    }

    private func keyboardActivityDetected() {
        guard !isStopped, !isSleeping, !isSuspended,
              connectionRequested, isConnected, !isBusy,
              session != nil else { return }

        let now = monotonicNow()
        let interval = Duration.seconds(3_600)
        if let latestSuccessfulSnapshotAt,
           now - latestSuccessfulSnapshotAt < interval { return }
        if let latestAutomaticBatteryRefreshAttemptAt,
           now - latestAutomaticBatteryRefreshAttemptAt < interval { return }

        latestAutomaticBatteryRefreshAttemptAt = now
        beginRefresh(batteryOnly: true)
    }

    private func fail(_ message: String) {
        errorMessage = message
        onDiagnostic?(DiagnosticEvent(code: .flowLiteFailure, message: message, isError: true))
    }

    private func reportStatus(_ message: String) {
        onDiagnostic?(DiagnosticEvent(code: .flowLiteStatus, message: message))
    }
}
