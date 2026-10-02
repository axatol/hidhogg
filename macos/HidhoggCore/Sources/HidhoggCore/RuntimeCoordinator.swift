import Foundation

private struct RuntimePreparedProfile: Sendable {
    let profile: ConfiguredProfile
    let page: D200XLivePageUpdate
}

private struct RuntimeCatalog: Sendable {
    let configuration: HidhoggConfiguration
    let profiles: [String: RuntimePreparedProfile]

    init(configuration: HidhoggConfiguration) throws {
        var prepared = [String: RuntimePreparedProfile]()
        for profile in configuration.profiles {
            prepared[profile.id] = RuntimePreparedProfile(
                profile: profile,
                page: try D200XPageRenderer.render(profile: profile)
            )
        }
        guard prepared[configuration.defaultProfileID] != nil else {
            throw RuntimeCoordinatorError.configurationRejected
        }
        self.configuration = configuration
        profiles = prepared
    }
}

private struct RuntimeInputReceipt: Sendable {
    let event: D200XInputEvent
    let stamp: RuntimeTransitionStamp
    let observedAt: RuntimeMonotonicInstant
}

private struct RuntimeReleaseBinding: Sendable {
    let profileID: String
    let action: ConfiguredAction
}

private struct RuntimeInputKey: Hashable, Sendable {
    let marker: UInt8
    let wireIndex: UInt8
}

private struct RuntimeAdmissionWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
}

private enum RuntimeTerminalFailure {
    case session(D200XSessionFailure)
    case inputOverflow
}

final class RuntimeFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var terminalFailure: RuntimeTerminalFailure?

    var failure: D200XSessionFailure? {
        lock.lock()
        defer { lock.unlock() }
        guard case let .session(failure) = terminalFailure else { return nil }
        return failure
    }

    var isFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalFailure != nil
    }

    func record(_ failure: D200XSessionFailure) -> Bool {
        lock.lock()
        guard terminalFailure == nil else {
            lock.unlock()
            return false
        }
        terminalFailure = .session(failure)
        lock.unlock()
        return true
    }

    func recordInputOverflow() -> Bool {
        lock.lock()
        guard terminalFailure == nil else {
            lock.unlock()
            return false
        }
        terminalFailure = .inputOverflow
        lock.unlock()
        return true
    }
}

private struct RuntimeStaleReceipt: Error {}

public actor RuntimeCoordinator {
    private static let keepAliveInterval = Duration.seconds(50)

    private let session: any D200XDeviceSession
    private let clock: any RuntimeMonotonicClock
    private let transitionFence = RuntimeTransitionFence()
    private let failureLatch = RuntimeFailureLatch()
    private var staticActionHandler: (@Sendable (RuntimeStaticActionRequest) -> Void)?

    private var catalog: RuntimeCatalog
    private var profileID: String?
    private var lifecycle: RuntimeLifecycle = .created
    private var revision: UInt64 = 0
    private var displayAwake = true
    private var dimmed = false
    private var cleanupUncertain = false
    private var lastActivity: RuntimeMonotonicInstant
    private var idleDeadline: RuntimeMonotonicInstant?
    private var nextKeepAliveDeadline: RuntimeMonotonicInstant

    private var admissionHeld = false
    private var transitionHeld = false
    private var admissionWaiters = [RuntimeAdmissionWaiter]()

    private var heldInputs = Set<RuntimeInputKey>()
    private var suppressedInputs = Set<RuntimeInputKey>()
    private var pendingReleaseBindings = [RuntimeInputKey: RuntimeReleaseBinding]()

    private var inputContinuation: AsyncStream<RuntimeInputReceipt>.Continuation?
    private var inputTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var stoppedOutcome: RuntimeStopOutcome?

    public init(
        configuration: HidhoggConfiguration,
        selection: RuntimeBackendSelection = .native
    ) throws {
        catalog = try RuntimeCatalog(configuration: configuration)
        let clock = SystemRuntimeMonotonicClock()
        self.clock = clock
        lastActivity = clock.now()
        nextKeepAliveDeadline = clock.now().advanced(by: Self.keepAliveInterval)
        let backendSelection: D200XBackendSelection
        switch selection {
        case .native: backendSelection = .native
        case .simulated: backendSelection = .simulated
        }
        session = D200XDeviceSessionFactory.live.make(selection: backendSelection)
        staticActionHandler = nil
    }

    init(
        configuration: HidhoggConfiguration,
        session: any D200XDeviceSession,
        clock: any RuntimeMonotonicClock,
        staticActionHandler: (@Sendable (RuntimeStaticActionRequest) -> Void)? = nil
    ) throws {
        catalog = try RuntimeCatalog(configuration: configuration)
        self.session = session
        self.clock = clock
        self.staticActionHandler = staticActionHandler
        lastActivity = clock.now()
        nextKeepAliveDeadline = clock.now().advanced(by: Self.keepAliveInterval)
    }

    public func snapshot() -> RuntimeSnapshot {
        makeSnapshot(transitioning: transitionFence.stampAtReceipt().active)
    }

    private func makeSnapshot(transitioning: Bool) -> RuntimeSnapshot {
        RuntimeSnapshot(
            lifecycle: lifecycle,
            profileID: profileID,
            revision: revision,
            displayAwake: displayAwake,
            dimmed: dimmed,
            transitioning: transitioning,
            cleanupUncertain: cleanupUncertain
        )
    }

    func setStaticActionHandler(_ handler: (@Sendable (RuntimeStaticActionRequest) -> Void)?) {
        staticActionHandler = handler
    }

    public func start() async throws {
        try await withAdmission(transition: true) {
            guard self.lifecycle == .created else { throw RuntimeCoordinatorError.alreadyStarted }
            let defaultProfileID = self.catalog.configuration.defaultProfileID
            guard let prepared = self.catalog.profiles[defaultProfileID] else {
                throw RuntimeCoordinatorError.configurationRejected
            }

            let stream = AsyncStream<RuntimeInputReceipt>.makeStream(bufferingPolicy: .bufferingOldest(64))
            self.inputContinuation = stream.continuation
            self.inputTask = Task { [weak self] in
                for await receipt in stream.stream {
                    guard let self else { return }
                    await self.handleInput(receipt)
                }
            }

            do {
                let candidates = try await self.session.candidates()
                guard candidates.count == 1, candidates[0].isEligible else {
                    throw RuntimeCoordinatorError.sessionUnavailable
                }
                let fence = self.transitionFence
                let clock = self.clock
                let latch = self.failureLatch
                let continuation = stream.continuation
                try await self.session.open(
                    candidates[0],
                    onInput: { [weak self] event in
                        guard !latch.isFailed else { return }
                        let stamp = fence.stampAtReceipt()
                        let receipt = RuntimeInputReceipt(event: event, stamp: stamp, observedAt: clock.now())
                        if case .dropped = continuation.yield(receipt), latch.recordInputOverflow() {
                            Task { await self?.sessionDidFail() }
                        }
                    },
                    onFailure: { [weak self] failure in
                        guard latch.record(failure) else { return }
                        Task { await self?.sessionDidFail() }
                    }
                )
                try await self.performChecked(.startup(
                    page: prepared.page,
                    brightness: self.catalog.configuration.brightness
                ))
                self.profileID = defaultProfileID
                self.lifecycle = .running
                self.revision = 1
                self.displayAwake = true
                self.dimmed = false
                self.lastActivity = self.clock.now()
                self.recomputeIdleDeadline()
                self.nextKeepAliveDeadline = self.clock.now().advanced(by: Self.keepAliveInterval)
                self.restartTimerTask()
            } catch {
                await self.failStopCore()
                throw error as? RuntimeCoordinatorError ?? .sessionUnavailable
            }
        }
    }

    public func activateProfile(_ requestedID: String) async throws -> RuntimeActivationResult {
        try await withAdmission(transition: true) {
            try self.requireRunning()
            return try await self.activateProfileCore(requestedID)
        }
    }

    public func reload(source: Data) async throws -> RuntimeReloadResult {
        let candidate = try makeCatalog(source)
        return try await withAdmission(transition: true) {
            try self.requireRunning()
            return try await self.reloadCore(candidate)
        }
    }

    public func setHostDisplayAwake(_ awake: Bool) async throws {
        try await withAdmission(transition: true) {
            try self.requireRunning()
            guard self.displayAwake != awake else { return }
            if awake {
                try await self.wakeHostCore()
                return
            }
            try await self.performChecked(.setBrightness(0))
            self.displayAwake = false
            self.dimmed = true
            self.idleDeadline = nil
            self.clearActionCandidatesForTransition()
        }
    }

    public func applyConfigurationEdit(
        at path: String,
        expectedDigest: ConfigurationStoreDigest,
        edit: RuntimeConfigurationEdit
    ) async throws -> RuntimeConfigurationEditResult {
        try await withAdmission(transition: true) {
            try self.requireRunning()
            let currentProfileID = self.profileID ?? self.catalog.configuration.defaultProfileID
            let result: ConfigurationStoreResult
            do {
                result = try ConfigurationStore.apply(at: path, expectedDigest: expectedDigest) { source in
                    try Self.apply(edit, to: source, currentProfileID: currentProfileID)
                }
            } catch let error as ConfigurationStoreError {
                throw RuntimeCoordinatorError.storeFailure(error)
            } catch {
                throw RuntimeCoordinatorError.storeFailure(.mutationFailed)
            }

            guard result.outcome != .unchanged else {
                return RuntimeConfigurationEditResult(
                    fileOutcome: result.outcome,
                    digest: result.digest,
                    reloadOutcome: .unchanged,
                    snapshot: self.makeSnapshot(transitioning: false)
                )
            }

            let reloadOutcome: RuntimeConfigurationReloadOutcome
            do {
                let candidate = try Self.makeCatalog(result.bytes)
                _ = try await self.reloadCore(candidate)
                reloadOutcome = .reloaded
            } catch is ConfigurationDiagnostic {
                reloadOutcome = .rejected
            } catch RuntimeCoordinatorError.physicalWriteFailed {
                reloadOutcome = .runtimeFailed
            } catch {
                reloadOutcome = .rejected
            }

            return RuntimeConfigurationEditResult(
                fileOutcome: result.outcome,
                digest: result.digest,
                reloadOutcome: reloadOutcome,
                snapshot: self.makeSnapshot(transitioning: false)
            )
        }
    }

    public func stop() async -> RuntimeStopOutcome {
        do {
            try await acquireAdmission(transition: true, cancellationAllowed: false)
        } catch {
            return .cleanupUncertain
        }
        defer { releaseAdmission() }
        if let stoppedOutcome { return stoppedOutcome }

        timerTask?.cancel()
        timerTask = nil
        lifecycle = .stopping
        session.stop()
        let outcome = await session.waitUntilStopped()
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
        cleanupUncertain = outcome == .cleanupUncertain
        lifecycle = failureLatch.isFailed || outcome == .cleanupUncertain ? .failed : .stopped
        let result: RuntimeStopOutcome = cleanupUncertain ? .cleanupUncertain : .closed
        stoppedOutcome = result
        return result
    }

    private func handleInput(_ receipt: RuntimeInputReceipt) async {
        guard isRecognizedInputEvent(receipt.event) else { return }
        do {
            try await withAdmission(expectedStamp: receipt.stamp, transition: false) {
                guard self.lifecycle == .running, !self.failureLatch.isFailed else {
                    self.reconcileStaleInput(receipt.event)
                    return
                }
                try await self.processInputCore(receipt)
            }
        } catch is RuntimeStaleReceipt {
            reconcileStaleInput(receipt.event)
        } catch {
            if failureLatch.isFailed { await failStopAfterAdmission() }
        }
    }

    private func processInputCore(_ receipt: RuntimeInputReceipt) async throws {
        let event = receipt.event
        guard let positionSpec = HidhoggConfiguration.supportedPositions.first(where: { $0.wireIndex == event.wireIndex }) else {
            return
        }
        guard displayAwake else {
            reconcileStaleInput(event)
            return
        }

        let deadline = idleDeadline
        let withinIdleDeadline = deadline.map { receipt.observedAt <= $0 } ?? true
        let afterIdleDeadline = deadline.map { receipt.observedAt > $0 } ?? false
        let wasDimmed = dimmed
        let restoreBrightness = dimmed || afterIdleDeadline
        if restoreBrightness {
            try beginTransitionForCurrentAdmission()
            try await performChecked(.setBrightness(catalog.configuration.brightness))
            if wasDimmed || !withinIdleDeadline {
                suppress(event)
                finishInputActivity(receivedAt: receipt.observedAt, wasDimmed: wasDimmed)
                restartTimerTask()
                return
            }
        }

        guard let currentProfileID = profileID,
              let currentProfile = catalog.profiles[currentProfileID]?.profile,
              let position = currentProfile.position(named: positionSpec.name) else {
            finishInputActivity(receivedAt: receipt.observedAt, wasDimmed: wasDimmed)
            restartTimerTask()
            return
        }

        if event.action == 0x02 || event.action == 0x03 {
            finishInputActivity(receivedAt: receipt.observedAt, wasDimmed: wasDimmed)
            restartTimerTask()
            return
        }

        let inputKey = RuntimeInputKey(marker: event.marker, wireIndex: event.wireIndex)

        switch event.action {
        case 0x01:
            guard heldInputs.insert(inputKey).inserted else {
                finishInputActivity(receivedAt: receipt.observedAt, wasDimmed: wasDimmed)
                restartTimerTask()
                return
            }
            guard !suppressedInputs.contains(inputKey), let action = position.action else {
                finishInputActivity(receivedAt: receipt.observedAt, wasDimmed: wasDimmed)
                restartTimerTask()
                return
            }
            if actionGesture(action) == .press {
                try await dispatch(action, profileID: currentProfileID, coordinate: positionSpec.name, inputKey: inputKey)
            } else {
                pendingReleaseBindings[inputKey] = RuntimeReleaseBinding(profileID: currentProfileID, action: action)
            }
        case 0x00:
            heldInputs.remove(inputKey)
            if suppressedInputs.remove(inputKey) != nil {
                pendingReleaseBindings.removeValue(forKey: inputKey)
                finishInputActivity(receivedAt: receipt.observedAt, wasDimmed: wasDimmed)
                restartTimerTask()
                return
            }
            guard let binding = pendingReleaseBindings.removeValue(forKey: inputKey),
                  binding.profileID == currentProfileID,
                  binding.action == position.action,
                  actionGesture(binding.action) == .release else {
                finishInputActivity(receivedAt: receipt.observedAt, wasDimmed: wasDimmed)
                restartTimerTask()
                return
            }
            try await dispatch(binding.action, profileID: currentProfileID, coordinate: positionSpec.name, inputKey: inputKey)
        default:
            break
        }
        finishInputActivity(receivedAt: receipt.observedAt, wasDimmed: wasDimmed)
        restartTimerTask()
    }

    private func finishInputActivity(receivedAt instant: RuntimeMonotonicInstant, wasDimmed: Bool) {
        if wasDimmed { dimmed = false }
        if wasDimmed { revision &+= 1 }
        recordActivity(at: instant)
    }

    private func dispatch(
        _ action: ConfiguredAction,
        profileID: String,
        coordinate: String,
        inputKey: RuntimeInputKey
    ) async throws {
        switch action {
        case let .activateProfile(targetID, _):
            try beginTransitionForCurrentAdmission()
            suppressedInputs.insert(inputKey)
            pendingReleaseBindings.removeValue(forKey: inputKey)
            _ = try await activateProfileCore(targetID)
        case .execute, .typeText, .keyPress:
            staticActionHandler?(RuntimeStaticActionRequest(
                profileID: profileID,
                coordinate: coordinate,
                action: action
            ))
        }
    }

    private func activateProfileCore(_ requestedID: String) async throws -> RuntimeActivationResult {
        guard let target = catalog.profiles[requestedID] else { throw RuntimeCoordinatorError.unknownProfile }
        guard profileID != requestedID else {
            return RuntimeActivationResult(profileID: requestedID, changed: false, revision: revision)
        }
        if displayAwake {
            try await performChecked(.redraw(page: target.page))
        }
        profileID = requestedID
        revision &+= 1
        return RuntimeActivationResult(profileID: requestedID, changed: true, revision: revision)
    }

    private func reloadCore(_ candidate: RuntimeCatalog) async throws -> RuntimeReloadResult {
        guard let currentID = profileID else { throw RuntimeCoordinatorError.notRunning }
        let targetID = candidate.profiles[currentID] == nil ? candidate.configuration.defaultProfileID : currentID
        guard let target = candidate.profiles[targetID] else { throw RuntimeCoordinatorError.configurationRejected }
        let previous = catalog
        let previousCurrent = previous.profiles[currentID]
        let displayChanged = previousCurrent?.page.archive != target.page.archive

        if displayAwake, displayChanged {
            try await performChecked(.redraw(page: target.page))
        }
        if displayAwake, !dimmed, candidate.configuration.brightness != previous.configuration.brightness {
            try await performChecked(.setBrightness(candidate.configuration.brightness))
        }

        let changed = candidate.configuration != previous.configuration || targetID != currentID
        catalog = candidate
        profileID = targetID
        if changed { revision &+= 1 }
        recomputeIdleDeadline()
        restartTimerTask()
        return RuntimeReloadResult(profileID: targetID, changed: changed, revision: revision)
    }

    private func wakeHostCore() async throws {
        guard let profileID, let prepared = catalog.profiles[profileID] else {
            throw RuntimeCoordinatorError.sessionUnavailable
        }
        try await performChecked(.startup(page: prepared.page, brightness: catalog.configuration.brightness))
        displayAwake = true
        dimmed = false
        lastActivity = clock.now()
        recomputeIdleDeadline()
        revision &+= 1
        clearActionCandidatesForTransition()
        restartTimerTask()
    }

    private func processDueTimersCore() async throws {
        guard lifecycle == .running else { return }
        let now = clock.now()
        if now >= nextKeepAliveDeadline {
            try await performChecked(.keepAlive)
            nextKeepAliveDeadline = nextDeadline(after: nextKeepAliveDeadline, now: clock.now())
        }
        if displayAwake, !dimmed, let idleDeadline, clock.now() >= idleDeadline {
            try beginTransitionForCurrentAdmission()
            try await performChecked(.setBrightness(0))
            dimmed = true
            revision &+= 1
            clearActionCandidatesForTransition()
        }
    }

    private func runTimerLoop() async {
        while !Task.isCancelled {
            guard lifecycle == .running else { return }
            let deadline = timerDeadline()
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try await withAdmission(transition: false) {
                    try await self.processDueTimersCore()
                }
            } catch is CancellationError {
                return
            } catch {
                if failureLatch.isFailed { await failStopAfterAdmission() }
                return
            }
        }
    }

    private func timerDeadline() -> RuntimeMonotonicInstant {
        guard displayAwake, !dimmed, let idleDeadline else { return nextKeepAliveDeadline }
        return min(nextKeepAliveDeadline, idleDeadline)
    }

    private func restartTimerTask() {
        timerTask?.cancel()
        guard lifecycle == .running else {
            timerTask = nil
            return
        }
        timerTask = Task { [weak self] in await self?.runTimerLoop() }
    }

    private func performChecked(_ batch: D200XOutboundBatch) async throws {
        do {
            try await session.perform(batch)
        } catch {
            await failStopCore()
            throw RuntimeCoordinatorError.physicalWriteFailed
        }
        guard !failureLatch.isFailed else {
            await failStopCore()
            throw RuntimeCoordinatorError.physicalWriteFailed
        }
    }

    private func sessionDidFail() async {
        guard lifecycle != .failed, lifecycle != .stopped else { return }
        do {
            try await withAdmission(transition: true, cancellationAllowed: false) {
                await self.failStopCore()
            }
        } catch {
            await failStopAfterAdmission()
        }
    }

    private func failStopAfterAdmission() async {
        do {
            try await withAdmission(transition: true, cancellationAllowed: false) {
                await self.failStopCore()
            }
        } catch {
            lifecycle = .failed
        }
    }

    private func failStopCore() async {
        guard lifecycle != .stopped, stoppedOutcome == nil else { return }
        if !transitionHeld, transitionFence.beginTransition() {
            transitionHeld = true
            prepareTransition()
        }
        lifecycle = .failed
        timerTask?.cancel()
        timerTask = nil
        session.stop()
        let outcome = await session.waitUntilStopped()
        cleanupUncertain = outcome == .cleanupUncertain
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
        stoppedOutcome = cleanupUncertain ? .cleanupUncertain : .closed
    }

    private func makeCatalog(_ source: Data) throws -> RuntimeCatalog {
        try Self.makeCatalog(source)
    }

    private static func makeCatalog(_ source: Data) throws -> RuntimeCatalog {
        do {
            return try RuntimeCatalog(configuration: HidhoggConfigurationDecoder.decode(source))
        } catch let diagnostic as ConfigurationDiagnostic {
            throw diagnostic
        } catch {
            throw RuntimeCoordinatorError.configurationRejected
        }
    }

    private static func apply(
        _ edit: RuntimeConfigurationEdit,
        to source: Data,
        currentProfileID: String
    ) throws -> Data {
        switch edit {
        case let .setProfileLabel(profileID, label):
            return try ConfigurationEditor.setProfileLabel(in: source, profileID: profileID, label: label)
        case let .cloneProfile(sourceID, newID, label):
            return try ConfigurationEditor.cloneProfile(in: source, sourceID: sourceID, newID: newID, label: label)
        case let .deleteProfile(profileID):
            return try ConfigurationEditor.deleteProfile(in: source, profileID: profileID, currentProfileID: currentProfileID)
        case let .patchPosition(profileID, coordinate, patch):
            return try ConfigurationEditor.patchPosition(in: source, profileID: profileID, coordinate: coordinate, patch: patch)
        }
    }

    private func requireRunning() throws {
        guard lifecycle == .running, !failureLatch.isFailed else {
            if failureLatch.isFailed { throw RuntimeCoordinatorError.physicalWriteFailed }
            throw RuntimeCoordinatorError.notRunning
        }
    }

    private func withAdmission<Value: Sendable>(
        expectedStamp: RuntimeTransitionStamp? = nil,
        transition: Bool,
        cancellationAllowed: Bool = true,
        operation: () async throws -> Value
    ) async throws -> Value {
        try await acquireAdmission(
            expectedStamp: expectedStamp,
            transition: transition,
            cancellationAllowed: cancellationAllowed
        )
        defer { releaseAdmission() }
        return try await operation()
    }

    private func acquireAdmission(
        expectedStamp: RuntimeTransitionStamp? = nil,
        transition: Bool,
        cancellationAllowed: Bool = true
    ) async throws {
        if cancellationAllowed, Task.isCancelled { throw CancellationError() }
        if admissionHeld {
            let identifier = UUID()
            let granted = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    if cancellationAllowed, Task.isCancelled {
                        continuation.resume(returning: false)
                        return
                    }
                    admissionWaiters.append(RuntimeAdmissionWaiter(id: identifier, continuation: continuation))
                }
            } onCancel: {
                guard cancellationAllowed else { return }
                Task { await self.cancelAdmissionWaiter(identifier) }
            }
            guard granted else { throw CancellationError() }
            if cancellationAllowed, Task.isCancelled {
                releaseAdmissionPermit()
                throw CancellationError()
            }
        } else {
            admissionHeld = true
        }

        if transition {
            let began = expectedStamp.map(transitionFence.beginTransition(after:)) ?? transitionFence.beginTransition()
            guard began else {
                releaseAdmissionPermit()
                if expectedStamp != nil { throw RuntimeStaleReceipt() }
                throw RuntimeCoordinatorError.notRunning
            }
            transitionHeld = true
            prepareTransition()
        } else if let expectedStamp, !transitionFence.accepts(expectedStamp) {
            releaseAdmissionPermit()
            throw RuntimeStaleReceipt()
        }
    }

    private func cancelAdmissionWaiter(_ identifier: UUID) {
        guard let index = admissionWaiters.firstIndex(where: { $0.id == identifier }) else { return }
        let waiter = admissionWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releaseAdmission() {
        if transitionHeld {
            _ = transitionFence.endTransition()
            transitionHeld = false
        }
        releaseAdmissionPermit()
    }

    private func releaseAdmissionPermit() {
        if admissionWaiters.isEmpty {
            admissionHeld = false
            return
        }
        let next = admissionWaiters.removeFirst()
        next.continuation.resume(returning: true)
    }

    private func beginTransitionForCurrentAdmission() throws {
        guard !transitionHeld, transitionFence.beginTransition() else {
            if transitionHeld { return }
            throw RuntimeCoordinatorError.notRunning
        }
        transitionHeld = true
        prepareTransition()
    }

    private func prepareTransition() {
        suppressedInputs.formUnion(heldInputs)
        pendingReleaseBindings.removeAll()
    }

    private func clearActionCandidatesForTransition() {
        suppressedInputs.formUnion(heldInputs)
        pendingReleaseBindings.removeAll()
    }

    private func reconcileStaleInput(_ event: D200XInputEvent) {
        guard event.marker == 0x01 || event.marker == 0x02 else { return }
        let inputKey = RuntimeInputKey(marker: event.marker, wireIndex: event.wireIndex)
        switch event.action {
        case 0x01:
            heldInputs.insert(inputKey)
            suppressedInputs.insert(inputKey)
            pendingReleaseBindings.removeValue(forKey: inputKey)
        case 0x00:
            heldInputs.remove(inputKey)
            suppressedInputs.remove(inputKey)
            pendingReleaseBindings.removeValue(forKey: inputKey)
        default:
            break
        }
    }

    private func suppress(_ event: D200XInputEvent) {
        guard event.marker == 0x01 || event.marker == 0x02 else { return }
        let inputKey = RuntimeInputKey(marker: event.marker, wireIndex: event.wireIndex)
        if event.action == 0x01 {
            heldInputs.insert(inputKey)
            suppressedInputs.insert(inputKey)
        } else if event.action == 0x00 {
            heldInputs.remove(inputKey)
            suppressedInputs.remove(inputKey)
            pendingReleaseBindings.removeValue(forKey: inputKey)
        }
    }

    private func recordActivity(at instant: RuntimeMonotonicInstant) {
        if instant > lastActivity { lastActivity = instant }
        recomputeIdleDeadline()
    }

    private func recomputeIdleDeadline() {
        let timeout = catalog.configuration.idleTimeoutSeconds
        idleDeadline = timeout == 0 ? nil : lastActivity.advanced(by: .seconds(timeout))
    }

    private func nextDeadline(after deadline: RuntimeMonotonicInstant, now: RuntimeMonotonicInstant) -> RuntimeMonotonicInstant {
        var next = deadline
        repeat { next = next.advanced(by: Self.keepAliveInterval) } while next <= now
        return next
    }

    private func actionGesture(_ action: ConfiguredAction) -> ButtonGesture {
        switch action {
        case let .activateProfile(_, gesture), let .execute(_, _, _, gesture),
             let .typeText(_, gesture), let .keyPress(_, gesture):
            return gesture
        }
    }

    private func isRecognizedInputEvent(_ event: D200XInputEvent) -> Bool {
        switch event.marker {
        case 0x01:
            return event.action == 0x00 || event.action == 0x01
        case 0x02:
            return event.action == 0x00 || event.action == 0x01 || event.action == 0x02 || event.action == 0x03
        default:
            return false
        }
    }
}
