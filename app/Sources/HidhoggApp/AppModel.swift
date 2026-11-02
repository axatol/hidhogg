import AppKit
import Combine
import CoreGraphics
import Darwin
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import UlanziD200X
import LofreeFlowLite84
import GenericBluetooth

protocol BindingSession: Sendable {
    var events: AsyncStream<BoltEvent> { get }

    var requiresExplicitAssociation: Bool { get }
    func existingConnections() async throws -> [LogitechEndpointCandidate]
    func discover(target: LogitechConnectionTarget) async
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
    var requiresExplicitAssociation: Bool { false }
    func existingConnections() async throws -> [LogitechEndpointCandidate] { [] }
    func discover(target: LogitechConnectionTarget) async { await discover() }

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

enum WorkspaceRoute: Hashable, Identifiable {
    case devices
    case logitechSetup
    case mouse(UUID)
    case d200x
    case flowLite
    case genericBluetooth(UUID)
    case actions
    case notifications
    case tilePresets
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
    let d200x: D200XModel
    let flowLite: FlowLite84Model
    let bluetooth: GenericBluetoothModel
    let genericBluetoothAlerts: GenericBluetoothAlertCoordinator?

    @Published private(set) var navigation = NavigationHistory(initialRoute: WorkspaceLocation())
    @Published private(set) var document = ConfigurationDraft()
    @Published private(set) var workspace = WorkspaceConfiguration(legacy: .empty)
    private var savedWorkspace: WorkspaceConfiguration?
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
    private let makeBoltPairingSession: (@Sendable () -> any BoltPairingManaging)?
    private let makeBoltReceiverManagementSession: (@Sendable () -> any BoltReceiverManaging)?
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
    private struct MouseLease: Equatable {
        let ownerID: UUID
        let epoch: UInt64
        let statusGenerationFloor: UInt64
        let startedAt: ContinuousClock.Instant
    }
    private var mouseLease: MouseLease?
    @Published private(set) var mouseConnectionChoices: [LogitechEndpointCandidate] = []
    @Published private(set) var isMouseSelectorPresented = false
    @Published private(set) var isMouseSelectorLoading = false
    @Published private(set) var mouseSelectorMessage: String?
    @Published private(set) var isBoltPairingPresented = false
    @Published private(set) var isBoltPairingLoading = false
    @Published private(set) var boltPairingReceivers: [BoltReceiverCandidate] = []
    @Published private(set) var boltPairingStatus: BoltPairingStatus?
    @Published private(set) var boltPairingMessage: String?
    @Published private(set) var logitechSetupDestination: LogitechSetupDestination?
    @Published private(set) var logitechSetupCandidates: [LogitechEndpointCandidate] = []
    @Published private(set) var isLogitechSetupLoading = false
    @Published private(set) var logitechSetupMessage: String?
    @Published private(set) var logitechSetupCompletedDeviceID: UUID?
    @Published private(set) var requiresLogitechSetupRefreshBeforePairing = false
    @Published private(set) var boltStoredInventories: [BoltReceiverInventory] = []
    @Published private(set) var boltStoredReceiverLabels: [UUID: String] = [:]
    @Published private(set) var isBoltManagedInventoryStale = true
    @Published private(set) var boltManagedReceivers: [BoltReceiverCandidate] = []
    @Published private(set) var boltManagedInventory: BoltReceiverInventory?
    @Published private(set) var isBoltReceiverManagementBusy = false
    @Published private(set) var boltReceiverManagementMessage: String?
    private struct LogitechSetupSnapshot {
        let token: UUID
        let destination: LogitechSetupDestination
        let workspace: WorkspaceConfiguration
        let revision: FileRevision
        let intent: UInt64
        let priorLocation: WorkspaceLocation
        let restoreConnection: Bool
    }
    private var logitechSetupSnapshot: LogitechSetupSnapshot?
    private var logitechSetupOperationTask: Task<Void, Never>?
    private var logitechSetupInventoryTask: Task<[LogitechEndpointCandidate]?, Never>?
    private struct BoltReceiverManagementSnapshot {
        let token: UUID
        let setupToken: UUID
        let intent: UInt64
    }
    private struct BoltReceiverManagementOperation {
        let snapshot: BoltReceiverManagementSnapshot
        let token: UUID
    }
    private var boltReceiverManagementSnapshot: BoltReceiverManagementSnapshot?
    private var boltReceiverManagementOperationToken: UUID?
    private var boltReceiverManagementSession: (any BoltReceiverManaging)?
    private var boltReceiverManagementOperationTaskToken: UUID?
    private var boltReceiverManagementOperationTask: Task<Void, Never>?
    private var boltReceiverManagementCloseTask: Task<Void, Never>?
    private var boltReceiverManagementCloseToken: UUID?
    private struct BoltPairingSnapshot {
        let token: UUID
        let registrationID: UUID
        let model: LogitechMouseModel?
        let setup: LogitechSetupSnapshot?
        let workspace: WorkspaceConfiguration
        let revision: FileRevision
        let intent: UInt64
        let restoreConnection: Bool
    }
    private var boltPairingSnapshot: BoltPairingSnapshot?
    private var boltPairingSession: (any BoltPairingManaging)?
    private var boltPairingEventTask: Task<Void, Never>?
    private var boltPairingFinishTask: Task<Void, Never>?
    private var boltPairingPreparationToken: UUID?
    private var boltPairingRevoked = false
    private var boltPairingMayHaveSucceeded = false
    private var boltPairingAssociationSaved = false
    private var boltPairingIdentityVerified = false
    private var boltPairingReceiverSelected = false
    private var recoveryRefreshSetupToken: UUID?
    private var recoveryRefreshConnectionsAreFresh = false
    private var recoveryRefreshReceiverInventoriesAreFresh = false
    private var isBoltPairingActive: Bool { boltPairingSnapshot != nil || boltPairingPreparationToken != nil }
    var isBoltReceiverManagementActive: Bool { boltReceiverManagementSnapshot != nil }
    var isLogitechSetupSelectionBlocked: Bool {
        if requiresLogitechSetupRefreshBeforePairing { return true }
        guard let status = boltPairingStatus else { return boltPairingMayHaveSucceeded }
        return status.phase == .pairedButNotAdded || boltPairingMayHaveSucceeded ||
            status.pairingMayHaveSucceeded || status.verifiedCandidate != nil
    }
    var shouldShowLogitechSetupRecoveryButton: Bool {
        let phase = boltPairingStatus?.phase
        return requiresLogitechSetupRefreshBeforePairing || phase == .failed || phase == .cancelled ||
            phase == .pairedButNotAdded ||
            (boltPairingStatus?.phase == .verified && !isBoltPairingActive && boltPairingFinishTask == nil &&
             boltPairingMayHaveSucceeded && !boltPairingAssociationSaved)
    }
    var canRefreshLogitechSetup: Bool {
        logitechSetupDestination != nil && !isLogitechSetupLoading && !isBoltPairingLoading &&
            !isBoltPairingActive && boltPairingFinishTask == nil && !isSaving &&
            !isBoltReceiverManagementBusy && boltReceiverManagementCloseTask == nil
    }
    private struct MouseSelectionSnapshot {
        let token: UUID
        let registrationID: UUID
        let revision: FileRevision
        let workspace: WorkspaceConfiguration
        let intent: UInt64
    }
    private var mouseSelectionSnapshot: MouseSelectionSnapshot?
    private var pendingMouseCandidateID: UUID?
    private var mouseActivationID: UUID?
    private var endpointOwnerID: UUID?
    private struct MouseEndpointTarget: Equatable {
        let ownerID: UUID
        let model: LogitechMouseModel
        let association: LogitechAssociation
    }
    private var endpointRecoveryTarget: MouseEndpointTarget?
    private var cleanupRestorePreviousSettings = false
    private var mouseOperations: [UUID: Task<Void, Never>] = [:]
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
    private var bluetoothAuthorizationObserver: NSObjectProtocol?
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
            bolt: BoltController(scrollPostingPreflight: { CGPreflightPostEventAccess() },
                                 nativeNaturalScrolling: { SystemScrollDirection.naturalScrollingEnabled() }),
            makeBoltPairingSession: { BoltPairingSession() },
            makeBoltReceiverManagementSession: { BoltReceiverManagementSession() },
            sender: ShortcutSender(),
            scrollSender: ScrollSender(),
            thumbwheelScrollSender: ScrollSender(),
            lowBatteryNotifications: LowBatteryNotificationController(),
            d200x: D200XModel(session: UlanziD200X.D200XSession(), sender: ShortcutSender(), nativePlatform: NativeActionSender(), observeScreenLock: true),
            flowLite: FlowLite84Model(session: FlowLite84Session(), keyboardActivityMonitor: AppKitKeyboardActivityMonitor()),
            bluetooth: GenericBluetoothModel(inventory: SystemPairedBluetoothInventory(),
                                             registryReport: SystemIORegistryBatteryReport(),
                                             scheduler: BluetoothCheckScheduler()),
            loadImmediately: true,
            observeSleep: true
        )
        d200x.startAutomation()
    }

    init(
        configurationURL: URL,
        store: ConfigurationStore,
        bolt: any BindingSession,
        makeBoltPairingSession: (@Sendable () -> any BoltPairingManaging)? = nil,
        makeBoltReceiverManagementSession: (@Sendable () -> any BoltReceiverManaging)? = nil,
        sender: ShortcutSender,
        scrollSender: ScrollSender = ScrollSender(preflight: { false }, post: { _, _ in }),
        thumbwheelScrollSender: ScrollSender = ScrollSender(preflight: { false }, post: { _, _ in }),
        lowBatteryNotifications: LowBatteryNotificationController? = nil,
        d200x: D200XModel? = nil,
        flowLite: FlowLite84Model? = nil,
        bluetooth: GenericBluetoothModel? = nil,
        genericBluetoothAlerts: GenericBluetoothAlertCoordinator? = nil,
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
        self.makeBoltPairingSession = makeBoltPairingSession
        self.makeBoltReceiverManagementSession = makeBoltReceiverManagementSession
        self.sender = sender
        self.scrollSender = scrollSender
        self.thumbwheelScrollSender = thumbwheelScrollSender
        self.lowBatteryNotifications = lowBatteryNotifications
        self.d200x = d200x ?? D200XModel(sender: sender, frontmostApplication: frontmostApplication)
        self.flowLite = flowLite ?? FlowLite84Model()
        self.bluetooth = bluetooth ?? GenericBluetoothModel()
        self.genericBluetoothAlerts = genericBluetoothAlerts ?? lowBatteryNotifications.map {
            GenericBluetoothAlertCoordinator(notificationCenter: $0.notificationCenter)
        }
        self.d200x.configureStorage(configurationURL: configurationURL)
        self.frontmostApplication = frontmostApplication
        self.wakeDelay = wakeDelay
        self.wakeStatusTimeout = wakeStatusTimeout
        self.savedWorkspace = self.workspace
        permissionChecks = sender.permissionChecks
        self.bluetooth.onStateChange = { [weak self] in self?.updateGenericBluetoothAlerts() }
        lowBatteryNotifications?.onAuthorizationChange = { [weak self] authorization in
            self?.updateGenericBluetoothAlerts(authorization: authorization)
        }
        self.d200x.onEdit = { [weak self] deckConfiguration in
            guard let self else { return }
            var configuration = self.document.draft
            configuration.d200x = deckConfiguration
            self.updateDraft(configuration)
        }
        self.d200x.onDiagnostic = { [weak self] event in self?.diagnosticEvent = event }
        self.flowLite.onDiagnostic = { [weak self] event in self?.diagnosticEvent = event }
        synchronizeD200X()

        let events = bolt.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.receive(event)
            }
        }

        if observeSleep {
            bluetoothAuthorizationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.bluetooth.recheckAccess()
                    self?.refreshNotificationAuthorization()
                }
            }
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
            self.flowLite.setSuspended(true)
            let initialLifecycleIntent = lifecycleIntent
            initialConfigurationLoadPending = true
            Task { [weak self] in
                await self?.loadInitialConfiguration(startupIntent: initialLifecycleIntent)
            }
        } else {
            isLoading = false
            synchronizeD200X()
        }
    }

    isolated deinit {
        if let bluetoothAuthorizationObserver { NotificationCenter.default.removeObserver(bluetoothAuthorizationObserver) }
        eventTask?.cancel()
        boltPairingEventTask?.cancel()
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

    var isDirty: Bool { savedWorkspace.map { $0 != workspace } ?? document.isDirty }
    var registeredDevices: [RegisteredDevice] { workspace.devices }
    var availableDeviceFamilies: [DeviceFamily] {
        DeviceFamily.allCases.filter { family in
            family != .genericBluetooth && (family.isLogitechMouse || !registeredDevices.contains { $0.family == family })
        }
    }

    func registration(for family: DeviceFamily) -> RegisteredDevice? {
        let matches = registeredDevices.filter { $0.family == family }
        return matches.count == 1 ? matches[0] : nil
    }

    func isDeviceEnabled(_ family: DeviceFamily) -> Bool {
        let matches = registeredDevices.filter { $0.family == family }
        return matches.count == 1 && matches[0].isEnabled
    }

    func addDevice(_ family: DeviceFamily) {
        guard canEditConfiguration, registeredDevices.count < 256, availableDeviceFamilies.contains(family),
              let registration = RegisteredDevice.make(family: family) else { return }
        let previous = workspace
        workspace.devices.append(registration)
        synchronizeRegistrations(previous: previous)
        navigate(to: Self.route(for: registration))
        scheduleAutosave()
    }

    func addBluetoothDevice(_ candidate: PairedBluetoothDevice) {
        guard canEditConfiguration, registeredDevices.count < 256,
              bluetooth.canRegister(candidate.endpoint),
              !registeredDevices.contains(where: { $0.bluetoothConfiguration?.endpoint == candidate.endpoint }) else { return }
        let previous = workspace
        let scalars = candidate.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        for character in cleaned {
            guard name.utf8.count + String(character).utf8.count <= 128 else { break }
            name.append(character)
        }
        let registration = RegisteredDevice(displayName: name.isEmpty ? nil : name, configuration: .genericBluetooth(candidate.endpoint))
        workspace.devices.append(registration)
        synchronizeRegistrations(previous: previous)
        navigate(to: Self.route(for: registration))
        scheduleAutosave()
    }

    func registration(id: UUID) -> RegisteredDevice? { registeredDevices.first { $0.id == id } }

    func setBluetoothBatteryAlerts(_ enabled: Bool, for id: UUID) {
        guard updateBluetoothConfiguration(id, { $0.lowBatteryAlertsEnabled = enabled }) else { return }
        guard enabled, let notifications = lowBatteryNotifications else { return }
        Task { [weak self] in
            await notifications.requestAuthorization()
            self?.bluetooth.refresh()
        }
    }

    func setBluetoothBatteryThreshold(_ threshold: Int, for id: UUID) {
        guard (1...100).contains(threshold) else { return }
        _ = updateBluetoothConfiguration(id) { $0.lowBatteryThreshold = threshold }
    }

    func setBluetoothIconOverride(_ kind: BluetoothDeviceKind?, for id: UUID) {
        _ = updateBluetoothConfiguration(id) { $0.iconOverride = kind }
    }

    @discardableResult
    private func updateBluetoothConfiguration(_ id: UUID, _ edit: (inout GenericBluetoothConfiguration) -> Void) -> Bool {
        guard canEditConfiguration, let index = workspace.devices.firstIndex(where: { $0.id == id }),
              var configuration = workspace.devices[index].bluetoothConfiguration else { return false }
        let original = configuration
        edit(&configuration)
        guard configuration != original else { return false }
        let previous = workspace
        workspace.devices[index].configuration = .genericBluetooth(configuration)
        synchronizeRegistrations(previous: previous)
        scheduleAutosave()
        return true
    }

    private func updateGenericBluetoothAlerts(authorization: LowBatteryNotificationAuthorizationState? = nil) {
        genericBluetoothAlerts?.synchronize(devices: registeredDevices, statuses: bluetooth.statuses,
            authorization: authorization ?? lowBatteryNotifications?.authorizationState ?? .unknown,
            suspended: bluetooth.isSuspended || isRestarting || isLoading || configurationLoadFailed || wakeRecovery.sleeping,
            bluetoothAllowed: bluetooth.access == .allowed)
    }

    func setDeviceEnabled(_ id: UUID, enabled: Bool) {
        guard canEditConfiguration, let index = workspace.devices.firstIndex(where: { $0.id == id }),
              workspace.devices[index].isEnabled != enabled else { return }
        let previous = workspace
        workspace.devices[index].isEnabled = enabled
        synchronizeRegistrations(previous: previous)
        scheduleAutosave()
    }

    func removeDevice(_ id: UUID) {
        guard canEditConfiguration, let removed = workspace.devices.first(where: { $0.id == id }) else { return }
        let previous = workspace
        workspace.devices.removeAll { $0.id == id }
        if workspace.preferredMouseID == id { workspace.preferredMouseID = nil }
        synchronizeRegistrations(previous: previous)
        if navigation.current.route == Self.route(for: removed) || (removed.family.isLogitechMouse && navigation.current.route == .devices) {
            navigate(to: registeredDevices.first.map { Self.route(for: $0) } ?? .settings)
        }
        scheduleAutosave()
    }

    static func route(for registration: RegisteredDevice) -> WorkspaceRoute {
        switch registration.family {
        case .mxMaster3S, .mxMaster4: .mouse(registration.id)
        case .d200x: .d200x
        case .flowLite84: .flowLite
        case .genericBluetooth: .genericBluetooth(registration.id)
        }
    }

    private func synchronizeRegistrations(previous: WorkspaceConfiguration) {
        if workspace != previous { revokeLogitechSetup(); revokeBoltPairing() }
        let previousOwner = mouseLease?.ownerID
        let previousAdmissibleID = runtimeMouseID(in: previous)
        let mouseWasManaged = sessionActivationRequested || wakeRecovery.isRecovering ||
            ![BoltPhase.idle, .failed].contains(boltStatus.phase)
        let previousAssociation = previous.devices.first { $0.id == previousOwner }?.logitechAssociation
        let currentAssociation = registeredDevices.first { $0.id == previousOwner }?.logitechAssociation
        let admissionChanged = previousAdmissibleID != admissibleMouseID || previousAssociation != currentAssociation
        let hadRuntime = endpointOwnerID != nil || sleepCleanupTask != nil || mouseWasManaged
        if let selectedMouseID, registration(id: selectedMouseID)?.isEnabled != true { cancelRecording() }
        if admissionChanged && hadRuntime {
            let restore = previous.configuration(forMouseID: previousOwner ?? previousAdmissibleID).mouse?.restorePreviousSettingsOnDisconnect ?? cleanupRestorePreviousSettings
            cancelRecording()
            prepareForLifecycleStop()
            cleanupRestorePreviousSettings = restore
            if mouseWasManaged && (previousOwner != nil || sleepCleanupTask == nil) {
                scheduleMouseCleanup(restore: restore)
            }
        }
        synchronizeEditorProjection()
        if previous.devices.first(where: { $0.family == .d200x })?.id != registration(for: .d200x)?.id,
           d200x.connectionRequested || d200x.isConnected || d200x.isBusy {
            d200x.setManagementEnabled(false)
        }
        if previous.devices.first(where: { $0.family == .flowLite84 })?.id != registration(for: .flowLite84)?.id,
           flowLite.connectionRequested || flowLite.isConnected || flowLite.isBusy {
            flowLite.setManagementEnabled(false)
        }
        d200x.setManagementEnabled(isDeviceEnabled(.d200x))
        flowLite.setManagementEnabled(isDeviceEnabled(.flowLite84))
        synchronizeD200X()
        synchronizeLowBatteryPreference()
        refreshDeliveryAdmission()
    }
    private var mouseRegistrations: [RegisteredDevice] {
        registeredDevices.filter { $0.family.isLogitechMouse }
    }

    private func runtimeMouseID(in configuration: WorkspaceConfiguration) -> UUID? {
        let mice = configuration.devices.filter { $0.family.isLogitechMouse }
        if !bolt.requiresExplicitAssociation {
            return mice.count == 1 && mice[0].isEnabled ? mice[0].id : nil
        }
        guard let preferred = configuration.preferredMouseID else { return nil }
        return mice.first { $0.id == preferred && $0.isEnabled && $0.logitechAssociation != nil }?.id
    }

    private var admissibleMouseID: UUID? {
        guard let id = runtimeMouseID(in: workspace) else { return nil }
        if bolt.requiresExplicitAssociation {
            guard let registration = registration(id: id),
                  savedWorkspace?.devices.first(where: { $0.id == id })?.logitechAssociation == registration.logitechAssociation,
                  savedWorkspace?.preferredMouseID == workspace.preferredMouseID else { return nil }
        }
        return id
    }

    private func mouseID(for route: WorkspaceRoute) -> UUID? {
        if route == .logitechSetup { return nil }
        if case .mouse(let id) = route {
            return registration(id: id)?.family.isLogitechMouse == true ? id : nil
        }
        return mouseRegistrations.count == 1 ? mouseRegistrations[0].id : nil
    }

    var selectedMouseID: UUID? { mouseID(for: navigation.current.route) }
    func needsMouseEndpointSelection(for id: UUID?) -> Bool {
        bolt.requiresExplicitAssociation ? id.flatMap { registration(id: $0)?.logitechAssociation } == nil : mouseRegistrations.count > 1
    }
    var needsMouseEndpointSelection: Bool { needsMouseEndpointSelection(for: selectedMouseID) }
    var isSelectedMouseRuntimeTarget: Bool { selectedMouseID != nil && selectedMouseID == admissibleMouseID }
    var selectedMouseName: String { selectedMouseID.flatMap { registration(id: $0)?.displayName } ?? "Logitech Mouse" }
    var canSelectExistingMouse: Bool {
        canEditConfiguration && logitechSetupSnapshot == nil && !isBoltPairingActive && !isBoltPairingPresented &&
            selectedMouseID.flatMap { registration(id: $0) }?.isEnabled == true && !isMouseSelectorLoading
    }
    var canPairNewMouse: Bool { makeBoltPairingSession != nil && canSelectExistingMouse && !isMouseSelectorPresented }
    var isBoltPairingInProgress: Bool { isBoltPairingActive }
    var selectedMouseSupportsManagement: Bool {
        selectedMouseID.flatMap { registration(id: $0)?.mouseModel } != .mxMaster4 && selectedMouseStatus.supportsManagement
    }

    var presentedMouseOwnerID: UUID? {
        guard let lease = activeMouseLease, runtimeIdentityVerified,
              boltStatus.generation > lease.statusGenerationFloor else { return nil }
        return lease.ownerID
    }

    func mouseStatus(for id: UUID?) -> BoltStatus {
        guard let id, presentedMouseOwnerID == id else {
            if let id, id == endpointOwnerID, id == admissibleMouseID,
               let message = associationFailureMessage(for: boltStatus.failure?.code), boltStatus.phase == .failed {
                return BoltStatus(phase: .failed, message: message, availableControls: [],
                                  generation: boltStatus.generation, cleanupUncertain: boltStatus.cleanupUncertain,
                                  failure: boltStatus.failure, supportsManagement: false)
            }
            return BoltStatus(phase: .idle, message: "Connect to discover a mouse endpoint.",
                              availableControls: [], generation: boltStatus.generation, cleanupUncertain: false)
        }
        return boltStatus
    }

    var selectedMouseStatus: BoltStatus { mouseStatus(for: selectedMouseID) }

    func mouseConnectionTitle(for id: UUID) -> String {
        if needsMouseEndpointSelection(for: id) { return "Association required" }
        return switch mouseStatus(for: id).phase {
        case .idle: "Disconnected"
        case .discovering: "Connecting"
        case .ready, .enabled: "Connected"
        case .enabling: "Enabling"
        case .stopping: "Stopping"
        case .failed: "Unavailable"
        }
    }

    func mouseConnectionColor(for id: UUID) -> NSColor {
        switch mouseStatus(for: id).phase {
        case .ready, .enabled: .systemGreen
        case .discovering, .enabling, .stopping: .systemOrange
        case .failed: .systemRed
        case .idle: .tertiaryLabelColor
        }
    }

    private func synchronizeEditorProjection() {
        let saved = (savedWorkspace ?? workspace).configuration(forMouseID: selectedMouseID)
        var next = ConfigurationDraft(configuration: saved)
        next.updateDraft(workspace.configuration(forMouseID: selectedMouseID))
        document = next
    }

    private var activeMouseLease: MouseLease? {
        guard !isBoltPairingActive, let lease = mouseLease, lease.ownerID == admissibleMouseID,
              lease.epoch == lifecycleIntent, sleepCleanupTask == nil else { return nil }
        return lease
    }

    private var runtimeMouse: DeviceBindings? {
        guard let lease = activeMouseLease else { return nil }
        return workspace.configuration(forMouseID: lease.ownerID).mouse
    }

    private var runtimeIdentityVerified: Bool {
        guard bolt.requiresExplicitAssociation else { return true }
        guard let owner = activeMouseLease?.ownerID,
              let association = registration(id: owner)?.logitechAssociation else { return false }
        return boltStatus.verifiedIdentity == association.identity
    }

    private var runtimeRestorePreviousSettings: Bool {
        runtimeMouse?.restorePreviousSettingsOnDisconnect ?? cleanupRestorePreviousSettings
    }

    private func owns(_ lease: MouseLease) -> Bool { activeMouseLease == lease }

    private func performMouseOperation(
        for lease: MouseLease,
        discoveryTarget: LogitechConnectionTarget? = nil,
        _ operation: @escaping @Sendable (any BindingSession) async -> Void
    ) async {
        guard owns(lease) else { return }
        let id = UUID()
        let task = Task { [weak self, bolt] in
            guard let self, self.owns(lease) else { return }
            if let discoveryTarget {
                self.endpointRecoveryTarget = MouseEndpointTarget(ownerID: lease.ownerID,
                                                                  model: discoveryTarget.model,
                                                                  association: discoveryTarget.association)
            }
            await operation(bolt)
        }
        mouseOperations[id] = task
        await task.value
        mouseOperations.removeValue(forKey: id)
    }

    @discardableResult
    private func scheduleMouseCleanup(restore: Bool) -> Task<Bool, Never> {
        let previous = sleepCleanupTask
        let operations = Array(mouseOperations.values)
        let inventory = logitechSetupInventoryTask
        let pairingClose = boltPairingFinishTask
        let receiverManagementClose = boltReceiverManagementCloseTask
        sleepCleanupSequence = statusSequence
        let cleanup = Task { [bolt] in
            if let previous { _ = await previous.value }
            for operation in operations { await operation.value }
            if let inventory { _ = await inventory.value }
            if let pairingClose { await pairingClose.value }
            if let receiverManagementClose { await receiverManagementClose.value }
            return await bolt.stopForRestart(restorePreviousSettingsOnDisconnect: restore)
        }
        sleepCleanupTask = cleanup
        return cleanup
    }

    private func admitsInput(observedAt: ContinuousClock.Instant) -> Bool {
        guard let lease = activeMouseLease else { return false }
        return observedAt >= lease.startedAt
    }

    private var canClaimConnectedMouse: Bool {
        guard let id = admissibleMouseID, sleepCleanupTask == nil,
              !isBoltReceiverManagementActive, boltReceiverManagementCloseTask == nil else { return false }
        return endpointOwnerID == nil || endpointOwnerID == id
    }

    private func claimConnectedMouse() {
        guard !bolt.requiresExplicitAssociation, mouseLease == nil, canClaimConnectedMouse, let id = admissibleMouseID else { return }
        endpointOwnerID = id
        mouseLease = MouseLease(ownerID: id, epoch: lifecycleIntent,
                                statusGenerationFloor: boltStatus.generation == 0 ? 0 : boltStatus.generation - 1,
                                startedAt: .now)
        synchronizeLowBatteryPreference()
    }

    var permission: InputPermission { permissionChecks.eventPostingAllowed ? .granted : .denied }
    var selectedApplicationID: String? { navigation.current.applicationID }
    var selectedControl: MouseControl { navigation.current.control }
    var applicationIDs: [String] { document.draft.mouse?.applications.keys.sorted() ?? [] }
    var isBindingsEnabled: Bool { isSelectedMouseRuntimeTarget && boltStatus.phase == .enabled && actionsEnabled }

    var buttonReadiness: String {
        if !selectedMouseSupportsManagement { return "Unsupported by this mouse; basic information is available" }
        if recordingTarget != nil { return "Shortcuts paused while recording" }
        if !hasUsableConfiguration { return "Shortcuts blocked: configuration unavailable" }
        if !containsConfiguredShortcut(in: document.draft.mouse) { return "No shortcuts configured" }
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
        switch selectedMouseStatus.wheel.support {
        case .unknown: "Not observed"
        case .unsupported: "Unsupported"
        case .supported:
            switch selectedMouseStatus.wheel.observedInverted {
            case .none: "Unknown"
            case .some(false): "Standard"
            case .some(true): "Natural"
            }
        }
    }
    var wheelSessionChange: String {
        if isWheelApplyInFlight { return "Applying" }
        guard selectedMouseStatus.wheel.isOwned else { return "No active change" }
        if selectedMouseStatus.wheel.captureActive { return "Temporary capture; always released on disconnect" }
        return restorePreviousSettingsOnDisconnect ? "Will restore on disconnect" : "Kept on device"
    }
    var scrollAmountStatus: String {
        guard wheelScrollAmountDraft != nil else { return "Native scrolling" }
        if scrollPostingFailed { return "Blocked after input posting failed. Refresh permission or switch custom amount off and on to retry." }
        if let blocker = selectedMouseStatus.wheel.captureBlocker { return blocker }
        if selectedMouseStatus.wheel.captureActive { return "Active: fixed line output for this mouse" }
        if wheelScrollAmountDraft != nil && permission != .granted { return "Blocked: input posting permission required; native scrolling is active" }
        return "Waiting for a connected supported mouse"
    }
    var effectiveWheelDirection: String {
        guard let inverted = selectedMouseStatus.wheel.effectiveInverted else { return observedWheelDirection }
        return inverted ? "Natural in software" : "Standard in software"
    }
    var observedThumbwheelDirection: String {
        switch selectedMouseStatus.thumbwheel.support {
        case .unknown: "Not observed"
        case .unsupported: "Unsupported"
        case .supported:
            switch selectedMouseStatus.thumbwheel.observedInverted {
            case .none: "Unknown"
            case .some(false): "Standard"
            case .some(true): "Natural"
            }
        }
    }
    var effectiveThumbwheelDirection: String {
        guard let inverted = selectedMouseStatus.thumbwheel.effectiveInverted else { return observedThumbwheelDirection }
        return inverted ? "Natural in software" : "Standard in software"
    }
    var thumbwheelSessionChange: String {
        if isThumbwheelApplyInFlight { return "Applying" }
        guard selectedMouseStatus.thumbwheel.isOwned else { return "No active change" }
        if selectedMouseStatus.thumbwheel.captureActive { return "Temporary capture; always released on disconnect" }
        return restorePreviousSettingsOnDisconnect ? "Will restore on disconnect" : "Kept on device"
    }
    var thumbwheelScrollAmountStatus: String {
        guard thumbwheelScrollAmountDraft != nil else { return "Native thumb-wheel scrolling" }
        if thumbwheelPostingFailed { return "Blocked after thumb-wheel posting failed. Refresh permission or switch custom amount off and on to retry." }
        if let blocker = selectedMouseStatus.thumbwheel.captureBlocker { return blocker }
        if selectedMouseStatus.thumbwheel.captureActive { return "Active: fixed line output for the thumb wheel" }
        if permission != .granted { return "Blocked: input posting permission required; native scrolling is active" }
        if selectedMouseStatus.thumbwheel.support == .unsupported { return "Unsupported by this connected mouse" }
        if selectedMouseStatus.thumbwheel.support == .unknown { return "Waiting for thumb-wheel discovery" }
        return "Waiting for a connected supported mouse"
    }
    var observedWheelResolution: String {
        switch selectedMouseStatus.wheel.support {
        case .unknown: "Not observed"
        case .unsupported: "Unsupported"
        case .supported:
            switch selectedMouseStatus.wheel.observedHighResolution {
            case .none: "Unknown"
            case .some(false): "Low"
            case .some(true): "High"
            }
        }
    }
    var canDiscover: Bool {
        logitechSetupSnapshot == nil && !isBoltPairingActive && !isBoltReceiverManagementActive &&
            boltReceiverManagementCloseTask == nil && admissibleMouseID != nil && !isRestarting &&
            !isLoading && !discoveryPending && canStartDiscovery
    }
    var connectionRequested: Bool { sessionActivationRequested || wakeRecovery.isRecovering }
    var isReconnectPending: Bool { wakeRecovery.isRecovering }
    var isBackgroundRecovery: Bool {
        isReconnectPending || (sessionActivationRequested && [.stopping, .failed].contains(boltStatus.phase))
    }
    private var hasAmbiguousBoltEndpointFailure: Bool {
        isSelectedMouseRuntimeTarget && boltStatus.phase == .failed && boltStatus.failure?.code == .endpointAmbiguous
    }
    private func associationFailureMessage(for code: BoltFailureCode?) -> String? {
        guard bolt.requiresExplicitAssociation else { return nil }
        switch code {
        case .associationRequired:
            return "Use Change Connection to associate this registration before connecting."
        case .identityUnavailable:
            return "The mouse identity could not be verified. Check its connection, then use Change Connection to retry."
        case .identityMismatch:
            return "The available mouse does not match this saved association. Use Change Connection to verify the intended mouse."
        case .candidateStale:
            return "The selected connection expired. Use Change Connection to refresh the list."
        case .unsupportedModel:
            return "This mouse model or connection is unsupported. Use Change Connection to select a supported connection."
        default:
            return nil
        }
    }
    private var selectedAssociationFailureMessage: String? {
        guard selectedMouseID == endpointOwnerID, isSelectedMouseRuntimeTarget, boltStatus.phase == .failed else { return nil }
        return associationFailureMessage(for: boltStatus.failure?.code)
    }
    var connectionMessage: String {
        if let message = selectedAssociationFailureMessage { return message }
        if hasAmbiguousBoltEndpointFailure {
            return "The saved mouse has multiple matching connections. Choose an existing connection to continue."
        }
        if needsMouseEndpointSelection { return "Endpoint selection is needed. Associate an already-paired mouse to retain these settings." }
        guard isSelectedMouseRuntimeTarget && isBackgroundRecovery else {
            return selectedMouseStatus.phase == .enabled ? "Bindings enabled." : selectedMouseStatus.message
        }
        return selectedMouseStatus.deviceResponding
            ? "Mouse detected. Restoring saved settings."
            : "Mouse unavailable. Saved settings will apply when it returns."
    }
    var connectionPresentationPhase: BoltPhase {
        if selectedAssociationFailureMessage != nil { return .failed }
        if hasAmbiguousBoltEndpointFailure { return .failed }
        if needsMouseEndpointSelection { return .idle }
        guard isSelectedMouseRuntimeTarget && isBackgroundRecovery else { return selectedMouseStatus.phase }
        return selectedMouseStatus.deviceResponding ? .discovering : .idle
    }
    var canEnableBindings: Bool {
        canClaimConnectedMouse && isSelectedMouseRuntimeTarget && admissibleMouseID != nil && runtimeIdentityVerified && boltStatus.supportsManagement && !isRestarting && !isLoading && hasUsableConfiguration &&
            permission == .granted && boltStatus.phase == .ready && !boltStatus.cleanupUncertain &&
            boltStatus.availableControls == Set(MouseControl.allCases) &&
            (try? document.draft.validated()) != nil
    }

    var connectionTitle: String {
        if selectedAssociationFailureMessage != nil { return "Association needs attention" }
        if hasAmbiguousBoltEndpointFailure { return "Receiver selection needed" }
        if needsMouseEndpointSelection { return "Endpoint selection needed" }
        if isSelectedMouseRuntimeTarget && isBackgroundRecovery { return selectedMouseStatus.deviceResponding ? "Reconnecting" : "Disconnected" }
        return switch selectedMouseStatus.phase {
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
        if selectedAssociationFailureMessage != nil { return .systemRed }
        if hasAmbiguousBoltEndpointFailure { return .systemRed }
        if needsMouseEndpointSelection { return .tertiaryLabelColor }
        if isSelectedMouseRuntimeTarget && isBackgroundRecovery { return selectedMouseStatus.deviceResponding ? .systemOrange : .tertiaryLabelColor }
        return switch selectedMouseStatus.phase {
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
        if navigation.current.route != route { cancelRecording(); dismissMouseSelector(); revokeLogitechSetup(); revokeBoltPairing() }
        var next = navigation
        var location = next.current
        location.route = route
        if initialConfigurationLoadPending {
            next.replaceCurrent(with: location)
            navigation = next
            synchronizeEditorProjection()
            return
        }
        next.navigate(to: location)
        navigation = next
        synchronizeEditorProjection()
    }

    func goBack() {
        var next = navigation
        guard next.goBack() else { return }
        dismissMouseSelector()
        revokeLogitechSetup()
        revokeBoltPairing()
        cancelRecording()
        next.replaceCurrent(with: normalized(next.current))
        navigation = next
        synchronizeEditorProjection()
    }

    func goForward() {
        var next = navigation
        guard next.goForward() else { return }
        dismissMouseSelector()
        revokeLogitechSetup()
        revokeBoltPairing()
        cancelRecording()
        next.replaceCurrent(with: normalized(next.current))
        navigation = next
        synchronizeEditorProjection()
    }

    func connect() {
        guard bolt.requiresExplicitAssociation else { connectRuntime(); return }
        guard canSelectExistingMouse, let id = selectedMouseID,
              let registration = registration(id: id) else { return }
        mouseSelectorMessage = nil
        guard registration.logitechAssociation != nil else { presentLogitechSetup(destination: .reassociate(id)); return }
        if id == admissibleMouseID, boltStatus.cleanupUncertain, matchesEndpointRecoveryTarget {
            connectRuntime()
            return
        }
        Task { await activateMouseRegistration(id, candidate: nil) }
    }

    func presentLogitechSetup(destination: LogitechSetupDestination = .newRegistration) {
        presentLogitechSetup(destination: destination, automaticallyInspectStoredInventories: true)
    }

    private func presentLogitechSetup(
        destination: LogitechSetupDestination,
        automaticallyInspectStoredInventories: Bool,
        preservingCachedRows: Bool = false
    ) {
        guard canEditConfiguration else { return }
        if case .reassociate(let id) = destination {
            guard let device = registration(id: id), device.isEnabled, device.family.isLogitechMouse else { return }
        }
        let prior = logitechSetupSnapshot?.priorLocation ?? navigation.current
        let restoreConnection: Bool
        if let previous = logitechSetupSnapshot {
            restoreConnection = previous.restoreConnection && workspace == previous.workspace && fileRevision == previous.revision
        } else {
            restoreConnection = connectionRequested && workspace == savedWorkspace
        }
        let previous = logitechSetupOperationTask
        prepareForLifecycleStop(
            preservingStoredInventories: true,
            preservingLogitechSetupCandidates: preservingCachedRows
        )
        navigate(to: .logitechSetup)
        logitechSetupDestination = destination
        logitechSetupCompletedDeviceID = nil
        if !preservingCachedRows { logitechSetupCandidates = [] }
        logitechSetupMessage = nil
        boltPairingMessage = nil
        boltPairingStatus = nil
        isLogitechSetupLoading = true
        let request = LogitechSetupSnapshot(token: UUID(), destination: destination, workspace: workspace,
                                           revision: fileRevision, intent: lifecycleIntent,
                                           priorLocation: prior, restoreConnection: restoreConnection)
        logitechSetupSnapshot = request
        if requiresLogitechSetupRefreshBeforePairing {
            recoveryRefreshSetupToken = request.token
            recoveryRefreshConnectionsAreFresh = false
            recoveryRefreshReceiverInventoriesAreFresh = false
        }
        logitechSetupOperationTask = Task { [weak self, bolt] in
            if let previous { await previous.value }
            guard let self else { return }
            if let close = self.boltPairingFinishTask { await close.value }
            guard self.isCurrentLogitechSetup(request, checkingRevision: false) else { return }
            var refreshedEndpointCandidates = false
            defer {
                if self.logitechSetupSnapshot?.token == request.token {
                    if !refreshedEndpointCandidates && !self.requiresLogitechSetupRefreshBeforePairing {
                        self.logitechSetupCandidates = []
                    }
                    self.isLogitechSetupLoading = false
                }
            }
            let sequence = self.statusSequence
            let cleaned = await self.scheduleMouseCleanup(restore: self.runtimeRestorePreviousSettings).value
            guard self.isCurrentLogitechSetup(request, checkingRevision: false) else { return }
            let settled = await self.waitForSettledControllerStatus(after: sequence)
            guard self.isCurrentLogitechSetup(request, checkingRevision: false) else { return }
            guard cleaned, settled?.cleanupUncertain == false else {
                self.logitechSetupMessage = "The previous connection could not be released safely. Disconnect and retry."
                return
            }
            self.sleepCleanupTask = nil
            self.endpointOwnerID = nil
            self.endpointRecoveryTarget = nil
            let saved = await self.flushPendingSave()
            guard self.isCurrentLogitechSetup(request, checkingRevision: false) else { return }
            guard saved, self.savedWorkspace == request.workspace, await self.currentConfigurationRevisionMatches(),
                  self.isCurrentLogitechSetup(request, checkingRevision: false) else {
                self.logitechSetupMessage = "Save and verify the configuration before adding a mouse."
                return
            }
            let snapshot = LogitechSetupSnapshot(token: request.token, destination: destination, workspace: self.workspace,
                                                revision: self.fileRevision, intent: request.intent,
                                                priorLocation: prior, restoreConnection: restoreConnection)
            self.logitechSetupSnapshot = snapshot
            let inventory = Task { () -> [LogitechEndpointCandidate]? in
                try? await bolt.existingConnections()
            }
            self.logitechSetupInventoryTask = inventory
            let candidates = await inventory.value
            self.logitechSetupInventoryTask = nil
            guard self.isCurrentLogitechSetup(snapshot) else { return }
            defer {
                if self.logitechSetupSnapshot?.token == snapshot.token {
                    self.isLogitechSetupLoading = false
                    if automaticallyInspectStoredInventories {
                        self.inspectBoltReceivers()
                    }
                }
            }
            guard let candidates else {
                self.logitechSetupMessage = "Existing connections could not be checked. Refresh to retry."
                return
            }
            let verified = candidates.filter { (try? $0.identity.validated()) != nil }
            self.logitechSetupCandidates = verified.filter { candidate in
                if case .reassociate(let id) = destination { return candidate.model == self.registration(id: id)?.mouseModel }
                return true
            }
            refreshedEndpointCandidates = true
            if self.logitechSetupCandidates.isEmpty {
                let message = verified.isEmpty
                    ? "No verified mouse connection was found. Check the receiver or Bluetooth connection and refresh."
                    : "Verified mice were found, but none matches the registered model. Connect a matching mouse and refresh."
                if self.logitechSetupMessage == nil { self.logitechSetupMessage = message }
            }
            self.markRecoveryConnectionsFresh(for: snapshot.token)
        }
    }

    func refreshLogitechSetup() {
        guard let destination = logitechSetupDestination, !isBoltPairingActive,
              boltPairingFinishTask == nil, !isSaving else { return }
        if shouldShowLogitechSetupRecoveryButton {
            guard canRefreshLogitechSetup else { return }
            requireLogitechSetupRefresh()
        }
        presentLogitechSetup(
            destination: destination,
            automaticallyInspectStoredInventories: true,
            preservingCachedRows: true
        )
    }

    private func requireLogitechSetupRefresh() {
        requiresLogitechSetupRefreshBeforePairing = true
        recoveryRefreshSetupToken = nil
        recoveryRefreshConnectionsAreFresh = false
        recoveryRefreshReceiverInventoriesAreFresh = false
    }

    private func markRecoveryConnectionsFresh(for setupToken: UUID) {
        guard requiresLogitechSetupRefreshBeforePairing,
              recoveryRefreshSetupToken == setupToken,
              logitechSetupSnapshot?.token == setupToken else { return }
        recoveryRefreshConnectionsAreFresh = true
        clearRecoveryRefreshIfComplete()
    }

    private func markRecoveryReceiverInventoriesFresh(for setupToken: UUID) {
        guard requiresLogitechSetupRefreshBeforePairing,
              recoveryRefreshSetupToken == setupToken,
              logitechSetupSnapshot?.token == setupToken else { return }
        recoveryRefreshReceiverInventoriesAreFresh = true
        clearRecoveryRefreshIfComplete()
    }

    private func clearRecoveryRefreshIfComplete() {
        guard recoveryRefreshConnectionsAreFresh, recoveryRefreshReceiverInventoriesAreFresh else { return }
        requiresLogitechSetupRefreshBeforePairing = false
        recoveryRefreshSetupToken = nil
        recoveryRefreshConnectionsAreFresh = false
        recoveryRefreshReceiverInventoriesAreFresh = false
        boltPairingMayHaveSucceeded = false
    }

    func inspectBoltReceivers() {
        guard let setup = logitechSetupSnapshot,
              isCurrentLogitechSetup(setup, checkingRevision: false) else { return }
        guard let makeBoltReceiverManagementSession else {
            boltReceiverManagementMessage = "Stored-pairing inspection is unavailable."
            return
        }
        guard !isBoltPairingActive, boltPairingFinishTask == nil, !isBoltReceiverManagementBusy,
              logitechSetupInventoryTask == nil, !isLogitechSetupLoading else {
            boltReceiverManagementMessage = "Wait for the current receiver operation to finish, then refresh."
            return
        }

        let previousClose = revokeBoltReceiverManagement(preservingStoredInventories: true)
        let snapshot = BoltReceiverManagementSnapshot(token: UUID(), setupToken: setup.token, intent: setup.intent)
        let operation = BoltReceiverManagementOperation(snapshot: snapshot, token: UUID())
        boltReceiverManagementSnapshot = snapshot
        boltReceiverManagementOperationToken = operation.token
        boltManagedReceivers = []
        boltManagedInventory = nil
        isBoltManagedInventoryStale = true
        boltReceiverManagementMessage = nil
        isBoltReceiverManagementBusy = true

        boltReceiverManagementOperationTaskToken = operation.token
        boltReceiverManagementOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishBoltReceiverManagementOperation(operation) }
            if let previousClose { await previousClose.value }
            guard self.isCurrentBoltReceiverManagement(operation) else { return }
            if let pairingClose = self.boltPairingFinishTask { await pairingClose.value }
            guard self.isCurrentBoltReceiverManagement(operation) else { return }

            let sequence = self.statusSequence
            let cleanup = self.scheduleMouseCleanup(restore: self.runtimeRestorePreviousSettings)
            let cleaned = await cleanup.value
            guard self.isCurrentBoltReceiverManagement(operation) else { return }
            let settled = await self.waitForSettledControllerStatus(after: sequence)
            guard self.isCurrentBoltReceiverManagement(operation) else { return }
            guard cleaned, settled?.cleanupUncertain == false else {
                self.boltReceiverManagementMessage = "The previous connection could not be released safely. Disconnect and retry before inspecting the receiver."
                self.finishBoltReceiverManagementOperation(operation)
                return
            }
            self.sleepCleanupTask = nil
            self.endpointOwnerID = nil
            self.endpointRecoveryTarget = nil

            let session = makeBoltReceiverManagementSession()
            self.boltReceiverManagementSession = session
            do {
                let receivers = try await session.receivers()
                guard self.isCurrentBoltReceiverManagement(operation) else { return }
                self.boltManagedReceivers = receivers
                if receivers.isEmpty {
                    self.boltReceiverManagementMessage = "No accessible Logi Bolt receiver was found. Connect a receiver and retry."
                    self.finishBoltReceiverManagementOperation(operation)
                    self.markRecoveryReceiverInventoriesFresh(for: snapshot.setupToken)
                    return
                }

                var receiverLabels: [UUID: String] = [:]
                for receiver in receivers {
                    receiverLabels[receiver.id] = receiver.label
                }
                let inventoriesLoaded = await self.loadBoltManagedInventories(
                    receivers, labels: receiverLabels, session: session, operation: operation
                )
                guard self.isCurrentBoltReceiverManagement(operation) else { return }
                self.finishBoltReceiverManagementOperation(operation)
                if inventoriesLoaded {
                    self.markRecoveryReceiverInventoriesFresh(for: snapshot.setupToken)
                }
            } catch {
                guard self.isCurrentBoltReceiverManagement(operation) else { return }
                self.revokeBoltReceiverManagement(preservingStoredInventories: true)
                self.boltReceiverManagementMessage = "Logi Bolt receivers could not be checked. Refresh to retry."
            }
        }
    }

    func selectBoltManagedReceiver(_ receiverID: UUID) {
        guard let snapshot = boltReceiverManagementSnapshot,
              isCurrentBoltReceiverManagement(snapshot), !isBoltReceiverManagementBusy,
              !isBoltPairingActive, boltPairingFinishTask == nil,
              boltManagedReceivers.contains(where: { $0.id == receiverID }) else { return }

        let session = boltReceiverManagementSession
        let operation = BoltReceiverManagementOperation(snapshot: snapshot, token: UUID())
        boltReceiverManagementOperationToken = operation.token
        boltManagedInventory = nil
        isBoltManagedInventoryStale = true
        boltReceiverManagementMessage = nil
        isBoltReceiverManagementBusy = true

        boltReceiverManagementOperationTaskToken = operation.token
        boltReceiverManagementOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishBoltReceiverManagementOperation(operation) }
            guard self.isCurrentBoltReceiverManagement(operation) else { return }
            guard let session else {
                self.failBoltReceiverManagementOperation(operation, message: "Refresh the receiver list before inspecting a receiver.")
                return
            }
            await self.loadBoltManagedInventory(receiverID: receiverID, session: session, operation: operation)
            self.finishBoltReceiverManagementOperation(operation)
        }
    }

    func canUnpairStoredRecord(inventoryID: UUID, recordID: UUID) -> Bool {
        guard let snapshot = boltReceiverManagementSnapshot,
              isCurrentBoltReceiverManagement(snapshot),
              !isBoltReceiverManagementBusy, !isBoltManagedInventoryStale,
              !isLogitechSetupLoading, !isBoltPairingActive, boltPairingFinishTask == nil,
              boltReceiverManagementSession != nil,
              let inventory = boltManagedInventory, inventory.id == inventoryID,
              inventory.rows.contains(where: { $0.id == recordID }),
              boltStoredInventories.contains(where: { $0 == inventory }),
              boltManagedReceivers.contains(where: { $0.id == inventory.receiverID }) else { return false }
        return true
    }

    func unpairBoltManagedRecord(recordID: UUID, inventoryID: UUID) {
        guard let snapshot = boltReceiverManagementSnapshot,
              canUnpairStoredRecord(inventoryID: inventoryID, recordID: recordID),
              let session = boltReceiverManagementSession,
              let inventory = boltManagedInventory else {
            if isBoltReceiverManagementActive, !isBoltReceiverManagementBusy {
                boltReceiverManagementMessage = "Inspect this receiver again before unpairing a stored device."
            }
            return
        }

        let operation = BoltReceiverManagementOperation(snapshot: snapshot, token: UUID())
        boltReceiverManagementOperationToken = operation.token
        isBoltReceiverManagementBusy = true
        boltReceiverManagementMessage = nil
        boltReceiverManagementOperationTaskToken = operation.token
        boltReceiverManagementOperationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishBoltReceiverManagementOperation(operation) }
            guard self.isCurrentBoltReceiverManagement(operation),
                  self.boltManagedInventory?.id == inventoryID,
                  self.boltManagedInventory?.rows.contains(where: { $0.id == recordID }) == true else { return }

            let outcome = await session.unpair(recordID: recordID, inventoryID: inventoryID)
            let setupStillCurrent = self.logitechSetupSnapshot?.token == snapshot.setupToken &&
                self.lifecycleIntent == snapshot.intent && self.navigation.current.route == .logitechSetup
            switch outcome {
            case .verifiedRemoved(let updatedInventory):
                if setupStillCurrent {
                    self.logitechSetupCandidates = []
                    self.logitechSetupMessage = "Refresh Devices before adding a mouse."
                    self.boltPairingStatus = nil
                    self.boltPairingMessage = nil
                    self.boltPairingMayHaveSucceeded = false
                    self.boltPairingIdentityVerified = false
                    self.boltPairingAssociationSaved = false
                    self.boltPairingReceiverSelected = false
                }
                if self.boltReceiverManagementSnapshot?.token == snapshot.token,
                   self.boltManagedInventory?.id == inventoryID,
                   setupStillCurrent,
                   updatedInventory.receiverID == inventory.receiverID {
                    self.boltManagedInventory = updatedInventory
                    self.storeBoltManagedInventory(updatedInventory)
                    self.isBoltManagedInventoryStale = false
                    self.boltReceiverManagementMessage = "The selected device was unpaired and its removal was verified."
                }
            case .notRemoved(let message):
                if self.boltReceiverManagementSnapshot?.token == snapshot.token {
                    self.boltManagedInventory = nil
                    self.isBoltManagedInventoryStale = true
                    self.boltReceiverManagementMessage = message
                }
            case .uncertain:
                if self.boltReceiverManagementSnapshot?.token == snapshot.token {
                    self.revokeBoltReceiverManagement(preservingStoredInventories: true)
                    self.boltReceiverManagementMessage = "The unpair result is uncertain. Refresh the receiver list to start a new session before trying again."
                }
                if setupStillCurrent {
                    self.logitechSetupCandidates = []
                    self.logitechSetupMessage = "The receiver state is uncertain. Refresh Devices before pairing."
                }
            }
            self.finishBoltReceiverManagementOperation(operation)
        }
    }

    @discardableResult
    func closeBoltReceiverManagement() -> Task<Void, Never>? {
        closeBoltReceiverManagement(preservingStoredInventories: false)
    }

    @discardableResult
    private func closeBoltReceiverManagement(preservingStoredInventories: Bool) -> Task<Void, Never>? {
        revokeBoltReceiverManagement(preservingStoredInventories: preservingStoredInventories)
    }

    private func loadBoltManagedInventory(
        receiverID: UUID,
        session: any BoltReceiverManaging,
        operation: BoltReceiverManagementOperation
    ) async {
        guard isCurrentBoltReceiverManagement(operation) else { return }
        do {
            let inventory = try await session.inventory(receiverID: receiverID)
            guard isCurrentBoltReceiverManagement(operation) else { return }
            guard inventory.receiverID == receiverID else {
                failBoltReceiverManagementOperation(operation, message: "The receiver changed. Refresh before inspecting it.")
                return
            }
            boltManagedInventory = inventory
            storeBoltManagedInventory(inventory)
            isBoltManagedInventoryStale = false
        } catch {
            guard isCurrentBoltReceiverManagement(operation) else { return }
            failBoltReceiverManagementOperation(operation, message: "Stored pairings could not be checked. Refresh to retry.")
        }
    }

    private func loadBoltManagedInventories(
        _ receivers: [BoltReceiverCandidate],
        labels: [UUID: String],
        session: any BoltReceiverManaging,
        operation: BoltReceiverManagementOperation
    ) async -> Bool {
        var lastInventory: BoltReceiverInventory?
        var inventories: [BoltReceiverInventory] = []
        for receiver in receivers {
            guard isCurrentBoltReceiverManagement(operation) else { return false }
            do {
                let inventory = try await session.inventory(receiverID: receiver.id)
                guard isCurrentBoltReceiverManagement(operation) else { return false }
                guard inventory.receiverID == receiver.id else {
                    failBoltReceiverManagementOperation(operation, message: "The receiver changed. Refresh before inspecting it.")
                    return false
                }
                inventories.append(inventory)
                lastInventory = inventory
            } catch {
                guard isCurrentBoltReceiverManagement(operation) else { return false }
                failBoltReceiverManagementOperation(operation, message: "Stored pairings could not be checked. Refresh to retry.")
                return false
            }
        }
        guard isCurrentBoltReceiverManagement(operation) else { return false }
        boltStoredInventories = inventories
        boltStoredReceiverLabels = labels
        boltManagedInventory = lastInventory
        isBoltManagedInventoryStale = lastInventory == nil
        return true
    }

    private func storeBoltManagedInventory(_ inventory: BoltReceiverInventory) {
        if let index = boltStoredInventories.firstIndex(where: { $0.receiverID == inventory.receiverID }) {
            boltStoredInventories[index] = inventory
        } else {
            boltStoredInventories.append(inventory)
        }
    }

    private func isCurrentBoltReceiverManagement(_ operation: BoltReceiverManagementOperation) -> Bool {
        boltReceiverManagementOperationToken == operation.token &&
            isCurrentBoltReceiverManagement(operation.snapshot)
    }

    private func isCurrentBoltReceiverManagement(_ snapshot: BoltReceiverManagementSnapshot) -> Bool {
        guard boltReceiverManagementSnapshot?.token == snapshot.token,
              logitechSetupSnapshot?.token == snapshot.setupToken,
              navigation.current.route == .logitechSetup,
              lifecycleIntent == snapshot.intent,
              !isLoading, !isRestarting, !wakeRecovery.sleeping else { return false }
        return true
    }

    private func finishBoltReceiverManagementOperation(_ operation: BoltReceiverManagementOperation) {
        if boltReceiverManagementOperationTaskToken == operation.token {
            boltReceiverManagementOperationTaskToken = nil
            boltReceiverManagementOperationTask = nil
        }
        guard isCurrentBoltReceiverManagement(operation) else { return }
        boltReceiverManagementOperationToken = nil
        boltReceiverManagementOperationTask = nil
        isBoltReceiverManagementBusy = false
    }

    private func failBoltReceiverManagementOperation(_ operation: BoltReceiverManagementOperation, message: String) {
        guard isCurrentBoltReceiverManagement(operation) else { return }
        revokeBoltReceiverManagement(preservingStoredInventories: true)
        boltReceiverManagementMessage = message
    }

    @discardableResult
    private func retireBoltReceiverManagementSession() -> Task<Void, Never>? {
        if let boltReceiverManagementCloseTask { return boltReceiverManagementCloseTask }
        guard let session = boltReceiverManagementSession else { return nil }
        boltReceiverManagementSession = nil
        let operation = boltReceiverManagementOperationTask
        let token = UUID()
        boltReceiverManagementCloseToken = token
        let close = Task { @MainActor [weak self] in
            await session.close()
            if let operation { await operation.value }
            guard let self, self.boltReceiverManagementCloseToken == token else { return }
            self.boltReceiverManagementCloseTask = nil
            self.boltReceiverManagementCloseToken = nil
        }
        boltReceiverManagementCloseTask = close
        return close
    }

    @discardableResult
    private func revokeBoltReceiverManagement(preservingStoredInventories: Bool = false) -> Task<Void, Never>? {
        boltReceiverManagementSnapshot = nil
        boltReceiverManagementOperationToken = nil
        isBoltReceiverManagementBusy = false
        boltManagedReceivers = []
        boltManagedInventory = nil
        isBoltManagedInventoryStale = true
        if !preservingStoredInventories {
            boltStoredInventories = []
            boltStoredReceiverLabels = [:]
        }
        boltReceiverManagementMessage = nil
        return retireBoltReceiverManagementSession()
    }

    func existingLogitechRegistrationID(for candidate: LogitechEndpointCandidate) -> UUID? {
        registeredDevices.first { $0.logitechAssociation?.identity == candidate.identity }?.id
    }

    func addLogitechSetupCandidate(_ id: UUID) {
        guard let snapshot = logitechSetupSnapshot, isCurrentLogitechSetup(snapshot), !isLogitechSetupLoading,
              !isBoltPairingActive, !isBoltReceiverManagementBusy, !isLogitechSetupSelectionBlocked,
              let candidate = logitechSetupCandidates.first(where: { $0.id == id }) else { return }
        if let existing = existingLogitechRegistrationID(for: candidate) {
            if snapshot.destination != .reassociate(existing) {
                logitechSetupMessage = "This mouse is already added. Open the existing device to retain its settings."
                return
            }
        }
        let receiverManagementClose = closeBoltReceiverManagement()
        isLogitechSetupLoading = true
        logitechSetupOperationTask = Task { [weak self] in
            if let receiverManagementClose { await receiverManagementClose.value }
            guard let self else { return }
            let id = await self.commitLogitechSetupCandidate(candidate, snapshot: snapshot)
            self.isLogitechSetupLoading = false
            guard id != nil, self.isCurrentLogitechSetup(snapshot, checkingRevision: false, checkingWorkspace: false) else { return }
            self.completeLogitechSetup()
        }
    }

    func pairLogitechSetup(receiverID: UUID? = nil) {
        if let receiverID, isBoltPairingActive { selectBoltPairingReceiver(receiverID); return }
        guard let snapshot = logitechSetupSnapshot, isCurrentLogitechSetup(snapshot), !isLogitechSetupLoading,
              makeBoltPairingSession != nil, !isBoltPairingActive, !isBoltReceiverManagementBusy,
              !isLogitechSetupSelectionBlocked else { return }
        let model: LogitechMouseModel?
        let id: UUID
        switch snapshot.destination {
        case .newRegistration: model = nil; id = UUID()
        case .reassociate(let registrationID): model = registration(id: registrationID)?.mouseModel; id = registrationID
        }
        let preparationToken = UUID()
        boltPairingPreparationToken = preparationToken
        isBoltPairingLoading = true
        let receiverManagementClose = closeBoltReceiverManagement(preservingStoredInventories: true)
        Task { @MainActor [weak self] in
            if let receiverManagementClose { await receiverManagementClose.value }
            guard let self, self.boltPairingPreparationToken == preparationToken else { return }
            self.boltPairingPreparationToken = nil
            guard self.isCurrentLogitechSetup(snapshot), !self.isLogitechSetupLoading,
                  !self.isBoltPairingActive, !self.isBoltReceiverManagementBusy else {
                self.isBoltPairingLoading = false
                return
            }
            self.startBoltPairing(registrationID: id, model: model, setup: snapshot)
        }
    }

    func cancelLogitechSetupPairing() {
        if boltPairingPreparationToken != nil {
            boltPairingPreparationToken = nil
            isBoltPairingLoading = false
            return
        }
        guard isBoltPairingActive, let snapshot = logitechSetupSnapshot else { return }
        boltPairingRevoked = true
        finishBoltPairing(cancel: true, restore: false)
        isLogitechSetupLoading = true
        let close = boltPairingFinishTask
        let previous = logitechSetupOperationTask
        logitechSetupOperationTask = Task { [weak self] in
            if let previous { await previous.value }
            if let close { await close.value }
            guard let self else { return }
            self.isLogitechSetupLoading = false
            guard self.isCurrentLogitechSetup(snapshot, checkingRevision: false, checkingWorkspace: false) else { return }
            let outcome = self.boltPairingMessage
            self.presentLogitechSetup(
                destination: snapshot.destination,
                automaticallyInspectStoredInventories: false,
                preservingCachedRows: true
            )
            self.logitechSetupMessage = outcome
        }
    }

    func cancelLogitechSetup() { leaveLogitechSetup() }

    func openExistingLogitechSetupDevice(_ id: UUID) {
        guard registration(id: id)?.family.isLogitechMouse == true else { return }
        leaveLogitechSetup(opening: id)
    }

    private func leaveLogitechSetup(opening id: UUID? = nil) {
        guard let snapshot = logitechSetupSnapshot else {
            if let id { navigate(to: .mouse(id)) }
            else if navigation.current.route == .logitechSetup { navigate(to: .devices) }
            return
        }
        revokeLogitechSetup()
        revokeBoltPairing()
        let receiverManagementClose = closeBoltReceiverManagement()
        let pending = logitechSetupOperationTask
        let close = boltPairingFinishTask
        Task { [weak self] in
            if let pending { await pending.value }
            if let close { await close.value }
            if let receiverManagementClose { await receiverManagementClose.value }
            guard let self, self.navigation.current.route == .logitechSetup,
                  self.logitechSetupSnapshot == nil, self.lifecycleIntent == snapshot.intent,
                  !self.isRestarting, !self.wakeRecovery.sleeping else { return }
            var destination = self.normalized(snapshot.priorLocation)
            if let id, self.registration(id: id)?.family.isLogitechMouse == true {
                destination.route = .mouse(id)
                destination.applicationID = nil
            }
            var next = self.navigation
            next.replaceCurrent(with: destination)
            self.navigation = next
            self.synchronizeEditorProjection()
            if snapshot.restoreConnection, self.workspace == snapshot.workspace, self.fileRevision == snapshot.revision,
               await self.currentConfigurationRevisionMatches(),
               self.navigation.current == destination,
               self.workspace == snapshot.workspace, self.fileRevision == snapshot.revision,
               self.lifecycleIntent == snapshot.intent, !self.isRestarting, !self.wakeRecovery.sleeping {
                self.connectRuntime()
            }
        }
    }

    func dismissLogitechSetup() {
        revokeLogitechSetup()
        revokeBoltPairing()
    }

    func openLogitechSetupDevice() {
        guard let id = logitechSetupCompletedDeviceID, registration(id: id) != nil else { return }
        navigate(to: .mouse(id))
    }

    func addAnotherLogitechDevice() { presentLogitechSetup() }

    private func revokeLogitechSetup(
        preservingStoredInventories: Bool = false,
        preservingCandidates: Bool = false
    ) {
        closeBoltReceiverManagement(preservingStoredInventories: preservingStoredInventories)
        guard logitechSetupSnapshot != nil else { return }
        logitechSetupSnapshot = nil
        isLogitechSetupLoading = false
        if !preservingCandidates { logitechSetupCandidates = [] }
        logitechSetupMessage = "The setup changed or was cancelled. Refresh before adding a mouse."
    }

    private func isCurrentLogitechSetup(
        _ snapshot: LogitechSetupSnapshot, checkingRevision: Bool = true, checkingWorkspace: Bool = true
    ) -> Bool {
        guard logitechSetupSnapshot?.token == snapshot.token, logitechSetupDestination == snapshot.destination,
              navigation.current.route == .logitechSetup, lifecycleIntent == snapshot.intent,
              (!checkingRevision || fileRevision == snapshot.revision),
              (!checkingWorkspace || workspace == snapshot.workspace),
              !isLoading, !isRestarting, !wakeRecovery.sleeping else { return false }
        if case .reassociate(let id) = snapshot.destination {
            return registration(id: id)?.isEnabled == true &&
                registration(id: id)?.mouseModel == snapshot.workspace.devices.first(where: { $0.id == id })?.mouseModel
        }
        return true
    }

    private func completeLogitechSetup() {
        guard let id = logitechSetupCompletedDeviceID, registration(id: id)?.isEnabled == true else { return }
        logitechSetupSnapshot = nil
        isLogitechSetupLoading = false
        logitechSetupMessage = nil
        navigate(to: .mouse(id))
        connectRuntime()
    }

    private func commitLogitechSetupCandidate(
        _ candidate: LogitechEndpointCandidate, snapshot: LogitechSetupSnapshot
    ) async -> UUID? {
        guard isCurrentLogitechSetup(snapshot), (try? candidate.identity.validated()) != nil,
              await currentConfigurationRevisionMatches(), isCurrentLogitechSetup(snapshot) else { return nil }
        if let existing = existingLogitechRegistrationID(for: candidate), snapshot.destination != .reassociate(existing) {
            logitechSetupMessage = "This mouse is already added. Open the existing device to retain its settings."
            return nil
        }
        if let pending = saveTask { _ = await pending.value }
        guard isCurrentLogitechSetup(snapshot), savedWorkspace == workspace else { return nil }
        let base = workspace
        var proposed = base
        let id: UUID
        switch snapshot.destination {
        case .newRegistration:
            guard proposed.devices.count < 256, let device = RegisteredDevice.make(family: candidate.model.family) else { return nil }
            proposed.devices.append(device)
            id = device.id
        case .reassociate(let registrationID):
            guard registration(id: registrationID)?.mouseModel == candidate.model else { return nil }
            id = registrationID
        }
        guard let index = proposed.devices.firstIndex(where: { $0.id == id }) else { return nil }
        proposed.devices[index].logitechAssociation = LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection)
        proposed.preferredMouseID = id
        guard let validated = try? proposed.validated() else { return nil }
        let stagedDevice = validated.devices[index]
        let revision = fileRevision
        autosaveTask?.cancel()
        autosaveTask = nil
        isSaving = true
        // The shared lane fences canonical autosaves while the staged registration is unpublished.
        let publication = Task { @MainActor [self] in
            defer { isSaving = false; saveTask = nil }
            do {
                let saved = try await store.save(validated, expecting: revision)
                fileRevision = saved.revision
                savedWorkspace = saved.workspace
                switch snapshot.destination {
                case .newRegistration:
                    workspace.devices.append(stagedDevice)
                case .reassociate:
                    if let current = workspace.devices.firstIndex(where: { $0.id == id }),
                       workspace.devices[current].logitechAssociation == base.devices[index].logitechAssociation {
                        workspace.devices[current].logitechAssociation = stagedDevice.logitechAssociation
                    }
                }
                if workspace.preferredMouseID == base.preferredMouseID, registration(id: id)?.isEnabled == true {
                    workspace.preferredMouseID = id
                }
                synchronizeEditorProjection()
                synchronizeD200X()
                configurationSaveError = nil
                configurationFailureKind = nil
                logitechSetupCompletedDeviceID = id
                return true
            } catch {
                configurationSaveError = error.localizedDescription
                configurationFailureKind = (error as? ConfigurationError) == .revisionConflict ? .conflict : .save
                logitechSetupMessage = "The verified mouse could not be saved. Resolve the configuration error and retry."
                return false
            }
        }
        saveTask = publication
        let saved = await publication.value
        if isDirty { scheduleAutosave() }
        guard saved else { return nil }
        guard isCurrentLogitechSetup(snapshot, checkingRevision: false, checkingWorkspace: false) else {
            logitechSetupMessage = "The mouse was saved; connection was cancelled. Open the device when ready."
            return id
        }
        guard workspace == savedWorkspace, await currentConfigurationRevisionMatches(),
              isCurrentLogitechSetup(snapshot, checkingRevision: false, checkingWorkspace: false) else {
            revokeLogitechSetup()
            logitechSetupMessage = "The mouse was saved; configuration changed before connection. Open the device when ready."
            return id
        }
        return id
    }

    func addDeviceAndPair(_ family: DeviceFamily) {
        guard family.isLogitechMouse else { addDevice(family); return }
        presentLogitechSetup()
    }

    func presentBoltPairing() {
        guard canPairNewMouse, let id = selectedMouseID,
              let model = registration(id: id)?.mouseModel else { return }
        startBoltPairing(registrationID: id, model: model, setup: nil)
    }

    private func startBoltPairing(registrationID id: UUID, model: LogitechMouseModel?, setup: LogitechSetupSnapshot?) {
        guard let makeBoltPairingSession, !isBoltPairingActive else { return }
        let restoreConnection = setup?.restoreConnection ?? (connectionRequested && workspace == savedWorkspace)
        let restore = runtimeRestorePreviousSettings
        if setup == nil { prepareForLifecycleStop() }
        isBoltPairingPresented = setup == nil
        isBoltPairingLoading = true
        boltPairingMessage = nil
        boltPairingStatus = nil
        boltPairingReceivers = []
        boltPairingRevoked = false
        boltPairingMayHaveSucceeded = false
        boltPairingAssociationSaved = false
        boltPairingIdentityVerified = false
        boltPairingReceiverSelected = false
        let request = BoltPairingSnapshot(token: UUID(), registrationID: id, model: model, setup: setup,
                                          workspace: workspace, revision: fileRevision,
                                          intent: lifecycleIntent, restoreConnection: restoreConnection)
        boltPairingSnapshot = request
        let session = makeBoltPairingSession()
        boltPairingSession = session
        boltPairingEventTask = Task { [weak self] in
            for await status in session.events {
                guard !Task.isCancelled, let self, self.boltPairingSnapshot?.token == request.token else { return }
                self.receiveBoltPairing(status)
            }
        }
        let sequence = statusSequence
        let cleanup = scheduleMouseCleanup(restore: restore)
        Task { [weak self] in
            guard let self else { return }
            let cleaned = await cleanup.value
            guard self.requireCurrentBoltPairing(request, checkingRevision: false) else { return }
            let settled = await self.waitForSettledControllerStatus(after: sequence)
            guard self.requireCurrentBoltPairing(request, checkingRevision: false) else { return }
            guard cleaned, settled?.cleanupUncertain == false else {
                self.boltPairingMessage = "The previous connection could not be released safely. Disconnect and retry."
                self.requireLogitechSetupRefresh()
                self.finishBoltPairing(cancel: true, restore: false)
                return
            }
            self.sleepCleanupTask = nil
            self.endpointOwnerID = nil
            self.endpointRecoveryTarget = nil
            let saved = await self.flushPendingSave()
            guard self.requireCurrentBoltPairing(request, checkingRevision: false) else { return }
            guard saved, self.savedWorkspace == request.workspace,
                  await self.currentConfigurationRevisionMatches(),
                  self.isCurrentBoltPairing(request, checkingRevision: false) else {
                self.boltPairingMessage = "Save and verify the configuration before pairing a mouse."
                self.finishBoltPairing(cancel: true, restore: false)
                return
            }
            let snapshot = BoltPairingSnapshot(token: request.token, registrationID: id, model: model, setup: setup,
                                               workspace: self.workspace, revision: self.fileRevision,
                                               intent: request.intent, restoreConnection: restoreConnection)
            self.boltPairingSnapshot = snapshot
            do {
                let receivers = try await session.receivers()
                guard self.requireCurrentBoltPairing(snapshot) else { return }
                self.boltPairingReceivers = receivers
                self.isBoltPairingLoading = false
                if receivers.isEmpty { self.boltPairingMessage = "No accessible Logi Bolt receiver was found. Connect a receiver and retry." }
                if setup != nil, receivers.count == 1, let receiver = receivers.first {
                    self.selectBoltPairingReceiver(receiver.id)
                }
            } catch {
                guard self.requireCurrentBoltPairing(snapshot) else { return }
                self.boltPairingMessage = "Logi Bolt receivers could not be checked. Stop pairing and retry."
                self.requireLogitechSetupRefresh()
                self.finishBoltPairing(cancel: true, restore: true)
            }
        }
    }

    func selectBoltPairingReceiver(_ id: UUID) {
        guard let snapshot = boltPairingSnapshot, isCurrentBoltPairing(snapshot),
              boltPairingFinishTask == nil, !isBoltPairingLoading, !boltPairingReceiverSelected,
              boltPairingReceivers.contains(where: { $0.id == id }), let session = boltPairingSession else { return }
        boltPairingReceiverSelected = true
        isBoltPairingLoading = true
        Task { await session.start(receiverID: id) }
    }

    func selectBoltPairingCandidate(_ id: UUID) {
        guard let snapshot = boltPairingSnapshot, isCurrentBoltPairing(snapshot),
              boltPairingFinishTask == nil, !isBoltPairingLoading,
              boltPairingStatus?.phase == .awaitingSelection,
              boltPairingStatus?.candidates.contains(where: { $0.id == id && (snapshot.model == nil || $0.model == snapshot.model) }) == true,
              let session = boltPairingSession else { return }
        isBoltPairingLoading = true
        Task { await session.select(candidateID: id) }
    }

    func dismissBoltPairing() {
        isBoltPairingPresented = false
        if boltPairingPreparationToken != nil {
            boltPairingPreparationToken = nil
            isBoltPairingLoading = false
            return
        }
        guard isBoltPairingActive else { return }
        boltPairingRevoked = true
        finishBoltPairing(cancel: true, restore: true)
    }

    private func revokeBoltPairing() {
        if boltPairingPreparationToken != nil {
            boltPairingPreparationToken = nil
            isBoltPairingLoading = false
        }
        guard isBoltPairingActive else { return }
        boltPairingRevoked = true
        isBoltPairingPresented = false
        finishBoltPairing(cancel: true, restore: false)
    }

    private func isCurrentBoltPairing(_ snapshot: BoltPairingSnapshot, checkingRevision: Bool = true) -> Bool {
        let destinationMatches: Bool
        if let setup = snapshot.setup {
            destinationMatches = isCurrentLogitechSetup(setup, checkingRevision: checkingRevision)
        } else {
            destinationMatches = selectedMouseID == snapshot.registrationID && registration(id: snapshot.registrationID)?.isEnabled == true &&
                registration(id: snapshot.registrationID)?.mouseModel == snapshot.model
        }
        return boltPairingSnapshot?.token == snapshot.token && !boltPairingRevoked && destinationMatches &&
            workspace == snapshot.workspace && (!checkingRevision || fileRevision == snapshot.revision) &&
            lifecycleIntent == snapshot.intent && !isRestarting && !isLoading && !wakeRecovery.sleeping
    }

    private func requireCurrentBoltPairing(_ snapshot: BoltPairingSnapshot, checkingRevision: Bool = true) -> Bool {
        guard isCurrentBoltPairing(snapshot, checkingRevision: checkingRevision) else {
            if boltPairingSnapshot?.token == snapshot.token { revokeBoltPairing() }
            return false
        }
        return true
    }

    private func receiveBoltPairing(_ status: BoltPairingStatus) {
        boltPairingStatus = status
        boltPairingMayHaveSucceeded = boltPairingMayHaveSucceeded || status.pairingMayHaveSucceeded || status.verifiedCandidate != nil
        boltPairingIdentityVerified = boltPairingIdentityVerified || status.verifiedCandidate != nil
        if [.failed, .cancelled, .pairedButNotAdded].contains(status.phase) {
            requireLogitechSetupRefresh()
        }
        if boltPairingRevoked, boltPairingMayHaveSucceeded { recordPairedButNotAdded() }
        switch status.phase {
        case .verified:
            finishBoltPairing(cancel: false, restore: false)
        case .failed, .cancelled, .pairedButNotAdded:
            finishBoltPairing(cancel: false, restore: true)
        case .discovering, .awaitingSelection, .authenticating, .verifying:
            isBoltPairingLoading = false
        default:
            break
        }
    }

    private func recordPairedButNotAdded() {
        if boltPairingAssociationSaved {
            boltPairingMessage = "Paired and saved; connection cancelled. The association is retained. Connect when you are ready."
        } else if boltPairingIdentityVerified {
            boltPairingMessage = "Paired, but not added to Hidhogg. Refresh Devices to associate it. Pairing was not undone."
        } else {
            boltPairingMessage = "Pairing may have completed, but the mouse was not added to Hidhogg. Refresh Devices to check. Pairing was not undone."
        }
    }

    private func finishBoltPairing(cancel: Bool, restore: Bool) {
        guard boltPairingFinishTask == nil, let snapshot = boltPairingSnapshot,
              let session = boltPairingSession else { return }
        boltPairingFinishTask = Task { [weak self] in
            guard let self else { return }
            if cancel { await session.cancel() }
            await session.close()
            self.boltPairingEventTask?.cancel()
            self.boltPairingEventTask = nil
            let finalStatus = await session.currentStatus()
            guard self.boltPairingSnapshot?.token == snapshot.token else { return }
            self.boltPairingStatus = finalStatus
            let definiteFailureWithoutVerifiedIdentity = finalStatus.phase == .failed &&
                !finalStatus.pairingMayHaveSucceeded && finalStatus.verifiedCandidate == nil &&
                !self.boltPairingIdentityVerified
            self.boltPairingMayHaveSucceeded = definiteFailureWithoutVerifiedIdentity
                ? false
                : self.boltPairingMayHaveSucceeded || finalStatus.pairingMayHaveSucceeded || finalStatus.verifiedCandidate != nil
            self.boltPairingIdentityVerified = self.boltPairingIdentityVerified || finalStatus.verifiedCandidate != nil
            if [.failed, .cancelled, .pairedButNotAdded].contains(finalStatus.phase) {
                self.requireLogitechSetupRefresh()
            }
            self.isBoltPairingLoading = false
            var activated = false
            if !cancel, finalStatus.phase == .verified, let candidate = finalStatus.verifiedCandidate,
               self.isCurrentBoltPairing(snapshot) {
                activated = await self.savePairedMouse(candidate, snapshot: snapshot)
            }
            if !activated, self.boltPairingMayHaveSucceeded {
                self.requireLogitechSetupRefresh()
                self.recordPairedButNotAdded()
            }
            let mayRestore = !activated && !self.boltPairingMayHaveSucceeded && restore && snapshot.restoreConnection &&
                self.workspace == snapshot.workspace && self.fileRevision == snapshot.revision &&
                self.lifecycleIntent == snapshot.intent && !self.isRestarting && !self.wakeRecovery.sleeping
            self.boltPairingSession = nil
            self.boltPairingSnapshot = nil
            self.boltPairingFinishTask = nil
            if activated {
                self.isBoltPairingPresented = false
                self.boltPairingMessage = nil
                self.requiresLogitechSetupRefreshBeforePairing = false
                self.recoveryRefreshSetupToken = nil
                self.recoveryRefreshConnectionsAreFresh = false
                self.recoveryRefreshReceiverInventoriesAreFresh = false
                if snapshot.setup != nil {
                    self.completeLogitechSetup()
                } else {
                    self.connectRuntime()
                }
            } else if mayRestore, await self.currentConfigurationRevisionMatches(),
                      self.workspace == snapshot.workspace, self.lifecycleIntent == snapshot.intent,
                      self.fileRevision == snapshot.revision, !self.isRestarting, !self.wakeRecovery.sleeping {
                self.connectRuntime()
            }
            if finalStatus.notificationCleanupRequiresAttention {
                let cleanupWarning = "The Bolt receiver notification cleanup could not be verified. Review receiver state before pairing again."
                let message: String
                if let existingMessage = self.errorMessage, !existingMessage.isEmpty {
                    message = existingMessage.contains(cleanupWarning)
                        ? existingMessage
                        : "\(existingMessage)\n\n\(cleanupWarning)"
                } else {
                    message = cleanupWarning
                }
                self.reportError(
                    message,
                    code: .boltCleanupUncertain,
                    diagnosticMessage: "Bolt pairing receiver notification cleanup could not be verified."
                )
            }
        }
    }

    private func savePairedMouse(_ candidate: LogitechEndpointCandidate, snapshot: BoltPairingSnapshot) async -> Bool {
        if let setup = snapshot.setup {
            guard isCurrentBoltPairing(snapshot), candidate.connection == .bolt else { return false }
            let id = await commitLogitechSetupCandidate(candidate, snapshot: setup)
            boltPairingAssociationSaved = id != nil
            return id != nil && isCurrentLogitechSetup(setup, checkingRevision: false, checkingWorkspace: false) && !boltPairingRevoked
        }
        guard isCurrentBoltPairing(snapshot), candidate.model == snapshot.model, candidate.connection == .bolt,
              (try? candidate.identity.validated()) != nil,
              !workspace.devices.contains(where: { $0.id != snapshot.registrationID && $0.logitechAssociation?.identity == candidate.identity }),
              await currentConfigurationRevisionMatches(), isCurrentBoltPairing(snapshot),
              let index = workspace.devices.firstIndex(where: { $0.id == snapshot.registrationID }) else { return false }
        workspace.devices[index].logitechAssociation = LogitechAssociation(identity: candidate.identity, preferredConnection: .bolt)
        workspace.preferredMouseID = snapshot.registrationID
        synchronizeEditorProjection()
        let submitted = workspace
        let saved = await flushPendingSave()
        boltPairingAssociationSaved = saved && savedWorkspace?.devices.first(where: { $0.id == snapshot.registrationID })?.logitechAssociation?.identity == candidate.identity
        guard saved, !boltPairingRevoked, boltPairingSnapshot?.token == snapshot.token,
              lifecycleIntent == snapshot.intent, selectedMouseID == snapshot.registrationID,
              workspace == submitted, savedWorkspace == submitted, !isRestarting, !wakeRecovery.sleeping,
              await currentConfigurationRevisionMatches(), !boltPairingRevoked,
              workspace == submitted, lifecycleIntent == snapshot.intent else {
            if !saved, workspace == submitted {
                workspace = snapshot.workspace
                synchronizeEditorProjection()
            }
            return false
        }
        return true
    }

    func presentMouseSelector() {
        guard canSelectExistingMouse, let id = selectedMouseID else { return }
        isMouseSelectorPresented = true
        isMouseSelectorLoading = true
        mouseConnectionChoices = []
        mouseSelectorMessage = nil
        let restore = runtimeRestorePreviousSettings
        prepareForLifecycleStop()
        let request = MouseSelectionSnapshot(token: UUID(), registrationID: id, revision: fileRevision,
                                             workspace: workspace, intent: lifecycleIntent)
        mouseSelectionSnapshot = request
        let sequence = statusSequence
        let cleanup = scheduleMouseCleanup(restore: restore)
        Task { [weak self, bolt] in
            guard let self else { return }
            defer {
                if self.mouseSelectionSnapshot?.token == request.token {
                    self.isMouseSelectorLoading = false
                }
            }
            let cleaned = await cleanup.value
            guard self.isCurrentSelection(request) else { return }
            let settled = await self.waitForSettledControllerStatus(after: sequence)
            guard self.isCurrentSelection(request) else { return }
            guard cleaned, settled?.cleanupUncertain == false else {
                self.mouseSelectorMessage = "The previous connection could not be released safely. Disconnect and retry."
                return
            }
            self.sleepCleanupTask = nil
            self.endpointOwnerID = nil
            self.endpointRecoveryTarget = nil
            let snapshot = MouseSelectionSnapshot(token: request.token, registrationID: id, revision: self.fileRevision,
                                                  workspace: self.workspace, intent: self.lifecycleIntent)
            self.mouseSelectionSnapshot = snapshot
            let candidates: [LogitechEndpointCandidate]
            do {
                candidates = try await bolt.existingConnections()
            } catch {
                guard self.mouseSelectionSnapshot?.token == snapshot.token else { return }
                self.mouseSelectorMessage = "Existing connections could not be checked. Refresh to retry."
                return
            }
            guard self.mouseSelectionSnapshot?.token == snapshot.token else { return }
            guard self.isCurrentSelection(snapshot) else {
                self.mouseSelectorMessage = "The configuration changed. Refresh the list before associating."
                return
            }
            self.mouseConnectionChoices = candidates.filter {
                $0.model == self.registration(id: id)?.mouseModel
            }
            if self.mouseConnectionChoices.isEmpty {
                self.mouseSelectorMessage = candidates.isEmpty
                    ? "No verified mouse connection was found. Check the receiver or Bluetooth connection and refresh."
                    : "Verified mice were found, but none matches this registration’s model. Select the matching registration and retry."
            }
        }
    }

    func dismissMouseSelector() {
        mouseActivationID = nil
        mouseSelectionSnapshot = nil
        isMouseSelectorPresented = false
        isMouseSelectorLoading = false
        mouseConnectionChoices = []
    }

    func associateMouse(candidateID: UUID) {
        guard let snapshot = mouseSelectionSnapshot, isCurrentSelection(snapshot),
              let candidate = mouseConnectionChoices.first(where: { $0.id == candidateID }) else {
            mouseSelectorMessage = "The selection changed. Refresh the list before associating."
            return
        }
        isMouseSelectorLoading = true
        Task { await activateMouseRegistration(snapshot.registrationID, candidate: candidate, snapshot: snapshot) }
    }

    private func isCurrentSelection(_ snapshot: MouseSelectionSnapshot) -> Bool {
        mouseSelectionSnapshot?.token == snapshot.token && selectedMouseID == snapshot.registrationID &&
            fileRevision == snapshot.revision && workspace == snapshot.workspace &&
            lifecycleIntent == snapshot.intent && !isRestarting && !isLoading
    }

    private func activateMouseRegistration(
        _ id: UUID, candidate: LogitechEndpointCandidate?, snapshot: MouseSelectionSnapshot? = nil
    ) async {
        guard canEditConfiguration, let registration = registration(id: id), registration.isEnabled,
              registration.family.isLogitechMouse else { return }
        if let snapshot, !isCurrentSelection(snapshot) { return }
        if let candidate {
            guard candidate.model == registration.mouseModel,
                  (try? candidate.identity.validated()) != nil,
                  !workspace.devices.contains(where: {
                      $0.id != id && $0.logitechAssociation?.identity == candidate.identity
                  }) else {
                mouseSelectorMessage = "This mouse is already associated with another registration, or its identity is unavailable."
                isMouseSelectorLoading = false
                return
            }
        }
        isMouseSelectorLoading = true
        let activationID = UUID()
        mouseActivationID = activationID
        defer {
            if mouseActivationID == activationID {
                isMouseSelectorLoading = false
                mouseActivationID = nil
            }
        }
        let originalWorkspace = workspace
        let revision = fileRevision
        let restore = runtimeRestorePreviousSettings
        prepareForLifecycleStop()
        let intent = lifecycleIntent
        let sequence = statusSequence
        let cleaned = await scheduleMouseCleanup(restore: restore).value
        guard mouseActivationID == activationID, lifecycleIntent == intent, workspace == originalWorkspace, fileRevision == revision,
              selectedMouseID == id, !isRestarting else {
            isMouseSelectorLoading = false
            return
        }
        let settled = await waitForSettledControllerStatus(after: sequence)
        guard mouseActivationID == activationID, lifecycleIntent == intent, workspace == originalWorkspace, fileRevision == revision,
              selectedMouseID == id, !isRestarting else {
            isMouseSelectorLoading = false
            return
        }
        guard cleaned, settled?.cleanupUncertain == false else {
            mouseSelectorMessage = "The previous connection could not be released safely. Disconnect and retry."
            isMouseSelectorLoading = false
            return
        }
        sleepCleanupTask = nil
        endpointOwnerID = nil
        endpointRecoveryTarget = nil
        guard let index = workspace.devices.firstIndex(where: { $0.id == id }) else { return }
        if let candidate {
            workspace.devices[index].logitechAssociation = LogitechAssociation(
                identity: candidate.identity, preferredConnection: candidate.connection)
        }
        workspace.preferredMouseID = id
        synchronizeEditorProjection()
        let submitted = workspace
        let saved = await flushPendingSave()
        guard mouseActivationID == activationID, lifecycleIntent == intent, workspace == submitted, selectedMouseID == id, !isRestarting else {
            isMouseSelectorLoading = false
            return
        }
        guard saved, savedWorkspace == submitted, await currentConfigurationRevisionMatches(),
              mouseActivationID == activationID, lifecycleIntent == intent, workspace == submitted, selectedMouseID == id else {
            mouseSelectorMessage = "The association could not be saved and verified. The mouse remains unmanaged; resolve the configuration error and retry."
            isMouseSelectorLoading = false
            return
        }
        pendingMouseCandidateID = candidate?.id
        dismissMouseSelector()
        connectRuntime()
    }

    private func currentConfigurationRevisionMatches() async -> Bool {
        guard bolt.requiresExplicitAssociation else { return true }
        let revision = fileRevision
        do {
            let current = try await store.load()
            guard fileRevision == revision, current.revision == revision else {
                configurationFailureKind = .conflict
                configurationSaveError = "The configuration changed outside Hidhogg. Reload before connecting."
                return false
            }
            return true
        } catch {
            configurationFailureKind = .load
            configurationLoadError = "The saved association could not be verified."
            return false
        }
    }

    private var matchesEndpointRecoveryTarget: Bool {
        guard bolt.requiresExplicitAssociation, let target = endpointRecoveryTarget,
              target.ownerID == endpointOwnerID, target.ownerID == admissibleMouseID,
              let registration = registration(id: target.ownerID), registration.isEnabled,
              registration.mouseModel == target.model, registration.logitechAssociation == target.association,
              let saved = savedWorkspace?.devices.first(where: { $0.id == target.ownerID }),
              saved.mouseModel == target.model, saved.logitechAssociation == target.association,
              savedWorkspace?.preferredMouseID == target.ownerID else { return false }
        return true
    }

    private func canRecoverUncertainEndpoint(after status: BoltStatus?) async -> Bool {
        guard let status, status.cleanupUncertain, [.idle, .failed].contains(status.phase),
              matchesEndpointRecoveryTarget else { return false }
        let target = endpointRecoveryTarget
        let intent = lifecycleIntent
        let revision = fileRevision
        guard await currentConfigurationRevisionMatches(), !Task.isCancelled,
              lifecycleIntent == intent, fileRevision == revision,
              endpointRecoveryTarget == target, matchesEndpointRecoveryTarget else { return false }
        return true
    }

    private func discoverMouse(for lease: MouseLease) async {
        guard owns(lease) else { return }
        guard bolt.requiresExplicitAssociation else {
            await performMouseOperation(for: lease) { await $0.discover() }
            return
        }
        guard let registration = registration(id: lease.ownerID),
              let model = registration.mouseModel, let association = registration.logitechAssociation,
              await currentConfigurationRevisionMatches(), owns(lease),
              self.registration(id: lease.ownerID) == registration else { return }
        if boltStatus.cleanupUncertain {
            guard await canRecoverUncertainEndpoint(after: boltStatus), owns(lease) else { return }
        }
        let target = LogitechConnectionTarget(model: model, association: association, candidateID: pendingMouseCandidateID)
        pendingMouseCandidateID = nil
        await performMouseOperation(for: lease, discoveryTarget: target) { await $0.discover(target: target) }
    }

    private func connectRuntime() {
        guard logitechSetupSnapshot == nil, logitechSetupInventoryTask == nil,
              !isBoltPairingActive, !isBoltReceiverManagementActive,
              boltReceiverManagementCloseTask == nil, admissibleMouseID != nil else { return }
        cancelWakeRecovery()
        guard !isRestarting else { return }
        if let cleanup = sleepCleanupTask {
            let intent = advanceLifecycleIntent()
            let sequence = sleepCleanupSequence
            Task { @MainActor [weak self] in
                var cleaned = await cleanup.value
                guard let self, self.lifecycleIntent == intent, !self.isRestarting else { return }
                var status = await self.waitForSettledControllerStatus(after: sequence)
                guard self.lifecycleIntent == intent else { return }
                if status == nil, !self.canDiscover {
                    let stopSequence = self.statusSequence
                    cleaned = await self.scheduleMouseCleanup(restore: self.runtimeRestorePreviousSettings).value
                    guard self.lifecycleIntent == intent, !self.isRestarting else { return }
                    status = await self.waitForSettledControllerStatus(after: stopSequence)
                    guard self.lifecycleIntent == intent else { return }
                }
                let recoveringSameTarget = await self.canRecoverUncertainEndpoint(after: status)
                guard self.lifecycleIntent == intent else { return }
                guard (cleaned && status?.cleanupUncertain != true) || recoveringSameTarget else {
                    self.scheduleMouseCleanup(restore: self.runtimeRestorePreviousSettings)
                    return
                }
                guard status != nil || self.canDiscover else { return }
                if cleaned && status?.cleanupUncertain == false { self.endpointRecoveryTarget = nil }
                self.sleepCleanupTask = nil
                self.connectRuntime()
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
            guard let lease = self.activeMouseLease else { return }
            let sequence = self.statusSequence
            await self.discoverMouse(for: lease)
            guard self.lifecycleIntent == intent, self.owns(lease) else { return }
            self.discoveryPending = false
            self.requestReconciliation()
            if self.statusSequence > sequence, !self.isRestarting, self.sessionActivationRequested,
               [.idle, .failed].contains(self.boltStatus.phase) {
                self.startConnectionRecovery()
            }
        }
    }

    func disconnect() {
        prepareForLifecycleStop()
        let restore = runtimeRestorePreviousSettings
        scheduleMouseCleanup(restore: restore)
    }

    func requestEnableConfirmation() {
        guard canEnableBindings else { return }
        isEnableConfirmationPresented = true
    }

    func setRestarting(_ restarting: Bool) {
        isRestarting = restarting
        d200x.suspendDelivery(restarting)
        flowLite.setSuspended(restarting || initialConfigurationLoadPending || configurationLoadFailed)
        synchronizeD200X()
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
        claimConnectedMouse()
        guard activeMouseLease != nil else { return }
        sessionActivationRequested = true
        requestReconciliation()
    }

    func refreshPermission(retryScrollCapture: Bool = false) -> InputPermission {
        bluetooth.recheckAccess()
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
        isSelectedMouseRuntimeTarget && canRefreshRuntimeDeviceInformation
    }

    private var canRefreshRuntimeDeviceInformation: Bool {
        presentedMouseOwnerID != nil && !isRestarting && !boltStatus.cleanupUncertain &&
            [.ready, .enabled].contains(boltStatus.phase) &&
            !boltStatus.deviceInformation.isRefreshing
    }

    func refreshDeviceInformation() {
        guard canRefreshDeviceInformation else { return }
        refreshRuntimeDeviceInformation()
    }

    private func refreshRuntimeDeviceInformation() {
        guard canRefreshRuntimeDeviceInformation else { return }
        guard let lease = activeMouseLease else { return }
        Task { [weak self] in
            guard let self, self.owns(lease) else { return }
            await self.performMouseOperation(for: lease) { await $0.refreshDeviceInformation() }
        }
    }

    func setLowBatteryNotificationsEnabled(_ enabled: Bool) {
        guard canEditConfiguration, !isRestarting, let notifications = lowBatteryNotifications else { return }
        var configuration = document.draft
        guard let index = configuration.devices.firstIndex(where: { $0.id == AppConfiguration.logitechProfileID }) else { return }
        configuration.devices[index].lowBatteryNotificationsEnabled = enabled
        updateDraft(configuration)
        let mouseID = selectedMouseID
        Task { [weak self] in
            if enabled { await notifications.requestAuthorization() }
            guard let self, self.selectedMouseID == mouseID else { return }
            self.synchronizeLowBatteryPreference()
            self.updateLowBatteryObservation()
        }
    }

    private func synchronizeLowBatteryPreference() {
        guard let notifications = lowBatteryNotifications else { return }
        notifications.synchronizeEnabled(admissibleMouseID != nil && hasUsableConfiguration && !configurationLoadFailed &&
            runtimeMouse?.lowBatteryNotificationsEnabled == true)
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
        let lease = activeMouseLease
        let fresh = lease != nil && [.ready, .enabled].contains(boltStatus.phase) && information.batteryState == .available &&
            battery.map { (0...300).contains(Date.now.timeIntervalSince($0.observedAt)) } == true
        let charging: Bool? = switch battery?.charging {
        case .discharging: false
        case .charging, .slowCharging, .complete: true
        default: nil
        }
        Task { [weak self] in
            guard let self, let lease, self.owns(lease) else { return }
            await notifications.observe(percentage: battery?.percentage, charging: charging, isFresh: fresh)
        }
    }

    func applySavedWheelPreference() {
        guard canApplyWheelPreference else { return }
        claimConnectedMouse()
        guard activeMouseLease != nil else { return }
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
        guard let selectedMouseID, registration(id: selectedMouseID)?.isEnabled == true,
              canEditConfiguration else { return }
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
        synchronizeEditorProjection()
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
        synchronizeEditorProjection()
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
        synchronizeEditorProjection()
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
        synchronizeEditorProjection()
    }

    func updateDraft(_ configuration: AppConfiguration) {
        guard canEditConfiguration else { return }
        do {
            let input = selectedMouseID == nil ? configuration : try configuration.validated()
            let updatedWorkspace = try workspace.applying(input, mouseID: selectedMouseID).validated()
            let validated = updatedWorkspace.configuration(forMouseID: selectedMouseID)
            guard document.draft != validated else { return }
            revokeLogitechSetup()
            revokeBoltPairing()
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
            workspace = updatedWorkspace
            synchronizeD200X()
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
        let submittedWorkspace = workspace
        let revision = fileRevision
        isSaving = true
        let task = Task { @MainActor [self] in
            defer {
                isSaving = false
                saveTask = nil
            }
            do {
                let snapshot = try await store.save(submittedWorkspace, expecting: revision)
                fileRevision = snapshot.revision
                savedWorkspace = snapshot.workspace
                synchronizeEditorProjection()
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
        d200x.sleep()
        flowLite.sleep()
        bluetooth.synchronize(registeredDevices, suspended: true)
        let reconnect = connectionRequested && !isRestarting
        prepareForLifecycleStop()
        let cleanup = scheduleMouseCleanup(restore: runtimeRestorePreviousSettings)
        wakeRecovery.sleep(reconnect: reconnect) { await cleanup.value }
    }

    func systemDidWake() {
        d200x.wake()
        flowLite.wake()
        bluetooth.synchronize(registeredDevices, suspended: isRestarting || isLoading || configurationLoadFailed)
        wakeRecovery.wake { [weak self] in
            guard let self else { return .stop }
            return await self.performRecoveryAttempt()
        }
    }

    @discardableResult
    func stopForTermination() async -> Bool {
        bluetooth.stop()
        cancelRecording()
        prepareForLifecycleStop()
        if let boltPairingFinishTask { await boltPairingFinishTask.value }
        let saved = await flushPendingSave()
        await flowLite.stop()
        await d200x.stop()
        _ = await scheduleMouseCleanup(restore: runtimeRestorePreviousSettings).value
        return saved
    }

    func stopForRestart() async -> Bool {
        bluetooth.stop()
        cancelRecording()
        prepareForLifecycleStop()
        if let boltPairingFinishTask { await boltPairingFinishTask.value }
        let saved = await flushPendingSave()
        await flowLite.stop()
        await d200x.stop()
        let cleaned = await scheduleMouseCleanup(restore: runtimeRestorePreviousSettings).value
        return saved && cleaned
    }

    func prepareForLifecycleStop() {
        prepareForLifecycleStop(preservingStoredInventories: false)
    }

    private func prepareForLifecycleStop(
        preservingStoredInventories: Bool,
        preservingLogitechSetupCandidates: Bool = false
    ) {
        revokeLogitechSetup(
            preservingStoredInventories: preservingStoredInventories,
            preservingCandidates: preservingLogitechSetupCandidates
        )
        revokeBoltPairing()
        cleanupRestorePreviousSettings = runtimeRestorePreviousSettings
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
        if let boltPairingFinishTask { await boltPairingFinishTask.value }
        let intent = lifecycleIntent
        let cleaned = await scheduleMouseCleanup(restore: runtimeRestorePreviousSettings).value
        guard cleaned, lifecycleIntent == intent else { return }
        sleepCleanupTask = nil
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
            let previous = workspace
            workspace = snapshot.workspace
            savedWorkspace = snapshot.workspace
            synchronizeEditorProjection()
            synchronizeRegistrations(previous: previous)
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

        if case .success = result, initialConfigurationLoadPending {
            replaceMissingInitialDeviceSelection()
        }

        isLoading = false
        initialConfigurationLoadPending = false
        flowLite.setSuspended(isRestarting || configurationLoadFailed)
        synchronizeD200X()
        synchronizeLowBatteryPreference()
        refreshNotificationAuthorization()

        if let deferredConnectOnLaunchValue {
            self.deferredConnectOnLaunchValue = nil
            if loadedConfiguration != nil { setConnectOnLaunch(deferredConnectOnLaunchValue) }
        }

        guard !startupConnectionDecisionConsumed else { return }
        startupConnectionDecisionConsumed = true
        if !isRestarting, loadedConfiguration?.connectOnLaunch == true {
            if isDeviceEnabled(.d200x) { d200x.connect(configureIfNeeded: false) }
            if isDeviceEnabled(.flowLite84) { flowLite.connectOnLaunch() }
        }
        guard !isRestarting,
              let startupIntent,
              lifecycleIntent == startupIntent,
              loadedConfiguration?.connectOnLaunch == true else { return }
        connectRuntime()
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
            let previous = workspace
            workspace = snapshot.workspace
            savedWorkspace = snapshot.workspace
            synchronizeEditorProjection()
            synchronizeRegistrations(previous: previous)
            configurationSaveError = nil
            configurationFailureKind = nil
            configurationLoadFailed = false
            configurationLoadError = nil
            hasUsableConfiguration = true
            flowLite.setSuspended(isRestarting)
            cancelRecording()
            synchronizeLowBatteryPreference()
            refreshNotificationAuthorization()
            if let selectedApplicationID, !applicationIDs.contains(selectedApplicationID) {
                var location = navigation.current
                location.applicationID = nil
                var next = navigation
                next.replaceCurrent(with: location)
                navigation = next
                synchronizeEditorProjection()
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
        synchronizeD200X()
        refreshDeliveryAdmission()
        requestReconciliation()
    }

    private func startReload() {
        guard canReloadConfiguration else { return }
        revokeLogitechSetup()
        revokeBoltPairing()
        autosaveTask?.cancel()
        autosaveTask = nil
        isLoading = true
        synchronizeD200X()
        isEnableConfirmationPresented = false
        refreshDeliveryAdmission()
        Task { await reloadFromDisk() }
    }

    private func synchronizeD200X() {
        bluetooth.synchronize(registeredDevices, suspended: isRestarting || isLoading || configurationLoadFailed || wakeRecovery.sleeping)
        let blocker: String?
        if isRestarting {
            blocker = "Hidhogg is restarting."
        } else if isLoading {
            blocker = "Loading configuration…"
        } else if configurationLoadFailed {
            blocker = "Configuration is unavailable. Open Settings → Configuration to resolve the error."
        } else {
            blocker = nil
        }
        d200x.synchronize(document.draft.d200x,
                          canEdit: canEditConfiguration && isDeviceEnabled(.d200x),
                          blocker: isDeviceEnabled(.d200x) ? blocker : "This device is disabled or removed.")
    }

    var canEditConfiguration: Bool { !isRestarting && !isLoading && !configurationLoadFailed }
    private var canStartWheelApply: Bool {
        canClaimConnectedMouse && isSelectedMouseRuntimeTarget && admissibleMouseID != nil && runtimeIdentityVerified && boltStatus.supportsManagement && !isRestarting && !isLoading && hasUsableConfiguration &&
            [.ready, .enabled].contains(boltStatus.phase) &&
            !boltStatus.cleanupUncertain && boltStatus.wheel.support == .supported &&
            !boltStatus.wheel.isApplying && (try? document.draft.validated()) != nil
    }

    private var hasConfiguredShortcut: Bool {
        containsConfiguredShortcut(in: runtimeMouse ?? document.draft.mouse)
    }

    private func containsConfiguredShortcut(in mouse: DeviceBindings?) -> Bool {
        guard let mouse else { return false }
        return (Array(mouse.defaults.values) + mouse.applications.values.flatMap { $0.values })
            .contains { $0.kind == .shortcut }
    }

    private var shouldEnableButtons: Bool {
        activeMouseLease != nil && runtimeIdentityVerified && sessionActivationRequested && boltStatus.supportsManagement && !isRestarting && !isLoading && !boltStatus.cleanupUncertain && hasUsableConfiguration &&
            permission == .granted && hasConfiguredShortcut &&
            boltStatus.availableControls == Set(MouseControl.allCases)
    }

    private func refreshDeliveryAdmission() {
        let canDeliver = activeMouseLease != nil && runtimeIdentityVerified && boltStatus.supportsManagement && permission == .granted && sessionActivationRequested && !isRestarting &&
            !isBoltReceiverManagementActive && boltReceiverManagementCloseTask == nil &&
            !boltStatus.cleanupUncertain && [.ready, .enabling, .enabled].contains(boltStatus.phase)
        if !canDeliver {
            bolt.invalidateScrollAdmission()
            scrollSender.reset()
            bolt.invalidateThumbwheelAdmission()
            thumbwheelScrollSender.reset()
        }
        actionsEnabled = shouldEnableButtons && boltStatus.phase == .enabled && recordingTarget == nil &&
            activeMouseLease.map { boltStatus.generation > $0.statusGenerationFloor } == true
        deliveryGeneration = actionsEnabled ? boltStatus.generation : nil
    }

    private func requestReconciliation() {
        guard !isBoltPairingActive else { return }
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
            guard !isBoltReceiverManagementActive, boltReceiverManagementCloseTask == nil else { continue }
            guard let lease = activeMouseLease, sessionActivationRequested, !isRestarting, !isLoading, hasUsableConfiguration,
                  !discoveryPending, [.ready, .enabled].contains(boltStatus.phase),
                  !boltStatus.cleanupUncertain, runtimeIdentityVerified, boltStatus.supportsManagement, boltStatus.generation > lease.statusGenerationFloor else { continue }
            let intent = lifecycleIntent
            let wheel = WheelRequest(
                inverted: runtimeMouse?.wheelInverted,
                highResolution: runtimeMouse?.wheelHighResolution,
                amount: runtimeMouse?.wheelScrollAmount,
                postingAllowed: !scrollReleasePending && !scrollPostingFailed && permission == .granted && (runtimeMouse?.wheelScrollAmount == nil || scrollSender.canPostEvents()),
                restorePreviousSettingsOnDisconnect: runtimeRestorePreviousSettings
            )
            if attemptedWheelRequest != wheel {
                let previous = attemptedWheelRequest
                if boltStatus.wheel.support == .supported &&
                    (wheel.inverted != nil || wheel.highResolution != nil || wheel.amount != nil || previous?.amount != nil || boltStatus.wheel.isOwned ||
                     previous?.inverted != nil || previous?.highResolution != nil ||
                     wheel.restorePreviousSettingsOnDisconnect || previous?.restorePreviousSettingsOnDisconnect == true) {
                    attemptedWheelRequest = wheel
                    isWheelApplyPending = true
                    await performMouseOperation(for: lease) { session in
                        await session.applyWheelPreferences(
                            inverted: wheel.inverted,
                            highResolution: wheel.highResolution,
                            restorePreviousSettingsOnDisconnect: wheel.restorePreviousSettingsOnDisconnect,
                            amount: wheel.amount,
                            scrollPostingAllowed: wheel.postingAllowed
                        )
                    }
                    guard lifecycleIntent == intent, owns(lease) else { continue }
                    if !wheel.postingAllowed { scrollReleasePending = false }
                    isWheelApplyPending = false
                    reconciliationRequested = true
                    continue
                }
            }
            let thumbwheel = ThumbwheelRequest(
                inverted: runtimeMouse?.thumbwheelInverted,
                amount: runtimeMouse?.thumbwheelScrollAmount,
                postingAllowed: !thumbwheelReleasePending && !thumbwheelPostingFailed && permission == .granted &&
                    (runtimeMouse?.thumbwheelScrollAmount == nil || thumbwheelScrollSender.canPostEvents()),
                restorePreviousSettingsOnDisconnect: runtimeRestorePreviousSettings
            )
            if attemptedThumbwheelRequest != thumbwheel {
                let previous = attemptedThumbwheelRequest
                let hasIntent = thumbwheel.inverted != nil || thumbwheel.amount != nil ||
                    previous?.inverted != nil || previous?.amount != nil || boltStatus.thumbwheel.isOwned ||
                    thumbwheel.restorePreviousSettingsOnDisconnect || previous?.restorePreviousSettingsOnDisconnect == true
                let hasConfiguredValue = thumbwheel.inverted != nil || thumbwheel.amount != nil
                let canApply = boltStatus.thumbwheel.support == .supported ||
                    (boltStatus.thumbwheel.support == .unknown && hasConfiguredValue)
                if hasIntent && canApply {
                    attemptedThumbwheelRequest = thumbwheel
                    isThumbwheelApplyPending = true
                    await performMouseOperation(for: lease) { session in
                        await session.applyThumbwheelPreferences(
                            inverted: thumbwheel.inverted,
                            amount: thumbwheel.amount,
                            restorePreviousSettingsOnDisconnect: thumbwheel.restorePreviousSettingsOnDisconnect,
                            scrollPostingAllowed: thumbwheel.postingAllowed
                        )
                    }
                    guard lifecycleIntent == intent, owns(lease) else { continue }
                    if !thumbwheel.postingAllowed { thumbwheelReleasePending = false }
                    isThumbwheelApplyPending = false
                    reconciliationRequested = true
                    continue
                }
            }
            let enabled = shouldEnableButtons
            guard attemptedButtonState != enabled else { continue }
            if enabled && boltStatus.phase == .ready {
                attemptedButtonState = enabled
                await performMouseOperation(for: lease) { await $0.enable() }
            } else if !enabled && [.enabling, .enabled].contains(boltStatus.phase) {
                attemptedButtonState = enabled
                await performMouseOperation(for: lease) { await $0.disable() }
            }
            guard lifecycleIntent == intent, owns(lease) else { continue }
            refreshDeliveryAdmission()
        }
    }

    private var canStartDiscovery: Bool {
        [.idle, .ready, .failed].contains(boltStatus.phase)
    }

    private func beginDiscovery() -> UInt64 {
        scrollPostingFailed = false
        thumbwheelPostingFailed = false
        _ = refreshPermission()
        let intent = advanceLifecycleIntent()
        if let id = admissibleMouseID {
            endpointOwnerID = id
            mouseLease = MouseLease(ownerID: id, epoch: intent, statusGenerationFloor: boltStatus.generation, startedAt: .now)
        }
        synchronizeLowBatteryPreference()
        discoveryPending = true
        sessionActivationRequested = true
        attemptedWheelRequest = nil
        attemptedThumbwheelRequest = nil
        attemptedButtonState = nil
        actionsEnabled = false
        deliveryGeneration = nil
        return intent
    }

    private func startConnectionRecovery() {
        guard logitechSetupSnapshot == nil, logitechSetupInventoryTask == nil, !isBoltPairingActive,
              admissibleMouseID != nil, sessionActivationRequested, !isRestarting, !wakeRecovery.sleeping else { return }
        wakeRecovery.retry { [weak self] in
            guard let self else { return .stop }
            return await self.performRecoveryAttempt()
        }
    }

    private func performRecoveryAttempt() async -> WakeRecoveryCoordinator.Outcome {
        guard logitechSetupSnapshot == nil, logitechSetupInventoryTask == nil, !isBoltPairingActive,
              admissibleMouseID != nil else { return .stop }
        if let cleanup = sleepCleanupTask {
            let cleanupIntent = lifecycleIntent
            var cleaned = await cleanup.value
            guard !Task.isCancelled, lifecycleIntent == cleanupIntent else { return .stop }
            var status = await waitForSettledControllerStatus(after: sleepCleanupSequence)
            guard lifecycleIntent == cleanupIntent, !Task.isCancelled else { return .stop }
            if status == nil {
                let stopSequence = statusSequence
                cleaned = await scheduleMouseCleanup(restore: runtimeRestorePreviousSettings).value
                guard lifecycleIntent == cleanupIntent, !Task.isCancelled else { return .stop }
                status = await waitForSettledControllerStatus(after: stopSequence)
                guard lifecycleIntent == cleanupIntent, !Task.isCancelled else { return .stop }
            }
            let recoveringSameTarget = await canRecoverUncertainEndpoint(after: status)
            guard lifecycleIntent == cleanupIntent, !Task.isCancelled else { return .stop }
            guard (cleaned && status?.cleanupUncertain != true) || recoveringSameTarget else {
                scheduleMouseCleanup(restore: runtimeRestorePreviousSettings)
                return .retry
            }
            if cleaned && status?.cleanupUncertain == false { endpointRecoveryTarget = nil }
            sleepCleanupTask = nil
            guard status != nil else { return .retry }
        }
        guard !Task.isCancelled, !isRestarting else { return .stop }
        guard !isLoading, hasUsableConfiguration else { return .retry }
        if activeMouseLease != nil, [.ready, .enabled].contains(boltStatus.phase), !boltStatus.cleanupUncertain { return .connected }
        guard !discoveryPending, canDiscover else { return .retry }
        let intent = beginDiscovery()
        guard let lease = activeMouseLease else { return .stop }
        let sequence = statusSequence
        await discoverMouse(for: lease)
        guard owns(lease), lifecycleIntent == intent else { return .stop }
        let status = await waitForWakeStatus(after: sequence, matching: { [.ready, .failed, .idle].contains($0.phase) })
        guard owns(lease), lifecycleIntent == intent else { return .stop }
        discoveryPending = false
        guard let status else {
            guard !Task.isCancelled else { return .stop }
            let restore = runtimeRestorePreviousSettings
            await performMouseOperation(for: lease) { await $0.stop(restorePreviousSettingsOnDisconnect: restore) }
            guard owns(lease), lifecycleIntent == intent, !Task.isCancelled else { return .stop }
            requestReconciliation()
            return .retry
        }
        requestReconciliation()
        guard !Task.isCancelled else { return .stop }
        if [.ready, .enabled].contains(status.phase) {
            return status.cleanupUncertain ? .retry : .connected
        }
        if [.idle, .failed].contains(status.phase) { return .retry }
        return .stop
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

    private func waitForSettledControllerStatus(after sequence: UInt64) async -> BoltStatus? {
        await waitForWakeStatus(after: sequence, matching: { [.idle, .failed].contains($0.phase) })
    }

    private func finishWakeStatusWait(returning status: BoltStatus?) {
        let wait = wakeStatusWait
        wakeStatusWait = nil
        wait?.timeout.cancel()
        wait?.continuation.resume(returning: status)
    }

    private func advanceLifecycleIntent() -> UInt64 {
        mouseSelectionSnapshot = nil
        lifecycleIntent &+= 1
        discoveryPending = false
        return lifecycleIntent
    }

    private func invalidateLifecycleIntent() {
        pendingMouseCandidateID = nil
        bolt.invalidateScrollAdmission()
        scrollSender.reset()
        bolt.invalidateThumbwheelAdmission()
        thumbwheelScrollSender.reset()
        _ = advanceLifecycleIntent()
        mouseLease = nil
        sessionActivationRequested = false
        synchronizeLowBatteryPreference()
    }

    private func normalized(_ location: WorkspaceLocation) -> WorkspaceLocation {
        if case .genericBluetooth(let id) = location.route,
           registration(id: id)?.family != .genericBluetooth {
            var normalized = location
            normalized.route = registeredDevices.first.map { Self.route(for: $0) } ?? .settings
            return normalized
        }
        if case .mouse(let id) = location.route, registration(id: id)?.family.isLogitechMouse != true {
            var normalized = location
            normalized.route = registeredDevices.first.map { Self.route(for: $0) } ?? .settings
            normalized.applicationID = nil
            return normalized
        }
        let applications = workspace.configuration(forMouseID: mouseID(for: location.route)).mouse?.applications ?? [:]
        guard let applicationID = location.applicationID, applications[applicationID] == nil else { return location }
        var normalized = location
        normalized.applicationID = nil
        return normalized
    }

    private func replaceMissingInitialDeviceSelection() {
        let route = navigation.current.route
        let initialMouseRoute = route == .devices ? mouseRegistrations.first.map { WorkspaceRoute.mouse($0.id) } : nil
        let isMissingDeviceRoute: Bool = switch route {
        case .devices: mouseRegistrations.isEmpty
        case .mouse(let id): registration(id: id)?.family.isLogitechMouse != true
        case .d200x: registration(for: .d200x) == nil
        case .flowLite: registration(for: .flowLite84) == nil
        case .genericBluetooth(let id): registration(id: id)?.family != .genericBluetooth
        case .logitechSetup, .actions, .notifications, .tilePresets, .settings: false
        }
        guard isMissingDeviceRoute || initialMouseRoute != nil else { return }

        var location = navigation.current
        location.route = initialMouseRoute ?? registeredDevices.first.map { Self.route(for: $0) } ?? .settings
        var next = navigation
        next.replaceCurrent(with: location)
        navigation = next
        synchronizeEditorProjection()
    }

    private func receive(_ event: BoltEvent) {
        switch event {
        case .status(let status):
            guard status.generation >= boltStatus.generation else { return }
            if status.phase == .discovering, boltStatus.phase != .discovering {
                attemptedWheelRequest = nil
                attemptedThumbwheelRequest = nil
                attemptedButtonState = nil
            }
            statusSequence &+= 1
            boltStatus = status
            if [.idle, .failed, .discovering].contains(status.phase) {
                informationRequestedForConnection = false
            }
            if [.ready, .enabled].contains(status.phase), !informationRequestedForConnection {
                informationRequestedForConnection = true
                refreshRuntimeDeviceInformation()
            }
            if [.ready, .enabled].contains(status.phase), !status.cleanupUncertain {
                wakeRecovery.connectionRestored()
            }
            updateLowBatteryObservation()
            if let wait = wakeStatusWait, wait.matches(status) {
                finishWakeStatusWait(returning: status)
            }
            if [.idle, .failed].contains(status.phase), !discoveryPending, sessionActivationRequested {
                startConnectionRecovery()
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
        guard admitsInput(observedAt: observedAt), runtimeIdentityVerified, boltStatus.supportsManagement,
              sessionActivationRequested, !isRestarting, !boltStatus.cleanupUncertain,
              [.ready, .enabling, .enabled].contains(boltStatus.phase), permission == .granted,
              let amount = runtimeMouse?.wheelScrollAmount else { return }
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
        guard admitsInput(observedAt: observedAt), runtimeIdentityVerified, boltStatus.supportsManagement,
              sessionActivationRequested, !isRestarting, !boltStatus.cleanupUncertain,
              [.ready, .enabling, .enabled].contains(boltStatus.phase), permission == .granted,
              let amount = runtimeMouse?.thumbwheelScrollAmount else { return }
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
        guard admitsInput(observedAt: observedAt), actionsEnabled,
              !boltStatus.cleanupUncertain,
              deliveryGeneration == generation,
              boltStatus.phase == .enabled,
              boltStatus.generation == generation,
              permission == .granted,
              recordingTarget == nil else { return }

        let applicationID = frontmostApplication()
        let binding = runtimeMouse?.binding(for: control, application: applicationID) ?? .disabled
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
