import Combine
import Foundation

@MainActor
public final class RuntimeSessionController: ObservableObject {
    public typealias SupervisorFactory = @Sendable (ProcessSupervisorConfiguration) -> ProcessSupervisor

    public struct RuntimeEndpoint: Equatable, Sendable {
        public let instanceID: String
        public let socketPath: String

        public init(instanceID: String, socketPath: String) {
            self.instanceID = instanceID
            self.socketPath = socketPath
        }
    }

    @Published public private(set) var lifecycleState: LifecycleState = .configurationRequired
    @Published public private(set) var endpoint: RuntimeEndpoint?
    @Published public private(set) var lastFailureDetail: String?

    public var configurationPath: String? {
        AppPreferences.validConfigurationPath(requestedConfigurationPath)
    }

    public var canStartManually: Bool {
        !hasQuit
            && !manualStartPending
            && activeSupervisor != nil
            && configurationPath != nil
            && lifecycleState == .failed(.restartExhausted)
    }

    private let executablePath: String
    private let supervisorFactory: SupervisorFactory
    private let snapshotPollNanoseconds: UInt64
    private var requestedConfigurationPath: String?
    private var transitionTask: Task<Void, Never>?
    private var activeSupervisor: ProcessSupervisor?
    private var activeRunTask: Task<Void, Never>?
    private var activeObservationTask: Task<Void, Never>?
    private var activePath: String?
    private var activeGenerationToken: UUID?
    private var retirementFailureState: LifecycleState?
    private var manualStartPending = false
    private var hasQuit = false

    private enum TransitionAction: Equatable {
        case reconcile
        case manualStart
    }

    public init(
        executablePath: String,
        supervisorFactory: @escaping SupervisorFactory = { configuration in
            ProcessSupervisor(configuration: configuration)
        },
        snapshotPollNanoseconds: UInt64 = 100_000_000
    ) {
        self.executablePath = executablePath
        self.supervisorFactory = supervisorFactory
        self.snapshotPollNanoseconds = max(1, snapshotPollNanoseconds)
    }

    public func setConfigurationPath(_ path: String?) {
        guard !hasQuit else { return }
        requestedConfigurationPath = path
        enqueueTransition()
    }

    public func start(configurationPath path: String?) {
        setConfigurationPath(path)
    }

    public func requestManualStart() {
        guard canStartManually else { return }
        manualStartPending = true
        enqueueTransition(.manualStart)
    }

    public func waitForTransition() async {
        await transitionTask?.value
    }

    public func quit() async {
        guard !hasQuit else {
            await transitionTask?.value
            return
        }
        hasQuit = true
        let pendingTransition = transitionTask
        await pendingTransition?.value
        _ = await stopActiveSession()
        transitionTask = nil
        lifecycleState = .stopped
        endpoint = nil
    }

    private func enqueueTransition(_ action: TransitionAction = .reconcile) {
        let previous = transitionTask
        transitionTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if action == .manualStart {
                    self.manualStartPending = false
                }
            }
            guard !self.hasQuit else { return }
            switch action {
            case .reconcile:
                await self.reconcileSession()
            case .manualStart:
                await self.startManuallyAfterFailure()
            }
        }
    }

    private func reconcileSession() async {
        let validPath = AppPreferences.validConfigurationPath(requestedConfigurationPath)
        if activePath == validPath, activeSupervisor != nil {
            return
        }

        let retired = await stopActiveSession()
        guard !hasQuit, retired else { return }
        guard let validPath else {
            lifecycleState = .configurationRequired
            endpoint = nil
            return
        }

        startSession(configurationPath: validPath)
    }

    private func startManuallyAfterFailure() async {
        guard !hasQuit,
              lifecycleState == .failed(.restartExhausted),
              activeSupervisor != nil else {
            return
        }

        let retired = await stopActiveSession()
        guard !hasQuit, retired else { return }
        guard let validPath = AppPreferences.validConfigurationPath(requestedConfigurationPath) else {
            lifecycleState = .configurationRequired
            endpoint = nil
            return
        }

        startSession(configurationPath: validPath)
    }

    private func startSession(configurationPath validPath: String) {
        lastFailureDetail = nil
        let supervisor = supervisorFactory(
            ProcessSupervisorConfiguration(
                executablePath: executablePath,
                configurationPath: validPath
            )
        )
        let runTask = Task { await supervisor.run() }
        let token = UUID()
        activeSupervisor = supervisor
        activeRunTask = runTask
        activePath = validPath
        activeGenerationToken = token
        lifecycleState = .starting
        endpoint = nil
        activeObservationTask = Task { @MainActor [weak self, weak supervisor] in
            guard let supervisor else { return }
            await self?.observe(supervisor: supervisor, token: token)
        }
    }

    private func observe(supervisor: ProcessSupervisor, token: UUID) async {
        while !Task.isCancelled {
            let snapshot = await supervisor.snapshot()
            guard !Task.isCancelled,
                  activeGenerationToken == token,
                  activeSupervisor === supervisor else {
                return
            }
            apply(snapshot: snapshot)
            if case .stopped = snapshot.state {
                return
            }
            do {
                try await Task.sleep(nanoseconds: snapshotPollNanoseconds)
            } catch {
                return
            }
        }
    }

    private func apply(snapshot: SupervisorSnapshot) {
        lifecycleState = snapshot.state
        lastFailureDetail = snapshot.lastFailureDetail
        guard snapshot.state == .ready,
              let instanceID = snapshot.instanceID,
              let socketPath = snapshot.socketPath else {
            endpoint = nil
            return
        }
        endpoint = RuntimeEndpoint(instanceID: instanceID, socketPath: socketPath)
    }

    private func stopActiveSession() async -> Bool {
        activeObservationTask?.cancel()
        activeObservationTask = nil
        activeGenerationToken = nil

        guard let supervisor = activeSupervisor else {
            activeRunTask = nil
            activePath = nil
            endpoint = nil
            guard let retirementFailureState else { return true }
            lifecycleState = retirementFailureState
            return false
        }
        lifecycleState = .stopping
        endpoint = nil
        await supervisor.quit()
        await activeRunTask?.value
        let finalState = await supervisor.snapshot().state
        let stopped = finalState == .stopped
        if !stopped {
            lifecycleState = finalState
            retirementFailureState = finalState
        }
        activeSupervisor = nil
        activeRunTask = nil
        activePath = nil
        endpoint = nil
        return stopped
    }
}
