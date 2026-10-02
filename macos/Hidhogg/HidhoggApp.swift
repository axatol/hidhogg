import AppKit
import SwiftUI

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
            Button("Choose Configuration…") {
                model.chooseConfiguration()
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
    let model: HidhoggAppModel
    private var terminationTask: Task<Void, Never>?
    private var terminationReplySent = false

    override init() {
        self.model = HidhoggAppModel()
        super.init()
    }

    init(model: HidhoggAppModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !HIDHOGG_TEST_HOST
        model.start()
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplySent, terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.quit()
            self.terminationReplySent = true
            sender.reply(toApplicationShouldTerminate: true)
            self.terminationTask = nil
        }
        return .terminateLater
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

    init(
        executablePath: String? = nil,
        preferencesStore: any AppPreferencesStore = UserDefaultsAppPreferencesStore(),
        runtimeSession: RuntimeSessionController? = nil,
        profileMappingStore: any ProfileMappingPreferencesStore = UserDefaultsProfileMappingPreferencesStore(),
        profileCoordinator: ProfileSwitchCoordinator? = nil,
        displayPowerCoordinator: HostDisplayPowerCoordinator? = nil,
        foregroundObserver: (any ForegroundApplicationObserving)? = nil,
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
        let resolvedExecutable: String
        if let executablePath {
            resolvedExecutable = executablePath
        } else {
            guard let bundledExecutable = Bundle.main.url(forAuxiliaryExecutable: "hidhogg-runtime") else {
                preconditionFailure("Hidhogg.app is missing its bundled hidhogg runtime")
            }
            resolvedExecutable = bundledExecutable.path
        }
        self.preferencesStore = preferencesStore
        self.profileMappingStore = profileMappingStore
        self.configurationBootstrapFactory = configurationBootstrapFactory
        self.preferences = AppPreferences(store: preferencesStore)
        if let runtimeSession {
            self.runtimeSession = runtimeSession
        } else {
            self.runtimeSession = RuntimeSessionController(executablePath: resolvedExecutable)
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
        applyConfigurationPreference(isStartup: true)
        displayPowerCoordinator.start()
        profileCoordinator.startObserving(foregroundObserver)
        observationTask = Task { @MainActor [weak self] in
            await self?.observeRuntime()
        }
    }

    func selectConfigurationPath(_ path: String) {
        guard !hasQuit else { return }
        preferences = preferences.savingConfigurationPath(path, to: preferencesStore)
        applyConfigurationPreference(isStartup: false)
    }

    func clearConfigurationPath() {
        guard !hasQuit else { return }
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
        guard !hasQuit else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "toml")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectConfigurationPath(url.path)
    }

    func quit() async {
        if hasQuit {
            if let quitTask {
                await quitTask.value
            }
            return
        }
        hasQuit = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.observationTask?.cancel()
            if let observationTask = self.observationTask {
                await observationTask.value
            }
            self.observationTask = nil
            await self.profileCoordinator.shutdown()
            await self.displayPowerCoordinator.shutdown()
            await self.runtimeSession.quit()
            self.publishRuntimeState()
            self.publishProfileState()
            self.publishDisplayPowerState()
            self.healthText = "Health: stopped"
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
}
