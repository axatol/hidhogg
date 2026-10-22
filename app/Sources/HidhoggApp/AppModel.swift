import AppKit
import Combine
import CoreGraphics
import Darwin
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions

protocol BindingSession: Sendable {
    var events: AsyncStream<BoltEvent> { get }

    func discover() async
    func refreshDeviceInformation() async
    func enable() async
    func disable() async
    func stop() async
    func stop(restorePreviousSettingsOnDisconnect: Bool) async
    func stopForRestart() async -> Bool
    func stopForRestart(restorePreviousSettingsOnDisconnect: Bool) async -> Bool
    func applyWheelPreference(_ inverted: Bool?) async
    func applyWheelPreference(_ inverted: Bool?, restorePreviousSettingsOnDisconnect: Bool) async
    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool) async
    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool, amount: Double?, scrollPostingAllowed: Bool) async
    func applyThumbwheelPreferences(inverted: Bool?, amount: Double?, restorePreviousSettingsOnDisconnect: Bool, scrollPostingAllowed: Bool) async
    func invalidateScrollAdmission()
    func suspendScrollAdmission()
    func withScrollAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool
    func invalidateThumbwheelAdmission()
    func suspendThumbwheelAdmission()
    func withThumbwheelAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool
    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool
}

extension BoltController: BindingSession {}

extension BindingSession {
    func refreshDeviceInformation() async {}

    func stop(restorePreviousSettingsOnDisconnect: Bool) async { await stop() }

    func stopForRestart(restorePreviousSettingsOnDisconnect: Bool) async -> Bool {
        await stopForRestart()
    }

    func applyWheelPreference(_ inverted: Bool?) async {}

    func applyWheelPreference(_ inverted: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        await applyWheelPreference(inverted)
    }

    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        await applyWheelPreference(inverted, restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
    }

    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool, amount: Double?, scrollPostingAllowed: Bool) async {
        await applyWheelPreferences(inverted: inverted, highResolution: highResolution, restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
    }

    func applyThumbwheelPreferences(inverted: Bool?, amount: Double?, restorePreviousSettingsOnDisconnect: Bool, scrollPostingAllowed: Bool) async {}

    func invalidateScrollAdmission() {}
    func suspendScrollAdmission() { invalidateScrollAdmission() }
    func withScrollAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool { false }
    func invalidateThumbwheelAdmission() {}
    func suspendThumbwheelAdmission() { invalidateThumbwheelAdmission() }
    func withThumbwheelAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool { false }

    func stopForRestart() async -> Bool {
        await stop()
        return false
    }
}

enum WorkspaceRoute: String, CaseIterable, Hashable, Identifiable {
    case devices
    case settings

    var id: Self { self }
}

struct WorkspaceLocation: Hashable {
    var route: WorkspaceRoute
    var applicationID: String?
    var control: MouseControl
    var target: DeviceEditorTarget

    init(route: WorkspaceRoute = .devices, applicationID: String? = nil, control: MouseControl = .back) {
        self.route = route
        self.applicationID = applicationID
        self.control = control
        self.target = control == .back ? .back : .forward
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
    let lowBatteryNotifications: LowBatteryNotificationController?

    @Published private(set) var navigation = NavigationHistory(initialRoute: WorkspaceLocation())
    @Published private(set) var document = ConfigurationDraft()
    @Published private(set) var boltStatus = BoltStatus(
        phase: .idle,
        message: "Disconnected. Connect to discover a Bolt candidate.",
        availableControls: [],
        generation: 0,
        cleanupUncertain: false
    )
    @Published private(set) var permissionChecks = PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: false)
    @Published private(set) var isRestarting = false
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var isWheelApplyPending = false
    @Published private(set) var isThumbwheelApplyPending = false
    @Published private(set) var configurationLoadFailed = false
    @Published private(set) var configurationLoadError: String?
    @Published private(set) var configurationSaveError: String?
    @Published private(set) var configurationFailureKind: ConfigurationFailureKind?
    @Published var selectedSettingsCategory: SettingsCategory = .general
    @Published private(set) var settingsScrollRequestID = UUID()
    @Published private(set) var captureSessionID: UUID?
    @Published private(set) var recordingTarget: ShortcutRecordingTarget?
    @Published private(set) var lastActionMessage: String?
    @Published var isReloadConfirmationPresented = false
    @Published var isEnableConfirmationPresented = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var diagnosticEvent: DiagnosticEvent?

    private let store: ConfigurationStore
    private let bolt: any BindingSession
    private let sender: ShortcutSender
    private let scrollSender: ScrollSender
    private let thumbwheelScrollSender: ScrollSender
    private var scrollPostingFailed = false
    private var scrollReleasePending = false
    private var thumbwheelPostingFailed = false
    private var thumbwheelReleasePending = false
    private let frontmostApplication: @MainActor () -> String?
    private var fileRevision = FileRevision.missing
    private var hasUsableConfiguration = true
    private var deliveryGeneration: UInt64?
    private var lifecycleIntent: UInt64 = 0
    private struct WheelRequest: Equatable {
        var inverted: Bool?
        var highResolution: Bool?
        var amount: Double?
        var postingAllowed: Bool
        var restorePreviousSettingsOnDisconnect: Bool
    }
    private var attemptedWheelRequest: WheelRequest?
    private struct ThumbwheelRequest: Equatable {
        var inverted: Bool?
        var amount: Double?
        var postingAllowed: Bool
        var restorePreviousSettingsOnDisconnect: Bool
    }
    private var attemptedThumbwheelRequest: ThumbwheelRequest?
    private var attemptedButtonState: Bool?
    private var reconciliationRequested = false
    private var reconciliationTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private var discoveryPending = false
    private var actionsEnabled = false
    private var sessionActivationRequested = false
    private var initialConfigurationLoadPending = false
    private var deferredConnectOnLaunchValue: Bool?
    private var startupConnectionDecisionConsumed = false
    private var deferredInitialConfigurationLoad: InitialConfigurationLoad?
    private var eventTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let wakeDelay: WakeRecoveryCoordinator.Delay
    private let wakeStatusTimeout: WakeRecoveryCoordinator.Delay
    private lazy var wakeRecovery = WakeRecoveryCoordinator(delay: wakeDelay) { [weak self] code, message in
        self?.recordDiagnostic(code: code, message: message)
    }
    private var statusSequence: UInt64 = 0
    private var informationRequestedForConnection = false
    private struct WakeStatusWait {
        let id: UUID
        let matches: @MainActor (BoltStatus) -> Bool
        let continuation: CheckedContinuation<BoltStatus?, Never>
        let timeout: Task<Void, Never>
    }
    private var wakeStatusWait: WakeStatusWait?
    private var sleepCleanupTask: Task<Bool, Never>?
    private var sleepCleanupSequence: UInt64 = 0

    private enum InitialConfigurationLoad {
        case success(ConfigurationSnapshot)
        case failure(String)
    }

    convenience init() {
        let url = Self.defaultConfigurationURL()
        self.init(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: BoltController(scrollPostingPreflight: { CGPreflightPostEventAccess() }),
            sender: ShortcutSender(),
            scrollSender: ScrollSender(),
            thumbwheelScrollSender: ScrollSender(),
            lowBatteryNotifications: LowBatteryNotificationController(),
            loadImmediately: true,
            observeSleep: true
        )
    }

    init(
        configurationURL: URL,
        store: ConfigurationStore,
        bolt: any BindingSession,
        sender: ShortcutSender,
        scrollSender: ScrollSender = ScrollSender(preflight: { false }, post: { _, _ in }),
        thumbwheelScrollSender: ScrollSender = ScrollSender(preflight: { false }, post: { _, _ in }),
        lowBatteryNotifications: LowBatteryNotificationController? = nil,
        loadImmediately: Bool = true,
        observeSleep: Bool = true,
        wakeDelay: @escaping WakeRecoveryCoordinator.Delay = { try await Task.sleep(for: $0) },
        wakeStatusTimeout: @escaping WakeRecoveryCoordinator.Delay = { try await Task.sleep(for: $0) },
        frontmostApplication: @escaping @MainActor () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.configurationURL = configurationURL
        self.store = store
        self.bolt = bolt
        self.sender = sender
        self.scrollSender = scrollSender
        self.thumbwheelScrollSender = thumbwheelScrollSender
        self.lowBatteryNotifications = lowBatteryNotifications
        self.frontmostApplication = frontmostApplication
        self.wakeDelay = wakeDelay
        self.wakeStatusTimeout = wakeStatusTimeout
        permissionChecks = sender.permissionChecks

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
                    self.systemWillSleep()
                }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            }
        }

        if loadImmediately {
            let initialLifecycleIntent = lifecycleIntent
            initialConfigurationLoadPending = true
            Task { [weak self] in
                await self?.loadInitialConfiguration(startupIntent: initialLifecycleIntent)
            }
        } else {
            isLoading = false
        }
    }

    isolated deinit {
        eventTask?.cancel()
        autosaveTask?.cancel()
        reconciliationTask?.cancel()
        wakeStatusWait?.timeout.cancel()
        wakeStatusWait?.continuation.resume(returning: nil)
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    var isDirty: Bool { document.isDirty }
    var permission: InputPermission { permissionChecks.eventPostingAllowed ? .granted : .denied }
    var selectedApplicationID: String? { navigation.current.applicationID }
    var selectedControl: MouseControl { navigation.current.control }
    var applicationIDs: [String] { document.draft.mouse?.applications.keys.sorted() ?? [] }
    var isBindingsEnabled: Bool { boltStatus.phase == .enabled && actionsEnabled }

    var buttonReadiness: String {
        if recordingTarget != nil { return "Shortcuts paused while recording" }
        if !hasUsableConfiguration { return "Shortcuts blocked: configuration unavailable" }
        if !hasConfiguredShortcut { return "No shortcuts configured" }
        if permission != .granted { return "Shortcuts blocked: input permission required" }
        if isBindingsEnabled { return "Button shortcuts ready" }
        return "Shortcuts waiting for a usable connection"
    }
    var isWheelApplyInFlight: Bool { isWheelApplyPending || boltStatus.wheel.isApplying }
    var isThumbwheelApplyInFlight: Bool { isThumbwheelApplyPending }
    var wheelPreferenceDraft: Bool? { document.draft.mouse?.wheelInverted }
    var savedWheelPreference: Bool? { document.saved.mouse?.wheelInverted }
    var wheelScrollAmountDraft: Double? { document.draft.mouse?.wheelScrollAmount }
    var wheelHighResolutionDraft: Bool? { document.draft.mouse?.wheelHighResolution }
    var thumbwheelPreferenceDraft: Bool? { document.draft.mouse?.thumbwheelInverted }
    var savedThumbwheelPreference: Bool? { document.saved.mouse?.thumbwheelInverted }
    var thumbwheelScrollAmountDraft: Double? { document.draft.mouse?.thumbwheelScrollAmount }
    var restorePreviousSettingsOnDisconnect: Bool { document.draft.mouse?.restorePreviousSettingsOnDisconnect ?? false }
    var observedWheelDirection: String {
        switch boltStatus.wheel.support {
        case .unknown: "Not observed"
        case .unsupported: "Unsupported"
        case .supported:
            switch boltStatus.wheel.observedInverted {
            case .none: "Unknown"
            case .some(false): "Standard"
            case .some(true): "Natural"
            }
        }
    }
    var wheelSessionChange: String {
        if isWheelApplyInFlight { return "Applying" }
        guard boltStatus.wheel.isOwned else { return "No active change" }
        if boltStatus.wheel.captureActive { return "Temporary capture; always released on disconnect" }
        return restorePreviousSettingsOnDisconnect ? "Will restore on disconnect" : "Kept on device"
    }
    var scrollAmountStatus: String {
        guard wheelScrollAmountDraft != nil else { return "Native scrolling" }
        if scrollPostingFailed { return "Blocked after input posting failed. Refresh permission or switch custom amount off and on to retry." }
        if let blocker = boltStatus.wheel.captureBlocker { return blocker }
        if boltStatus.wheel.captureActive { return "Active: fixed line output for this mouse" }
        if wheelScrollAmountDraft != nil && permission != .granted { return "Blocked: input posting permission required; native scrolling is active" }
        return "Waiting for a connected supported mouse"
    }
    var effectiveWheelDirection: String {
        guard let inverted = boltStatus.wheel.effectiveInverted else { return observedWheelDirection }
        return inverted ? "Natural in software" : "Standard in software"
    }
    var observedThumbwheelDirection: String {
        switch boltStatus.thumbwheel.support {
        case .unknown: "Not observed"
        case .unsupported: "Unsupported"
        case .supported:
            switch boltStatus.thumbwheel.observedInverted {
            case .none: "Unknown"
            case .some(false): "Standard"
            case .some(true): "Natural"
            }
        }
    }
    var effectiveThumbwheelDirection: String {
        guard let inverted = boltStatus.thumbwheel.effectiveInverted else { return observedThumbwheelDirection }
        return inverted ? "Natural in software" : "Standard in software"
    }
    var thumbwheelSessionChange: String {
        if isThumbwheelApplyInFlight { return "Applying" }
        guard boltStatus.thumbwheel.isOwned else { return "No active change" }
        if boltStatus.thumbwheel.captureActive { return "Temporary capture; always released on disconnect" }
        return restorePreviousSettingsOnDisconnect ? "Will restore on disconnect" : "Kept on device"
    }
    var thumbwheelScrollAmountStatus: String {
        guard thumbwheelScrollAmountDraft != nil else { return "Native thumb-wheel scrolling" }
        if thumbwheelPostingFailed { return "Blocked after thumb-wheel posting failed. Refresh permission or switch custom amount off and on to retry." }
        if let blocker = boltStatus.thumbwheel.captureBlocker { return blocker }
        if boltStatus.thumbwheel.captureActive { return "Active: fixed line output for the thumb wheel" }
        if permission != .granted { return "Blocked: input posting permission required; native scrolling is active" }
        if boltStatus.thumbwheel.support == .unsupported { return "Unsupported by this connected mouse" }
        if boltStatus.thumbwheel.support == .unknown { return "Waiting for thumb-wheel discovery" }
        return "Waiting for a connected supported mouse"
    }
    var observedWheelResolution: String {
        switch boltStatus.wheel.support {
        case .unknown: "Not observed"
        case .unsupported: "Unsupported"
        case .supported:
            switch boltStatus.wheel.observedHighResolution {
            case .none: "Unknown"
            case .some(false): "Low"
            case .some(true): "High"
            }
        }
    }
    var canDiscover: Bool {
        !isRestarting && !isLoading && !discoveryPending && canStartDiscovery
    }
    var canEnableBindings: Bool {
        !isRestarting && !isLoading && hasUsableConfiguration &&
            permission == .granted && boltStatus.phase == .ready &&
            boltStatus.availableControls == Set(MouseControl.allCases) &&
            (try? document.draft.validated()) != nil
    }

    var connectionTitle: String {
        switch boltStatus.phase {
        case .idle: "Disconnected"
        case .discovering: "Discovering"
        case .ready: "Connected"
        case .enabling: "Enabling"
        case .enabled: "Connected"
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
        if configurationFailureKind == .conflict { return "File conflict" }
        if configurationSaveError != nil { return "Save failed" }
        if isDirty { return "Saving changes soon" }
        return fileRevision.exists ? "Saved" : "Not saved"
    }

    var canSaveConfiguration: Bool {
        !isRestarting && !isLoading && !isSaving && !configurationLoadFailed && (isDirty || !fileRevision.exists)
    }

    var canReloadConfiguration: Bool {
        !isRestarting && !isLoading && !isSaving
    }

    var canApplyWheelPreference: Bool {
        !isWheelApplyInFlight && canStartWheelApply
    }

    func navigate(to route: WorkspaceRoute) {
        if navigation.current.route != route { cancelRecording() }
        var next = navigation
        var location = next.current
        location.route = route
        next.navigate(to: location)
        navigation = next
    }

    func goBack() {
        var next = navigation
        guard next.goBack() else { return }
        cancelRecording()
        next.replaceCurrent(with: normalized(next.current))
        navigation = next
    }

    func goForward() {
        var next = navigation
        guard next.goForward() else { return }
        cancelRecording()
        next.replaceCurrent(with: normalized(next.current))
        navigation = next
    }

    func connect() {
        cancelWakeRecovery()
        guard !isRestarting else { return }
        if let cleanup = sleepCleanupTask {
            let intent = advanceLifecycleIntent()
            let sequence = sleepCleanupSequence
            Task { @MainActor [weak self] in
                let cleaned = await cleanup.value
                guard let self, self.lifecycleIntent == intent, !self.isRestarting else { return }
                self.sleepCleanupTask = nil
                guard cleaned else { return }
                let status = await self.waitForWakeStatus(after: sequence, matching: { [.idle, .failed].contains($0.phase) })
                guard self.lifecycleIntent == intent, status?.phase == .idle, status?.cleanupUncertain == false else { return }
                self.connect()
            }
            return
        }
        scrollPostingFailed = false
        thumbwheelPostingFailed = false
        if isLoading, initialConfigurationLoadPending {
            _ = advanceLifecycleIntent()
            return
        }
        guard canDiscover else { return }
        let intent = beginDiscovery()
        Task { @MainActor [weak self] in
            guard let self,
                  self.lifecycleIntent == intent,
                  self.discoveryPending,
                  !self.isRestarting,
                  self.canStartDiscovery else { return }
            await self.bolt.discover()
            guard self.lifecycleIntent == intent else { return }
            self.discoveryPending = false
            self.requestReconciliation()
        }
    }

    func disconnect() {
        prepareForLifecycleStop()
        let restore = restorePreviousSettingsOnDisconnect
        Task { await bolt.stop(restorePreviousSettingsOnDisconnect: restore) }
    }

    func requestEnableConfirmation() {
        guard canEnableBindings else { return }
        isEnableConfirmationPresented = true
    }

    func setRestarting(_ restarting: Bool) {
        isRestarting = restarting
        if restarting {
            cancelRecording()
            prepareForLifecycleStop()
            isEnableConfirmationPresented = false
            isReloadConfirmationPresented = false
        } else if let deferredInitialConfigurationLoad {
            self.deferredInitialConfigurationLoad = nil
            applyInitialConfiguration(deferredInitialConfigurationLoad, startupIntent: nil)
        }
    }

    func confirmEnableBindings() {
        isEnableConfirmationPresented = false
        guard canEnableBindings, refreshPermission() == .granted else { return }
        if !sessionActivationRequested {
            attemptedButtonState = nil
            attemptedWheelRequest = nil
        }
        sessionActivationRequested = true
        requestReconciliation()
    }

    func refreshPermission(retryScrollCapture: Bool = false) -> InputPermission {
        if retryScrollCapture {
            scrollPostingFailed = false
            thumbwheelPostingFailed = false
        }
        let permission = sender.refreshPermission()
        permissionChecks = sender.permissionChecks
        refreshDeliveryAdmission()
        requestReconciliation()
        return permission
    }

    func requestPermission() -> InputPermission {
        scrollPostingFailed = false
        thumbwheelPostingFailed = false
        let permission = sender.requestPermission()
        permissionChecks = sender.permissionChecks
        refreshDeliveryAdmission()
        requestReconciliation()
        return permission
    }

    func setWheelPreference(_ inverted: Bool?) {
        guard canEditConfiguration else { return }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        configuration.devices[index].wheelInverted = inverted
        updateDraft(configuration)
    }

    func setWheelScrollAmount(_ amount: Double?) {
        guard canEditConfiguration else { return }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        if amount != nil && configuration.devices[index].wheelScrollAmount == nil { scrollPostingFailed = false }
        configuration.devices[index].wheelScrollAmount = amount
        updateDraft(configuration)
    }

    func setThumbwheelPreference(_ inverted: Bool?) {
        guard canEditConfiguration else { return }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        configuration.devices[index].thumbwheelInverted = inverted
        updateDraft(configuration)
    }

    func setThumbwheelScrollAmount(_ amount: Double?) {
        guard canEditConfiguration else { return }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        if amount != nil && configuration.devices[index].thumbwheelScrollAmount == nil {
            thumbwheelPostingFailed = false
        }
        configuration.devices[index].thumbwheelScrollAmount = amount
        updateDraft(configuration)
    }

    func setWheelHighResolution(_ highResolution: Bool?) {
        guard canEditConfiguration else { return }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        configuration.devices[index].wheelHighResolution = highResolution
        updateDraft(configuration)
    }

    func setRestorePreviousSettingsOnDisconnect(_ enabled: Bool) {
        guard canEditConfiguration else { return }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }),
              configuration.devices[index].restorePreviousSettingsOnDisconnect != enabled else { return }
        configuration.devices[index].restorePreviousSettingsOnDisconnect = enabled
        updateDraft(configuration)
    }

    func setConnectOnLaunch(_ enabled: Bool) {
        guard !isRestarting else { return }
        if isLoading, initialConfigurationLoadPending {
            deferredConnectOnLaunchValue = enabled
            if !enabled { _ = advanceLifecycleIntent() }
            return
        }
        guard canEditConfiguration else { return }
        var configuration = document.draft
        guard configuration.connectOnLaunch != enabled else { return }
        configuration.connectOnLaunch = enabled
        updateDraft(configuration)
    }

    var canRefreshDeviceInformation: Bool {
        !isRestarting && !boltStatus.cleanupUncertain &&
            [.ready, .enabled].contains(boltStatus.phase) &&
            !boltStatus.deviceInformation.isRefreshing
    }

    func refreshDeviceInformation() {
        guard canRefreshDeviceInformation else { return }
        Task { await bolt.refreshDeviceInformation() }
    }

    func setLowBatteryNotificationsEnabled(_ enabled: Bool) {
        guard canEditConfiguration, !isRestarting, let notifications = lowBatteryNotifications else { return }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        configuration.devices[index].lowBatteryNotificationsEnabled = enabled
        updateDraft(configuration)
        Task { [weak self] in
            await notifications.setEnabled(enabled)
            self?.updateLowBatteryObservation()
        }
    }

    private func synchronizeLowBatteryPreference() {
        guard let notifications = lowBatteryNotifications else { return }
        notifications.synchronizeEnabled(hasUsableConfiguration && !configurationLoadFailed &&
            document.draft.mouse?.lowBatteryNotificationsEnabled == true)
    }

    private func refreshNotificationAuthorization() {
        guard let notifications = lowBatteryNotifications else { return }
        Task { [weak self] in
            await notifications.refreshAuthorization()
            self?.updateLowBatteryObservation()
        }
    }

    func refreshLowBatteryNotificationPermission() {
        refreshNotificationAuthorization()
    }

    private func updateLowBatteryObservation() {
        guard let notifications = lowBatteryNotifications else { return }
        let information = boltStatus.deviceInformation
        let battery = information.battery
        let fresh = [.ready, .enabled].contains(boltStatus.phase) && information.batteryState == .available &&
            battery.map { (0...300).contains(Date.now.timeIntervalSince($0.observedAt)) } == true
        let charging: Bool? = switch battery?.charging {
        case .discharging: false
        case .charging, .slowCharging, .complete: true
        default: nil
        }
        Task {
            await notifications.observe(percentage: battery?.percentage, charging: charging, isFresh: fresh)
        }
    }

    func applySavedWheelPreference() {
        guard canApplyWheelPreference else { return }
        sessionActivationRequested = true
        attemptedWheelRequest = nil
        isWheelApplyPending = document.draft.mouse?.wheelInverted != nil || wheelHighResolutionDraft != nil || boltStatus.wheel.isOwned
        requestReconciliation()
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
        captureSessionID = UUID()
        recordingTarget = ShortcutRecordingTarget(control: control, applicationID: applicationID)
        refreshDeliveryAdmission()
    }

    func selectApplication(_ applicationID: String?) {
        guard applicationID.map(applicationIDs.contains) ?? true else { return }
        if recordingTarget?.applicationID != applicationID { cancelRecording() }
        var location = navigation.current
        location.applicationID = applicationID
        var next = navigation
        next.navigate(to: location)
        navigation = next
    }

    func selectControl(_ control: MouseControl) {
        selectTarget(control == .back ? .back : .forward)
    }

    var selectedTarget: DeviceEditorTarget { navigation.current.target }

    func selectTarget(_ target: DeviceEditorTarget) {
        guard selectedTarget != target else { return }
        cancelRecording()
        var location = navigation.current
        location.target = target
        if let control = target.control { location.control = control }
        var next = navigation
        next.navigate(to: location)
        navigation = next
    }

    func completeRecording(_ shortcut: KeyboardShortcut) {
        guard canEditConfiguration, let target = recordingTarget else { return }
        setBinding(.key(shortcut), for: target.control, applicationID: target.applicationID)
        cancelRecording()
    }

    func completeRecording(_ shortcut: KeyboardShortcut, sessionID: UUID) {
        guard captureSessionID == sessionID else { return }
        completeRecording(shortcut)
    }

    func cancelRecording() {
        recordingTarget = nil
        captureSessionID = nil
        refreshDeliveryAdmission()
    }

    func cancelRecording(sessionID: UUID) {
        guard captureSessionID == sessionID else { return }
        cancelRecording()
    }

    func openPermissions() {
        selectedSettingsCategory = .permissions
        settingsScrollRequestID = UUID()
        navigate(to: .settings)
    }

    func addApplication(at url: URL) {
        guard canEditConfiguration else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let applicationID = Bundle(url: url)?.bundleIdentifier, !applicationID.isEmpty else {
            setError(
                "The selected application does not have a bundle identifier.",
                code: .configurationValidationFailed,
                diagnosticMessage: "Application override could not be added."
            )
            return
        }

        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        if configuration.devices[index].applications[applicationID] == nil {
            guard configuration.devices[index].applications.count < 128 else {
                setError(
                    "A maximum of 128 application overrides is supported.",
                    code: .configurationValidationFailed,
                    diagnosticMessage: "Application override limit reached."
                )
                return
            }
            configuration.devices[index].applications[applicationID] = [:]
            updateDraft(configuration)
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
        if recordingTarget?.applicationID == applicationID { cancelRecording() }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        configuration.devices[index].applications.removeValue(forKey: applicationID)
        updateDraft(configuration)
        var location = navigation.current
        location.applicationID = nil
        var next = navigation
        next.replaceCurrent(with: location)
        navigation = next
    }

    func updateDraft(_ configuration: AppConfiguration) {
        guard canEditConfiguration else { return }
        do {
            let validated = try configuration.validated()
            guard document.draft != validated else { return }
            if document.draft.mouse?.wheelInverted != validated.mouse?.wheelInverted ||
                document.draft.mouse?.wheelHighResolution != validated.mouse?.wheelHighResolution ||
                (document.draft.mouse?.wheelScrollAmount != nil && validated.mouse?.wheelScrollAmount == nil) {
                bolt.suspendScrollAdmission()
                scrollSender.reset()
                attemptedWheelRequest = nil
            }
            if document.draft.mouse?.thumbwheelInverted != validated.mouse?.thumbwheelInverted ||
                document.draft.mouse?.thumbwheelScrollAmount != validated.mouse?.thumbwheelScrollAmount {
                bolt.suspendThumbwheelAdmission()
                thumbwheelScrollSender.reset()
                attemptedThumbwheelRequest = nil
            }
            document.updateDraft(validated)
            synchronizeLowBatteryPreference()
            scheduleAutosave()
            refreshDeliveryAdmission()
            requestReconciliation()
        } catch {
            setError(
                error.localizedDescription,
                code: .configurationValidationFailed,
                diagnosticMessage: "Configuration edit could not be validated."
            )
        }
    }

    func save() async {
        guard !isRestarting else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        _ = await persistPendingConfiguration()
    }

    @discardableResult
    func flushPendingSave() async -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        repeat {
            guard await persistPendingConfiguration() else { return false }
        } while isDirty
        autosaveTask?.cancel()
        autosaveTask = nil
        return true
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.autosaveTask = nil
            _ = await self.persistPendingConfiguration()
        }
    }

    private func persistPendingConfiguration() async -> Bool {
        if let saveTask { return await saveTask.value }
        guard !isLoading, !initialConfigurationLoadPending, !configurationLoadFailed else { return !isDirty }
        guard isDirty || !fileRevision.exists else { return true }
        let submittedConfiguration = document.draft
        let revision = fileRevision
        isSaving = true
        let task = Task { @MainActor [self] in
            defer {
                isSaving = false
                saveTask = nil
            }
            do {
                let snapshot = try await store.save(submittedConfiguration, expecting: revision)
                fileRevision = snapshot.revision
                document.acceptSaved(snapshot.configuration)
                configurationSaveError = nil
                configurationFailureKind = nil
                return true
            } catch {
                configurationSaveError = error.localizedDescription
                configurationFailureKind = (error as? ConfigurationError) == .revisionConflict ? .conflict : .save
                setError(
                    "Could not save configuration: \(error.localizedDescription)",
                    code: .configurationSaveFailed,
                    diagnosticMessage: "Configuration could not be saved."
                )
                return false
            }
        }
        saveTask = task
        let saved = await task.value
        if saved && isDirty && autosaveTask == nil { scheduleAutosave() }
        return saved
    }

    func requestReload() {
        guard canReloadConfiguration else { return }
        cancelRecording()
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDirty else {
            startReload()
            return
        }
        isReloadConfirmationPresented = true
    }

    func confirmDiscardAndReload() {
        isReloadConfirmationPresented = false
        guard canReloadConfiguration else { return }
        startReload()
    }

    func cancelReload() {
        isReloadConfirmationPresented = false
        if isDirty { scheduleAutosave() }
    }

    func dismissError() {
        errorMessage = nil
    }

    func reportError(_ message: String, fileID: String = #fileID, line: UInt = #line) {
        reportError(
            message,
            code: .applicationError,
            diagnosticMessage: "An operation failed. See the error shown by Hidhogg.",
            fileID: fileID,
            line: line
        )
    }

    func reportError(
        _ message: String,
        code: DiagnosticCode,
        diagnosticMessage: String,
        fileID: String = #fileID,
        line: UInt = #line
    ) {
        setError(
            message,
            code: code,
            diagnosticMessage: diagnosticMessage,
            fileID: fileID,
            line: line
        )
    }

    private func setError(
        _ message: String,
        code: DiagnosticCode,
        diagnosticMessage: String,
        fileID: String = #fileID,
        line: UInt = #line
    ) {
        errorMessage = message
        diagnosticEvent = DiagnosticEvent(
            code: code,
            message: diagnosticMessage,
            isError: true,
            fileID: fileID,
            line: line
        )
    }

    private func recordDiagnostic(
        code: DiagnosticCode,
        message: String,
        isError: Bool = false,
        fileID: String = #fileID,
        line: UInt = #line
    ) {
        diagnosticEvent = DiagnosticEvent(code: code, message: message, isError: isError, fileID: fileID, line: line)
    }

    func stopForSleep() async {
        await stopControllerSession()
    }

    func systemWillSleep() {
        guard !wakeRecovery.sleeping else { return }
        let reconnect = sessionActivationRequested && !isRestarting && !boltStatus.cleanupUncertain && [.ready, .enabled].contains(boltStatus.phase)
        prepareForLifecycleStop()
        sleepCleanupSequence = statusSequence
        let previous = sleepCleanupTask
        let restore = restorePreviousSettingsOnDisconnect
        let cleanup = Task { [bolt] in
            if let previous { _ = await previous.value }
            return await bolt.stopForRestart(restorePreviousSettingsOnDisconnect: restore)
        }
        sleepCleanupTask = cleanup
        wakeRecovery.sleep(reconnect: reconnect) { await cleanup.value }
    }

    func systemDidWake() {
        wakeRecovery.wake { [weak self] in
            guard let self else { return .stop }
            return await self.discoverAfterWake()
        }
    }

    @discardableResult
    func stopForTermination() async -> Bool {
        cancelRecording()
        prepareForLifecycleStop()
        let saved = await flushPendingSave()
        await bolt.stop(restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
        return saved
    }

    func stopForRestart() async -> Bool {
        cancelRecording()
        prepareForLifecycleStop()
        let saved = await flushPendingSave()
        let cleaned = await bolt.stopForRestart(restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
        return saved && cleaned
    }

    func prepareForLifecycleStop() {
        cancelWakeRecovery()
        invalidateLifecycleIntent()
        reconciliationRequested = false
        isWheelApplyPending = false
        isThumbwheelApplyPending = false
        isEnableConfirmationPresented = false
        actionsEnabled = false
        deliveryGeneration = nil
    }

    private func stopControllerSession() async {
        prepareForLifecycleStop()
        await bolt.stop(restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
    }

    private func loadInitialConfiguration(startupIntent: UInt64) async {
        let result: InitialConfigurationLoad
        do {
            let snapshot = try await store.load()
            result = .success(snapshot)
        } catch {
            result = .failure(error.localizedDescription)
        }

        guard !isRestarting else {
            deferredInitialConfigurationLoad = result
            isLoading = false
            return
        }
        applyInitialConfiguration(result, startupIntent: startupIntent)
    }

    private func applyInitialConfiguration(_ result: InitialConfigurationLoad, startupIntent: UInt64?) {
        let loadedConfiguration: AppConfiguration?
        switch result {
        case .success(let snapshot):
            fileRevision = snapshot.revision
            document.acceptReload(snapshot.configuration)
            configurationLoadFailed = false
            configurationLoadError = nil
            configurationFailureKind = nil
            hasUsableConfiguration = true
            loadedConfiguration = snapshot.configuration
        case .failure(let message):
            setError(
                message,
                code: .configurationLoadFailed,
                diagnosticMessage: "Configuration could not be loaded."
            )
            configurationLoadFailed = true
            configurationLoadError = message
            configurationFailureKind = .load
            hasUsableConfiguration = false
            loadedConfiguration = nil
        }

        isLoading = false
        initialConfigurationLoadPending = false
        synchronizeLowBatteryPreference()
        refreshNotificationAuthorization()

        if let deferredConnectOnLaunchValue {
            self.deferredConnectOnLaunchValue = nil
            if loadedConfiguration != nil { setConnectOnLaunch(deferredConnectOnLaunchValue) }
        }

        guard !startupConnectionDecisionConsumed else { return }
        startupConnectionDecisionConsumed = true
        guard !isRestarting,
              let startupIntent,
              lifecycleIntent == startupIntent,
              loadedConfiguration?.connectOnLaunch == true else { return }
        connect()
    }

    private func reloadFromDisk() async {
        guard !isRestarting, isLoading, !isSaving else { return }
        errorMessage = nil
        do {
            let snapshot = try await store.load()
            guard !isRestarting else {
                isLoading = false
                return
            }
            fileRevision = snapshot.revision
            document.acceptReload(snapshot.configuration)
            configurationSaveError = nil
            configurationFailureKind = nil
            configurationLoadFailed = false
            configurationLoadError = nil
            hasUsableConfiguration = true
            cancelRecording()
            synchronizeLowBatteryPreference()
            refreshNotificationAuthorization()
            if let selectedApplicationID, !applicationIDs.contains(selectedApplicationID) {
                var location = navigation.current
                location.applicationID = nil
                var next = navigation
                next.replaceCurrent(with: location)
                navigation = next
            }
        } catch {
            guard !isRestarting else {
                isLoading = false
                return
            }
            setError(
                error.localizedDescription,
                code: .configurationLoadFailed,
                diagnosticMessage: "Configuration could not be loaded."
            )
            configurationLoadFailed = true
            configurationLoadError = error.localizedDescription
            configurationFailureKind = .load
            synchronizeLowBatteryPreference()
        }
        isLoading = false
        refreshDeliveryAdmission()
        requestReconciliation()
    }

    private func startReload() {
        guard canReloadConfiguration else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        isLoading = true
        isEnableConfirmationPresented = false
        refreshDeliveryAdmission()
        Task { await reloadFromDisk() }
    }

    var canEditConfiguration: Bool { !isRestarting && !isLoading && !configurationLoadFailed }
    private var canStartWheelApply: Bool {
        !isRestarting && !isLoading && hasUsableConfiguration &&
            [.ready, .enabled].contains(boltStatus.phase) &&
            !boltStatus.cleanupUncertain && boltStatus.wheel.support == .supported &&
            !boltStatus.wheel.isApplying && (try? document.draft.validated()) != nil
    }

    private var hasConfiguredShortcut: Bool {
        guard let mouse = document.draft.mouse else { return false }
        return (Array(mouse.defaults.values) + mouse.applications.values.flatMap { $0.values })
            .contains { $0.kind == .shortcut }
    }

    private var shouldEnableButtons: Bool {
        sessionActivationRequested && !isRestarting && !isLoading && hasUsableConfiguration &&
            permission == .granted && hasConfiguredShortcut &&
            boltStatus.availableControls == Set(MouseControl.allCases)
    }

    private func refreshDeliveryAdmission() {
        if permission != .granted || !sessionActivationRequested || isRestarting {
            bolt.invalidateScrollAdmission()
            scrollSender.reset()
            bolt.invalidateThumbwheelAdmission()
            thumbwheelScrollSender.reset()
        }
        actionsEnabled = shouldEnableButtons && boltStatus.phase == .enabled && recordingTarget == nil
        deliveryGeneration = actionsEnabled ? boltStatus.generation : nil
    }

    private func requestReconciliation() {
        reconciliationRequested = true
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileSession()
            self.reconciliationTask = nil
            if self.reconciliationRequested { self.requestReconciliation() }
        }
    }

    private func reconcileSession() async {
        while reconciliationRequested {
            reconciliationRequested = false
            guard sessionActivationRequested, !isRestarting, !isLoading, hasUsableConfiguration,
                  !discoveryPending, [.ready, .enabled].contains(boltStatus.phase),
                  !boltStatus.cleanupUncertain else { continue }
            let intent = lifecycleIntent
            let wheel = WheelRequest(
                inverted: document.draft.mouse?.wheelInverted,
                highResolution: wheelHighResolutionDraft,
                amount: wheelScrollAmountDraft,
                postingAllowed: !scrollReleasePending && !scrollPostingFailed && permission == .granted && (wheelScrollAmountDraft == nil || scrollSender.canPostEvents()),
                restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect
            )
            if attemptedWheelRequest != wheel {
                let previous = attemptedWheelRequest
                attemptedWheelRequest = wheel
                if boltStatus.wheel.support == .supported &&
                    (wheel.inverted != nil || wheel.highResolution != nil || wheel.amount != nil || previous?.amount != nil || boltStatus.wheel.isOwned ||
                     previous?.inverted != nil || previous?.highResolution != nil ||
                     wheel.restorePreviousSettingsOnDisconnect || previous?.restorePreviousSettingsOnDisconnect == true) {
                    isWheelApplyPending = true
                    await bolt.applyWheelPreferences(
                        inverted: wheel.inverted,
                        highResolution: wheel.highResolution,
                        restorePreviousSettingsOnDisconnect: wheel.restorePreviousSettingsOnDisconnect,
                        amount: wheel.amount,
                        scrollPostingAllowed: wheel.postingAllowed
                    )
                    if !wheel.postingAllowed { scrollReleasePending = false }
                    guard lifecycleIntent == intent else { continue }
                    isWheelApplyPending = false
                    reconciliationRequested = true
                    continue
                }
            }
            let thumbwheel = ThumbwheelRequest(
                inverted: thumbwheelPreferenceDraft,
                amount: thumbwheelScrollAmountDraft,
                postingAllowed: !thumbwheelReleasePending && !thumbwheelPostingFailed && permission == .granted &&
                    (thumbwheelScrollAmountDraft == nil || thumbwheelScrollSender.canPostEvents()),
                restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect
            )
            if attemptedThumbwheelRequest != thumbwheel {
                let previous = attemptedThumbwheelRequest
                attemptedThumbwheelRequest = thumbwheel
                let hasIntent = thumbwheel.inverted != nil || thumbwheel.amount != nil ||
                    previous?.inverted != nil || previous?.amount != nil || boltStatus.thumbwheel.isOwned ||
                    thumbwheel.restorePreviousSettingsOnDisconnect || previous?.restorePreviousSettingsOnDisconnect == true
                let hasConfiguredValue = thumbwheel.inverted != nil || thumbwheel.amount != nil
                let canApply = boltStatus.thumbwheel.support == .supported ||
                    (boltStatus.thumbwheel.support == .unknown && hasConfiguredValue)
                if hasIntent && canApply {
                    isThumbwheelApplyPending = true
                    await bolt.applyThumbwheelPreferences(
                        inverted: thumbwheel.inverted,
                        amount: thumbwheel.amount,
                        restorePreviousSettingsOnDisconnect: thumbwheel.restorePreviousSettingsOnDisconnect,
                        scrollPostingAllowed: thumbwheel.postingAllowed
                    )
                    if !thumbwheel.postingAllowed { thumbwheelReleasePending = false }
                    guard lifecycleIntent == intent else { continue }
                    isThumbwheelApplyPending = false
                    reconciliationRequested = true
                    continue
                }
            }
            let enabled = shouldEnableButtons
            guard attemptedButtonState != enabled else { continue }
            if enabled && boltStatus.phase == .ready {
                attemptedButtonState = enabled
                await bolt.enable()
            } else if !enabled && [.enabling, .enabled].contains(boltStatus.phase) {
                attemptedButtonState = enabled
                await bolt.disable()
            }
            guard lifecycleIntent == intent else { continue }
            refreshDeliveryAdmission()
        }
    }

    private var canStartDiscovery: Bool {
        !boltStatus.cleanupUncertain && [.idle, .ready, .failed].contains(boltStatus.phase)
    }

    private func beginDiscovery() -> UInt64 {
        scrollPostingFailed = false
        thumbwheelPostingFailed = false
        _ = refreshPermission()
        let intent = advanceLifecycleIntent()
        discoveryPending = true
        sessionActivationRequested = true
        attemptedWheelRequest = nil
        attemptedThumbwheelRequest = nil
        attemptedButtonState = nil
        actionsEnabled = false
        deliveryGeneration = nil
        return intent
    }

    private func discoverAfterWake() async -> WakeRecoveryCoordinator.Outcome {
        if sleepCleanupTask != nil {
            let cleanupIntent = lifecycleIntent
            let status = await waitForWakeStatus(after: sleepCleanupSequence, matching: { [.idle, .failed].contains($0.phase) })
            guard !Task.isCancelled, lifecycleIntent == cleanupIntent,
                  status?.phase == .idle, status?.cleanupUncertain == false else { return .stop }
            sleepCleanupTask = nil
        }
        guard !Task.isCancelled, canDiscover else { return .stop }
        let intent = beginDiscovery()
        let sequence = statusSequence
        await bolt.discover()
        guard lifecycleIntent == intent else { return .stop }
        let status = await waitForWakeStatus(after: sequence, matching: { [.ready, .failed, .idle].contains($0.phase) })
        guard lifecycleIntent == intent else { return .stop }
        discoveryPending = false
        guard let status else {
            invalidateLifecycleIntent()
            return .stop
        }
        requestReconciliation()
        guard !Task.isCancelled, !status.cleanupUncertain else { return .stop }
        if status.phase == .ready { return .connected }
        guard status.phase == .failed, let failure = status.failure else { return .stop }
        switch failure.code {
        case .endpointUnavailable, .requestTimeout, .disconnected, .transportFailed: return .retry
        default: return .stop
        }
    }

    private func cancelWakeRecovery() {
        wakeRecovery.cancel()
        finishWakeStatusWait(returning: nil)
    }

    private func waitForWakeStatus(
        after sequence: UInt64,
        matching matches: @escaping @MainActor (BoltStatus) -> Bool
    ) async -> BoltStatus? {
        guard !Task.isCancelled else { return nil }
        if statusSequence > sequence, matches(boltStatus) { return boltStatus }
        finishWakeStatusWait(returning: nil)
        return await withCheckedContinuation { continuation in
            let id = UUID()
            let timeout = Task { @MainActor [weak self, wakeStatusTimeout] in
                do { try await wakeStatusTimeout(.seconds(2)) } catch { return }
                guard let self, self.wakeStatusWait?.id == id else { return }
                self.finishWakeStatusWait(returning: nil)
            }
            wakeStatusWait = WakeStatusWait(id: id, matches: matches, continuation: continuation, timeout: timeout)
        }
    }

    private func finishWakeStatusWait(returning status: BoltStatus?) {
        let wait = wakeStatusWait
        wakeStatusWait = nil
        wait?.timeout.cancel()
        wait?.continuation.resume(returning: status)
    }

    private func advanceLifecycleIntent() -> UInt64 {
        lifecycleIntent &+= 1
        discoveryPending = false
        return lifecycleIntent
    }

    private func invalidateLifecycleIntent() {
        bolt.invalidateScrollAdmission()
        scrollSender.reset()
        bolt.invalidateThumbwheelAdmission()
        thumbwheelScrollSender.reset()
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
            statusSequence &+= 1
            boltStatus = status
            if [.idle, .failed, .discovering].contains(status.phase) {
                informationRequestedForConnection = false
            }
            if [.ready, .enabled].contains(status.phase), !informationRequestedForConnection {
                informationRequestedForConnection = true
                refreshDeviceInformation()
            }
            updateLowBatteryObservation()
            if let wait = wakeStatusWait, wait.matches(status) {
                finishWakeStatusWait(returning: status)
            }
            if status.phase == .idle || status.phase == .failed {
                if !discoveryPending { sessionActivationRequested = false }
            }
            refreshDeliveryAdmission()
            requestReconciliation()
        case .scroll(let vertical, let horizontal, let generation, let observedAt):
            deliverScroll(vertical: vertical, horizontal: horizontal, generation: generation, observedAt: observedAt)
        case .thumbwheel(let rotation, let state, let generation, let observedAt):
            deliverThumbwheel(rotation: rotation, state: state, generation: generation, observedAt: observedAt)
        case .press(let control, let generation, let observedAt):
            deliver(control: control, generation: generation, observedAt: observedAt)
        }
    }

    private func deliverScroll(vertical: Double, horizontal: Double, generation: UInt64, observedAt: ContinuousClock.Instant) {
        guard sessionActivationRequested, !isRestarting,
              [.ready, .enabling, .enabled].contains(boltStatus.phase), permission == .granted,
              let amount = wheelScrollAmountDraft else { return }
        var deliveryError: Error?
        let admitted = bolt.withScrollAdmission(generation: generation, observedAt: observedAt) {
            do {
                try scrollSender.send(vertical: vertical, horizontal: horizontal, amount: amount,
                                      generation: generation, observedAt: observedAt)
            } catch { deliveryError = error }
        }
        guard admitted, let deliveryError else { return }
        bolt.invalidateScrollAdmission()
        scrollPostingFailed = true
        scrollReleasePending = true
        scrollSender.reset()
        setError(
            deliveryError.localizedDescription,
            code: .scrollDeliveryFailed,
            diagnosticMessage: "Scroll input delivery failed."
        )
        permissionChecks = sender.permissionChecks
        if !scrollSender.canPostEvents() {
            permissionChecks = PermissionChecks(accessibilityTrusted: permissionChecks.accessibilityTrusted, eventPostingAllowed: false)
        }
        attemptedWheelRequest = nil
        requestReconciliation()
    }

    private func deliverThumbwheel(rotation: Double, state: UInt8, generation: UInt64, observedAt: ContinuousClock.Instant) {
        guard sessionActivationRequested, !isRestarting,
              [.ready, .enabling, .enabled].contains(boltStatus.phase), permission == .granted,
              let amount = thumbwheelScrollAmountDraft else { return }
        var deliveryError: Error?
        let admitted = bolt.withThumbwheelAdmission(generation: generation, observedAt: observedAt) {
            do {
                try thumbwheelScrollSender.send(vertical: 0, horizontal: rotation, amount: amount,
                                                amountAxis: .horizontal, generation: generation,
                                                observedAt: observedAt, resetFractionsBefore: state == 1,
                                                resetFractionsAfter: state == 3)
            } catch { deliveryError = error }
        }
        guard admitted, let deliveryError else { return }
        bolt.invalidateThumbwheelAdmission()
        thumbwheelPostingFailed = true
        thumbwheelReleasePending = true
        thumbwheelScrollSender.reset()
        setError(
            deliveryError.localizedDescription,
            code: .thumbwheelDeliveryFailed,
            diagnosticMessage: "Thumb-wheel input delivery failed."
        )
        permissionChecks = sender.permissionChecks
        if !thumbwheelScrollSender.canPostEvents() {
            permissionChecks = PermissionChecks(accessibilityTrusted: permissionChecks.accessibilityTrusted, eventPostingAllowed: false)
        }
        attemptedThumbwheelRequest = nil
        requestReconciliation()
    }

    private func deliver(control: MouseControl, generation: UInt64, observedAt: ContinuousClock.Instant) {
        guard actionsEnabled,
              deliveryGeneration == generation,
              boltStatus.phase == .enabled,
              boltStatus.generation == generation,
              permission == .granted,
              recordingTarget == nil else { return }

        let applicationID = frontmostApplication()
        let binding = document.draft.mouse?.binding(for: control, application: applicationID) ?? .disabled
        guard binding.kind == .shortcut, let shortcut = binding.shortcut else { return }

        var deliveryError: Error?
        let admitted = bolt.withPressAdmission(generation: generation, observedAt: observedAt) {
            do {
                try sender.send(shortcut)
                let message = "Posted \(ShortcutSender.label(for: shortcut)). The receiving app decides whether to respond."
                let shouldRecord = lastActionMessage != message
                lastActionMessage = message
                if shouldRecord { recordDiagnostic(code: .keyboardDeliverySucceeded, message: "Shortcut posted to macOS.") }
            } catch {
                deliveryError = error
            }
        }
        guard admitted else { return }
        permissionChecks = sender.permissionChecks
        guard let deliveryError else { return }
        let message = deliveryError.localizedDescription
        let shouldRecord = lastActionMessage != message
        lastActionMessage = message
        if shouldRecord { recordDiagnostic(code: .keyboardDeliveryFailed, message: "Shortcut delivery failed.", isError: true) }
        if !permissionChecks.eventPostingAllowed {
            refreshDeliveryAdmission()
            requestReconciliation()
        }
    }

    private func cancelRecording(for control: MouseControl, applicationID: String?) {
        guard recordingTarget == ShortcutRecordingTarget(control: control, applicationID: applicationID) else { return }
        cancelRecording()
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
            configuration.devices[index].applications[applicationID] = overrides
        } else if let binding {
            configuration.devices[index].defaults[control.rawValue] = binding
        }
        updateDraft(configuration)
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
