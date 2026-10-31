import Combine
import Foundation
import LofreeFlowLite84

private struct FlowLite84LightingDraft: Equatable {
    var effect: FlowLite84LightingEffect?
    var enabled: Bool?
    var brightnessLevel: UInt8?
    var speedLevel: UInt8?
    var idleOff: FlowLite84LightingIdleOff?

    init(lighting: FlowLite84Lighting?) {
        effect = lighting?.effect
        enabled = lighting?.enabled
        brightnessLevel = FlowLite84Lighting.displayedLevel(lighting?.brightnessLevel)
        speedLevel = FlowLite84Lighting.displayedLevel(lighting?.speedLevel)
        idleOff = lighting?.idleOff
    }

    func edit(relativeTo baseline: Self) -> FlowLite84LightingEdit {
        FlowLite84LightingEdit(
            effect: effect == baseline.effect ? nil : effect,
            enabled: enabled == baseline.enabled ? nil : enabled,
            brightnessLevel: brightnessLevel == baseline.brightnessLevel ? nil : brightnessLevel.map { $0 - 1 },
            speedLevel: speedLevel == baseline.speedLevel ? nil : speedLevel.map { $0 - 1 },
            idleOff: idleOff == baseline.idleOff ? nil : idleOff
        )
    }

    func rebased(from submitted: Self, onto baseline: Self) -> Self {
        var rebased = baseline
        if effect != submitted.effect { rebased.effect = effect }
        if enabled != submitted.enabled { rebased.enabled = enabled }
        if brightnessLevel != submitted.brightnessLevel { rebased.brightnessLevel = brightnessLevel }
        if speedLevel != submitted.speedLevel { rebased.speedLevel = speedLevel }
        if idleOff != submitted.idleOff { rebased.idleOff = idleOff }
        return rebased
    }
}

@MainActor
final class FlowLite84Model: ObservableObject {
    @Published private(set) var status: FlowLite84ConnectionStatus = .disconnected
    @Published private(set) var snapshot: FlowLite84Snapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var connectionRequested = false
    @Published private(set) var isApplyingLighting = false
    @Published private(set) var isRestoringLighting = false
    @Published private(set) var hasLightingWriteError = false
    @Published private(set) var isApplyingSystemMode = false
    @Published private(set) var isRestoringSystemMode = false
    @Published private(set) var hasSystemModeWriteError = false

    @Published private var lightingDraft: FlowLite84LightingDraft?
    @Published private var systemModeDraft: FlowLite84SystemMode?

    var onDiagnostic: ((DiagnosticEvent) -> Void)?

    private var session: (any FlowLite84SessionProtocol)?
    private var eventTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var sessionEpoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var snapshotGeneration: UInt64?
    private var lightingDraftBaseline: FlowLite84LightingDraft?
    private var systemModeDraftBaseline: UInt8?
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
    private let lightingAutoApplyDelay: Duration
    private var lightingAutoApplyTask: Task<Void, Never>?
    private var lightingAutoApplyRevision: UInt64 = 0
    private let systemModeAutoApplyDelay: Duration
    private var systemModeAutoApplyTask: Task<Void, Never>?
    private var systemModeAutoApplyRevision: UInt64 = 0
    private enum AutoApplyKind: Equatable { case lighting, systemMode }
    private var pendingAutoAppliesInDueOrder: [AutoApplyKind] = []

    init(
        session: (any FlowLite84SessionProtocol)? = nil,
        keyboardActivityMonitor: (any KeyboardActivityMonitoring)? = nil,
        monotonicNow: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock().now },
        lightingAutoApplyDelay: Duration = .milliseconds(200),
        systemModeAutoApplyDelay: Duration = .milliseconds(200)
    ) {
        self.session = session
        self.keyboardActivityMonitor = keyboardActivityMonitor ?? NoopKeyboardActivityMonitor()
        self.monotonicNow = monotonicNow
        self.lightingAutoApplyDelay = lightingAutoApplyDelay
        self.systemModeAutoApplyDelay = systemModeAutoApplyDelay
        if session != nil { sessionEpoch = 1 }
    }

    isolated deinit {
        eventTask?.cancel()
        lightingAutoApplyTask?.cancel()
        systemModeAutoApplyTask?.cancel()
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

    var isLightingDraftDirty: Bool {
        guard let lightingDraft, let lightingDraftBaseline else { return false }
        return lightingDraft != lightingDraftBaseline
    }

    var canEditLighting: Bool {
        (!isBusy || isApplyingLighting || isApplyingSystemMode) && hasCurrentLightingConnection
    }

    var canApplyLightingDraft: Bool {
        guard canEditLighting,
              isLightingDraftDirty,
              let lightingDraft,
              let lightingDraftBaseline else { return false }
        let changesEffectLevels = lightingDraft.brightnessLevel != lightingDraftBaseline.brightnessLevel ||
            lightingDraft.speedLevel != lightingDraftBaseline.speedLevel
        return !changesEffectLevels || lightingDraft.effect != nil
    }

    var canEditLightingEffectDependentFields: Bool {
        canEditLighting && lightingDraft?.effect != nil
    }

    var canRestorePreviousLighting: Bool {
        !isBusy && canEditLighting && snapshot?.canRestoreOriginalLighting == true
    }

    var canEditSystemMode: Bool {
        (!isBusy || isApplyingLighting || isApplyingSystemMode) && hasCurrentLightingConnection
    }

    var isSystemModeDraftDirty: Bool {
        guard let systemModeDraft else { return false }
        return systemModeDraft.rawValue != systemModeDraftBaseline
    }

    var canApplySystemModeDraft: Bool {
        canEditSystemMode && isSystemModeDraftDirty
    }

    var canRestoreOriginalSystemMode: Bool {
        !isBusy && canEditSystemMode && snapshot?.canRestoreOriginalSystemMode == true
    }

    var systemModeDraftPlaceholder: String {
        guard let rawValue = snapshot?.systemMode else { return "Reported mode unavailable" }
        return switch rawValue {
        case 0: "Reported Windows"
        case 1: "Reported Mac"
        case 2: "Reported Android (read-only)"
        case 3: "Reported iOS (read-only)"
        default: "Unknown (reported \(rawValue))"
        }
    }

    var lightingDraftEffectPlaceholder: String {
        guard let lighting = snapshot?.lighting else { return "Keep unavailable" }
        return "Keep unknown mode (reported \(lighting.mode))"
    }

    var lightingDraftEnabledPlaceholder: String {
        snapshot?.lighting == nil ? "Keep unavailable" : "Keep current value"
    }

    var lightingDraftBrightnessPlaceholder: String {
        guard let raw = snapshot?.lighting?.brightnessLevel else { return "Keep unavailable" }
        return "Keep unknown level (reported \(raw))"
    }

    var lightingDraftSpeedPlaceholder: String {
        guard let raw = snapshot?.lighting?.speedLevel else { return "Keep unavailable" }
        return "Keep unknown level (reported \(raw))"
    }

    var lightingDraftIdleOffPlaceholder: String {
        guard let units = snapshot?.lighting?.idleOffUnits else { return "Keep unavailable" }
        return units == 0
            ? "Keep default / unknown (reported 0)"
            : "Keep unknown duration (reported \(units) units)"
    }

    var draftLightingEffect: FlowLite84LightingEffect? {
        get { lightingDraft?.effect }
        set {
            guard canEditLighting else { return }
            if newValue == nil, lightingDraftBaseline?.effect != nil { return }
            updateLightingDraft { $0.effect = newValue }
        }
    }

    var draftLightingEnabled: Bool? {
        get { lightingDraft?.enabled }
        set {
            guard canEditLighting else { return }
            if newValue == nil, lightingDraftBaseline?.enabled != nil { return }
            updateLightingDraft { $0.enabled = newValue }
        }
    }

    var draftLightingBrightnessLevel: UInt8? {
        get { lightingDraft?.brightnessLevel }
        set {
            guard canEditLightingEffectDependentFields,
                  newValue.map({ (1...5).contains($0) }) ?? (lightingDraftBaseline?.brightnessLevel == nil) else { return }
            updateLightingDraft { $0.brightnessLevel = newValue }
        }
    }

    var draftLightingSpeedLevel: UInt8? {
        get { lightingDraft?.speedLevel }
        set {
            guard canEditLightingEffectDependentFields,
                  newValue.map({ (1...5).contains($0) }) ?? (lightingDraftBaseline?.speedLevel == nil) else { return }
            updateLightingDraft { $0.speedLevel = newValue }
        }
    }

    var draftLightingIdleOff: FlowLite84LightingIdleOff? {
        get { lightingDraft?.idleOff }
        set {
            guard canEditLighting else { return }
            if newValue == nil, lightingDraftBaseline?.idleOff != nil { return }
            updateLightingDraft { $0.idleOff = newValue }
        }
    }

    var draftSystemMode: FlowLite84SystemMode? {
        get { systemModeDraft }
        set {
            guard canEditSystemMode else { return }
            let next = newValue ?? snapshot?.systemMode.flatMap(FlowLite84SystemMode.init(rawValue:))
            guard next != systemModeDraft else { return }
            systemModeDraft = next
            scheduleSystemModeAutoApply()
        }
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

    func applyLightingDraft() {
        guard !isBusy,
              canApplyLightingDraft,
              let lightingDraft,
              let lightingDraftBaseline else { return }
        cancelLightingAutoApply()
        beginDeviceWrite(.applyLighting(
            lightingDraft.edit(relativeTo: lightingDraftBaseline),
            submittedDraft: lightingDraft
        ))
    }

    func restorePreviousLighting() {
        guard canRestorePreviousLighting else { return }
        cancelLightingAutoApply()
        beginDeviceWrite(.restoreLighting)
    }

    func retryLightingDraft() {
        guard hasLightingWriteError, !isBusy else { return }
        applyLightingDraft()
    }

    func applySystemModeDraft() {
        guard !isBusy, canApplySystemModeDraft, let systemModeDraft else { return }
        cancelSystemModeAutoApply()
        beginDeviceWrite(.applySystemMode(systemModeDraft))
    }

    func retrySystemModeDraft() {
        guard hasSystemModeWriteError, !isBusy else { return }
        applySystemModeDraft()
    }

    func restoreOriginalSystemMode() {
        guard canRestoreOriginalSystemMode else { return }
        cancelSystemModeAutoApply()
        beginDeviceWrite(.restoreSystemMode)
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
        cancelAutoApplies()
        snapshotGeneration = nil
        lightingDraft = nil
        lightingDraftBaseline = nil
        systemModeDraft = nil
        systemModeDraftBaseline = nil
        hasLightingWriteError = false
        hasSystemModeWriteError = false
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
                cancelAutoApplies()
                stopObservingKeyboardActivity()
                reportStatus("Connecting to Lofree Flow Lite84.")
            case .disconnecting:
                cancelAutoApplies()
                stopObservingKeyboardActivity()
                reportStatus("Disconnecting from Lofree Flow Lite84.")
            case .disconnected:
                cancelAutoApplies()
                stopObservingKeyboardActivity()
                if isRefreshing { operationRevision &+= 1 }
                isRefreshing = false
                reportStatus("Disconnected from Lofree Flow Lite84.")
            case .failed(let failure):
                cancelAutoApplies()
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
            snapshot = snapshotPreservingNewerBattery(in: next)
            snapshotGeneration = eventGeneration
            latestSuccessfulSnapshotAt = monotonicNow()
            synchronizeCleanLightingDraft()
            synchronizeCleanSystemModeDraft()
        }
    }

    private func releaseSession() {
        cancelAutoApplies()
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

    private func finishOperation(_ operationID: UInt64, replacingLightingDraft: Bool = false) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        operationTask = nil
        isRefreshing = false
        isApplyingLighting = false
        isRestoringLighting = false
        isApplyingSystemMode = false
        isRestoringSystemMode = false
        synchronizeCleanLightingDraft(replacingDirtyDraft: replacingLightingDraft)
        synchronizeCleanSystemModeDraft()
        drainPendingAutoApplies()
    }

    private enum DeviceWrite {
        case applyLighting(FlowLite84LightingEdit, submittedDraft: FlowLite84LightingDraft)
        case restoreLighting
        case applySystemMode(FlowLite84SystemMode)
        case restoreSystemMode
    }

    private func beginDeviceWrite(_ write: DeviceWrite) {
        guard !isStopped, !isSleeping, !isSuspended, !isBusy,
              hasCurrentLightingConnection, let session else { return }

        nextOperationID &+= 1
        let operationID = nextOperationID
        let revision = operationRevision
        let expectedSessionEpoch = sessionEpoch
        let expectedGeneration = generation
        activeOperationID = operationID
        switch write {
        case .applyLighting:
            isApplyingLighting = true
            isRestoringLighting = false
            isApplyingSystemMode = false
            isRestoringSystemMode = false
            hasLightingWriteError = false
        case .restoreLighting:
            isApplyingLighting = false
            isRestoringLighting = true
            isApplyingSystemMode = false
            isRestoringSystemMode = false
        case .applySystemMode:
            isApplyingLighting = false
            isRestoringLighting = false
            isApplyingSystemMode = true
            isRestoringSystemMode = false
            hasSystemModeWriteError = false
        case .restoreSystemMode:
            isApplyingLighting = false
            isRestoringLighting = false
            isApplyingSystemMode = false
            isRestoringSystemMode = true
        }
        errorMessage = nil

        operationTask = Task { @MainActor [weak self] in
            do {
                let confirmedSnapshot: FlowLite84Snapshot
                switch write {
                case .applyLighting(let edit, _):
                    confirmedSnapshot = try await session.applyLighting(edit)
                case .restoreLighting:
                    confirmedSnapshot = try await session.restoreOriginalLighting()
                case .applySystemMode(let mode):
                    confirmedSnapshot = try await session.applySystemMode(mode)
                case .restoreSystemMode:
                    confirmedSnapshot = try await session.restoreOriginalSystemMode()
                }

                guard let self,
                      self.operationRevision == revision,
                      self.sessionEpoch == expectedSessionEpoch,
                      self.generation == expectedGeneration else {
                    self?.finishOperation(operationID)
                    return
                }
                self.adoptConfirmedReadback(confirmedSnapshot)
                switch write {
                case .applyLighting(_, let submittedDraft):
                    self.rebaseLightingDraft(after: submittedDraft, confirmedSnapshot: confirmedSnapshot)
                    self.hasLightingWriteError = false
                    self.finishOperation(operationID)
                case .restoreLighting:
                    self.hasLightingWriteError = false
                    self.finishOperation(operationID, replacingLightingDraft: true)
                case .applySystemMode(let submittedMode):
                    if self.systemModeDraft == submittedMode {
                        self.systemModeDraft = confirmedSnapshot.systemMode.flatMap(FlowLite84SystemMode.init(rawValue:))
                    }
                    self.systemModeDraftBaseline = confirmedSnapshot.systemMode
                    self.hasSystemModeWriteError = false
                    self.finishOperation(operationID)
                case .restoreSystemMode:
                    self.systemModeDraft = confirmedSnapshot.systemMode.flatMap(FlowLite84SystemMode.init(rawValue:))
                    self.systemModeDraftBaseline = confirmedSnapshot.systemMode
                    self.hasSystemModeWriteError = false
                    self.finishOperation(operationID)
                }
            } catch let failure as FlowLite84Failure {
                guard let self,
                      self.operationRevision == revision,
                      self.sessionEpoch == expectedSessionEpoch,
                      self.generation == expectedGeneration else {
                    self?.finishOperation(operationID)
                    return
                }
                if case .applyLighting = write {
                    self.hasLightingWriteError = true
                }
                if case .applySystemMode = write {
                    self.hasSystemModeWriteError = true
                }
                self.fail(failure.userMessage)
                self.finishOperation(operationID)
            } catch {
                guard let self,
                      self.operationRevision == revision,
                      self.sessionEpoch == expectedSessionEpoch,
                      self.generation == expectedGeneration else {
                    self?.finishOperation(operationID)
                    return
                }
                switch write {
                case .applyLighting:
                    self.hasLightingWriteError = true
                    self.fail("The Flow Lite84 lighting settings could not be confirmed.")
                case .restoreLighting:
                    self.fail("The Flow Lite84 lighting settings could not be restored.")
                case .applySystemMode:
                    self.hasSystemModeWriteError = true
                    self.fail("The Flow Lite84 system mode could not be confirmed.")
                case .restoreSystemMode:
                    self.fail("The Flow Lite84 system mode could not be confirmed.")
                }
                self.finishOperation(operationID)
            }
        }
    }

    private var hasCurrentLightingConnection: Bool {
        guard case .connected(let identity) = status,
              identity.isSupported,
              let snapshot,
              snapshot.identity == identity,
              snapshotGeneration == generation else { return false }
        return true
    }

    private func updateLightingDraft(_ update: (inout FlowLite84LightingDraft) -> Void) {
        guard var lightingDraft else { return }
        let previousDraft = lightingDraft
        update(&lightingDraft)
        guard lightingDraft != previousDraft else { return }
        self.lightingDraft = lightingDraft
        scheduleLightingAutoApply()
    }

    private func synchronizeCleanLightingDraft(replacingDirtyDraft: Bool = false) {
        guard !isBusy,
              hasCurrentLightingConnection,
              replacingDirtyDraft || !isLightingDraftDirty else { return }
        let freshDraft = FlowLite84LightingDraft(lighting: snapshot?.lighting)
        lightingDraft = freshDraft
        lightingDraftBaseline = freshDraft
    }

    private func synchronizeCleanSystemModeDraft() {
        guard !isBusy, canEditSystemMode else { return }
        if let systemModeDraft,
           systemModeDraft.rawValue != systemModeDraftBaseline,
           systemModeDraft.rawValue != snapshot?.systemMode { return }
        systemModeDraftBaseline = snapshot?.systemMode
        systemModeDraft = snapshot?.systemMode.flatMap(FlowLite84SystemMode.init(rawValue:))
    }

    private func adoptConfirmedReadback(_ confirmed: FlowLite84Snapshot) {
        guard case .connected(let identity) = status,
              identity.isSupported,
              identity == confirmed.identity,
              let current = snapshot,
              current.identity == identity else { return }

        snapshot = snapshotPreservingNewerBattery(in: confirmed)
        snapshotGeneration = generation
        latestSuccessfulSnapshotAt = monotonicNow()
    }

    private func rebaseLightingDraft(
        after submittedDraft: FlowLite84LightingDraft,
        confirmedSnapshot: FlowLite84Snapshot
    ) {
        guard let lightingDraft else { return }
        let confirmedDraft = FlowLite84LightingDraft(lighting: confirmedSnapshot.lighting)
        lightingDraftBaseline = confirmedDraft
        self.lightingDraft = lightingDraft.rebased(from: submittedDraft, onto: confirmedDraft)
    }

    private func scheduleLightingAutoApply() {
        cancelLightingAutoApply()
        guard isLightingDraftDirty || isApplyingLighting,
              hasCurrentLightingConnection,
              !isStopped, !isSleeping, !isSuspended else { return }

        let revision = lightingAutoApplyRevision
        let delay = lightingAutoApplyDelay
        lightingAutoApplyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.lightingAutoApplyRevision == revision else { return }
            self.lightingAutoApplyTask = nil
            guard self.isLightingDraftDirty || self.isApplyingLighting else { return }
            self.pendingAutoAppliesInDueOrder.append(.lighting)
            self.drainPendingAutoApplies()
        }
    }

    private func cancelLightingAutoApply() {
        lightingAutoApplyRevision &+= 1
        lightingAutoApplyTask?.cancel()
        lightingAutoApplyTask = nil
        pendingAutoAppliesInDueOrder.removeAll { $0 == .lighting }
    }

    private func scheduleSystemModeAutoApply() {
        cancelSystemModeAutoApply()
        guard isSystemModeDraftDirty || isApplyingSystemMode,
              hasCurrentLightingConnection,
              !isStopped, !isSleeping, !isSuspended else { return }

        let revision = systemModeAutoApplyRevision
        let delay = systemModeAutoApplyDelay
        systemModeAutoApplyTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.systemModeAutoApplyRevision == revision else { return }
            self.systemModeAutoApplyTask = nil
            guard self.isSystemModeDraftDirty || self.isApplyingSystemMode else { return }
            self.pendingAutoAppliesInDueOrder.append(.systemMode)
            self.drainPendingAutoApplies()
        }
    }

    private func cancelSystemModeAutoApply() {
        systemModeAutoApplyRevision &+= 1
        systemModeAutoApplyTask?.cancel()
        systemModeAutoApplyTask = nil
        pendingAutoAppliesInDueOrder.removeAll { $0 == .systemMode }
    }

    private func cancelAutoApplies() {
        cancelLightingAutoApply()
        cancelSystemModeAutoApply()
    }

    private func drainPendingAutoApplies() {
        guard !pendingAutoAppliesInDueOrder.isEmpty else { return }
        guard !isStopped, !isSleeping, !isSuspended,
              hasCurrentLightingConnection else {
            cancelAutoApplies()
            return
        }
        guard !isBusy else { return }
        while !pendingAutoAppliesInDueOrder.isEmpty {
            switch pendingAutoAppliesInDueOrder.removeFirst() {
            case .lighting:
                guard canApplyLightingDraft,
                      let lightingDraft,
                      let lightingDraftBaseline else { continue }
                beginDeviceWrite(.applyLighting(
                    lightingDraft.edit(relativeTo: lightingDraftBaseline),
                    submittedDraft: lightingDraft
                ))
            case .systemMode:
                guard canApplySystemModeDraft, let systemModeDraft else { continue }
                beginDeviceWrite(.applySystemMode(systemModeDraft))
            }
            return
        }
    }

    private func snapshotPreservingNewerBattery(in next: FlowLite84Snapshot) -> FlowLite84Snapshot {
        guard let current = snapshot,
              current.identity == next.identity,
              let currentBatteryReadAt = current.batteryReadAt,
              next.batteryReadAt.map({ currentBatteryReadAt >= $0 }) ?? true else { return next }

        let unavailableFields = next.unavailableFields.filter { $0 != "battery" && !$0.hasPrefix("battery.") }
            + current.unavailableFields.filter { $0 == "battery" || $0.hasPrefix("battery.") }
        return FlowLite84Snapshot(
            identity: next.identity,
            online: next.online,
            keyboardVersion: next.keyboardVersion,
            receiverVersion: next.receiverVersion,
            battery: current.battery,
            lighting: next.lighting,
            systemMode: next.systemMode,
            readAt: next.readAt,
            batteryReadAt: current.batteryReadAt,
            unavailableFields: unavailableFields,
            canRestoreOriginalLighting: next.canRestoreOriginalLighting,
            canRestoreOriginalSystemMode: next.canRestoreOriginalSystemMode
        )
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
        cancelAutoApplies()
        errorMessage = message
        onDiagnostic?(DiagnosticEvent(code: .flowLiteFailure, message: message, isError: true))
    }

    private func reportStatus(_ message: String) {
        onDiagnostic?(DiagnosticEvent(code: .flowLiteStatus, message: message))
    }
}
