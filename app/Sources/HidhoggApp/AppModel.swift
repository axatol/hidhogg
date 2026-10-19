import AppKit
import Combine
import Darwin
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions

protocol BindingSession: Sendable {
    var events: AsyncStream<BoltEvent> { get }

    func discover() async
    func enable() async
    func disable() async
    func stop() async
    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool
}

extension BoltController: BindingSession {}

enum WorkspaceRoute: String, CaseIterable, Hashable, Identifiable {
    case devices
    case settings

    var id: Self { self }
}

struct WorkspaceLocation: Hashable {
    var route: WorkspaceRoute
    var applicationID: String?
    var control: MouseControl

    init(route: WorkspaceRoute = .devices, applicationID: String? = nil, control: MouseControl = .back) {
        self.route = route
        self.applicationID = applicationID
        self.control = control
    }
}

enum BindingEditorMode: String, CaseIterable, Identifiable {
    case inherit
    case disabled
    case shortcut

    var id: Self { self }

    var title: String {
        switch self {
        case .inherit: "Inherit"
        case .disabled: "Disabled"
        case .shortcut: "Shortcut"
        }
    }
}

struct ShortcutRecordingTarget: Equatable {
    let control: MouseControl
    let applicationID: String?
}

@MainActor
final class AppModel: ObservableObject {
    let configurationURL: URL

    @Published private(set) var navigation = NavigationHistory(initialRoute: WorkspaceLocation())
    @Published private(set) var document = ConfigurationDraft()
    @Published private(set) var boltStatus = BoltStatus(
        phase: .idle,
        message: "Disconnected. Connect to discover a Bolt candidate.",
        availableControls: [],
        generation: 0,
        cleanupUncertain: false
    )
    @Published private(set) var permission: InputPermission = .denied
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var configurationLoadFailed = false
    @Published private(set) var recordingTarget: ShortcutRecordingTarget?
    @Published private(set) var lastActionMessage: String?
    @Published var isReloadConfirmationPresented = false
    @Published var isEnableConfirmationPresented = false
    @Published private(set) var errorMessage: String?

    private let store: ConfigurationStore
    private let bolt: any BindingSession
    private let sender: ShortcutSender
    private let frontmostApplication: @MainActor () -> String?
    private var fileRevision = FileRevision.missing
    private var deliveryGeneration: UInt64?
    private var lifecycleIntent: UInt64 = 0
    private var discoveryPending = false
    private var actionsEnabled = false
    private var sessionActivationRequested = false
    private var eventTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?

    convenience init() {
        let url = Self.defaultConfigurationURL()
        self.init(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: BoltController(),
            sender: ShortcutSender(),
            loadImmediately: true,
            observeSleep: true
        )
    }

    init(
        configurationURL: URL,
        store: ConfigurationStore,
        bolt: any BindingSession,
        sender: ShortcutSender,
        loadImmediately: Bool = true,
        observeSleep: Bool = true,
        frontmostApplication: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.configurationURL = configurationURL
        self.store = store
        self.bolt = bolt
        self.sender = sender
        self.frontmostApplication = frontmostApplication
        permission = sender.permission

        let events = bolt.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
        }

        if observeSleep {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.prepareForLifecycleStop()
                    Task { @MainActor [weak self] in await self?.stopForSleep() }
                }
            }
        }

        if loadImmediately {
            Task { [weak self] in await self?.loadInitialConfiguration() }
        } else {
            isLoading = false
        }
    }

    isolated deinit {
        eventTask?.cancel()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
    }

    var isDirty: Bool { document.isDirty }
    var selectedApplicationID: String? { navigation.current.applicationID }
    var selectedControl: MouseControl { navigation.current.control }
    var applicationIDs: [String] { document.draft.mouse?.applications.keys.sorted() ?? [] }
    var isBindingsEnabled: Bool { boltStatus.phase == .enabled && actionsEnabled }
    var canDiscover: Bool {
        !isLoading && !isSaving && !discoveryPending && canStartDiscovery
    }
    var canEnableBindings: Bool {
        BindingReadiness(
            configurationIsSaved: !isLoading && !isSaving && !configurationLoadFailed && fileRevision.exists && !isDirty,
            permissionIsGranted: permission == .granted,
            deviceIsReady: boltStatus.phase == .ready,
            supportsRequiredControls: boltStatus.availableControls == Set(MouseControl.allCases)
        ).canEnable
    }

    var connectionTitle: String {
        switch boltStatus.phase {
        case .idle: "Disconnected"
        case .discovering: "Discovering"
        case .ready: "Connected"
        case .enabling: "Enabling"
        case .enabled: actionsEnabled ? "Enabled" : "Stopping"
        case .stopping: "Stopping"
        case .failed: "Failed"
        }
    }

    var connectionColor: NSColor {
        switch boltStatus.phase {
        case .ready: .systemGreen
        case .enabled: actionsEnabled ? .systemGreen : .systemOrange
        case .discovering, .enabling, .stopping: .systemOrange
        case .failed: .systemRed
        case .idle: .tertiaryLabelColor
        }
    }

    var configurationStatus: String {
        if isLoading { return "Loading configuration" }
        if isSaving { return "Saving configuration" }
        if configurationLoadFailed { return "Configuration unavailable" }
        if isDirty { return "Unsaved changes" }
        return fileRevision.exists ? "Saved" : "Not saved"
    }

    var canSaveConfiguration: Bool {
        !isLoading && !isSaving && !configurationLoadFailed && (isDirty || !fileRevision.exists)
    }

    func navigate(to route: WorkspaceRoute) {
        var next = navigation
        var location = next.current
        location.route = route
        next.navigate(to: location)
        navigation = next
    }

    func goBack() {
        var next = navigation
        guard next.goBack() else { return }
        next.replaceCurrent(with: normalized(next.current))
        navigation = next
    }

    func goForward() {
        var next = navigation
        guard next.goForward() else { return }
        next.replaceCurrent(with: normalized(next.current))
        navigation = next
    }

    func connect() {
        guard canDiscover else { return }
        let intent = advanceLifecycleIntent()
        discoveryPending = true
        sessionActivationRequested = false
        actionsEnabled = false
        deliveryGeneration = nil
        Task { @MainActor [weak self] in
            guard let self,
                  self.lifecycleIntent == intent,
                  self.discoveryPending,
                  self.canStartDiscovery else { return }
            await self.bolt.discover()
            guard self.lifecycleIntent == intent else { return }
            self.discoveryPending = false
        }
    }

    func disconnect() {
        prepareForLifecycleStop()
        Task { await bolt.stop() }
    }

    func requestEnableConfirmation() {
        guard canEnableBindings else { return }
        isEnableConfirmationPresented = true
    }

    func confirmEnableBindings() {
        isEnableConfirmationPresented = false
        guard canEnableBindings, refreshPermission() == .granted else { return }
        let intent = advanceLifecycleIntent()
        sessionActivationRequested = true
        Task { @MainActor [weak self] in
            guard let self,
                  self.lifecycleIntent == intent,
                  self.sessionActivationRequested,
                  self.canEnableBindings else { return }
            await self.bolt.enable()
        }
    }

    func refreshPermission() -> InputPermission {
        permission = sender.refreshPermission()
        if permission == .denied { stopDeliveryAndBindings() }
        return permission
    }

    func requestPermission() -> InputPermission {
        permission = sender.requestPermission()
        if permission == .denied { stopDeliveryAndBindings() }
        return permission
    }

    func setBindingMode(_ mode: BindingEditorMode, for control: MouseControl) {
        guard canEditConfiguration else { return }
        let applicationID = selectedApplicationID
        switch mode {
        case .inherit:
            guard applicationID != nil else { return }
            cancelRecording(for: control, applicationID: applicationID)
            setBinding(nil, for: control, applicationID: applicationID)
        case .disabled:
            cancelRecording(for: control, applicationID: applicationID)
            setBinding(.disabled, for: control, applicationID: applicationID)
        case .shortcut:
            let inherited = document.draft.mouse?.binding(for: control, application: applicationID)
            if inherited?.kind == .shortcut, let shortcut = inherited?.shortcut {
                cancelRecording(for: control, applicationID: applicationID)
                setBinding(.key(shortcut), for: control, applicationID: applicationID)
            } else {
                beginRecording(for: control, applicationID: applicationID)
            }
        }
    }

    func bindingMode(for control: MouseControl) -> BindingEditorMode {
        let applicationID = selectedApplicationID
        if recordingTarget == ShortcutRecordingTarget(control: control, applicationID: applicationID) {
            return .shortcut
        }
        guard let device = document.draft.mouse else { return .disabled }
        if let applicationID, device.applications[applicationID]?[control.rawValue] == nil {
            return .inherit
        }
        return device.binding(for: control, application: applicationID).kind == .shortcut ? .shortcut : .disabled
    }

    func bindingDescription(for control: MouseControl) -> String {
        let applicationID = selectedApplicationID
        if recordingTarget == ShortcutRecordingTarget(control: control, applicationID: applicationID) {
            return "Press a key combination. Escape cancels."
        }
        guard let device = document.draft.mouse else { return "Disabled" }

        if let applicationID, device.applications[applicationID]?[control.rawValue] == nil {
            return "Inherited: " + Self.bindingDescription(device.binding(for: control, application: nil))
        }
        return Self.bindingDescription(device.binding(for: control, application: applicationID))
    }

    func beginRecording(for control: MouseControl, applicationID: String? = nil) {
        guard canEditConfiguration else { return }
        let shouldStopSession = hasPendingOrActiveSession
        recordingTarget = ShortcutRecordingTarget(control: control, applicationID: applicationID)
        invalidateLifecycleIntent()
        actionsEnabled = false
        deliveryGeneration = nil
        if shouldStopSession { Task { await bolt.stop() } }
    }

    func selectApplication(_ applicationID: String?) {
        guard applicationID.map(applicationIDs.contains) ?? true else { return }
        if recordingTarget?.applicationID != applicationID { recordingTarget = nil }
        var location = navigation.current
        location.applicationID = applicationID
        var next = navigation
        next.navigate(to: location)
        navigation = next
    }

    func selectControl(_ control: MouseControl) {
        guard selectedControl != control else { return }
        if recordingTarget?.control != control { recordingTarget = nil }
        var location = navigation.current
        location.control = control
        var next = navigation
        next.navigate(to: location)
        navigation = next
    }

    func completeRecording(_ shortcut: KeyboardShortcut) {
        guard canEditConfiguration, let target = recordingTarget else { return }
        setBinding(.key(shortcut), for: target.control, applicationID: target.applicationID)
        recordingTarget = nil
    }

    func cancelRecording() {
        recordingTarget = nil
    }

    func addApplication(at url: URL) {
        guard canEditConfiguration else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let applicationID = Bundle(url: url)?.bundleIdentifier, !applicationID.isEmpty else {
            errorMessage = "The selected application does not have a bundle identifier."
            return
        }

        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        if configuration.devices[index].applications[applicationID] == nil {
            guard configuration.devices[index].applications.count < 128 else {
                errorMessage = "A maximum of 128 application overrides is supported."
                return
            }
            configuration.devices[index].applications[applicationID] = [:]
            document.updateDraft(configuration)
        }
        var location = navigation.current
        location.applicationID = applicationID
        var next = navigation
        next.navigate(to: location)
        navigation = next
        errorMessage = nil
    }

    func removeSelectedApplication() {
        guard canEditConfiguration else { return }
        guard let applicationID = selectedApplicationID else { return }
        if recordingTarget?.applicationID == applicationID { recordingTarget = nil }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        configuration.devices[index].applications.removeValue(forKey: applicationID)
        document.updateDraft(configuration)
        var location = navigation.current
        location.applicationID = nil
        var next = navigation
        next.replaceCurrent(with: location)
        navigation = next
    }

    func updateDraft(_ configuration: AppConfiguration) {
        guard canEditConfiguration else { return }
        document.updateDraft(configuration)
    }

    func save() async {
        guard canSaveConfiguration else { return }
        let shouldStopSession = hasPendingOrActiveSession
        isSaving = true
        errorMessage = nil
        let submittedConfiguration = document.draft
        invalidateLifecycleIntent()
        actionsEnabled = false
        deliveryGeneration = nil
        if shouldStopSession { await bolt.stop() }
        do {
            let snapshot = try await store.save(submittedConfiguration, expecting: fileRevision)
            fileRevision = snapshot.revision
            document.acceptSaved(snapshot.configuration)
            configurationLoadFailed = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    func requestReload() {
        guard !isLoading, !isSaving else { return }
        guard isDirty else {
            startReload()
            return
        }
        isReloadConfirmationPresented = true
    }

    func confirmDiscardAndReload() {
        isReloadConfirmationPresented = false
        guard !isLoading, !isSaving else { return }
        startReload()
    }

    func cancelReload() {
        isReloadConfirmationPresented = false
    }

    func dismissError() {
        errorMessage = nil
    }

    func reportError(_ message: String) {
        errorMessage = message
    }

    func stopForSleep() async {
        await stopControllerSession()
    }

    func stopForTermination() async {
        await stopControllerSession()
    }

    func prepareForLifecycleStop() {
        invalidateLifecycleIntent()
        isEnableConfirmationPresented = false
        actionsEnabled = false
        deliveryGeneration = nil
    }

    private func stopControllerSession() async {
        prepareForLifecycleStop()
        await bolt.stop()
    }

    private func loadInitialConfiguration() async {
        do {
            let snapshot = try await store.load()
            fileRevision = snapshot.revision
            document.acceptReload(snapshot.configuration)
            configurationLoadFailed = false
        } catch {
            errorMessage = error.localizedDescription
            configurationLoadFailed = true
        }
        isLoading = false
    }

    private func reloadFromDisk(stopSession: Bool) async {
        guard isLoading, !isSaving else { return }
        if stopSession { await bolt.stop() }
        errorMessage = nil
        do {
            let snapshot = try await store.load()
            fileRevision = snapshot.revision
            document.acceptReload(snapshot.configuration)
            configurationLoadFailed = false
            recordingTarget = nil
            if let selectedApplicationID, !applicationIDs.contains(selectedApplicationID) {
                var location = navigation.current
                location.applicationID = nil
                var next = navigation
                next.replaceCurrent(with: location)
                navigation = next
            }
        } catch {
            errorMessage = error.localizedDescription
            configurationLoadFailed = true
        }
        isLoading = false
    }

    private func startReload() {
        guard !isLoading, !isSaving else { return }
        let shouldStopSession = hasPendingOrActiveSession
        isLoading = true
        invalidateLifecycleIntent()
        actionsEnabled = false
        deliveryGeneration = nil
        Task { await reloadFromDisk(stopSession: shouldStopSession) }
    }

    private func stopDeliveryAndBindings() {
        let shouldStopSession = hasPendingOrActiveSession
        invalidateLifecycleIntent()
        actionsEnabled = false
        deliveryGeneration = nil
        if shouldStopSession { Task { await bolt.stop() } }
    }

    private var canEditConfiguration: Bool { !isLoading && !isSaving }
    private var hasPendingOrActiveSession: Bool {
        discoveryPending || sessionActivationRequested || boltStatus.phase != .idle
    }

    private var canStartDiscovery: Bool {
        !boltStatus.cleanupUncertain && [.idle, .ready, .failed].contains(boltStatus.phase)
    }

    private func advanceLifecycleIntent() -> UInt64 {
        lifecycleIntent &+= 1
        discoveryPending = false
        return lifecycleIntent
    }

    private func invalidateLifecycleIntent() {
        _ = advanceLifecycleIntent()
        sessionActivationRequested = false
    }

    private func normalized(_ location: WorkspaceLocation) -> WorkspaceLocation {
        guard let applicationID = location.applicationID, !applicationIDs.contains(applicationID) else { return location }
        var normalized = location
        normalized.applicationID = nil
        return normalized
    }

    private func receive(_ event: BoltEvent) {
        switch event {
        case .status(let status):
            boltStatus = status
            if status.phase == .idle || status.phase == .failed { sessionActivationRequested = false }
            guard status.phase == .enabled,
                  sessionActivationRequested,
                  permission == .granted,
                  recordingTarget == nil else {
                actionsEnabled = false
                deliveryGeneration = nil
                if status.phase == .enabled { Task { await bolt.disable() } }
                return
            }
            actionsEnabled = true
            deliveryGeneration = status.generation
        case .press(let control, let generation, let observedAt):
            deliver(control: control, generation: generation, observedAt: observedAt)
        }
    }

    private func deliver(control: MouseControl, generation: UInt64, observedAt: ContinuousClock.Instant) {
        guard actionsEnabled,
              deliveryGeneration == generation,
              boltStatus.phase == .enabled,
              boltStatus.generation == generation,
              permission == .granted,
              recordingTarget == nil else { return }

        let applicationID = frontmostApplication()
        let binding = document.saved.mouse?.binding(for: control, application: applicationID) ?? .disabled
        guard binding.kind == .shortcut, let shortcut = binding.shortcut else { return }

        var deliveryError: Error?
        let admitted = bolt.withPressAdmission(generation: generation, observedAt: observedAt) {
            do {
                try sender.send(shortcut)
                lastActionMessage = "Posted \(ShortcutSender.label(for: shortcut)). The receiving app decides whether to respond."
            } catch {
                deliveryError = error
            }
        }
        guard admitted, let deliveryError else { return }
        lastActionMessage = deliveryError.localizedDescription
        if sender.permission == .denied {
            permission = .denied
            stopDeliveryAndBindings()
        }
    }

    private func cancelRecording(for control: MouseControl, applicationID: String?) {
        guard recordingTarget == ShortcutRecordingTarget(control: control, applicationID: applicationID) else { return }
        recordingTarget = nil
    }

    private func setBinding(_ binding: ControlBinding?, for control: MouseControl, applicationID: String?) {
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        if let applicationID {
            var overrides = configuration.devices[index].applications[applicationID] ?? [:]
            if let binding {
                overrides[control.rawValue] = binding
            } else {
                overrides.removeValue(forKey: control.rawValue)
            }
            if overrides.isEmpty {
                configuration.devices[index].applications.removeValue(forKey: applicationID)
            } else {
                configuration.devices[index].applications[applicationID] = overrides
            }
        } else if let binding {
            configuration.devices[index].defaults[control.rawValue] = binding
        }
        document.updateDraft(configuration)
    }

    private static func bindingDescription(_ binding: ControlBinding) -> String {
        guard binding.kind == .shortcut, let shortcut = binding.shortcut else { return "Disabled" }
        return ShortcutSender.label(for: shortcut)
    }

    private static func defaultConfigurationURL() -> URL {
        let xdgConfigHome = getenv("XDG_CONFIG_HOME").map { String(cString: $0) }
        return ConfigurationLocation.url(
            xdgConfigHome: xdgConfigHome,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }
}
