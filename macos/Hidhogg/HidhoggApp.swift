import AppKit
import Darwin
import SwiftUI
import HidhoggCore

@main
struct HidhoggApp: App {
    @NSApplicationDelegateAdaptor(HidhoggApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        MenuBarExtra("Hidhogg", systemImage: "shield") {
            HidhoggMenu(model: applicationDelegate.model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: applicationDelegate.model)
        }
    }
}

@MainActor
private struct HidhoggMenu: View {
    @ObservedObject var model: HidhoggAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.lifecycleText)
                .font(.headline)
            Text(model.healthText)
                .foregroundStyle(.secondary)
            if model.canStartRuntime {
                Button("Start Runtime") {
                    model.startRuntime()
                }
            }
            if let displayPowerErrorText = model.displayPowerErrorText {
                Text(displayPowerErrorText)
                    .foregroundStyle(.orange)
            }
            Text(model.profileStatusText)
                .foregroundStyle(.secondary)
            if model.canRetryProfileSwitch {
                Button("Retry Profile Switch") {
                    model.retryProfileSwitch()
                }
            }
            SettingsLink {
                Text("Settings…")
            }
            if model.allowsConfigurationSelection {
                Button("Choose Configuration…") {
                    model.chooseConfiguration()
                }
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }
}

@MainActor
final class HidhoggApplicationDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationState {
        case acceptingRequests
        case cleaningUp
        case readyToTerminate
    }

    let model: HidhoggAppModel
    private var simulationLaunchControl: HidhoggSimulationLaunchControl?
    private var simulationDiagnostics: HidhoggSimulationDiagnostics?
    private var terminationTask: Task<Void, Never>?
    private var terminationState = TerminationState.acceptingRequests
    private let requestTermination: @MainActor (NSApplication) -> Void

    override init() {
        self.requestTermination = { application in application.terminate(nil) }
#if HIDHOGG_TEST_HOST
        self.model = HidhoggAppModel.testHost()
        self.simulationLaunchControl = nil
#else
        switch HidhoggSimulationArguments.parse(CommandLine.arguments) {
        case .production:
            self.model = HidhoggAppModel()
            self.simulationLaunchControl = nil
        case .simulated(let configurationPath, let runtimeRoot):
            self.model = HidhoggAppModel.simulated(
                configurationPath: configurationPath,
                runtimeRoot: runtimeRoot
            )
            self.simulationLaunchControl = nil
        case .simulatedControlled(
            let configurationPath,
            let runtimeRoot,
            let readyMarkerPath,
            let stopMarkerPath
        ):
            let diagnostics = HidhoggSimulationDiagnostics()
            let model = HidhoggAppModel.simulated(
                configurationPath: configurationPath,
                runtimeRoot: runtimeRoot,
                diagnostics: diagnostics
            )
            self.model = model
            self.simulationDiagnostics = diagnostics
            self.simulationLaunchControl = HidhoggSimulationLaunchControl(
                readyMarkerPath: readyMarkerPath,
                stopMarkerPath: stopMarkerPath,
                diagnostics: diagnostics,
                readiness: {
                    diagnostics.emit(.readinessTransitionWaitBegan)
                    await model.runtimeSession.waitForTransition()
                    diagnostics.emit(.readinessTransitionWaitCompleted)
                    guard model.runtimeSession.lifecycleState == .ready,
                          let endpoint = model.runtimeSession.endpoint else {
                        diagnostics.emit(.readinessRuntimeUnavailable)
                        return nil
                    }
                    diagnostics.emit(.readinessHealthCheckBegan)
                    do {
                        let client = try UnixSocketClient(
                            socketPath: endpoint.socketPath,
                            instanceID: endpoint.instanceID
                        )
                        let health = try client.health(requestID: UUID().uuidString.lowercased())
                        guard health.instanceID == endpoint.instanceID,
                              health.state == "ready" else {
                            diagnostics.emit(.readinessHealthCheckRejected)
                            return nil
                        }
                        diagnostics.emit(.readinessHealthCheckCompleted)
                        return endpoint
                    } catch {
                        diagnostics.emit(.readinessHealthCheckFailed)
                        return nil
                    }
                }
            )
        case .invalid(let message):
            self.model = HidhoggAppModel.invalidSimulation(message)
            self.simulationLaunchControl = nil
        }
#endif
        super.init()
    }

    init(
        model: HidhoggAppModel,
        simulationDiagnostics: HidhoggSimulationDiagnostics? = nil,
        requestTermination: @escaping @MainActor (NSApplication) -> Void = { application in
            application.terminate(nil)
        }
    ) {
        self.model = model
        self.simulationLaunchControl = nil
        self.simulationDiagnostics = simulationDiagnostics
        self.requestTermination = requestTermination
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !HIDHOGG_TEST_HOST
        simulationDiagnostics?.emit(.applicationLaunchBegan)
        model.start()
        simulationDiagnostics?.emit(.applicationStartQueued)
        simulationLaunchControl?.start()
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationState {
        case .readyToTerminate:
            return .terminateNow
        case .cleaningUp:
            return .terminateCancel
        case .acceptingRequests:
            break
        }

        terminationState = .cleaningUp
        simulationLaunchControl?.cancel()
        simulationDiagnostics?.emit(.applicationQuitBegan)
        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.simulationDiagnostics?.emit(.applicationQuitTaskStarted)
            await self.model.quit()
            self.simulationDiagnostics?.emit(
                self.model.runtimeSession.lifecycleState == .stopped
                    ? .applicationQuitCompleted
                    : .applicationQuitUncertain
            )
            self.terminationState = .readyToTerminate
            self.requestTermination(sender)
            self.terminationTask = nil
        }
        return .terminateCancel
    }
}

@MainActor
final class HidhoggAppModel: ObservableObject {
    @Published private(set) var lifecycleText = LifecycleState.configurationRequired.description
    @Published private(set) var healthText = "Configuration required"
    @Published private(set) var displayPowerErrorText: String?
    @Published private(set) var profileStatusText = "Profile: waiting for runtime"
    @Published private(set) var currentProfileID: String?
    @Published private(set) var currentBundleIdentifier: String?
    @Published private(set) var profileCatalog: ProfileListResponse?
    @Published private(set) var profileState: ProfileSwitchCoordinatorState = .idle
    @Published private(set) var mappings: ProfileMappingPreferences
    @Published private(set) var resolvedConfigurationPath: String?

    let allowsConfigurationSelection: Bool
    let runtimeSession: RuntimeSessionController
    let profileCoordinator: ProfileSwitchCoordinator
    let displayPowerCoordinator: HostDisplayPowerCoordinator
    private let preferencesStore: any AppPreferencesStore
    private let profileMappingStore: any ProfileMappingPreferencesStore
    private let foregroundObserver: any ForegroundApplicationObserving
    private let configurationBootstrapFactory: @Sendable () -> DefaultConfigurationBootstrap
    private var preferences: AppPreferences
    private var configurationBootstrap: DefaultConfigurationBootstrap?
    private var configurationBootstrapErrorText: String?
    private var observationTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var hasQuit = false

    var selectedConfigurationPath: String? {
        preferences.persistedConfigurationPath ?? resolvedConfigurationPath
    }

    var canStartRuntime: Bool {
        !hasQuit
            && configurationBootstrapErrorText == nil
            && runtimeSession.canStartManually
    }

    private var simulationDiagnostics: HidhoggSimulationDiagnostics? {
        runtimeSession.simulationDiagnostics
    }

    init(
        preferencesStore: any AppPreferencesStore = UserDefaultsAppPreferencesStore(),
        runtimeSession: RuntimeSessionController? = nil,
        runtimeBackendSelection: RuntimeBackendSelection = .native,
        runtimeDirectoryFactory: any GenerationDirectoryCreating = DefaultGenerationDirectoryFactory(),
        profileMappingStore: any ProfileMappingPreferencesStore = UserDefaultsProfileMappingPreferencesStore(),
        profileCoordinator: ProfileSwitchCoordinator? = nil,
        displayPowerCoordinator: HostDisplayPowerCoordinator? = nil,
        foregroundObserver: (any ForegroundApplicationObserving)? = nil,
        allowsConfigurationSelection: Bool = true,
        initialConfigurationError: String? = nil,
        configurationBootstrapFactory: @escaping @Sendable () -> DefaultConfigurationBootstrap = {
            let environment = ProcessInfo.processInfo.environment
            let templateURL = Bundle.main.url(forResource: "DefaultConfig", withExtension: "toml")
            let templateData = templateURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
            return DefaultConfigurationBootstrap(
                xdgConfigHome: environment["XDG_CONFIG_HOME"],
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                templateData: templateData
            )
        }
    ) {
        self.preferencesStore = preferencesStore
        self.profileMappingStore = profileMappingStore
        self.configurationBootstrapFactory = configurationBootstrapFactory
        self.preferences = AppPreferences(store: preferencesStore)
        self.allowsConfigurationSelection = allowsConfigurationSelection
        self.configurationBootstrapErrorText = initialConfigurationError
        if let runtimeSession {
            self.runtimeSession = runtimeSession
        } else {
            self.runtimeSession = RuntimeSessionController(
                backendSelection: runtimeBackendSelection,
                runtimeDirectoryFactory: runtimeDirectoryFactory
            )
        }
        let loadedMappings = ProfileMappingPreferences(store: profileMappingStore)
        if let profileCoordinator {
            self.profileCoordinator = profileCoordinator
            self.mappings = profileCoordinator.mappings
        } else {
            self.profileCoordinator = ProfileSwitchCoordinator(mappings: loadedMappings)
            self.mappings = loadedMappings
        }
        self.displayPowerCoordinator = displayPowerCoordinator ?? HostDisplayPowerCoordinator()
        self.foregroundObserver = foregroundObserver ?? ForegroundApplicationObserver()
    }

    func start() {
        guard observationTask == nil, !hasQuit else { return }
        if configurationBootstrapErrorText == nil {
            applyConfigurationPreference(isStartup: true)
        }
        displayPowerCoordinator.start()
        profileCoordinator.startObserving(foregroundObserver)
        observationTask = Task { @MainActor [weak self] in
            await self?.observeRuntime()
        }
    }

    func selectConfigurationPath(_ path: String) {
        guard !hasQuit, allowsConfigurationSelection else { return }
        preferences = preferences.savingConfigurationPath(path, to: preferencesStore)
        applyConfigurationPreference(isStartup: false)
    }

    func clearConfigurationPath() {
        guard !hasQuit, allowsConfigurationSelection else { return }
        preferences = preferences.savingConfigurationPath(nil, to: preferencesStore)
        applyConfigurationPreference(isStartup: false)
    }

    func setMapping(
        profileID: String,
        forBundleIdentifier bundleIdentifier: String
    ) throws {
        let updated = try profileCoordinator.setMapping(
            profileID: profileID,
            forBundleIdentifier: bundleIdentifier
        )
        updated.save(to: profileMappingStore)
        mappings = updated
        publishProfileState()
    }

    func removeMapping(forBundleIdentifier bundleIdentifier: String) {
        let updated = profileCoordinator.removeMapping(forBundleIdentifier: bundleIdentifier)
        updated.save(to: profileMappingStore)
        mappings = updated
        publishProfileState()
    }

    func mappingProfileID(for bundleIdentifier: String) -> String? {
        mappings.profileID(for: bundleIdentifier)
    }

    func retryProfileSwitch() {
        profileCoordinator.retry()
        publishProfileState()
    }

    func startRuntime() {
        guard canStartRuntime else { return }
        runtimeSession.requestManualStart()
    }

    func refreshProfileCatalog() async {
        profileCoordinator.refreshCatalog()
        await profileCoordinator.waitForIdle()
        publishProfileState()
    }

    func chooseConfiguration() {
        guard !hasQuit, allowsConfigurationSelection else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "toml")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectConfigurationPath(url.path)
    }

    func quit() async {
        simulationDiagnostics?.emit(.modelQuitEntered)
        if hasQuit {
            if let quitTask {
                await quitTask.value
            }
            return
        }
        hasQuit = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.simulationDiagnostics?.emit(.modelQuitTaskStarted)
            self.observationTask?.cancel()
            if let observationTask = self.observationTask {
                self.simulationDiagnostics?.emit(.observationTaskWaitBegan)
                await observationTask.value
                self.simulationDiagnostics?.emit(.observationTaskWaitCompleted)
            }
            self.observationTask = nil
            self.simulationDiagnostics?.emit(.profileCoordinatorShutdownBegan)
            await self.profileCoordinator.shutdown()
            self.simulationDiagnostics?.emit(.profileCoordinatorShutdownCompleted)
            self.simulationDiagnostics?.emit(.displayPowerShutdownBegan)
            await self.displayPowerCoordinator.shutdown()
            self.simulationDiagnostics?.emit(.displayPowerShutdownCompleted)
            await self.runtimeSession.quit()
            self.publishRuntimeState()
            self.publishProfileState()
            self.publishDisplayPowerState()
            if self.runtimeSession.lifecycleState == .stopped {
                self.healthText = "Health: stopped"
            }
        }
        quitTask = task
        await task.value
        quitTask = nil
    }

    private func observeRuntime() async {
        var observedEndpoint: RuntimeSessionController.RuntimeEndpoint?
        var hasObservedEndpoint = false
        while !Task.isCancelled {
            let endpoint = runtimeSession.endpoint
            if !hasObservedEndpoint || endpoint != observedEndpoint {
                hasObservedEndpoint = true
                observedEndpoint = endpoint
                await profileCoordinator.setRuntimeEndpoint(endpoint)
                displayPowerCoordinator.setRuntimeEndpoint(endpoint)
            }
            publishRuntimeState()
            publishProfileState()
            publishDisplayPowerState()
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
    }

    private func publishProfileState() {
        profileState = profileCoordinator.state
        profileCatalog = profileCoordinator.catalog
        currentProfileID = profileCoordinator.currentProfileID
        currentBundleIdentifier = profileCoordinator.currentBundleIdentifier
        mappings = profileCoordinator.mappings
        profileStatusText = Self.profileStatusText(
            state: profileState,
            currentProfileID: currentProfileID
        )
    }

    private func publishDisplayPowerState() {
        displayPowerErrorText = displayPowerCoordinator.errorText
    }

    static func profileStatusText(
        state: ProfileSwitchCoordinatorState,
        currentProfileID: String?
    ) -> String {
        switch state {
        case .loadingCatalog:
            return "Profile: loading catalog…"
        case .waitingForRuntime:
            return "Profile: waiting for runtime"
        case .unavailable:
            return "Profile: runtime unavailable"
        case .invalidMapping(_, let profileID):
            return "Profile: stale mapping (\(profileID))"
        case .outcomeUnknown(let profileID):
            return "Profile: switch to \(profileID) is unconfirmed"
        case .unmatched:
            if let currentProfileID {
                return "Profile: \(currentProfileID)"
            }
            return "Profile: unchanged"
        case .stopped:
            return "Profile: stopped"
        case .idle:
            return "Profile: waiting for runtime"
        case .current(let profileID):
            return "Profile: \(profileID)"
        case .switching(let profileID):
            return "Profile: switching to \(profileID)…"
        }
    }

    var canRetryProfileSwitch: Bool {
        switch profileState {
        case .outcomeUnknown, .unavailable:
            return true
        default:
            return false
        }
    }

    private func publishRuntimeState() {
        let state = runtimeSession.lifecycleState
        lifecycleText = state.description
        if let configurationBootstrapErrorText {
            healthText = configurationBootstrapErrorText
            return
        }
        healthText = switch state {
        case .ready:
            "Health: ready"
        case .configurationRequired:
            "Configuration required"
        case .failed(let failure):
            Self.runtimeFailureHealthText(
                failure: failure,
                lastFailureDetail: runtimeSession.lastFailureDetail
            )
        default:
            "Health: waiting for runtime"
        }
    }

    static func runtimeFailureHealthText(
        failure: SupervisorFailure,
        lastFailureDetail: String?
    ) -> String {
        guard failure == .restartExhausted,
              let lastFailureDetail else {
            return failure.description
        }
        return "\(failure.description)\nLast failure: \(lastFailureDetail)"
    }

    private func applyConfigurationPreference(isStartup: Bool) {
        let bootstrap = configurationBootstrap ?? configurationBootstrapFactory()
        configurationBootstrap = bootstrap
        let target = bootstrap.resolve(persistedSelectedPath: preferences.persistedConfigurationPath)
        resolvedConfigurationPath = target.path

        do {
            try bootstrap.prepare(target)
            configurationBootstrapErrorText = nil
            if isStartup {
                runtimeSession.start(configurationPath: target.path)
            } else {
                runtimeSession.setConfigurationPath(target.path)
            }
        } catch {
            configurationBootstrapErrorText = "Configuration error at \(target.path): \(error.localizedDescription)"
            if !isStartup {
                runtimeSession.setConfigurationPath(nil)
            }
        }

        publishRuntimeState()
    }

    static func simulated(
        configurationPath: String,
        runtimeRoot: String,
        diagnostics: HidhoggSimulationDiagnostics? = nil
    ) -> HidhoggAppModel {
        let preferencesStore = MemoryAppPreferencesStore(configurationPath: configurationPath)
        let mappingStore = MemoryProfileMappingPreferencesStore()
        let runtimeDirectoryFactory = DefaultGenerationDirectoryFactory(
            root: URL(fileURLWithPath: runtimeRoot, isDirectory: true),
            rootPolicy: .injected
        )
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: nil,
            homeDirectory: URL(fileURLWithPath: runtimeRoot, isDirectory: true),
            templateData: Data()
        )
        let runtimeSession = RuntimeSessionController(
            backendSelection: .simulated,
            runtimeDirectoryFactory: runtimeDirectoryFactory,
            simulationDiagnostics: diagnostics
        )
        return HidhoggAppModel(
            preferencesStore: preferencesStore,
            runtimeSession: runtimeSession,
            runtimeBackendSelection: .simulated,
            runtimeDirectoryFactory: runtimeDirectoryFactory,
            profileMappingStore: mappingStore,
            displayPowerCoordinator: HostDisplayPowerCoordinator(
                observer: SimulationHostDisplayPowerObserver()
            ),
            foregroundObserver: SimulationForegroundApplicationObserver(),
            allowsConfigurationSelection: false,
            configurationBootstrapFactory: { bootstrap }
        )
    }

#if HIDHOGG_TEST_HOST
    static func testHost() -> HidhoggAppModel {
        let testRoot = URL(fileURLWithPath: "/Volumes/Data/tmp/hidhogg-test-host", isDirectory: true)
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: nil,
            homeDirectory: testRoot,
            templateData: Data()
        )
        return HidhoggAppModel(
            preferencesStore: MemoryAppPreferencesStore(),
            runtimeBackendSelection: .simulated,
            runtimeDirectoryFactory: DefaultGenerationDirectoryFactory(
                root: testRoot,
                rootPolicy: .injected
            ),
            profileMappingStore: MemoryProfileMappingPreferencesStore(),
            displayPowerCoordinator: HostDisplayPowerCoordinator(
                observer: SimulationHostDisplayPowerObserver()
            ),
            foregroundObserver: SimulationForegroundApplicationObserver(),
            allowsConfigurationSelection: false,
            initialConfigurationError: "The runtime is disabled in the test host.",
            configurationBootstrapFactory: { bootstrap }
        )
    }
#endif

    static func invalidSimulation(_ message: String) -> HidhoggAppModel {
        HidhoggAppModel(
            preferencesStore: MemoryAppPreferencesStore(),
            runtimeBackendSelection: .simulated,
            profileMappingStore: MemoryProfileMappingPreferencesStore(),
            displayPowerCoordinator: HostDisplayPowerCoordinator(
                observer: SimulationHostDisplayPowerObserver()
            ),
            foregroundObserver: SimulationForegroundApplicationObserver(),
            allowsConfigurationSelection: false,
            initialConfigurationError: message,
            configurationBootstrapFactory: {
                DefaultConfigurationBootstrap(
                    xdgConfigHome: nil,
                    homeDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                    templateData: Data()
                )
            }
        )
    }
}

enum HidhoggSimulationArguments: Equatable {
    case production
    case simulated(configurationPath: String, runtimeRoot: String)
    case simulatedControlled(
        configurationPath: String,
        runtimeRoot: String,
        readyMarkerPath: String,
        stopMarkerPath: String
    )
    case invalid(String)

    static func parse(_ arguments: [String]) -> HidhoggSimulationArguments {
        let values = Array(arguments.dropFirst())
        let simulationFlags = values.filter { $0 == "--hidhogg-simulated" }
        guard !simulationFlags.isEmpty else {
            return values.contains(where: { $0.hasPrefix("--hidhogg-") })
                ? .invalid("Simulation arguments require --hidhogg-simulated.")
                : .production
        }
        guard simulationFlags.count == 1 else {
            return .invalid("Simulation arguments are invalid.")
        }

        var options = [String: String]()
        var index = 0
        while index < values.count {
            let option = values[index]
            if option == "--hidhogg-simulated" {
                index += 1
                continue
            }
            guard index + 1 < values.count,
                  [
                    "--hidhogg-config",
                    "--hidhogg-runtime-root",
                    "--hidhogg-ready-marker",
                    "--hidhogg-stop-marker"
                  ].contains(option),
                  options[option] == nil else {
                return .invalid("Simulation arguments are invalid.")
            }
            options[option] = values[index + 1]
            index += 2
        }

        guard let configurationPath = options["--hidhogg-config"],
              AppPreferences.validConfigurationPath(configurationPath) != nil,
              let runtimeRoot = options["--hidhogg-runtime-root"],
              AppPreferences.validConfigurationPath(runtimeRoot) != nil else {
            return .invalid("Simulation requires absolute configuration and runtime-root paths.")
        }

        switch (options["--hidhogg-ready-marker"], options["--hidhogg-stop-marker"]) {
        case (nil, nil):
            return .simulated(configurationPath: configurationPath, runtimeRoot: runtimeRoot)
        case let (readyMarkerPath?, stopMarkerPath?):
            guard let readyMarkerIdentity = freshMarkerIdentity(readyMarkerPath),
                  let stopMarkerIdentity = freshMarkerIdentity(stopMarkerPath),
                  readyMarkerIdentity != stopMarkerIdentity else {
                return .invalid("Simulation marker paths must be absolute, normalized, distinct, and fresh.")
            }
            return .simulatedControlled(
                configurationPath: configurationPath,
                runtimeRoot: runtimeRoot,
                readyMarkerPath: readyMarkerPath,
                stopMarkerPath: stopMarkerPath
            )
        default:
            return .invalid("Simulation requires both readiness and stop marker paths.")
        }
    }

    private static func freshMarkerIdentity(_ path: String) -> String? {
        guard AppPreferences.validConfigurationPath(path) != nil,
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            return nil
        }

        let parentPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard let resolvedParent = parentPath.withCString({ Darwin.realpath($0, nil) }) else {
            return nil
        }
        let canonicalParent = String(cString: resolvedParent)
        free(resolvedParent)

        var metadata = stat()
        let result = path.withCString { lstat($0, &metadata) }
        guard result == -1, errno == ENOENT else { return nil }

        let markerName = URL(fileURLWithPath: path).lastPathComponent
        return "\(canonicalParent)/\(markerName)"
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

@MainActor
final class HidhoggSimulationLaunchControl {
    enum State: Equatable {
        case idle
        case waitingForReadiness
        case readyPublished
        case readinessFailed
        case stopping
        case completed
        case timedOut
        case cancelled
    }

    private let maximumPollCount: Int
    private let pollIntervalNanoseconds: UInt64
    private let readiness: @MainActor () async -> RuntimeSessionController.RuntimeEndpoint?
    private let publishReady: @MainActor (RuntimeSessionController.RuntimeEndpoint) -> Bool
    private let stopRequested: @MainActor () -> Bool
    private let pause: @MainActor (UInt64) async -> Void
    private let terminate: @MainActor () -> Void
    private let diagnostics: HidhoggSimulationDiagnostics?
    private var monitorTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var readinessOutcome: RuntimeSessionController.RuntimeEndpoint??
    private var didHandleReadiness = false
    private var readinessPollCount = 0
    private(set) var state: State = .idle

    init(
        readyMarkerPath: String,
        stopMarkerPath: String,
        diagnostics: HidhoggSimulationDiagnostics? = nil,
        maximumPollCount: Int = 2_400,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        readiness: @escaping @MainActor () async -> RuntimeSessionController.RuntimeEndpoint?,
        publishReady: (@MainActor (RuntimeSessionController.RuntimeEndpoint) -> Bool)? = nil,
        stopRequested: (@MainActor () -> Bool)? = nil,
        pause: @escaping @MainActor (UInt64) async -> Void = { interval in
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {}
        },
        terminate: @escaping @MainActor () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.maximumPollCount = max(1, maximumPollCount)
        self.pollIntervalNanoseconds = max(1, pollIntervalNanoseconds)
        self.readiness = readiness
        self.publishReady = publishReady ?? { endpoint in
            Self.publishReadyMarker(at: readyMarkerPath, endpoint: endpoint)
        }
        self.stopRequested = stopRequested ?? {
            Self.hasValidStopMarker(at: stopMarkerPath)
        }
        self.pause = pause
        self.terminate = terminate
        self.diagnostics = diagnostics
    }

    func start() {
        guard monitorTask == nil, state == .idle else { return }
        state = .waitingForReadiness
        diagnostics?.emit(.launchControlStarted)
        let readiness = self.readiness
        readinessTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let endpoint = await readiness()
            guard !Task.isCancelled,
                  let self,
                  self.state == .waitingForReadiness,
                  !self.didHandleReadiness else { return }
            self.readinessOutcome = .some(endpoint)
        }
        monitorTask = Task { @MainActor [weak self] in
            await self?.monitor()
        }
    }

    func cancel() {
        guard state != .completed, state != .cancelled else { return }
        state = .cancelled
        readinessTask?.cancel()
        monitorTask?.cancel()
    }

    func waitForMonitoring() async {
        await monitorTask?.value
    }

    private func monitor() async {
        while !Task.isCancelled {
            guard !Task.isCancelled, state != .cancelled else { return }
            if stopRequested() {
                state = .stopping
                readinessTask?.cancel()
                diagnostics?.emit(.stopMarkerDetected)
                terminate()
                state = .completed
                return
            }
            if !didHandleReadiness {
                if let readinessOutcome {
                    didHandleReadiness = true
                    if let endpoint = readinessOutcome, publishReady(endpoint) {
                        state = .readyPublished
                        diagnostics?.emit(.readyMarkerPublished)
                    } else {
                        state = .readinessFailed
                        diagnostics?.emit(.readinessFailed)
                    }
                } else if state == .waitingForReadiness {
                    readinessPollCount += 1
                    if readinessPollCount >= maximumPollCount {
                        didHandleReadiness = true
                        readinessTask?.cancel()
                        state = .timedOut
                        diagnostics?.emit(.readinessTimedOut)
                    }
                }
            }
            await pause(pollIntervalNanoseconds)
        }
    }

    static func publishReadyMarker(
        at path: String,
        endpoint: RuntimeSessionController.RuntimeEndpoint
    ) -> Bool {
        let generationDirectory = URL(fileURLWithPath: endpoint.socketPath)
            .deletingLastPathComponent()
            .path
        let contents = """
        state=ready
        instance_id=\(endpoint.instanceID)
        generation_directory=\(generationDirectory)
        socket_path=\(endpoint.socketPath)
        """
        let markerURL = URL(fileURLWithPath: path)
        let temporaryURL = markerURL.deletingLastPathComponent()
            .appendingPathComponent(".\(markerURL.lastPathComponent).\(UUID().uuidString).tmp")
        let fileDescriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard fileDescriptor >= 0 else { return false }
        defer {
            _ = Darwin.close(fileDescriptor)
            temporaryURL.path.withCString { _ = Darwin.unlink($0) }
        }

        let data = Data(contents.utf8)
        let didWrite = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard result > 0 else { return false }
                offset += result
            }
            return true
        }
        guard didWrite,
              Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0,
              Darwin.fsync(fileDescriptor) == 0 else {
            return false
        }
        return temporaryURL.path.withCString { source in
            path.withCString { destination in Darwin.link(source, destination) == 0 }
        }
    }

    static func hasValidStopMarker(at path: String) -> Bool {
        var metadata = stat()
        let result = path.withCString { lstat($0, &metadata) }
        guard result == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o077) == 0 else {
            return false
        }
        return true
    }
}

@MainActor
private final class SimulationForegroundApplicationObserver: ForegroundApplicationObserving {
    func start(handler: @escaping ForegroundApplicationHandler) {
        handler(nil)
    }

    func stop() {}
}

@MainActor
private final class SimulationHostDisplayPowerObserver: HostDisplayPowerObserving {
    private(set) var lastKnownDisplayAwake: Bool? = true

    func start(
        stateHandler: @escaping HostDisplayPowerStateHandler,
        errorHandler: @escaping HostDisplayPowerErrorHandler
    ) {
        stateHandler(true)
        errorHandler(nil)
    }

    func reconcileIfUnknown() {}

    func stop() {}
}

private final class MemoryAppPreferencesStore: AppPreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(configurationPath: String? = nil) {
        values = configurationPath.map { [AppPreferences.configurationPathKey: $0] } ?? [:]
    }

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

private final class MemoryProfileMappingPreferencesStore: ProfileMappingPreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String: [String: String]]()

    func dictionary(forKey key: String) -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: [String: String]?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}
