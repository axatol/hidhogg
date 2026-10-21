import XCTest
@testable import HidhoggApp
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions

@MainActor
final class WheelEditorTests: XCTestCase {
    func testResolutionOnlyReconcilesSavesAndReleasesWithoutKeyboardPermission() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = WheelBindingSession()
        let model = makeModel(url: url, session: session, sender: sender(permissionAllowed: false))
        XCTAssertNil(model.wheelHighResolutionDraft)
        XCTAssertEqual(model.observedWheelResolution, "Not observed")
        model.setWheelHighResolution(true)
        model.connect()
        let applied = await eventually { session.appliedResolutions == [true] && !model.isWheelApplyInFlight }
        XCTAssertTrue(applied)
        XCTAssertEqual(session.appliedPreferences, [nil])
        XCTAssertEqual(model.observedWheelResolution, "High")
        XCTAssertEqual(model.observedWheelDirection, "Natural")
        XCTAssertEqual(session.enableCount, 0)
        await model.save()
        let persisted = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(persisted.configuration.mouse?.wheelHighResolution, true)
        XCTAssertNil(persisted.configuration.mouse?.wheelInverted)
        model.setWheelHighResolution(nil)
        let released = await eventually { session.appliedResolutions == [true, nil] && !model.isWheelApplyInFlight }
        XCTAssertTrue(released)
        XCTAssertEqual(model.observedWheelResolution, "High")
        XCTAssertNil(model.wheelHighResolutionDraft)
    }

    func testMixedEditsDuringApplyReconcileAsOneLatestRequest() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WheelBindingSession()
        let model = makeModel(url: root.appendingPathComponent("config.toml"), session: session, sender: sender(permissionAllowed: false))
        model.setWheelHighResolution(true)
        session.pauseNextApply()
        model.connect()
        let pending = await eventually { session.applyIsPending }
        XCTAssertTrue(pending)
        model.setWheelPreference(false)
        model.setWheelHighResolution(false)
        model.setWheelHighResolution(true)
        model.setRestorePreviousSettingsOnDisconnect(true)
        session.resumeApply()
        let finished = await eventually { session.appliedResolutions.count == 2 && !model.isWheelApplyInFlight }
        XCTAssertTrue(finished)
        XCTAssertEqual(session.appliedPreferences, [nil, false])
        XCTAssertEqual(session.appliedResolutions, [true, true])
        XCTAssertEqual(session.appliedPolicies, [false, true])
    }

    func testPolicyOnlyEditsReconcileAndAutosaveWithoutManagedDirection() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = WheelBindingSession()
        let model = makeModel(url: url, session: session, sender: sender(permissionAllowed: false))
        model.connect()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertFalse(model.restorePreviousSettingsOnDisconnect)
        model.setRestorePreviousSettingsOnDisconnect(true)
        let enabled = await eventually { session.appliedPolicies == [true] }
        XCTAssertTrue(enabled)
        let enabledSaved = await eventually { !model.isDirty }
        XCTAssertTrue(enabledSaved)
        let enabledConfiguration = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(enabledConfiguration.configuration.mouse?.restorePreviousSettingsOnDisconnect, true)
        model.setRestorePreviousSettingsOnDisconnect(false)
        let disabled = await eventually { session.appliedPolicies == [true, false] }
        XCTAssertTrue(disabled)
        let saved = await eventually { !model.isDirty }
        XCTAssertTrue(saved)
        let persisted = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(persisted.configuration.mouse?.restorePreviousSettingsOnDisconnect, false)
        XCTAssertNil(persisted.configuration.mouse?.wheelInverted)
    }

    func testImmediateLifecycleStopUsesLatestPolicyWithoutApplyingPendingDirection() async throws {
        for initiallyRestoring in [false, true] {
            for lifecycle in ["disconnect", "sleep", "termination", "restart"] {
                let root = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let session = WheelBindingSession()
                let model = makeModel(
                    url: root.appendingPathComponent("config.toml"),
                    session: session, sender: sender(permissionAllowed: false)
                )
                model.setWheelPreference(true)
                model.setRestorePreviousSettingsOnDisconnect(initiallyRestoring)
                model.connect()
                let applied = await eventually { session.appliedPreferences == [true] && !model.isWheelApplyInFlight }
                XCTAssertTrue(applied)
                model.setRestorePreviousSettingsOnDisconnect(!initiallyRestoring)
                model.setWheelPreference(false)
                model.setWheelHighResolution(true)
                switch lifecycle {
                case "disconnect": model.disconnect()
                case "sleep": await model.stopForSleep()
                case "termination": _ = await model.stopForTermination()
                default: _ = await model.stopForRestart()
                }
                let stopped = await eventually { session.stoppedPolicies == [!initiallyRestoring] }
                XCTAssertTrue(stopped, lifecycle)
                XCTAssertEqual(session.appliedPreferences, [true], lifecycle)
                XCTAssertEqual(session.appliedPolicies, [initiallyRestoring], lifecycle)
                XCTAssertEqual(session.appliedResolutions, [nil], lifecycle)
            }
        }
    }

    func testConnectAutomaticallyAppliesUnsavedWheelWithoutKeyboardPermission() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = WheelBindingSession()
        let model = makeModel(url: url, session: session, sender: sender(permissionAllowed: false))
        model.setWheelPreference(false)
        model.connect()
        let applied = await eventually { session.appliedPreferences == [false] && !model.isWheelApplyInFlight }
        XCTAssertTrue(applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(model.permission, .denied)
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertEqual(session.stopCount, 0)
        model.setWheelPreference(nil)
        let retained = await eventually { session.appliedPreferences == [false, nil] && !model.isWheelApplyInFlight }
        XCTAssertTrue(retained)
        XCTAssertTrue(model.boltStatus.wheel.isOwned)
        XCTAssertEqual(model.observedWheelDirection, "Standard")
    }

    func testFailedWheelApplyDoesNotRetryOnRepeatedStatusOrPermissionRefresh() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WheelBindingSession()
        session.failNextApply()
        let model = makeModel(
            url: root.appendingPathComponent("config.toml"), session: session,
            sender: sender(permissionAllowed: false)
        )
        model.setWheelPreference(false)
        await model.save()
        model.connect()
        let failed = await eventually { model.boltStatus.wheel.message == "Fixture apply failed." && !model.isWheelApplyInFlight }
        XCTAssertTrue(failed)
        _ = model.refreshPermission()
        _ = model.refreshPermission()
        session.emitReady(wheel: model.boltStatus.wheel)
        await drainMainActorTasks()
        XCTAssertEqual(session.appliedPreferences, [false])
        XCTAssertEqual(model.savedWheelPreference, false)
        XCTAssertEqual(model.observedWheelDirection, "Natural")
        XCTAssertNil(model.configurationSaveError)
        XCTAssertEqual(session.stopCount, 0)
        model.disconnect()
        let stopped = await eventually { session.stopCount == 1 && model.boltStatus.phase == .idle }
        XCTAssertTrue(stopped)
        model.connect()
        let retried = await eventually { session.appliedPreferences == [false, false] && !model.isWheelApplyInFlight }
        XCTAssertTrue(retried)
        XCTAssertEqual(model.observedWheelDirection, "Standard")
    }

    func testApplyRequiresSupportedConnectionAndAcceptsUnsavedDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = WheelBindingSession()
        let model = makeModel(url: url, session: session, sender: sender(permissionAllowed: true))
        var configuration = AppConfiguration.empty
        configuration.devices[0].wheelInverted = false
        model.updateDraft(configuration)

        XCTAssertFalse(model.canApplyWheelPreference)
        await model.save()
        XCTAssertFalse(model.canApplyWheelPreference)

        session.emitReady(wheel: BoltWheelStatus(support: .unsupported, message: "Wheel preference unavailable."))
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.observedWheelDirection, "Unsupported")
        XCTAssertFalse(model.canApplyWheelPreference)

        session.emitReady(wheel: BoltWheelStatus(support: .supported, observedInverted: true))
        let supported = await eventually { model.canApplyWheelPreference }
        XCTAssertTrue(supported)

        model.setWheelPreference(true)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canApplyWheelPreference)
    }

    func testDeniedKeyboardPermissionDoesNotGateSavedFalseApply() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WheelBindingSession()
        let model = try await makeReadyModel(
            url: root.appendingPathComponent("config.toml"),
            session: session,
            sender: sender(permissionAllowed: false),
            wheelInverted: false
        )

        XCTAssertEqual(model.permission, .denied)
        XCTAssertTrue(model.canApplyWheelPreference)
        model.applySavedWheelPreference()

        let applied = await eventually { session.appliedPreferences.count == 1 }
        XCTAssertTrue(applied)
        XCTAssertEqual(session.appliedPreferences, [false])
        let finished = await eventually { !model.isWheelApplyInFlight }
        XCTAssertTrue(finished)
        XCTAssertEqual(model.observedWheelDirection, "Standard")
        XCTAssertEqual(model.wheelSessionChange, "Kept on device")
        XCTAssertEqual(session.stopCount, 0)
    }

    func testUnmanagedUnownedWheelDoesNotSpendAnApplyOperation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WheelBindingSession()
        let model = try await makeReadyModel(
            url: root.appendingPathComponent("config.toml"),
            session: session,
            sender: sender(permissionAllowed: true),
            wheelInverted: nil
        )

        XCTAssertNil(model.savedWheelPreference)
        model.applySavedWheelPreference()

        await drainMainActorTasks()
        XCTAssertEqual(session.appliedPreferences, [])
        let finished = await eventually { !model.isWheelApplyInFlight }
        XCTAssertTrue(finished)
        XCTAssertFalse(model.boltStatus.wheel.isOwned)
    }

    func testQueuedApplyIsInvalidatedByDisconnect() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WheelBindingSession()
        let model = try await makeReadyModel(
            url: root.appendingPathComponent("config.toml"),
            session: session,
            sender: sender(permissionAllowed: true),
            wheelInverted: false
        )

        model.applySavedWheelPreference()
        XCTAssertTrue(model.isWheelApplyPending)
        model.disconnect()

        let stopped = await eventually { session.stopCount == 1 }
        XCTAssertTrue(stopped)
        await drainMainActorTasks()
        XCTAssertEqual(session.appliedPreferences, [])
        XCTAssertFalse(model.isWheelApplyPending)
    }

    func testQueuedApplyIsInvalidatedByRestart() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WheelBindingSession()
        let model = try await makeReadyModel(
            url: root.appendingPathComponent("config.toml"),
            session: session,
            sender: sender(permissionAllowed: true),
            wheelInverted: false
        )

        model.applySavedWheelPreference()
        XCTAssertTrue(model.isWheelApplyPending)
        model.setRestarting(true)
        _ = await model.stopForRestart()
        await drainMainActorTasks()

        XCTAssertEqual(session.appliedPreferences, [])
        XCTAssertFalse(model.isWheelApplyPending)
    }

    func testDraftChangesDuringApplyCoalesceAndRemainEditableAndSaveable() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = WheelBindingSession()
        let model = try await makeReadyModel(
            url: url,
            session: session,
            sender: sender(permissionAllowed: true),
            wheelInverted: false
        )
        session.pauseNextApply()
        XCTAssertTrue(model.canReloadConfiguration)
        model.applySavedWheelPreference()
        XCTAssertTrue(model.isWheelApplyPending)
        let applying = await eventually { session.applyIsPending }
        XCTAssertTrue(applying)

        var edited = AppConfiguration.empty
        edited.devices[0].wheelInverted = true
        model.setWheelPreference(true)
        model.updateDraft(edited)
        model.setWheelPreference(false)
        model.setWheelPreference(true)
        await model.save()
        model.beginRecording(for: .back)

        XCTAssertFalse(model.canSaveConfiguration)
        XCTAssertTrue(model.canReloadConfiguration)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isReloadConfirmationPresented)
        XCTAssertNotNil(model.recordingTarget)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.document.draft.mouse?.wheelInverted, true)
        XCTAssertEqual(session.discoverCount, 0)
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertEqual(session.stopCount, 0)
        let persisted = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(persisted.configuration.mouse?.wheelInverted, true)

        session.resumeApply()
        let finished = await eventually { !model.isWheelApplyInFlight && session.appliedPreferences.count == 2 }
        XCTAssertTrue(finished)
        XCTAssertEqual(session.appliedPreferences, [false, true])
    }

    func testPermissionRefreshDoesNotCancelWheelOnlyApply() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var permissionAllowed = true
        let sender = ShortcutSender(
            preflight: { permissionAllowed },
            request: { permissionAllowed },
            postPair: { _ in }
        )
        let session = WheelBindingSession()
        let model = try await makeReadyModel(
            url: root.appendingPathComponent("config.toml"),
            session: session,
            sender: sender,
            wheelInverted: false
        )
        session.pauseNextApply()
        model.applySavedWheelPreference()
        let applying = await eventually { session.applyIsPending }
        XCTAssertTrue(applying)

        permissionAllowed = false
        XCTAssertEqual(model.refreshPermission(), .denied)
        XCTAssertTrue(model.isWheelApplyInFlight)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(session.appliedPreferences, [false])

        session.resumeApply()
        let finished = await eventually { !model.isWheelApplyInFlight }
        XCTAssertTrue(finished)
        XCTAssertEqual(session.stopCount, 0)
    }

    func testSaveAndReloadFromReadyRetainOwnedWheelChange() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WheelBindingSession()
        let model = try await makeReadyModel(
            url: root.appendingPathComponent("config.toml"),
            session: session,
            sender: sender(permissionAllowed: true),
            wheelInverted: false
        )
        model.applySavedWheelPreference()
        let applied = await eventually { model.boltStatus.wheel.isOwned && !model.isWheelApplyInFlight }
        XCTAssertTrue(applied)

        model.setWheelPreference(true)
        await model.save()
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertTrue(model.boltStatus.wheel.isOwned)
        XCTAssertEqual(session.stopCount, 0)

        model.requestReload()
        let reloaded = await eventually { !model.isLoading }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertTrue(model.boltStatus.wheel.isOwned)
        XCTAssertEqual(model.savedWheelPreference, true)
        XCTAssertEqual(session.stopCount, 0)
        let reconciled = await eventually { session.appliedPreferences == [false, true] && !model.isWheelApplyInFlight }
        XCTAssertTrue(reconciled)
    }

    private func sender(permissionAllowed: Bool) -> ShortcutSender {
        ShortcutSender(
            preflight: { permissionAllowed },
            request: { permissionAllowed },
            postPair: { _ in }
        )
    }

    private func makeModel(url: URL, session: WheelBindingSession, sender: ShortcutSender) -> AppModel {
        AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
    }

    private func makeReadyModel(
        url: URL,
        session: WheelBindingSession,
        sender: ShortcutSender,
        wheelInverted: Bool?
    ) async throws -> AppModel {
        let model = makeModel(url: url, session: session, sender: sender)
        var configuration = AppConfiguration.empty
        configuration.devices[0].wheelInverted = wheelInverted
        model.updateDraft(configuration)
        await model.save()
        session.emitReady(wheel: BoltWheelStatus(support: .supported, observedInverted: true))
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        return model
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WheelEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func drainMainActorTasks() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

private final class WheelBindingSession: BindingSession, @unchecked Sendable {
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var applyValues = [Bool?]()
    private var resolutionValues = [Bool?]()
    private var observedResolution = false
    private var pauseNextApplyValue = false
    private var applyIsPendingValue = false
    private var applyContinuation: CheckedContinuation<Void, Never>?
    private var discoverCalls = 0
    private var enableCalls = 0
    private var stopCalls = 0
    private var failNextApplyValue = false
    private var policyValues = [Bool]()
    private var stopPolicyValues = [Bool]()
    private var observedWheel = true
    private var ownedWheel = false

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var appliedPreferences: [Bool?] { locked { applyValues } }
    var appliedResolutions: [Bool?] { locked { resolutionValues } }
    var applyIsPending: Bool { locked { applyIsPendingValue } }
    var discoverCount: Int { locked { discoverCalls } }
    var enableCount: Int { locked { enableCalls } }
    var stopCount: Int { locked { stopCalls } }
    var appliedPolicies: [Bool] { locked { policyValues } }
    var stoppedPolicies: [Bool] { locked { stopPolicyValues } }

    func discover() async {
        locked { discoverCalls += 1 }
        emitReady(wheel: BoltWheelStatus(support: .supported, observedInverted: true))
    }

    func enable() async {
        locked { enableCalls += 1 }
    }

    func disable() async { await stop() }

    func stop(restorePreviousSettingsOnDisconnect: Bool) async {
        locked { stopPolicyValues.append(restorePreviousSettingsOnDisconnect) }
        await stop()
    }

    func stopForRestart(restorePreviousSettingsOnDisconnect: Bool) async -> Bool {
        await stop(restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
        return true
    }

    func stop() async {
        let continuationToResume = locked { () -> CheckedContinuation<Void, Never>? in
            stopCalls += 1
            let pending = applyContinuation
            applyContinuation = nil
            applyIsPendingValue = false
            return pending
        }
        continuationToResume?.resume()
        continuation.yield(.status(BoltStatus(
            phase: .idle,
            message: "Stopped.",
            availableControls: [],
            generation: 1,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(support: .supported, observedInverted: false)
        )))
    }

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool { false }

    func applyWheelPreference(_ inverted: Bool?) async {
        await apply(inverted: inverted, highResolution: nil)
    }

    private func apply(inverted: Bool?, highResolution: Bool?) async {
        let shouldPause = locked { () -> Bool in
            applyValues.append(inverted)
            let pause = pauseNextApplyValue
            pauseNextApplyValue = false
            return pause
        }
        continuation.yield(.status(BoltStatus(
            phase: .ready,
            message: "Applying wheel preference.",
            availableControls: Set(MouseControl.allCases),
            generation: 1,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(support: .supported, observedInverted: true, isApplying: true)
        )))

        if shouldPause {
            await withCheckedContinuation { applyContinuation in
                locked {
                    self.applyContinuation = applyContinuation
                    applyIsPendingValue = true
                }
            }
        }

        locked { applyIsPendingValue = false }
        let failed = locked {
            let failed = failNextApplyValue
            failNextApplyValue = false
            return failed
        }
        if failed {
            emitReady(wheel: BoltWheelStatus(support: .supported, observedInverted: true, message: "Fixture apply failed."))
            return
        }
        let result = locked {
            if let inverted {
                observedWheel = inverted
                ownedWheel = true
            } else if policyValues.last == true {
                observedWheel = true
                ownedWheel = false
            }
            if let highResolution {
                observedResolution = highResolution
                ownedWheel = true
            } else if policyValues.last == true {
                observedResolution = false
            }
            return (observedWheel, ownedWheel, observedResolution)
        }
        continuation.yield(.status(BoltStatus(
            phase: .ready,
            message: "Wheel preference complete.",
            availableControls: Set(MouseControl.allCases),
            generation: 1,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(
                support: .supported,
                observedInverted: result.0,
                isOwned: result.1,
                message: "Wheel preference verified.",
                observedHighResolution: result.2
            )
        )))
    }

    func applyWheelPreference(_ inverted: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        locked { policyValues.append(restorePreviousSettingsOnDisconnect) }
        await applyWheelPreference(inverted)
    }

    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        locked {
            policyValues.append(restorePreviousSettingsOnDisconnect)
            resolutionValues.append(highResolution)
        }
        await apply(inverted: inverted, highResolution: highResolution)
    }

    func emitReady(wheel: BoltWheelStatus) {
        continuation.yield(.status(BoltStatus(
            phase: .ready,
            message: "Ready.",
            availableControls: Set(MouseControl.allCases),
            generation: 1,
            cleanupUncertain: false,
            wheel: wheel
        )))
    }

    func pauseNextApply() { locked { pauseNextApplyValue = true } }

    func failNextApply() { locked { failNextApplyValue = true } }

    func resumeApply() {
        let continuationToResume = locked { () -> CheckedContinuation<Void, Never>? in
            let pending = applyContinuation
            applyContinuation = nil
            return pending
        }
        continuationToResume?.resume()
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
