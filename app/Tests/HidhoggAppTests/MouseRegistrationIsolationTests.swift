import Foundation
@testable import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class MouseRegistrationIsolationTests: XCTestCase {
    func testSelectedUUIDSettingsAndSaveCompletionRemainIndependent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let gate = MouseSaveGate()
        let store = ConfigurationStore(url: url, beforeRegistryPublication: { gate.waitOnce() })
        let model = makeModel(url: url, store: store, session: MouseIsolationSession())
        let firstID = try XCTUnwrap(model.selectedMouseID)
        model.setWheelPreference(true)
        model.addDevice(.mxMaster3S)
        let secondID = try XCTUnwrap(model.selectedMouseID)
        XCTAssertNotEqual(firstID, secondID)
        model.setWheelPreference(false)
        model.setWheelScrollAmount(4)
        model.beginRecording(for: .forward)
        XCTAssertNotNil(model.recordingTarget)
        model.completeRecording(KeyboardShortcut(keyCode: 14))
        XCTAssertEqual(model.document.draft.mouse?.defaults["forward"], .key(KeyboardShortcut(keyCode: 14)))
        var second = model.document.draft
        second.devices[0].applications["test.synthetic.app"] = ["back": .key(KeyboardShortcut(keyCode: 13))]
        model.updateDraft(second)

        let saving = Task { await model.save() }
        let savingStarted = await eventually { gate.hasEntered }
        XCTAssertTrue(savingStarted)
        model.navigate(to: .mouse(firstID))
        XCTAssertEqual(model.wheelPreferenceDraft, true)
        XCTAssertNil(model.wheelScrollAmountDraft)
        XCTAssertTrue(model.applicationIDs.isEmpty)
        XCTAssertEqual(model.document.draft.mouse?.defaults["forward"], .disabled)
        model.setThumbwheelPreference(false)
        gate.release()
        await saving.value

        XCTAssertEqual(model.selectedMouseID, firstID)
        XCTAssertEqual(model.wheelPreferenceDraft, true)
        XCTAssertEqual(model.thumbwheelPreferenceDraft, false)
        XCTAssertEqual(model.document.saved.mouse?.thumbwheelInverted, true)
        XCTAssertTrue(model.isDirty)
        model.navigate(to: .mouse(secondID))
        XCTAssertEqual(model.wheelPreferenceDraft, false)
        XCTAssertEqual(model.wheelScrollAmountDraft, 4)
        XCTAssertEqual(model.applicationIDs, ["test.synthetic.app"])
        let saved = await model.flushPendingSave()
        XCTAssertTrue(saved)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.workspace.configuration(forMouseID: firstID).mouse?.thumbwheelInverted, false)
        XCTAssertEqual(loaded.workspace.configuration(forMouseID: firstID).mouse?.wheelInverted, true)
        XCTAssertEqual(loaded.workspace.configuration(forMouseID: secondID).mouse?.wheelInverted, false)
        XCTAssertEqual(loaded.workspace.configuration(forMouseID: secondID).mouse?.applications, second.mouse?.applications)
        model.navigate(to: .devices)
        XCTAssertNil(model.document.draft.mouse)
        XCTAssertNil(model.selectedMouseID)
    }

    func testSecondRegistrationIncludingDisabledRevokesRuntimeAdmission() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = MouseIsolationSession()
        var posted = [KeyboardShortcut]()
        let model = makeModel(url: url, session: session, post: { posted.append($0) })
        var configuration = model.document.draft
        configuration.devices[0].defaults["back"] = .key(KeyboardShortcut(keyCode: 12))
        model.updateDraft(configuration)
        model.connect()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)
        let oldGeneration = model.boltStatus.generation
        session.pauseStop()
        model.addDevice(.mxMaster3S)
        let secondID = try XCTUnwrap(model.selectedMouseID)
        model.setDeviceEnabled(secondID, enabled: false)
        let cleanupPending = await eventually { session.stopIsPending }
        XCTAssertTrue(cleanupPending)
        model.connect()
        model.confirmEnableBindings()
        model.applySavedWheelPreference()
        session.press(generation: oldGeneration)
        session.emitEnabled(generation: oldGeneration + 1)
        await drain()
        XCTAssertTrue(model.needsMouseEndpointSelection)
        XCTAssertFalse(model.isBindingsEnabled)
        XCTAssertFalse(model.canDiscover)
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertEqual(session.discoverCount, 1)
        XCTAssertEqual(session.enableCount, 1)
        XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(model.connectionMessage.contains("Endpoint selection"))
        session.resumeStop()
        let stopped = await eventually { model.boltStatus.phase == .idle }
        XCTAssertTrue(stopped)
        _ = await model.flushPendingSave()
    }

    func testRemoveAndReaddCancelsConnectWaitingForOldCleanup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = MouseIsolationSession()
        let model = makeModel(url: url, session: session)
        let oldID = try XCTUnwrap(model.selectedMouseID)
        model.connect()
        let connected = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(connected)
        session.pauseStop()
        model.setDeviceEnabled(oldID, enabled: false)
        let cleanupPending = await eventually { session.stopIsPending }
        XCTAssertTrue(cleanupPending)
        model.setDeviceEnabled(oldID, enabled: true)
        model.connect()
        model.removeDevice(oldID)
        model.addDevice(.mxMaster3S)
        let newID = try XCTUnwrap(model.selectedMouseID)
        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(model.mouseStatus(for: newID).phase, .idle)
        XCTAssertNil(model.mouseStatus(for: newID).deviceInformation.battery)
        XCTAssertNil(model.presentedMouseOwnerID)
        session.resumeStop()
        await drain()
        XCTAssertEqual(session.discoverCount, 1)
        XCTAssertFalse(model.connectionRequested)
        XCTAssertFalse(model.canEnableBindings)
        model.connect()
        let rediscovered = await eventually {
            session.discoverCount == 2 && model.presentedMouseOwnerID == newID &&
                [.ready, .enabled].contains(model.boltStatus.phase)
        }
        XCTAssertTrue(rediscovered)
        XCTAssertEqual(model.selectedMouseID, newID)
        XCTAssertEqual(model.presentedMouseOwnerID, newID)
        model.navigate(to: .mouse(oldID))
        model.navigate(to: .mouse(newID))
        model.goBack()
        XCTAssertNotEqual(model.navigation.current.route, .mouse(oldID))
        _ = await model.flushPendingSave()
    }

    func testPersistedMultipleMiceNeverActivateOnLaunch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        var second = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        second.isEnabled = false
        _ = try await store.save(WorkspaceConfiguration(connectOnLaunch: true, devices: [first, second]), expecting: .missing)
        let session = MouseIsolationSession()
        let model = makeModel(url: url, store: store, session: session, loadImmediately: true)
        let loaded = await eventually { !model.isLoading }
        XCTAssertTrue(loaded)
        await drain()
        XCTAssertEqual(model.navigation.current.route, .mouse(first.id))
        XCTAssertEqual(model.selectedMouseID, first.id)
        XCTAssertEqual(model.document.draft.mouse, WorkspaceConfiguration(devices: [first]).configuration(forMouseID: first.id).mouse)
        XCTAssertFalse(model.navigation.canGoBack)
        XCTAssertTrue(model.needsMouseEndpointSelection)
        XCTAssertEqual(session.discoverCount, 0)
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertTrue(session.wheelInversions.isEmpty)
        XCTAssertNil(model.presentedMouseOwnerID)
        XCTAssertFalse(model.connectionRequested)
    }

    func testSharedAndDeckEditsWithNoSelectedMousePreserveEveryMousePayload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let session = MouseIsolationSession()
        let model = makeModel(url: url, store: store, session: session)
        model.setWheelPreference(true)
        model.addDevice(.mxMaster3S)
        model.setWheelPreference(false)
        let originalMice = model.registeredDevices.filter { $0.family == .mxMaster3S }
        model.navigate(to: .settings)
        XCTAssertNil(model.selectedMouseID)
        model.setConnectOnLaunch(false)
        XCTAssertFalse(model.workspace.connectOnLaunch)
        model.navigate(to: .d200x)
        XCTAssertNil(model.selectedMouseID)
        model.d200x.enableConfiguration()
        model.d200x.setBrightnessPercent(65)
        XCTAssertEqual(model.document.draft.d200x?.brightnessPercent, 65)
        XCTAssertNil(model.errorMessage)
        let saved = await model.flushPendingSave()
        XCTAssertTrue(saved)
        let loaded = try await store.load()
        XCTAssertFalse(loaded.workspace.connectOnLaunch)
        XCTAssertEqual(loaded.configuration.d200x?.brightnessPercent, 65)
        XCTAssertEqual(loaded.workspace.devices.filter { $0.family == .mxMaster3S }, originalMice)
        XCTAssertEqual(session.discoverCount, 0)
        XCTAssertTrue(session.wheelInversions.isEmpty)
    }

    func testUncertainCleanupCannotAdmitReplacementUUID() async throws {
        try await assertCleanupFailureBlocksReplacement(uncertainStatus: true)
    }

    func testFalseCleanupResultWithCleanStatusCannotAdmitReplacementUUID() async throws {
        try await assertCleanupFailureBlocksReplacement(uncertainStatus: false)
    }

    private func assertCleanupFailureBlocksReplacement(uncertainStatus: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = MouseIsolationSession()
        let model = makeModel(url: url, session: session)
        let oldID = try XCTUnwrap(model.selectedMouseID)
        model.connect()
        let connected = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(connected)
        session.setCleanupFailure(uncertainStatus: uncertainStatus)
        model.removeDevice(oldID)
        model.addDevice(.mxMaster3S)
        let cleanupFailed = await eventually { session.stopCount >= 1 && model.boltStatus.phase == .idle }
        XCTAssertTrue(cleanupFailed)
        model.connect()
        await drain()
        XCTAssertEqual(session.discoverCount, 1)
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertNil(model.presentedMouseOwnerID)
        XCTAssertEqual(model.selectedMouseStatus.phase, .idle)
        _ = await model.flushPendingSave()
    }

    func testStaleWheelCompletionCannotReactivateOrApplyAnotherEditor() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = MouseIsolationSession()
        let model = makeModel(url: url, session: session)
        model.setWheelPreference(true)
        session.pauseWheel()
        model.connect()
        let applying = await eventually { session.wheelIsPending }
        XCTAssertTrue(applying)
        model.addDevice(.mxMaster3S)
        model.setWheelPreference(false)
        await drain()
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(session.wheelInversions, [true])
        session.resumeWheel()
        let stopped = await eventually { session.stopCount == 1 && model.boltStatus.phase == .idle }
        XCTAssertTrue(stopped)
        XCTAssertFalse(model.isWheelApplyPending)
        XCTAssertFalse(model.isBindingsEnabled)
        XCTAssertFalse(model.canDiscover)
        XCTAssertEqual(session.wheelInversions, [true])
        XCTAssertEqual(session.enableCount, 0)
        _ = await model.flushPendingSave()
    }

    private func makeModel(
        url: URL,
        store: ConfigurationStore? = nil,
        session: MouseIsolationSession,
        loadImmediately: Bool = false,
        post: @escaping @MainActor (KeyboardShortcut) throws -> Void = { _ in }
    ) -> AppModel {
        AppModel(configurationURL: url, store: store ?? ConfigurationStore(url: url), bolt: session,
                 sender: ShortcutSender(preflight: { true }, request: { true }, postPair: post),
                 loadImmediately: loadImmediately, observeSleep: false, frontmostApplication: { nil })
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

private final class MouseSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false

    var hasEntered: Bool { lock.withLock { entered } }

    func waitOnce() {
        let shouldWait = lock.withLock {
            guard !entered else { return false }
            entered = true
            return true
        }
        if shouldWait { semaphore.wait() }
    }

    func release() { semaphore.signal() }
}

private final class MouseIsolationSession: BindingSession, @unchecked Sendable {
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var generation: UInt64 = 10
    private var discoveries = 0
    private var enables = 0
    private var stops = 0
    private var shouldPauseStop = false
    private var shouldPauseWheel = false
    private var stopWait: CheckedContinuation<Void, Never>?
    private var wheelWait: CheckedContinuation<Void, Never>?
    private var inversions: [Bool?] = []
    private var cleanupUncertain = false
    private var cleanupSucceeded = true

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    var discoverCount: Int { lock.withLock { discoveries } }
    var enableCount: Int { lock.withLock { enables } }
    var stopCount: Int { lock.withLock { stops } }
    var stopIsPending: Bool { lock.withLock { stopWait != nil } }
    var wheelIsPending: Bool { lock.withLock { wheelWait != nil } }
    var wheelInversions: [Bool?] { lock.withLock { inversions } }

    func discover() async {
        lock.withLock { discoveries += 1 }
        emit(.ready)
    }

    func enable() async {
        lock.withLock { enables += 1 }
        emit(.enabled)
    }

    func disable() async { emit(.ready) }

    func stopForRestart() async -> Bool {
        await stop()
        return lock.withLock { cleanupSucceeded }
    }

    func stop() async {
        lock.withLock { stops += 1 }
        await withCheckedContinuation { continuation in
            let paused = lock.withLock {
                guard shouldPauseStop else { return false }
                shouldPauseStop = false
                stopWait = continuation
                return true
            }
            if !paused { continuation.resume() }
        }
        emit(.idle)
    }

    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                               amount: Double?, scrollPostingAllowed: Bool) async {
        lock.withLock { inversions.append(inverted) }
        await withCheckedContinuation { continuation in
            let paused = lock.withLock {
                guard shouldPauseWheel else { return false }
                shouldPauseWheel = false
                wheelWait = continuation
                return true
            }
            if !paused { continuation.resume() }
        }
    }

    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        operation()
        return true
    }

    func pauseStop() { lock.withLock { shouldPauseStop = true } }
    func pauseWheel() { lock.withLock { shouldPauseWheel = true } }
    func setCleanupFailure(uncertainStatus: Bool) {
        lock.withLock {
            cleanupUncertain = uncertainStatus
            cleanupSucceeded = false
        }
    }

    func resumeStop() {
        let wait = lock.withLock { let wait = stopWait; stopWait = nil; return wait }
        wait?.resume()
    }

    func resumeWheel() {
        let wait = lock.withLock { let wait = wheelWait; wheelWait = nil; return wait }
        wait?.resume()
    }

    func press(generation: UInt64) { continuation.yield(.press(.back, generation: generation, observedAt: .now)) }

    func emitEnabled(generation: UInt64) { emit(.enabled, generation: generation) }

    private func emit(_ phase: BoltPhase, generation requestedGeneration: UInt64? = nil) {
        let next = lock.withLock {
            generation = requestedGeneration ?? generation + 1
            return generation
        }
        continuation.yield(.status(BoltStatus(phase: phase, message: "Synthetic session", availableControls: Set(MouseControl.allCases),
                                             generation: next, cleanupUncertain: lock.withLock { cleanupUncertain },
                                             wheel: .init(support: .supported),
                                             deviceInformation: .init(batteryState: .available,
                                                                      battery: .init(percentage: 7, charging: .discharging, observedAt: .now)))))
    }
}
