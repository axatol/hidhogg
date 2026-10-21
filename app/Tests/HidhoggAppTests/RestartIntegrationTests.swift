import Foundation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class RestartIntegrationTests: XCTestCase {
    func testRestartFreezesModelAndWaitsForAuthoritativeCleanupResult() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let session = RestartFixtureBindingSession()
        let sender = ShortcutSender(
            accessibilityPreflight: { true },
            preflight: { true },
            request: { true },
            postPair: { _ in XCTFail("Restart integration must not post keyboard events.") }
        )
        let model = AppModel(
            configurationURL: url,
            store: store,
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertTrue(model.canDiscover)
        XCTAssertTrue(model.canSaveConfiguration)

        var edited = AppConfiguration.empty
        edited.devices[0].defaults[MouseControl.back.rawValue] = .key(
            KeyboardShortcut(keyCode: 0x7B, modifiers: [.command])
        )
        model.updateDraft(edited)
        XCTAssertTrue(model.isDirty)

        var launchCalls = 0
        var terminationCalls = 0
        var reportedError: String?
        let coordinator = RestartCoordinator(
            cleanup: {
                model.setRestarting(true)
                return await model.stopForRestart()
            },
            launch: { launchCalls += 1 },
            terminate: { terminationCalls += 1 },
            reportError: {
                model.setRestarting(false)
                model.reportError($0)
                reportedError = $0
            }
        )

        coordinator.requestRestart()

        let cleanupPending = await eventually {
            model.isRestarting &&
                session.restartCleanupIsPending &&
                model.boltStatus.phase == .idle
        }
        XCTAssertTrue(cleanupPending)
        XCTAssertTrue(coordinator.inProgress)
        XCTAssertFalse(model.canDiscover)
        XCTAssertFalse(model.canSaveConfiguration)
        XCTAssertEqual(model.document.saved, edited)
        XCTAssertFalse(model.isDirty)
        let savedSnapshot = try await store.load()
        XCTAssertEqual(savedSnapshot.configuration, edited)

        model.connect()
        model.updateDraft(.empty)
        await model.save()

        XCTAssertEqual(model.document.draft, edited)
        XCTAssertEqual(session.discoverCount, 0)
        XCTAssertEqual(session.restartCleanupCount, 1)
        XCTAssertEqual(launchCalls, 0)
        XCTAssertEqual(terminationCalls, 0)

        session.completeRestartCleanup(returning: false)

        let failed = await eventually { !coordinator.inProgress && !model.isRestarting }
        XCTAssertTrue(failed)
        XCTAssertEqual(reportedError, "Restart stopped. Review configuration and device errors before retrying.")
        XCTAssertEqual(model.errorMessage, reportedError)
        XCTAssertTrue(model.canDiscover)
        XCTAssertFalse(model.canSaveConfiguration)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.document.draft, edited)
        XCTAssertEqual(launchCalls, 0)
        XCTAssertEqual(terminationCalls, 0)
    }

    func testRestartDisablesShortcutDeliveryBeforeControllerCleanupStarts() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = RestartFixtureBindingSession()
        var posted = [KeyboardShortcut]()
        let sender = ShortcutSender(
            accessibilityPreflight: { true },
            preflight: { true },
            request: { true },
            postPair: { posted.append($0) }
        )
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        let shortcut = KeyboardShortcut(keyCode: 0x7B, modifiers: [.command])
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(shortcut)
        model.updateDraft(configuration)
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.refreshPermission(), .granted)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)

        let coordinator = RestartCoordinator(
            cleanup: {
                model.setRestarting(true)
                session.emitPress(.back)
                await Task.yield()
                return await model.stopForRestart()
            },
            launch: {},
            terminate: {},
            reportError: { _ in model.setRestarting(false) }
        )

        coordinator.requestRestart()

        let cleanupPending = await eventually {
            session.restartCleanupIsPending && model.boltStatus.phase == .idle
        }
        XCTAssertTrue(cleanupPending)
        XCTAssertTrue(model.isRestarting)
        XCTAssertEqual(posted, [])
        XCTAssertEqual(session.admissionCallCount, 0)

        session.completeRestartCleanup(returning: false)
        let failed = await eventually { !coordinator.inProgress && !model.isRestarting }
        XCTAssertTrue(failed)
    }

    func testPermissionRefreshDoesNotRequestEventPostingAccess() {
        var requestCalls = 0
        let sender = ShortcutSender(
            accessibilityPreflight: { false },
            preflight: { true },
            request: { requestCalls += 1; return true },
            postPair: { _ in XCTFail("Permission refresh must not post keyboard events.") }
        )
        let model = AppModel(
            configurationURL: FileManager.default.temporaryDirectory.appendingPathComponent("hidhogg-permission-refresh-test.toml"),
            store: ConfigurationStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("hidhogg-permission-refresh-test.toml")),
            bolt: RestartFixtureBindingSession(),
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )

        XCTAssertEqual(model.refreshPermission(), .granted)
        XCTAssertEqual(model.permissionChecks, PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: true))
        XCTAssertEqual(requestCalls, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggRestartIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

private final class RestartFixtureBindingSession: BindingSession, @unchecked Sendable {
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var discoverCalls = 0
    private var restartCleanupCalls = 0
    private var restartCleanupIsPendingValue = false
    private var restartCleanupContinuation: CheckedContinuation<Bool, Never>?
    private var generation: UInt64 = 0
    private var admissionEnabled = false
    private var admissionCalls = 0

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var discoverCount: Int { locked { discoverCalls } }
    var restartCleanupCount: Int { locked { restartCleanupCalls } }
    var restartCleanupIsPending: Bool { locked { restartCleanupIsPendingValue } }
    var admissionCallCount: Int { locked { admissionCalls } }

    func discover() async {
        locked { discoverCalls += 1 }
        emitReady()
    }

    func enable() async {
        let status = locked { () -> BoltStatus in
            generation &+= 1
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
        emitIdle()
    }

    func stop() async {
        emitIdle()
    }

    func stopForRestart() async -> Bool {
        locked { restartCleanupCalls += 1 }
        emitIdle()
        return await withCheckedContinuation { continuation in
            locked {
                restartCleanupIsPendingValue = true
                restartCleanupContinuation = continuation
            }
        }
    }

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        locked {
            guard admissionEnabled, self.generation == generation else { return false }
            admissionCalls += 1
            operation()
            return true
        }
    }

    func emitPress(_ control: MouseControl) {
        let currentGeneration = locked { generation }
        continuation.yield(.press(control, generation: currentGeneration, observedAt: .now))
    }

    func emitReady() {
        let status = locked { () -> BoltStatus in
            generation &+= 1
            admissionEnabled = false
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

    private func emitIdle() {
        let status = locked { () -> BoltStatus in
            generation &+= 1
            admissionEnabled = false
            return BoltStatus(
                phase: .idle,
                message: "Fixture reports idle before restart cleanup resolves",
                availableControls: [],
                generation: generation,
                cleanupUncertain: false
            )
        }
        continuation.yield(.status(status))
    }

    func completeRestartCleanup(returning result: Bool) {
        let continuation = locked { () -> CheckedContinuation<Bool, Never>? in
            restartCleanupIsPendingValue = false
            let pending = restartCleanupContinuation
            restartCleanupContinuation = nil
            return pending
        }
        continuation?.resume(returning: result)
    }

    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
