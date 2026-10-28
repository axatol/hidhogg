import AppKit
import Combine
import Foundation
import HidhoggDomain
import HidhoggAutomation
import MacOSActions
import UlanziD200X

@MainActor
final class D200XModel: ObservableObject {
    @Published private(set) var configuration: D200XConfiguration?
    @Published private(set) var status: D200XStatus = .disconnected
    @Published private(set) var canEdit = false
    @Published private(set) var configurationBlocker: String?
    @Published private(set) var message = "Disconnected. Connect to discover D200X."
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastActionMessage: String?
    @Published var selectedControl: D200XControl = .key0
    @Published var applicationID: String?
    @Published private(set) var activeApplicationID: String?
    @Published private(set) var brightnessMessage: String?
    @Published private(set) var wideDisplayMessage: String?
    @Published private(set) var displayMetrics = D200XMetricsSnapshot()
    @Published private(set) var screensaverMessage: String?
    @Published private(set) var isApplyingScreensaver = false
    @Published private(set) var isPreviewingScreensaver = false
    let screensaverPreviewStore = D200XScreensaverPreviewStore()
    private var screensaverRevision: UInt64 = 0
    private var screensaverTimer: Task<Void, Never>?
    private var screensaverMaintenancePaused = false
    private var screensaverNeedsPageRestore = false
    private var screensaverLocked = false
    private var screensaverRestoreAfterUnlock = false
    private var screensaverLockObservations: [AnyCancellable] = []
    private let screensaverDelay: @Sendable (Duration) async throws -> Void
    private var displayTask: Task<Void, Never>?
    private var displayRevision: UInt64 = 0
    private var lastWideMode: Int?
    private var lastWideNotification = false
    private let sampleMetrics: @MainActor () -> D200XMetricsSnapshot
    private let displayNow: @MainActor () -> Date
    private let displayDelay: @Sendable (Duration) async throws -> Void
    private let iconResolver: any D200XApplicationIconResolving
    private(set) var assetDirectory: URL?
    private let configuredActionRunner: ConfiguredActionRunner
    private let nativeRuntime: AppNativeActionRunner
    private lazy var automation = D200XAutomationCoordinator(model: self, runner: configuredActionRunner, iconResolver: iconResolver)
    private var automationObservation: AnyCancellable?
    private var foregroundObservation: AnyCancellable?
    private var brightnessTask: Task<Void, Never>?
    private var brightnessRevision: UInt64 = 0
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleRevision: UInt64 = 0
    private var systemSleeping = false
    private var lifecycleTransitionPending = false
    private var wakeRestorePending = false
    private var sleepSettingsPending = false
    private var automationStarted = false

    var notificationHistory: [NotificationHistoryEntry] { automation.notificationHistory }
    var notificationLabels: [String: String] { automation.labels }
    var notificationIcons: [String: Data] { automation.iconOverrides }
    var actionHistory: [ConfiguredActionRecord] { automation.actionHistory }
    var automationMessage: String? { automation.message }
    var isListening: Bool { automation.isListening }
    var liveNotifications: [LiveNotificationEvent] { automation.liveNotifications }
    var notificationTopics: [String] { configuration?.topics(for: selectedControl, application: applicationID) ?? [] }
    var runtimeConfiguration: D200XConfiguration? { configuration?.resolved(application: activeApplicationID) }
    var editingConfiguration: D200XConfiguration? { configuration?.resolved(application: applicationID) }
    var activeProfileName: String {
        guard let activeApplicationID, configuration?.applicationIDs.contains(activeApplicationID) == true else { return "Default" }
        return activeApplicationID
    }
    var actionSessionEpoch: UInt64 { epoch }
    var canRunConfiguredActions: Bool {
        canEdit && !suspended && !systemSleeping && !lifecycleTransitionPending && configuration != nil
    }
    var canDeliverNotification: Bool { canRunConfiguredActions && wanted && isConnected }

    var onEdit: ((D200XConfiguration) -> Void)?
    var onDiagnostic: ((DiagnosticEvent) -> Void)?
    private let session: (any D200XSessionProtocol)?
    private let sender: ShortcutSender
    private let frontmostApplication: @MainActor () -> String?
    private let delay: @Sendable (Duration) async throws -> Void
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var wanted = false
    private var suspended = false
    private var generation: UInt64 = 0
    private var epoch: UInt64 = 0
    private var renderRevision: UInt64 = 0
    private var retryCount = 0
    private var pressed: Set<UInt8> = []
    private var lastPage: D200XPage?
    private enum PageWriteOutcome: Equatable { case rejected, unchanged, written }
    private enum DevicePowerTransition { case sleep, wake }
    private var pageOperation: Task<PageWriteOutcome, Error>?
    private var pageOperationID: UUID?

    init(session: (any D200XSessionProtocol)? = nil, sender: ShortcutSender,
         frontmostApplication: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         actionRunner: ConfiguredActionRunner? = nil, nativePlatform: (any NativeActionPerforming)? = nil,
         sampleMetrics: (@MainActor () -> D200XMetricsSnapshot)? = nil,
         displayNow: @escaping @MainActor () -> Date = Date.init,
         displayDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         iconResolver: any D200XApplicationIconResolving = D200XApplicationIconResolver(),
         observeScreenLock: Bool = false,
         screensaverDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.screensaverDelay = screensaverDelay
        self.session = session
        self.sender = sender
        self.frontmostApplication = frontmostApplication
        self.delay = delay
        let hostMetrics = D200XHostMetrics()
        self.sampleMetrics = sampleMetrics ?? { hostMetrics.sample() }
        self.displayNow = displayNow
        self.displayDelay = displayDelay
        self.iconResolver = iconResolver
        let nativeRuntime = AppNativeActionRunner(platform: nativePlatform)
        self.nativeRuntime = nativeRuntime
        self.configuredActionRunner = actionRunner ?? ConfiguredActionRunner(nativeRunner: nativeRuntime)
        self.activeApplicationID = frontmostApplication()
        nativeRuntime.model = self
        automationObservation = automation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        foregroundObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshActiveApplication() }
            }
        if observeScreenLock {
            let center = DistributedNotificationCenter.default()
            screensaverLockObservations = [
                center.publisher(for: Notification.Name("com.apple.screenIsLocked")).sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.setScreensaverPreviewLocked(true) }
                },
                center.publisher(for: Notification.Name("com.apple.screenIsUnlocked")).sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.setScreensaverPreviewLocked(false) }
                }
            ]
        }
        if let session {
            eventTask = Task { [weak self] in
                for await event in session.events {
                    guard let self, !Task.isCancelled else { return }
                    self.receive(event)
                }
            }
        }
    }

    isolated deinit {
        eventTask?.cancel()
        connectionTask?.cancel()
        renderTask?.cancel()
        stopTask?.cancel()
        brightnessTask?.cancel()
        displayTask?.cancel()
        screensaverTimer?.cancel()
    }

    var isConfigured: Bool { configuration != nil }
    var isConnected: Bool { if case .connected = status { true } else { false } }
    var isBusy: Bool { if case .connecting = status { true } else if case .disconnecting = status { true } else { false } }
    var connectionTitle: String {
        switch status {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting"
        case .failed: "Failed"
        }
    }
    var applications: [String] { configuration?.applicationIDs ?? [] }
    var binding: D200XBinding { configuration?.binding(for: selectedControl, application: applicationID) ?? .disabled }
    var isInherited: Bool { applicationID.map { configuration?.applications[$0]?[selectedControl.rawValue] == nil } ?? false }
    var appearance: D200XTileAppearance {
        configuration?.appearance(for: selectedControl, application: applicationID) ?? D200XConfiguration.defaultAppearance(for: selectedControl)
    }
    func refreshActiveApplication() {
        let next = frontmostApplication()
        guard next != activeApplicationID else { return }
        let previousConfiguration = runtimeConfiguration
        let previousProfile = activeProfileName
        activeApplicationID = next
        pressed.removeAll()
        guard previousProfile != activeProfileName || previousConfiguration != runtimeConfiguration else { return }
        automation.reset()
        if isConnected { scheduleRender() }
    }
    var firmware: String? { if case .connected(let identity) = status { identity.firmware } else { nil } }

    func synchronize(_ configuration: D200XConfiguration?, canEdit: Bool, blocker: String? = nil) {
        let configurationChanged = runtimeConfiguration != configuration?.resolved(application: activeApplicationID)
        let brightnessChanged = self.configuration?.brightnessPercent != configuration?.brightnessPercent
        let displayChanged = self.configuration?.wideDisplayMode != configuration?.wideDisplayMode ||
            self.configuration?.clockFormat != configuration?.clockFormat
        if displayChanged { stopDisplayUpdates() }
        if configurationChanged { automation.reset() }
        self.configuration = configuration
        self.canEdit = canEdit
        configurationBlocker = blocker ?? (canEdit ? nil : "D200X configuration cannot be edited right now.")
        if configuration == nil, wanted { disconnect() }
        if configurationChanged, isConnected, canEdit { scheduleRender() }
        if brightnessChanged, isConnected, canEdit { scheduleBrightness() }
    }

    func enableConfiguration() {
        guard canEdit, configuration == nil else { return }
        onEdit?(.empty)
    }

    func setWideDisplayMode(_ mode: D200XWideDisplayMode) {
        guard canEdit, var next = configuration else { return }
        next.wideDisplayMode = mode
        onEdit?(next)
    }

    func setClockFormat(_ format: D200XClockFormat) {
        guard canEdit, var next = configuration else { return }
        next.clockFormat = format
        onEdit?(next)
    }

    func setScreensaverPreviewLocked(_ locked: Bool) {
        screensaverLocked = locked
        if locked {
            guard isPreviewingScreensaver || screensaverMaintenancePaused else { return }
            screensaverRestoreAfterUnlock = true
            invalidateScreensaverPreview()
            stopDisplayUpdates()
        } else if screensaverRestoreAfterUnlock {
            screensaverRestoreAfterUnlock = false
            finishScreensaverPreview()
        }
    }

    func holdScreensaverPreview() {
        screensaverRevision &+= 1
        screensaverTimer?.cancel()
        screensaverTimer = nil
    }

    func finishScreensaverPreview() {
        guard isPreviewingScreensaver || screensaverNeedsPageRestore else { return }
        invalidateScreensaverPreview()
        guard !screensaverLocked, canDeliverNotification else { return }
        lastPage = nil
        lastWideMode = nil
        scheduleRender()
    }

    private func invalidateScreensaverPreview() {
        if isPreviewingScreensaver || screensaverMaintenancePaused {
            lastPage = nil
            lastWideMode = nil
        }
        holdScreensaverPreview()
        isPreviewingScreensaver = false
        isApplyingScreensaver = false
    }

    func applyScreensaver(_ jpeg: Data, confirmedPersistentOverwrite: Bool) async throws {
        guard confirmedPersistentOverwrite, !screensaverLocked, canDeliverNotification, let session else { throw CancellationError() }
        let screensaver = D200XScreensaver(jpeg: jpeg)
        _ = try screensaver.archive()
        holdScreensaverPreview()
        let revision = screensaverRevision
        isPreviewingScreensaver = true
        screensaverNeedsPageRestore = true
        isApplyingScreensaver = true
        stopDisplayUpdates()
        let intent = epoch
        let previous = pageOperation
        let id = UUID()
        let operation = Task { @MainActor [weak self] () throws -> PageWriteOutcome in
            if let previous { _ = try? await previous.value }
            guard let self, self.screensaverIsCurrent(revision, intent: intent) else { return .rejected }
            self.screensaverMaintenancePaused = true
            try await session.setKeepAwakeEnabled(false)
            guard self.screensaverIsCurrent(revision, intent: intent) else { return .rejected }
            try await session.applyScreensaver(screensaver)
            self.screensaverPreviewStore.recordSent(jpeg)
            guard self.screensaverIsCurrent(revision, intent: intent) else { return .rejected }
            try await session.showScreensaver()
            guard self.screensaverIsCurrent(revision, intent: intent) else { return .rejected }
            return .written
        }
        pageOperation = operation
        pageOperationID = id
        defer {
            if pageOperationID == id { pageOperation = nil; pageOperationID = nil }
            if screensaverRevision == revision { isApplyingScreensaver = false }
        }
        do {
            guard try await operation.value == .written else { throw CancellationError() }
            screensaverMessage = "Screensaver saved."
            screensaverTimer = Task { @MainActor [weak self] in
                guard let wait = self?.screensaverDelay else { return }
                do { try await wait(.seconds(5)) } catch { return }
                guard let self, !Task.isCancelled, self.screensaverIsCurrent(revision, intent: intent) else { return }
                self.finishScreensaverPreview()
            }
        } catch {
            if screensaverRevision == revision {
                screensaverMessage = "The screensaver image could not be previewed."
                finishScreensaverPreview()
            }
            throw error
        }
    }

    private func screensaverIsCurrent(_ revision: UInt64, intent: UInt64) -> Bool {
        screensaverRevision == revision && epoch == intent && !screensaverLocked && isPreviewingScreensaver && canDeliverNotification
    }

    func setBinding(_ binding: D200XBinding?) {
        guard canEdit, var next = configuration else { return }
        if let applicationID {
            var overrides = next.applications[applicationID] ?? [:]
            overrides[selectedControl.rawValue] = binding
            next.applications[applicationID] = overrides
        } else {
            next.defaults[selectedControl.rawValue] = binding ?? .disabled
        }
        onEdit?(next)
    }

    func setAppearance(label: String, backgroundHex: String) {
        var next = appearance
        next.label = label
        next.backgroundHex = backgroundHex
        setAppearance(next)
    }

    func setAppearance(_ value: D200XTileAppearance) {
        guard canEdit, selectedControl.isTile, var next = configuration else { return }
        if let applicationID {
            next.applicationTiles[applicationID, default: [:]][selectedControl.rawValue] = value
        } else {
            next.tiles[selectedControl.rawValue] = value
        }
        guard (try? next.validated()) != nil else { return }
        onEdit?(next)
    }

    func configureStorage(configurationURL: URL) {
        assetDirectory = configurationURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        screensaverPreviewStore.configure(directory: assetDirectory)
    }

    func applyAppearanceToOtherTiles(properties: Set<D200XAppearanceProperty>) {
        guard canEdit, selectedControl.isTile, !properties.isEmpty, var next = configuration else { return }
        let source = appearance
        for control in D200XControl.allCases where control.isTile && control != selectedControl {
            let value = next.appearance(for: control, application: applicationID).copying(properties, from: source)
            if let applicationID { next.applicationTiles[applicationID, default: [:]][control.rawValue] = value }
            else { next.tiles[control.rawValue] = value }
        }
        guard (try? next.validated()) != nil else { return }
        onEdit?(next)
    }

    func importImage(from url: URL) async throws {
        guard canEdit, selectedControl.isTile, let assetDirectory else { throw CancellationError() }
        let control = selectedControl
        let application = applicationID
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let reference = try await Task.detached(priority: .utility) {
            try D200XAssetStore(directory: assetDirectory).importImage(from: url)
        }.value
        guard canEdit, selectedControl == control, applicationID == application else { throw CancellationError() }
        var next = appearance
        next.imageAsset = reference
        setAppearance(next)
    }

    func removeImage() {
        var next = appearance
        next.imageAsset = nil
        setAppearance(next)
    }

    func setBrightnessPercent(_ percent: Int?) {
        guard canEdit, var next = configuration else { return }
        next.brightnessPercent = percent
        guard (try? next.validated()) != nil else { return }
        onEdit?(next)
    }

    func saveAction(id: String, action: ConfiguredExecutable) throws {
        guard canEdit, var next = configuration else { throw CancellationError() }
        next.actions[id] = action
        next.nativeActions.removeValue(forKey: id)
        onEdit?(try next.validated())
    }

    func saveNativeAction(id: String, action: NativeAction) throws {
        guard canEdit, var next = configuration else { throw CancellationError() }
        next.nativeActions[id] = try action.validated()
        next.actions.removeValue(forKey: id)
        onEdit?(try next.validated())
    }

    func removeAction(id: String) {
        guard canEdit, var next = configuration else { return }
        next.actions.removeValue(forKey: id)
        next.nativeActions.removeValue(forKey: id)
        for key in next.defaults.keys where next.defaults[key]?.actionID == id { next.defaults[key] = .disabled }
        for application in next.applications.keys {
            for key in next.applications[application]?.keys ?? Dictionary<String, D200XBinding>().keys
                where next.applications[application]?[key]?.actionID == id { next.applications[application]?[key] = .disabled }
        }
        onEdit?(next)
    }

    func setNotificationTopics(_ topics: [String]) throws {
        guard canEdit, selectedControl.isTile, var next = configuration else { throw CancellationError() }
        if let applicationID {
            next.applicationNotificationTopics[applicationID, default: [:]][selectedControl.rawValue] = topics
        } else {
            next.notificationTopics[selectedControl.rawValue] = topics.isEmpty ? nil : topics
        }
        onEdit?(try next.validated())
    }

    func resetSelectedAppearanceAndTopics() {
        guard canEdit, let applicationID, var next = configuration else { return }
        next.applicationTiles[applicationID]?.removeValue(forKey: selectedControl.rawValue)
        next.applicationNotificationTopics[applicationID]?.removeValue(forKey: selectedControl.rawValue)
        onEdit?(next)
    }

    func saveTilePreset(id: String, name: String, includeAction: Bool) throws {
        guard canEdit, selectedControl.isTile, var next = configuration,
              ConfiguredExecutable.isValidIdentifier(id), next.tilePresets[id] == nil else {
            throw D200XTilePresetPackage.Failure.duplicatePreset
        }
        let copiedBinding = includeAction ? binding : nil
        let copiedActions = copiedBinding?.actionID.flatMap { actionID in
            next.actions[actionID].map { [actionID: $0] }
        } ?? [:]
        let copiedNativeActions = copiedBinding?.actionID.flatMap { actionID in
            next.nativeActions[actionID].map { [actionID: $0] }
        } ?? [:]
        next.tilePresets[id] = try D200XTilePreset(name: name, appearance: appearance,
            binding: copiedBinding, actions: copiedActions, nativeActions: copiedNativeActions).validated()
        onEdit?(try next.validated())
    }

    func saveTilePreset(id: String, preset: D200XTilePreset, replacing original: D200XTilePreset? = nil) throws {
        guard canEdit, var next = configuration else { throw CancellationError() }
        guard ConfiguredExecutable.isValidIdentifier(id) else { throw D200XTilePresetPackage.Failure.duplicatePreset }
        guard next.tilePresets[id] == original else {
            throw original == nil ? D200XTilePresetPackage.Failure.duplicatePreset : .presetChanged
        }
        next.tilePresets[id] = try preset.validated()
        onEdit?(try next.validated())
    }

    func importPresetImage(from url: URL) async throws -> String {
        guard canEdit, isConfigured, let assetDirectory else { throw CancellationError() }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let reference = try await Task.detached(priority: .utility) {
            try D200XAssetStore(directory: assetDirectory).importImage(from: url)
        }.value
        guard canEdit, isConfigured, self.assetDirectory == assetDirectory else { throw CancellationError() }
        return reference
    }

    func removeTilePreset(id: String) {
        guard canEdit, var next = configuration else { return }
        next.tilePresets.removeValue(forKey: id)
        onEdit?(next)
    }

    func applyTilePreset(id: String, includeAction: Bool) throws {
        guard canEdit, selectedControl.isTile, var next = configuration,
              let preset = next.tilePresets[id] else { throw CancellationError() }
        if includeAction, let binding = preset.binding {
            for (id, action) in preset.actions {
                if let existing = next.actionDefinition(id: id), existing != .executable(action) { throw D200XTilePresetPackage.Failure.actionConflict }
                next.actions[id] = action
            }
            for (id, action) in preset.nativeActions {
                if let existing = next.actionDefinition(id: id), existing != .native(action) { throw D200XTilePresetPackage.Failure.actionConflict }
                next.nativeActions[id] = action
            }
            if let applicationID { next.applications[applicationID, default: [:]][selectedControl.rawValue] = binding }
            else { next.defaults[selectedControl.rawValue] = binding }
        }
        if let applicationID { next.applicationTiles[applicationID, default: [:]][selectedControl.rawValue] = preset.appearance }
        else { next.tiles[selectedControl.rawValue] = preset.appearance }
        onEdit?(try next.validated())
    }

    func tilePresetPackage(id: String) throws -> D200XTilePresetPackage {
        guard let preset = configuration?.tilePresets[id], let assetDirectory else { throw CancellationError() }
        let image = try preset.appearance.imageAsset.map { try D200XAssetStore(directory: assetDirectory).imageData(for: $0) }
        return try D200XTilePresetPackage(version: preset.nativeActions.isEmpty ? 1 : 2,
            preset: preset, image: image).validated(assetDirectory: assetDirectory)
    }

    func importTilePreset(_ package: D200XTilePresetPackage, id: String, includeAction: Bool) throws {
        guard canEdit, var next = configuration, let assetDirectory,
              ConfiguredExecutable.isValidIdentifier(id), next.tilePresets[id] == nil else {
            throw D200XTilePresetPackage.Failure.duplicatePreset
        }
        var preset = try package.validated(assetDirectory: assetDirectory).preset
        if !includeAction { preset.binding = nil; preset.actions = [:]; preset.nativeActions = [:] }
        next.tilePresets[id] = preset
        _ = try next.validated()
        if let image = package.image, let reference = preset.appearance.imageAsset {
            try D200XAssetStore(directory: assetDirectory).restoreImage(image, reference: reference)
        }
        onEdit?(next)
    }

    func startAutomation() {
        automationStarted = true
        automation.start()
    }
    func refreshAutomationHistory() async { await automation.refreshHistory() }
    func clearActionHistory() async { await automation.clearActionHistory() }
    func clearNotification(id: UUID) async {
        _ = await handleAutomation(AutomationRequest(method: .notificationsClear, params: .init(notificationID: id)))
    }
    func clearActiveNotifications() async { await automation.clearActiveNotifications() }
    func handleAutomation(_ request: AutomationRequest) async -> AutomationResponse { await automation.handle(request) }
    func setListening(_ enabled: Bool) { automation.setListening(enabled) }
    func publishNotification(topic: String, text: String = "", ttlSeconds: Int? = nil, appID: String? = nil) async -> AutomationResponse {
        await handleAutomation(AutomationRequest(method: .notificationsEmit,
            params: AutomationParameters(topic: topic, text: text.isEmpty ? nil : text, ttlSeconds: ttlSeconds, appID: appID)))
    }

    func addApplication(_ identifier: String) {
        guard canEdit, var next = configuration else { return }
        next.applications[identifier] = next.applications[identifier] ?? [:]
        guard (try? next.validated()) != nil else { return }
        onEdit?(next)
        applicationID = identifier
    }

    func removeSelectedApplication() {
        guard canEdit, let applicationID, var next = configuration else { return }
        next.applications.removeValue(forKey: applicationID)
        next.applicationTiles.removeValue(forKey: applicationID)
        next.applicationNotificationTopics.removeValue(forKey: applicationID)
        onEdit?(next)
        self.applicationID = nil
    }

    func connect(configureIfNeeded: Bool = true) {
        guard session != nil, !suspended, !systemSleeping, !isConnected, !isBusy else { return }
        if configuration == nil, !configureIfNeeded { return }
        guard canEdit else {
            blockConnection(configurationBlocker ?? "D200X configuration cannot be edited right now.")
            return
        }
        if let configurationBlocker {
            blockConnection(configurationBlocker)
            return
        }
        if configuration == nil {
            onEdit?(.empty)
            guard canEdit else {
                blockConnection(configurationBlocker ?? "D200X configuration cannot be edited right now.")
                return
            }
            if let configurationBlocker {
                blockConnection(configurationBlocker)
                return
            }
            guard configuration != nil else {
                blockConnection("D200X configuration is unavailable. Resolve the configuration issue before connecting.")
                return
            }
        }
        wanted = true
        retryCount = 0
        errorMessage = nil
        beginConnection()
    }

    func disconnect() {
        wanted = false
        invalidateScreensaverPreview()
        screensaverMaintenancePaused = false
        screensaverNeedsPageRestore = false
        stopDisplayUpdates()
        epoch &+= 1
        lifecycleRevision &+= 1
        lifecycleTransitionPending = false
        wakeRestorePending = false
        sleepSettingsPending = false
        automation.reset()
        brightnessRevision &+= 1
        let pendingBrightness = brightnessTask
        brightnessTask?.cancel()
        brightnessTask = nil
        renderRevision &+= 1
        let pendingConnection = connectionTask
        connectionTask?.cancel()
        connectionTask = nil
        let pendingRender = renderTask
        renderTask?.cancel()
        renderTask = nil
        pressed.removeAll()
        lastPage = nil
        guard let session else { return }
        status = .disconnecting
        let previous = stopTask
        let pendingLifecycle = lifecycleTask
        let pendingPageOperation = pageOperation
        stopTask = Task { [weak self] in
            if let previous { await previous.value }
            if let pendingLifecycle { await pendingLifecycle.value }
            if let pendingConnection { await pendingConnection.value }
            if let pendingRender { await pendingRender.value }
            if let pendingPageOperation { _ = try? await pendingPageOperation.value }
            if let pendingBrightness { await pendingBrightness.value }
            await session.disconnect()
            guard let self else { return }
            self.status = .disconnected
            self.message = "Disconnected."
        }
    }

    func sleep() {
        guard !systemSleeping else { return }
        systemSleeping = true
        invalidateScreensaverPreview()
        screensaverMaintenancePaused = false
        stopDisplayUpdates()
        lifecycleTransitionPending = false
        wakeRestorePending = false
        sleepSettingsPending = wanted && connectionTask != nil
        pressed.removeAll()
        automation.reset()
        brightnessRevision &+= 1
        renderRevision &+= 1
        nativeRuntime.stop()
        enqueueDevicePowerTransition(.sleep)
    }

    func wake() {
        guard systemSleeping else { return }
        systemSleeping = false
        lifecycleTransitionPending = true
        sleepSettingsPending = false
        enqueueDevicePowerTransition(.wake)
    }

    func suspendDelivery(_ suspended: Bool) {
        self.suspended = suspended
        if suspended {
            invalidateScreensaverPreview()
            stopDisplayUpdates()
            pressed.removeAll()
            automation.reset()
            brightnessTask?.cancel()
            brightnessTask = nil
            nativeRuntime.stop()
        } else if automationStarted, automation.isStopped {
            automation = D200XAutomationCoordinator(model: self, runner: ConfiguredActionRunner(nativeRunner: nativeRuntime), iconResolver: iconResolver)
            automationObservation = automation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            automation.start()
        }
        if !suspended, isConnected { scheduleRender() }
    }

    func stop() async {
        disconnect()
        if let stopTask { await stopTask.value }
        await automation.stop()
        nativeRuntime.stop()
    }

    private func enqueueDevicePowerTransition(_ transition: DevicePowerTransition) {
        lifecycleRevision &+= 1
        let revision = lifecycleRevision
        let expectedEpoch = epoch
        let previous = lifecycleTask
        lifecycleTask = Task { [weak self] in
            if let previous { await previous.value }
            guard let self, self.lifecycleIsCurrent(revision, epoch: expectedEpoch) else { return }
            switch transition {
            case .sleep:
                await self.applySleepPowerSettings(revision, epoch: expectedEpoch)
            case .wake:
                await self.applyWakePowerSettings(revision, epoch: expectedEpoch)
            }
        }
    }

    private func applySleepPowerSettings(_ revision: UInt64, epoch expectedEpoch: UInt64) async {
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), systemSleeping, wanted,
              let session else { return }

        if let connectionTask { await connectionTask.value }
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), systemSleeping else { return }
        if let renderTask { await renderTask.value }
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), systemSleeping else { return }
        if let pageOperation { _ = try? await pageOperation.value }
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), systemSleeping else { return }
        if let brightnessTask { await brightnessTask.value }
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), systemSleeping else { return }
        guard wanted else {
            sleepSettingsPending = false
            return
        }
        guard isConnected else { return }
        sleepSettingsPending = false

        var keepAwakeFailed = false
        do {
            try await session.setKeepAwakeEnabled(false)
        } catch {
            keepAwakeFailed = true
        }
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), systemSleeping, wanted, isConnected else { return }
        if keepAwakeFailed {
            reportPowerTransitionFailure("Could not pause D200X keep-awake for system sleep.")
        }

        var brightnessFailed = false
        do {
            try await session.setBrightness(0)
        } catch {
            brightnessFailed = true
        }
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), systemSleeping, wanted else { return }
        if brightnessFailed {
            reportPowerTransitionFailure("D200X brightness could not be set to 0% for system sleep.")
        } else {
            brightnessMessage = "Sent 0%; device readback is unavailable."
        }
    }

    private func applyWakePowerSettings(_ revision: UInt64, epoch expectedEpoch: UInt64) async {
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), !systemSleeping else { return }
        guard wanted, isConfigured, canEdit, let session else {
            lifecycleTransitionPending = false
            wakeRestorePending = false
            return
        }

        guard isConnected else {
            guard !suspended else {
                lifecycleTransitionPending = false
                wakeRestorePending = false
                return
            }
            wakeRestorePending = true
            beginConnection()
            return
        }

        var keepAwakeFailed = false
        do {
            try await session.setKeepAwakeEnabled(true)
        } catch {
            keepAwakeFailed = true
        }
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), !systemSleeping, wanted else { return }
        if keepAwakeFailed {
            reportPowerTransitionFailure("Could not resume D200X keep-awake after system wake.")
        }
        guard isConnected else {
            queueWakeReconnect(revision, epoch: expectedEpoch)
            return
        }

        var observedBrightnessRevision = brightnessRevision
        while true {
            let restoreBrightness = configuration?.brightnessPercent ?? 100
            var brightnessFailed = false
            do {
                try await session.setBrightness(restoreBrightness)
            } catch {
                brightnessFailed = true
            }
            guard lifecycleIsCurrent(revision, epoch: expectedEpoch), !systemSleeping, wanted else { return }
            guard isConnected else {
                queueWakeReconnect(revision, epoch: expectedEpoch)
                return
            }
            if brightnessFailed {
                if observedBrightnessRevision != brightnessRevision {
                    observedBrightnessRevision = brightnessRevision
                    continue
                }
                reportPowerTransitionFailure("D200X brightness could not be restored after system wake.")
                break
            }
            guard observedBrightnessRevision != brightnessRevision ||
                    restoreBrightness != (configuration?.brightnessPercent ?? 100) else {
                brightnessMessage = "Sent \(restoreBrightness)%; device readback is unavailable."
                break
            }
            observedBrightnessRevision = brightnessRevision
        }
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), !systemSleeping, wanted else { return }
        guard isConnected else {
            queueWakeReconnect(revision, epoch: expectedEpoch)
            return
        }

        lifecycleTransitionPending = false
        wakeRestorePending = false
        if !suspended { scheduleRender() }
    }

    private func queueWakeReconnect(_ revision: UInt64, epoch expectedEpoch: UInt64) {
        guard lifecycleIsCurrent(revision, epoch: expectedEpoch), !systemSleeping,
              wanted, !suspended, canEdit else { return }
        wakeRestorePending = true
        beginConnection()
    }

    private func lifecycleIsCurrent(_ revision: UInt64, epoch expectedEpoch: UInt64) -> Bool {
        lifecycleRevision == revision && epoch == expectedEpoch
    }

    private func reportPowerTransitionFailure(_ message: String) {
        brightnessMessage = message
        diagnostic(.d200xFailure, message, error: true)
    }

    private func beginConnection(retry: Bool = false) {
        guard let session, wanted, !suspended, !systemSleeping, connectionTask == nil else { return }
        stopDisplayUpdates()
        epoch &+= 1
        renderTask?.cancel()
        renderTask = nil
        lastPage = nil
        lastWideMode = nil
        lastWideNotification = false
        let intent = epoch
        status = .connecting
        message = retry ? "Reconnecting to D200X…" : "Discovering D200X…"
        let wait = retry ? [1, 2, 5][min(retryCount - 1, 2)] : 0
        let pendingStop = stopTask
        connectionTask = Task { [weak self, delay] in
            do {
                if let pendingStop { await pendingStop.value }
                if wait > 0 { try await delay(.seconds(wait)) }
                try Task.checkCancellation()
                guard let self, self.epoch == intent, self.wanted else { return }
                guard !self.suspended, !self.systemSleeping else {
                    if self.systemSleeping { self.sleepSettingsPending = false }
                    self.connectionTask = nil
                    return
                }
                try await session.connect()
                guard !Task.isCancelled, self.epoch == intent, self.wanted else { return }
                self.connectionTask = nil
                self.lastPage = nil
                self.scheduleRender()
            } catch {
                guard let self, self.epoch == intent, !Task.isCancelled else { return }
                self.connectionTask = nil
                let failure = error as? D200XFailure ?? .transport
                self.status = .failed(failure)
                self.fail(failure.userMessage)
                self.retryConnection()
            }
        }
    }

    private func retryConnection() {
        guard wanted, !suspended, !systemSleeping, canEdit, retryCount < 3, connectionTask == nil else { return }
        retryCount += 1
        beginConnection(retry: true)
    }

    private func receive(_ event: D200XSessionEvent) {
        switch event {
        case .status(let next, let eventGeneration):
            guard eventGeneration >= generation else { return }
            if eventGeneration != generation { pressed.removeAll(); lastPage = nil }
            generation = eventGeneration
            if case .connected = next, !wanted { return }
            status = next
            switch next {
            case .connected:
                message = "Connected to Ulanzi D200X."
                errorMessage = nil
                diagnostic(.d200xStatus, message)
                if systemSleeping, sleepSettingsPending {
                    sleepSettingsPending = false
                    enqueueDevicePowerTransition(.sleep)
                } else if wakeRestorePending, !systemSleeping {
                    wakeRestorePending = false
                    enqueueDevicePowerTransition(.wake)
                } else if !systemSleeping, !suspended, !lifecycleTransitionPending,
                          configuration?.brightnessPercent != nil {
                    scheduleBrightness()
                }
            case .failed(let failure):
                invalidateScreensaverPreview()
                screensaverMaintenancePaused = false
                lastPage = nil
                if systemSleeping { sleepSettingsPending = false }
                fail(failure.userMessage)
                retryConnection()
            case .disconnected:
                invalidateScreensaverPreview()
                screensaverMaintenancePaused = false
                message = "Disconnected."
                if systemSleeping { sleepSettingsPending = false }
                if lifecycleTransitionPending, !systemSleeping, wanted {
                    wakeRestorePending = true
                    beginConnection()
                }
            default: break
            }
        case .input(let input, let eventGeneration):
            guard eventGeneration == generation, isConnected, wanted, !suspended,
                  !systemSleeping, !lifecycleTransitionPending, canEdit else { return }
            if input.gesture == .release { pressed.remove(input.index); return }
            guard let control = mappedControl(input) else { return }
            if control.gesture.map({ $0 != .press }) == true,
               configuration?.brightnessPercent != nil {
                scheduleBrightness()
            }
            if input.gesture == .press, !pressed.insert(input.index).inserted { return }
            refreshActiveApplication()
            let binding = configuration?.binding(for: control, application: activeApplicationID) ?? .disabled
            let capturedApplication = activeApplicationID
            let capturedConfiguration = runtimeConfiguration
            let capturedAction = binding.actionID.flatMap { configuration?.actionDefinition(id: $0) }
            let capturedNotificationID = automation.captureNotificationID(control: control)
            let trigger = ConfiguredActionTrigger(kind: .device, profile: activeProfileName, control: control.rawValue,
                sessionEpoch: epoch, applicationID: activeApplicationID)
            let intent = epoch
            Task { [weak self] in
                guard let self, self.runtimeConfiguration == capturedConfiguration,
                      await self.automation.dismiss(control: control, capturedID: capturedNotificationID),
                      self.runtimeConfiguration == capturedConfiguration, self.activeApplicationID == capturedApplication, self.epoch == intent,
                      self.canDeliverNotification else { return }
                switch binding.kind {
                case .disabled: break
                case .shortcut:
                    guard let shortcut = binding.shortcut else { return }
                    do {
                        try self.sender.send(shortcut)
                        self.lastActionMessage = "Posted \(ShortcutSender.label(for: shortcut)) from \(control.title)."
                    } catch {
                        self.reportAutomationFailure("Shortcut delivery failed. Check input permissions in Settings.")
                    }
                case .action:
                    guard let id = binding.actionID, let capturedAction else { return }
                    do {
                        _ = try await self.automation.invokeCaptured(id: id, definition: capturedAction, trigger: trigger)
                        self.lastActionMessage = "Configured action admitted from \(control.title)."
                    } catch { self.reportAutomationFailure("The configured script could not be admitted.") }
                }
            }
        }
    }

    private func mappedControl(_ input: D200XInput) -> D200XControl? {
        guard input.prefix == 1 else { return nil }
        if input.family == 1, input.gesture == .press {
            return D200XControl.allCases.first { $0.wireIndex == Int(input.index) && $0.gesture == nil }
        }
        guard input.family == 2, input.gesture != .unknown, input.gesture != .release else { return nil }
        return D200XControl.allCases.first { $0.wireIndex == Int(input.index) && $0.gesture?.rawValue == input.state }
    }

    private func scheduleRender() {
        guard !(screensaverLocked && screensaverRestoreAfterUnlock), !isPreviewingScreensaver, configuration != nil, let session, wanted, !suspended, !systemSleeping,
              !lifecycleTransitionPending, canEdit else { return }
        startDisplayUpdates()
        renderRevision &+= 1
        guard renderTask == nil else { return }
        let intent = epoch
        renderTask = Task { [weak self] in
            do {
                while let self, self.epoch == intent, self.wanted, !self.suspended,
                      !self.systemSleeping, !self.lifecycleTransitionPending, !self.isPreviewingScreensaver, self.canEdit,
                      let configuration = self.runtimeConfiguration {
                    try Task.checkCancellation()
                    let revision = self.renderRevision
                    try await Task.sleep(for: .milliseconds(150))
                    if revision != self.renderRevision { continue }
                    let labels = self.automation.labels
                    let icons = self.automation.iconOverrides
                    let assetDirectory = self.assetDirectory
                    let page = try await Task.detached(priority: .utility) {
                        try D200XPageRenderer.page(configuration: configuration, labelOverrides: labels, assetDirectory: assetDirectory, notificationIcons: icons)
                    }.value
                    guard !Task.isCancelled, self.epoch == intent else { return }
                    if revision != self.renderRevision { continue }
                    let applied = try await self.writePage(page, session: session, intent: intent,
                        wideNotification: labels["key13"] != nil || icons["key13"] != nil) { [weak self] in
                        self?.renderRevision == revision
                    }
                    if applied == .written {
                        guard !Task.isCancelled, self.epoch == intent else { return }
                        self.retryCount = 0
                        self.message = "Page sent to D200X."
                        self.diagnostic(.d200xPageSent, "D200X page transfer completed; appearance requires physical verification.")
                    }
                    if revision == self.renderRevision {
                        self.renderTask = nil
                        return
                    }
                }
                if let self, self.epoch == intent { self.renderTask = nil }
            } catch {
                guard let self, !Task.isCancelled, self.epoch == intent else { return }
                self.renderTask = nil
                self.lastPage = nil
                self.fail("Could not send the D200X page.")
            }
        }
    }

    func applyNotificationLabels(_ labels: [String: String], notificationIcons: [String: Data] = [:], authorize: @escaping @MainActor () -> Bool = { true }) async throws {
        let expectedConfiguration = runtimeConfiguration
        let expectedProfile = activeProfileName
        let intent = epoch
        if let pendingRender = renderTask { await pendingRender.value }
        guard canDeliverNotification, authorize(), epoch == intent, runtimeConfiguration == expectedConfiguration,
              activeProfileName == expectedProfile,
              let session, let configuration = runtimeConfiguration else { throw CancellationError() }
        renderRevision &+= 1
        let revision = renderRevision
        let assetDirectory = assetDirectory
        let page = try await Task.detached(priority: .utility) {
            try D200XPageRenderer.page(configuration: configuration, labelOverrides: labels, assetDirectory: assetDirectory, notificationIcons: notificationIcons)
        }.value
        guard !Task.isCancelled, canDeliverNotification, authorize(), epoch == intent, renderRevision == revision, activeProfileName == expectedProfile else { throw CancellationError() }
        let applied = try await writePage(page, session: session, intent: intent,
            wideNotification: labels["key13"] != nil || notificationIcons["key13"] != nil) { [weak self] in
            guard let self else { return false }
            return authorize() && self.activeProfileName == expectedProfile && self.renderRevision == revision
        }
        guard applied != .rejected else { throw CancellationError() }
        guard !Task.isCancelled, canDeliverNotification, epoch == intent, renderRevision == revision else { throw CancellationError() }
    }

    private func writePage(_ page: D200XPage, session: any D200XSessionProtocol, intent: UInt64,
                           wideNotification: Bool = false,
                           authorize: @escaping @MainActor () -> Bool) async throws -> PageWriteOutcome {
        let previous = pageOperation
        let id = UUID()
        let operation = Task { @MainActor [weak self] () throws -> PageWriteOutcome in
            if let previous { _ = try? await previous.value }
            guard let self, self.epoch == intent, self.wanted, !self.suspended,
                  !self.systemSleeping, !self.lifecycleTransitionPending, self.canEdit, authorize() else { return .rejected }
            if self.isPreviewingScreensaver || (self.screensaverLocked && self.screensaverRestoreAfterUnlock) { return .unchanged }
            var slots = page.slots
            if self.configuration?.wideDisplayMode.firmwareMode != nil || self.lastWideMode != nil,
               let wide = slots["3_2"] {
                slots["3_2"] = D200XSlot(image: wide.image, format: wide.format, text: wide.text, smallViewMode: 2)
            }
            let desiredPage = D200XPage(slots: slots)
            let oldPage = self.lastPage
            let changed = desiredPage.slots.filter { oldPage?.slots[$0.key] != $0.value }
            if !changed.isEmpty {
                try await session.applyPage(D200XPage(slots: changed), update: oldPage == nil ? .replace : .incremental)
            }
            guard self.epoch == intent, self.canDeliverNotification,
                  !(self.screensaverLocked && self.screensaverRestoreAfterUnlock) else { return .rejected }
            self.lastPage = desiredPage
            guard !self.isPreviewingScreensaver, !(self.screensaverLocked && self.screensaverRestoreAfterUnlock),
                  self.canDeliverNotification, authorize() else { return .rejected }
            try await self.applyWideDisplay(session: session, intent: intent, wideNotification: wideNotification)
            guard self.epoch == intent, !self.isPreviewingScreensaver, !(self.screensaverLocked && self.screensaverRestoreAfterUnlock),
                  self.canDeliverNotification, authorize() else { return .rejected }
            self.lastWideNotification = wideNotification
            if self.screensaverMaintenancePaused {
                try await session.setKeepAwakeEnabled(true)
                guard self.epoch == intent, self.canDeliverNotification, !self.isPreviewingScreensaver,
                      !(self.screensaverLocked && self.screensaverRestoreAfterUnlock) else { return .rejected }
                self.screensaverMaintenancePaused = false
            }
            self.screensaverNeedsPageRestore = false
            return changed.isEmpty ? .unchanged : .written
        }
        pageOperation = operation
        pageOperationID = id
        defer { if pageOperationID == id { pageOperation = nil; pageOperationID = nil } }
        return try await operation.value
    }

    private func applyWideDisplay(session: any D200XSessionProtocol, intent: UInt64, wideNotification: Bool) async throws {
        guard let configuration else { return }
        let selected = configuration.wideDisplayMode
        var mode = selected == .custom && lastWideMode == nil && !screensaverNeedsPageRestore ? nil : (wideNotification ? 2 : selected.firmwareMode)
        if selected == .systemStatus, !wideNotification, !displayMetrics.isComplete {
            mode = 2
            wideDisplayMessage = "System status is unavailable until CPU, RAM and GPU readings are valid. Showing the custom tile."
        } else {
            wideDisplayMessage = wideNotification ? "Notification temporarily uses the custom tile." : nil
        }
        if mode == nil, lastWideMode != nil || screensaverNeedsPageRestore { mode = 2 }
        guard let mode else { return }
        let status = D200XDisplayStatus.make(mode: mode, format: configuration.clockFormat,
                                            date: displayNow(), metrics: displayMetrics)
        try await session.setWideDisplay(status)
        guard epoch == intent, canDeliverNotification else { return }
        lastWideMode = mode
    }

    private func startDisplayUpdates() {
        guard !(screensaverLocked && screensaverRestoreAfterUnlock), !isPreviewingScreensaver, displayTask == nil, configuration?.wideDisplayMode != .custom else { return }
        if configuration?.wideDisplayMode == .systemStatus { displayMetrics = sampleMetrics() }
        let revision = displayRevision
        let intent = epoch
        displayTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let wait = self?.displayDelay else { return }
                do { try await wait(.seconds(1)) } catch { return }
                guard !Task.isCancelled, let self, self.displayRevision == revision, self.epoch == intent else { return }
                guard self.canDeliverNotification,
                      self.configuration?.wideDisplayMode != .custom else {
                    self.displayTask = nil
                    return
                }
                tick += 1
                if tick.isMultiple(of: 2), self.configuration?.wideDisplayMode == .systemStatus {
                    self.displayMetrics = self.sampleMetrics()
                }
                if tick.isMultiple(of: 5) { await self.refreshWideDisplay() }
            }
        }
    }

    private func refreshWideDisplay() async {
        guard !(screensaverLocked && screensaverRestoreAfterUnlock), !isPreviewingScreensaver, canDeliverNotification, renderTask == nil, lastPage != nil,
              configuration?.wideDisplayMode != .custom, let session else { return }
        let intent = epoch
        let revision = renderRevision
        let expectedConfiguration = runtimeConfiguration
        let expectedProfile = activeProfileName
        let previous = pageOperation
        let id = UUID()
        let operation = Task { @MainActor [weak self] () throws -> PageWriteOutcome in
            if let previous { _ = try? await previous.value }
            guard let self, !(self.screensaverLocked && self.screensaverRestoreAfterUnlock), !self.isPreviewingScreensaver, self.epoch == intent, self.canDeliverNotification,
                  self.renderRevision == revision, self.runtimeConfiguration == expectedConfiguration,
                  self.activeProfileName == expectedProfile else { return .rejected }
            try await self.applyWideDisplay(session: session, intent: intent, wideNotification: self.lastWideNotification)
            return .unchanged
        }
        pageOperation = operation
        pageOperationID = id
        defer { if pageOperationID == id { pageOperation = nil; pageOperationID = nil } }
        do { _ = try await operation.value }
        catch {
            guard epoch == intent, canDeliverNotification else { return }
            wideDisplayMessage = "The wide display could not be updated."
        }
    }

    private func stopDisplayUpdates() {
        displayRevision &+= 1
        displayTask?.cancel()
        displayTask = nil
        displayMetrics = D200XMetricsSnapshot()
    }

    func reportAutomationFailure(_ message: String) {
        lastActionMessage = message
        diagnostic(.d200xActionFailed, message, error: true)
    }

    private func scheduleBrightness() {
        brightnessRevision &+= 1
        guard brightnessTask == nil else { return }
        guard canDeliverNotification, let session else {
            brightnessMessage = "Saved for the next connection."
            return
        }
        let intent = epoch
        brightnessTask = Task { [weak self] in
            defer { if let self, self.epoch == intent { self.brightnessTask = nil } }
            do {
                while let self, self.epoch == intent, self.canDeliverNotification, !Task.isCancelled {
                    let revision = self.brightnessRevision
                    try await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, self.epoch == intent, self.canDeliverNotification else { return }
                    if revision != self.brightnessRevision { continue }
                    guard let percent = self.configuration?.brightnessPercent else {
                        self.brightnessMessage = "No brightness override."
                        self.brightnessTask = nil
                        return
                    }
                    try await session.setBrightness(percent)
                    guard !Task.isCancelled, self.epoch == intent else { return }
                    self.brightnessMessage = "Sent \(percent)%; device readback is unavailable."
                    if revision == self.brightnessRevision { self.brightnessTask = nil; return }
                }
            } catch {
                guard let self, !Task.isCancelled, self.epoch == intent else { return }
                self.brightnessMessage = "Brightness could not be sent."
                self.brightnessTask = nil
                self.diagnostic(.d200xFailure, "D200X brightness write failed.", error: true)
            }
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        self.message = message
        diagnostic(.d200xFailure, message, error: true)
    }

    private func blockConnection(_ reason: String) {
        errorMessage = reason
        message = reason
    }

    private func diagnostic(_ code: DiagnosticCode, _ message: String, error: Bool = false) {
        onDiagnostic?(DiagnosticEvent(code: code, message: message, isError: error))
    }
}
