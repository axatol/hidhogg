import Foundation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class AppModelIntegrationTests: XCTestCase {
    func testMissingConfigurationCannotEnableUntilDefaultsAreSaved() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )

        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.refreshPermission(), .granted)
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertTrue(model.canSaveConfiguration)

        await model.save()

        XCTAssertEqual(model.document.saved, .empty)
        XCTAssertEqual(model.document.draft, .empty)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.boltStatus.phase, .idle)
        XCTAssertFalse(model.canEnableBindings)
        model.connect()
        let reconnected = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(reconnected)
        XCTAssertTrue(model.canEnableBindings)
        let saved = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(saved.configuration, .empty)
    }

    func testInvalidConfigurationBlocksSavingAndPreservesOriginalBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let invalidBytes = Data("schema_version = 2\n".utf8)
        try invalidBytes.write(to: url)
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: true,
            observeSleep: false
        )

        session.emitReady()
        let loaded = await eventually { !model.isLoading }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.refreshPermission(), .granted)
        XCTAssertEqual(model.configurationStatus, "Configuration unavailable")
        XCTAssertTrue(model.configurationLoadFailed)
        XCTAssertFalse(model.canSaveConfiguration)
        XCTAssertFalse(model.canEnableBindings)

        await model.save()

        XCTAssertEqual(try Data(contentsOf: url), invalidBytes)
    }

    func testPermissionRevocationOnPressSuppressesDeliveryAndDisablesSession() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var permissionAvailable = true
        var posted = [KeyboardShortcut]()
        let session = FixtureBindingSession()
        let sender = ShortcutSender(
            preflight: { permissionAvailable },
            request: { permissionAvailable },
            postPair: { posted.append($0) }
        )
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false,
            frontmostApplication: { "com.example.browser" }
        )
        var configuration = AppConfiguration.empty
        let shortcut = KeyboardShortcut(keyCode: 0x7B, modifiers: [.command])
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(shortcut)
        model.updateDraft(configuration)
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.refreshPermission(), .granted)
        XCTAssertTrue(model.canEnableBindings)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)

        session.press(.back)
        let firstPressPosted = await eventually { posted.count == 1 }
        XCTAssertTrue(firstPressPosted)
        XCTAssertEqual(posted, [shortcut])

        permissionAvailable = false
        session.press(.back)
        let stopped = await eventually { session.stopCount == 1 }
        XCTAssertTrue(stopped)
        XCTAssertEqual(model.permission, .denied)
        XCTAssertFalse(model.isBindingsEnabled)
        XCTAssertEqual(posted, [shortcut])
    }

    func testDisconnectSleepAndTerminationInvalidateQueuedSessionIntents() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        model.refreshPermission()
        await model.save()

        model.connect()
        model.disconnect()
        let disconnected = await eventually { session.stopCount == 1 }
        XCTAssertTrue(disconnected)
        await drainMainActorTasks()
        XCTAssertEqual(session.discoverCount, 0)
        XCTAssertEqual(session.enableCount, 0)

        model.connect()
        model.prepareForLifecycleStop()
        let sleepCleanup = Task { await model.stopForSleep() }
        await sleepCleanup.value
        await drainMainActorTasks()
        XCTAssertEqual(session.stopCount, 2)
        XCTAssertEqual(session.discoverCount, 0)

        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        model.prepareForLifecycleStop()
        let terminationCleanup = Task { await model.stopForTermination() }
        await terminationCleanup.value
        await drainMainActorTasks()
        XCTAssertEqual(session.stopCount, 3)
        XCTAssertEqual(session.enableCount, 0)
    }

    func testSaveInvalidatesQueuedEnableAndDisablesEnableDuringSave() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        model.refreshPermission()
        model.requestEnableConfirmation()
        model.confirmEnableBindings()

        var edited = AppConfiguration.empty
        edited.devices[0].defaults[MouseControl.forward.rawValue] = .key(KeyboardShortcut(keyCode: 0x7C))
        model.updateDraft(edited)
        session.pauseNextStop()
        let observation = Task { @MainActor in
            let stopped = await eventually { session.stopIsPending }
            let saving = model.isSaving
            let canEnableDuringSave = model.canEnableBindings
            session.resumeStop()
            return (stopped, saving, canEnableDuringSave)
        }

        await model.save()

        let (stopWasAwaited, savingWasVisible, enableWasBlocked) = await observation.value
        XCTAssertTrue(stopWasAwaited)
        XCTAssertTrue(savingWasVisible)
        XCTAssertFalse(enableWasBlocked)
        await drainMainActorTasks()
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertEqual(model.document.saved, edited)
        XCTAssertFalse(model.isDirty)
    }

    func testReloadTemporarilyBlocksEnableFromReadyState() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        model.refreshPermission()
        XCTAssertTrue(model.canEnableBindings)

        model.requestReload()

        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.canEnableBindings)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        XCTAssertFalse(model.isEnableConfirmationPresented)
        let loaded = await eventually { !model.isLoading }
        XCTAssertTrue(loaded)
        await drainMainActorTasks()
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertEqual(model.boltStatus.phase, .idle)
        model.connect()
        let reconnected = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(reconnected)
        XCTAssertTrue(model.canEnableBindings)
    }

    func testSleepAndTerminationAwaitInjectedSessionCleanup() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var posted = 0
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in posted += 1 })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 0x7B))
        model.updateDraft(configuration)
        await model.save()
        session.emitReady()
        let firstReady = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(firstReady)
        _ = model.refreshPermission()
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        let firstEnable = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(firstEnable)

        await model.stopForSleep()
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertFalse(model.isBindingsEnabled)
        session.press(.back)
        await Task.yield()
        XCTAssertEqual(posted, 0)

        session.emitReady()
        let secondReady = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(secondReady)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        let secondEnable = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(secondEnable)

        await model.stopForTermination()
        XCTAssertEqual(session.stopCount, 2)
        XCTAssertFalse(model.isBindingsEnabled)
        session.press(.back)
        await Task.yield()
        XCTAssertEqual(posted, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("HidhoggAppIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func drainMainActorTasks() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

private final class FixtureBindingSession: BindingSession, @unchecked Sendable {
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var admissionEnabled = false
    private var nextGeneration: UInt64 = 10
    private var discoverCalls = 0
    private var enableCalls = 0
    private var disableCalls = 0
    private var stopCalls = 0
    private var pauseNextStopCall = false
    private var stopIsPendingValue = false
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var discoverCount: Int { locked { discoverCalls } }
    var enableCount: Int { locked { enableCalls } }
    var disableCount: Int { locked { disableCalls } }
    var stopCount: Int { locked { stopCalls } }
    var stopIsPending: Bool { locked { stopIsPendingValue } }

    func discover() async {
        locked { discoverCalls += 1 }
        emitReady()
    }

    func enable() async {
        let status = locked { () -> BoltStatus in
            enableCalls += 1
            nextGeneration &+= 1
            generation = nextGeneration
            admissionEnabled = true
            return BoltStatus(
                phase: .enabled,
                message: "Fixture enabled",
                availableControls: Set(MouseControl.allCases),
                generation: generation,
                cleanupUncertain: false
            )
        }
        continuation.yield(.status(status))
    }

    func disable() async {
        locked { disableCalls += 1 }
        finishSession()
    }

    func stop() async {
        let shouldPause = locked { () -> Bool in
            stopCalls += 1
            guard pauseNextStopCall else { return false }
            pauseNextStopCall = false
            return true
        }
        if shouldPause {
            await withCheckedContinuation { continuation in
                locked {
                    stopIsPendingValue = true
                    stopContinuation = continuation
                }
            }
            locked { stopIsPendingValue = false }
        }
        finishSession()
    }

    func withPressAdmission(
        generation requestedGeneration: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        locked {
            let age = observedAt.duration(to: .now)
            guard admissionEnabled, generation == requestedGeneration,
                  age >= .zero, age <= .milliseconds(250) else { return false }
            operation()
            return true
        }
    }

    func emitReady() {
        let status = locked { () -> BoltStatus in
            admissionEnabled = false
            nextGeneration &+= 1
            generation = nextGeneration
            return BoltStatus(
                phase: .ready,
                message: "Fixture ready",
                availableControls: Set(MouseControl.allCases),
                generation: generation,
                cleanupUncertain: false
            )
        }
        continuation.yield(.status(status))
    }

    func press(_ control: MouseControl) {
        let currentGeneration = locked { generation }
        continuation.yield(.press(control, generation: currentGeneration, observedAt: .now))
    }

    func pauseNextStop() {
        locked { pauseNextStopCall = true }
    }

    func resumeStop() {
        let continuation = locked { () -> CheckedContinuation<Void, Never>? in
            let current = stopContinuation
            stopContinuation = nil
            return current
        }
        continuation?.resume()
    }

    private func finishSession() {
        let status = locked { () -> BoltStatus in
            admissionEnabled = false
            nextGeneration &+= 1
            generation = nextGeneration
            return BoltStatus(
                phase: .idle,
                message: "Fixture stopped",
                availableControls: [],
                generation: generation,
                cleanupUncertain: false
            )
        }
        continuation.yield(.status(status))
    }

    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
