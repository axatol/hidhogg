import Combine
import Darwin
import Foundation
import HidhoggCore

enum HidhoggSimulationDiagnosticEvent: String, Sendable {
    case applicationLaunchBegan = "app.launch.begin"
    case applicationStartQueued = "app.launch.start-queued"
    case applicationQuitBegan = "app.quit.begin"
    case applicationQuitTaskStarted = "app.quit.delegate-task.begin"
    case modelQuitEntered = "app.quit.model.begin"
    case modelQuitTaskStarted = "app.quit.model-task.begin"
    case applicationQuitCompleted = "app.quit.cleanup-closed"
    case applicationQuitUncertain = "app.quit.cleanup-uncertain"
    case observationTaskWaitBegan = "app.quit.observation-wait.begin"
    case observationTaskWaitCompleted = "app.quit.observation-wait.complete"
    case profileCoordinatorShutdownBegan = "app.quit.profile-shutdown.begin"
    case profileCoordinatorShutdownCompleted = "app.quit.profile-shutdown.complete"
    case displayPowerShutdownBegan = "app.quit.display-power-shutdown.begin"
    case displayPowerShutdownCompleted = "app.quit.display-power-shutdown.complete"
    case launchControlStarted = "simulation.control.started"
    case readinessTransitionWaitBegan = "simulation.transition-wait.begin"
    case readinessTransitionWaitCompleted = "simulation.transition-wait.complete"
    case readinessRuntimeUnavailable = "simulation.runtime-unavailable"
    case readyMarkerPublished = "simulation.ready-marker.published"
    case readinessFailed = "simulation.readiness.failed"
    case stopMarkerDetected = "simulation.stop-marker.detected"
    case readinessTimedOut = "simulation.readiness.timed-out"
    case runtimeSessionStartBegan = "runtime.session-start.begin"
    case runtimeSessionReady = "runtime.session-start.ready"
    case runtimeSessionStartFailed = "runtime.session-start.failed"
    case runtimeGenerationStartBegan = "runtime.generation-start.begin"
    case runtimeCoordinatorStarted = "runtime.coordinator.started"
    case runtimeIPCServerStartBegan = "runtime.ipc-server-start.begin"
    case runtimeIPCServerStarted = "runtime.ipc-server-start.complete"
    case runtimeInitialHealthCheckBegan = "runtime.initial-health-check.begin"
    case runtimeInitialHealthCheckReady = "runtime.initial-health-check.ready"
    case runtimeInitialHealthCheckRejected = "runtime.initial-health-check.rejected"
    case runtimeInitialHealthCheckFailed = "runtime.initial-health-check.failed"
    case runtimeGenerationStopBegan = "runtime.generation-stop.begin"
    case runtimeGenerationStopClosed = "runtime.generation-stop.closed"
    case runtimeGenerationStopUncertain = "runtime.generation-stop.uncertain"
}

struct HidhoggSimulationDiagnostics: Sendable {
    private let output: @Sendable (HidhoggSimulationDiagnosticEvent) -> Void

    init(
        output: @escaping @Sendable (HidhoggSimulationDiagnosticEvent) -> Void =
            HidhoggSimulationDiagnostics.writeToStandardError
    ) {
        self.output = output
    }

    func emit(_ event: HidhoggSimulationDiagnosticEvent) {
        output(event)
    }

    private static func writeToStandardError(_ event: HidhoggSimulationDiagnosticEvent) {
        let line = "hidhogg-simulation stage=\(event.rawValue)\n"
        line.withCString { pointer in
            _ = Darwin.write(STDERR_FILENO, pointer, line.utf8.count)
        }
    }
}

@MainActor
public final class RuntimeSessionController: ObservableObject {
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
    @Published private(set) var operationsHandle: RuntimeOperationsHandle?
    @Published private(set) var cliConnectivityError: String?

    public var configurationPath: String? {
        AppPreferences.validConfigurationPath(requestedConfigurationPath)
    }

    public var canStartManually: Bool {
        !hasQuit
            && !manualStartPending
            && configurationPath != nil
            && retirementFailureState == nil
            && isFailed(lifecycleState)
    }

    let backendSelection: RuntimeBackendSelection
    let simulationDiagnostics: HidhoggSimulationDiagnostics?

    var usesSimulatedBackend: Bool {
        if case .simulated = backendSelection { return true }
        return false
    }

    private let generationFactory: RuntimeGenerationFactory
    private let configurationWatcherFactory: RuntimeConfigurationWatcherFactory
    private let snapshotPollNanoseconds: UInt64
    private var requestedConfigurationPath: String?
    private var transitionTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var activeGeneration: (any RuntimeSessionGeneration)?
    private var configurationWatcher: (any RuntimeConfigurationWatching)?
    private var activePath: String?
    private var activeGenerationToken: UUID?
    private var activeObservationTask: Task<Void, Never>?
    private var retirementFailureState: LifecycleState?
    private var manualStartPending = false
    private var hasQuit = false

    private enum TransitionAction: Equatable {
        case reconcile
        case manualStart
    }

    public convenience init(
        backendSelection: RuntimeBackendSelection = .native,
        runtimeDirectoryFactory: any GenerationDirectoryCreating = DefaultGenerationDirectoryFactory(),
        snapshotPollNanoseconds: UInt64 = 100_000_000
    ) {
        self.init(
            backendSelection: backendSelection,
            runtimeDirectoryFactory: runtimeDirectoryFactory,
            snapshotPollNanoseconds: snapshotPollNanoseconds,
            simulationDiagnostics: nil
        )
    }

    convenience init(
        backendSelection: RuntimeBackendSelection,
        runtimeDirectoryFactory: any GenerationDirectoryCreating,
        snapshotPollNanoseconds: UInt64 = 100_000_000,
        simulationDiagnostics: HidhoggSimulationDiagnostics?
    ) {
        self.init(
            backendSelection: backendSelection,
            generationFactory: { path, selection in
                CoreRuntimeGeneration(
                    configurationPath: path,
                    backendSelection: selection,
                    runtimeDirectoryFactory: runtimeDirectoryFactory,
                    simulationDiagnostics: simulationDiagnostics
                )
            },
            configurationWatcherFactory: { path, onChange in
                ConfigurationFileWatcher(path: path, onChange: onChange)
            },
            snapshotPollNanoseconds: snapshotPollNanoseconds,
            simulationDiagnostics: simulationDiagnostics
        )
    }

    init(
        backendSelection: RuntimeBackendSelection,
        generationFactory: @escaping RuntimeGenerationFactory,
        configurationWatcherFactory: @escaping RuntimeConfigurationWatcherFactory,
        snapshotPollNanoseconds: UInt64 = 100_000_000,
        simulationDiagnostics: HidhoggSimulationDiagnostics? = nil
    ) {
        self.backendSelection = backendSelection
        self.simulationDiagnostics = simulationDiagnostics
        self.generationFactory = generationFactory
        self.configurationWatcherFactory = configurationWatcherFactory
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
        if let quitTask {
            await quitTask.value
            return
        }
        hasQuit = true
        let pendingTransition = transitionTask
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await pendingTransition?.value
            let stopped = await self.stopActiveSession()
            self.endpoint = nil
            self.lifecycleState = stopped ? .stopped : (self.retirementFailureState ?? .failed(.internalFailure))
        }
        quitTask = task
        await task.value
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
        if activePath == validPath, activeGeneration != nil {
            return
        }

        guard await stopActiveSession(), !hasQuit else { return }
        guard let validPath else {
            lifecycleState = .configurationRequired
            endpoint = nil
            return
        }

        await startSession(configurationPath: validPath)
    }

    private func startManuallyAfterFailure() async {
        guard !hasQuit, canStartManually else { return }
        guard await stopActiveSession(), !hasQuit else { return }
        guard let validPath = AppPreferences.validConfigurationPath(requestedConfigurationPath) else {
            lifecycleState = .configurationRequired
            endpoint = nil
            return
        }

        await startSession(configurationPath: validPath)
    }

    private func startSession(configurationPath validPath: String) async {
        lastFailureDetail = nil
        lifecycleState = .starting

        let generation: any RuntimeSessionGeneration
        do {
            generation = try generationFactory(validPath, backendSelection)
        } catch {
            await recordStartFailure(error, generation: nil)
            return
        }

        let token = UUID()
        activeGeneration = generation
        activePath = validPath
        activeGenerationToken = token
        endpoint = nil
        operationsHandle = nil
        cliConnectivityError = nil

        do {
            simulationDiagnostics?.emit(.runtimeSessionStartBegan)
            let readyGeneration = try await generation.start()
            let watcher = try configurationWatcherFactory(validPath) { [weak self, generation] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeGenerationToken == token,
                          !self.hasQuit else {
                        return
                    }
                    await generation.reloadConfiguration()
                }
            }
            try watcher.start()
            configurationWatcher = watcher
            await generation.reloadConfiguration()
            guard await generation.isRunning() else {
                throw RuntimeSessionControllerError.runtimeNotReady
            }

            operationsHandle = readyGeneration.operationsHandle
            endpoint = readyGeneration.endpoint
            cliConnectivityError = readyGeneration.cliConnectivityError
            lifecycleState = .ready
            simulationDiagnostics?.emit(.runtimeSessionReady)
            activeObservationTask = Task { @MainActor [weak self, generation] in
                await self?.observe(generation: generation, token: token)
            }
        } catch {
            simulationDiagnostics?.emit(.runtimeSessionStartFailed)
            await recordStartFailure(error, generation: generation)
        }
    }

    private func observe(generation: any RuntimeSessionGeneration, token: UUID) async {
        while !Task.isCancelled {
            guard activeGenerationToken == token,
                  activeGeneration != nil else {
                return
            }
            if !(await generation.isRunning()) {
                guard !hasQuit else { return }
                _ = await stopActiveSession()
                guard !hasQuit else { return }
                lifecycleState = retirementFailureState ?? .failed(.restartExhausted)
                endpoint = nil
                return
            }
            do {
                try await Task.sleep(nanoseconds: snapshotPollNanoseconds)
            } catch {
                return
            }
        }
    }

    private func recordStartFailure(
        _ error: Error,
        generation: (any RuntimeSessionGeneration)?
    ) async {
        lastFailureDetail = String(describing: error)
        if let generation {
            activeGeneration = generation
            activeGenerationToken = UUID()
            let retired = await stopActiveSession()
            if !retired {
                lifecycleState = retirementFailureState ?? .failed(.internalFailure)
                return
            }
        }
        activeGeneration = nil
        activeGenerationToken = nil
        activePath = nil
        endpoint = nil
        operationsHandle = nil
        cliConnectivityError = nil
        lifecycleState = .failed(.restartExhausted)
    }

    @discardableResult
    private func stopActiveSession() async -> Bool {
        activeObservationTask?.cancel()
        activeObservationTask = nil
        activeGenerationToken = nil
        configurationWatcher?.stop()
        configurationWatcher = nil
        endpoint = nil
        operationsHandle = nil
        cliConnectivityError = nil

        guard let generation = activeGeneration else {
            activePath = nil
            guard let retirementFailureState else { return true }
            lifecycleState = retirementFailureState
            return false
        }

        lifecycleState = .stopping
        simulationDiagnostics?.emit(.runtimeGenerationStopBegan)
        let outcome = await generation.stop()
        guard outcome == .closed else {
            simulationDiagnostics?.emit(.runtimeGenerationStopUncertain)
            let failure = LifecycleState.failed(.cleanup("Core runtime or IPC cleanup is uncertain"))
            retirementFailureState = failure
            lifecycleState = failure
            return false
        }

        activeGeneration = nil
        activePath = nil
        endpoint = nil
        simulationDiagnostics?.emit(.runtimeGenerationStopClosed)
        return true
    }

    private func isFailed(_ state: LifecycleState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

enum RuntimeSessionControllerError: Error {
    case runtimeNotReady
}

protocol RuntimeSessionGeneration: Sendable {
    func start() async throws -> RuntimeGenerationStart
    func isRunning() async -> Bool
    func reloadConfiguration() async
    func stop() async -> RuntimeGenerationStopOutcome
}

public protocol HidhoggProfileOperations: Sendable {
    func profiles() async throws -> [RuntimeOperationProfile]
    func activateProfile(_ profileID: String) async throws -> RuntimeActivationResult
}

public protocol HidhoggDisplayOperations: Sendable {
    func setHostDisplayAwake(_ awake: Bool) async throws -> RuntimeOperationDisplayResult
}

public protocol HidhoggEditorOperations: Sendable {
    func editorSnapshot() async throws -> RuntimeOperationEditorSnapshot
    func editorProfile(sourceDigest: String, profileID: String) async throws -> RuntimeOperationEditorProfile
    func editorPositions(sourceDigest: String, profileID: String) async throws -> RuntimeOperationEditorPositions
    func editorPosition(
        sourceDigest: String,
        profileID: String,
        positionID: String
    ) async throws -> RuntimeOperationEditorPosition
    func edit(expectedDigest: String, edit: RuntimeConfigurationEdit) async throws -> RuntimeOperationEditResult
    func cloneProfile(
        expectedDigest: String,
        sourceProfileID: String?,
        profileID: String,
        label: String
    ) async throws -> RuntimeOperationEditResult
}

public protocol HidhoggAppRuntimeOperations: HidhoggProfileOperations, HidhoggDisplayOperations, HidhoggEditorOperations {
    func reloadConfiguration() async throws -> RuntimeOperationReloadResult
    func configurationStatus() async throws -> RuntimeOperationConfigurationStatus
    func retire() async
}

extension RuntimeOperations: HidhoggAppRuntimeOperations {}

struct RuntimeOperationsHandle: Sendable {
    let identity: String
    let operations: any HidhoggAppRuntimeOperations
}

struct RuntimeGenerationStart: Sendable {
    let operationsHandle: RuntimeOperationsHandle
    let endpoint: RuntimeSessionController.RuntimeEndpoint?
    let cliConnectivityError: String?
}

enum RuntimeGenerationStopOutcome: Sendable, Equatable {
    case closed
    case cleanupUncertain
}

typealias RuntimeGenerationFactory = @Sendable (String, RuntimeBackendSelection) throws -> any RuntimeSessionGeneration
typealias RuntimeConfigurationWatcherFactory = @Sendable (
    String,
    @escaping @Sendable () -> Void
) throws -> any RuntimeConfigurationWatching

protocol RuntimeConfigurationWatching: AnyObject {
    func start() throws
    func stop()
}

private actor CoreRuntimeGeneration: RuntimeSessionGeneration {
    private let configurationPath: String
    private let backendSelection: RuntimeBackendSelection
    private let runtimeDirectoryFactory: any GenerationDirectoryCreating
    private let simulationDiagnostics: HidhoggSimulationDiagnostics?
    private var coordinator: RuntimeCoordinator?
    private var operations: RuntimeOperations?
    private var serviceBinding: IPCServiceBinding?
    private var server: IPCServer?
    private var generationDirectory: GenerationDirectory?
    private var stopTask: Task<RuntimeGenerationStopOutcome, Never>?

    init(
        configurationPath: String,
        backendSelection: RuntimeBackendSelection,
        runtimeDirectoryFactory: any GenerationDirectoryCreating,
        simulationDiagnostics: HidhoggSimulationDiagnostics?
    ) {
        self.configurationPath = configurationPath
        self.backendSelection = backendSelection
        self.runtimeDirectoryFactory = runtimeDirectoryFactory
        self.simulationDiagnostics = simulationDiagnostics
    }

    func start() async throws -> RuntimeGenerationStart {
        simulationDiagnostics?.emit(.runtimeGenerationStartBegan)
        let source = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
        let configuration = try HidhoggConfigurationDecoder.decode(source)
        let coordinator = try RuntimeCoordinator(configuration: configuration, selection: backendSelection)
        self.coordinator = coordinator
        let operations = try RuntimeOperations(coordinator: coordinator, configurationPath: configurationPath)
        self.operations = operations
        try await coordinator.start()
        simulationDiagnostics?.emit(.runtimeCoordinatorStarted)

        let instanceID = UUID().uuidString.lowercased()
        let operationsHandle = RuntimeOperationsHandle(identity: instanceID, operations: operations)
        do {
            let endpoint = try await startCLIEndpoint(instanceID: instanceID)
            return RuntimeGenerationStart(
                operationsHandle: operationsHandle,
                endpoint: endpoint,
                cliConnectivityError: nil
            )
        } catch {
            if Task.isCancelled { throw error }
            let cleanupConfirmed = await cleanupFailedCLIStart()
            return RuntimeGenerationStart(
                operationsHandle: operationsHandle,
                endpoint: nil,
                cliConnectivityError: cleanupConfirmed
                    ? "The command-line service could not be started."
                    : "The command-line service could not be started, and cleanup is uncertain."
            )
        }
    }

    private func startCLIEndpoint(instanceID: String) async throws -> RuntimeSessionController.RuntimeEndpoint {
        let generationDirectory = try runtimeDirectoryFactory.create(instanceID: instanceID)
        self.generationDirectory = generationDirectory
        guard let operations else { throw RuntimeSessionControllerError.runtimeNotReady }
        let binding = IPCServiceBinding(operations: operations)
        serviceBinding = binding
        simulationDiagnostics?.emit(.runtimeIPCServerStartBegan)
        let server = try await binding.startServer(
            runtimeDirectory: generationDirectory.directory.path,
            instanceID: instanceID
        )
        self.server = server
        simulationDiagnostics?.emit(.runtimeIPCServerStarted)

        let endpoint = RuntimeSessionController.RuntimeEndpoint(
            instanceID: instanceID,
            socketPath: generationDirectory.socket.path
        )
        simulationDiagnostics?.emit(.runtimeInitialHealthCheckBegan)
        let resolvedRuntime = try IPCRuntimeDiscovery.resolve(generationDirectory.directory.path)
        guard resolvedRuntime.metadata.instanceID == instanceID else {
            simulationDiagnostics?.emit(.runtimeInitialHealthCheckRejected)
            throw RuntimeSessionControllerError.runtimeNotReady
        }
        let health: IPCWireResponse
        do {
            health = try await IPCClient(runtime: resolvedRuntime).call(.health)
        } catch {
            simulationDiagnostics?.emit(.runtimeInitialHealthCheckFailed)
            throw error
        }
        guard health.failure == nil,
              health.result?.value(for: "state")?.stringValue == "ready" else {
            simulationDiagnostics?.emit(.runtimeInitialHealthCheckRejected)
            throw RuntimeSessionControllerError.runtimeNotReady
        }
        simulationDiagnostics?.emit(.runtimeInitialHealthCheckReady)
        return endpoint
    }

    private func cleanupFailedCLIStart() async -> Bool {
        let serverOutcome = await server?.stop() ?? IPCServerStopOutcome.closed
        guard serverOutcome == .closed,
              removeRuntimeGeneration() else {
            return false
        }
        server = nil
        serviceBinding = nil
        generationDirectory = nil
        return true
    }

    func isRunning() async -> Bool {
        guard let coordinator else { return false }
        let snapshot = await coordinator.snapshot()
        return snapshot.lifecycle == .running && !snapshot.cleanupUncertain
    }

    func reloadConfiguration() async {
        guard let operations else { return }
        _ = try? await operations.reloadConfiguration()
    }

    func stop() async -> RuntimeGenerationStopOutcome {
        if let stopTask {
            return await stopTask.value
        }
        let task = Task { await self.stopCore() }
        stopTask = task
        return await task.value
    }

    private func stopCore() async -> RuntimeGenerationStopOutcome {
        await operations?.retire()
        let serverOutcome = await server?.stop() ?? IPCServerStopOutcome.closed
        let runtimeOutcome = await coordinator?.stop() ?? RuntimeStopOutcome.closed
        let directoryClean = serverOutcome == .closed && removeRuntimeGeneration()
        let outcome: RuntimeGenerationStopOutcome =
            serverOutcome == .closed && runtimeOutcome == .closed && directoryClean
                ? .closed
                : .cleanupUncertain
        if outcome == .closed {
            server = nil
            serviceBinding = nil
            operations = nil
            coordinator = nil
            generationDirectory = nil
        }
        return outcome
    }

    private func removeRuntimeGeneration() -> Bool {
        guard let generationDirectory else { return true }
        do {
            switch try PathSecurity.removeMatchingGeneration(
                directory: generationDirectory.directory,
                directoryIdentity: generationDirectory.directoryIdentity,
                socket: generationDirectory.socket,
                socketIdentity: nil
            ) {
            case .removed, .alreadyAbsent:
                return true
            case .refused:
                return false
            }
        } catch {
            return false
        }
    }
}

final class ConfigurationFileWatcher: RuntimeConfigurationWatching, @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.hidhogg.configuration-watcher")
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingChange: DispatchWorkItem?
    private var watchedFileIdentity: FileIdentity?
    private var stopped = false

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() throws {
        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let descriptor = parentPath.withCString { Darwin.open($0, O_EVTONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw ConfigurationFileWatcherError.parentUnavailable(errno) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { _ = Darwin.close(descriptor) }
        directorySource = source
        source.resume()

        do {
            try queue.sync { try installFileSource() }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.pendingChange?.cancel()
            self.pendingChange = nil
            self.fileSource?.cancel()
            self.fileSource = nil
            self.watchedFileIdentity = nil
            self.directorySource?.cancel()
            self.directorySource = nil
        }
    }

    private func directoryChanged() {
        guard !stopped else { return }
        let previousIdentity = watchedFileIdentity
        do {
            try installFileSource()
        } catch {
            watchedFileIdentity = nil
        }
        guard previousIdentity != watchedFileIdentity else { return }
        scheduleChange()
    }

    private func fileChanged() {
        guard !stopped else { return }
        scheduleChange()
    }

    private func installFileSource() throws {
        fileSource?.cancel()
        fileSource = nil
        let descriptor = path.withCString { Darwin.open($0, O_EVTONLY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw ConfigurationFileWatcherError.configurationUnavailable(errno)
        }
        var fileStat = stat()
        guard fstat(descriptor, &fileStat) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            throw ConfigurationFileWatcherError.configurationUnavailable(error)
        }
        watchedFileIdentity = FileIdentity(device: UInt64(fileStat.st_dev), inode: UInt64(fileStat.st_ino))
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.fileChanged() }
        source.setCancelHandler { _ = Darwin.close(descriptor) }
        fileSource = source
        source.resume()
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.onChange()
        }
        pendingChange = work
        queue.asyncAfter(deadline: .now() + .milliseconds(75), execute: work)
    }
}

enum ConfigurationFileWatcherError: Error {
    case parentUnavailable(Int32)
    case configurationUnavailable(Int32)
}
