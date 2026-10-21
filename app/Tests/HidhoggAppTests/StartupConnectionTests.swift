import AppKit
import Foundation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class StartupConnectionTests: XCTestCase {
    func testMissingConfigurationDefaultsToOneDiscoveryWithoutInputPermission() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session, eventPostingAllowed: false)

        let discovered = await eventually {
            !model.isLoading && model.boltStatus.phase == .ready && session.discoverCount == 1
        }

        XCTAssertTrue(discovered)
        XCTAssertEqual(model.document.saved.connectOnLaunch, true)
        XCTAssertEqual(model.permission, .denied)
        XCTAssertFalse(model.isBindingsEnabled)

        model.requestReload()
        let reloaded = await eventually { !model.isLoading }
        XCTAssertTrue(reloaded)
        await drainMainActorTasks()
        XCTAssertEqual(session.discoverCount, 1)
    }

    func testSavedEnabledPreferenceStartsOneDiscovery() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try await writeConfiguration(.empty, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)
        model.setConnectOnLaunch(true)

        let discovered = await eventually {
            !model.isLoading && model.boltStatus.phase == .ready && session.discoverCount == 1
        }

        XCTAssertTrue(discovered)
        await drainMainActorTasks()
        XCTAssertEqual(session.discoverCount, 1)
    }

    func testSavedDisabledPreferenceSkipsStartupDiscovery() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var configuration = AppConfiguration.empty
        configuration.connectOnLaunch = false
        try await writeConfiguration(configuration, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        let loaded = await eventually { !model.isLoading }

        XCTAssertTrue(loaded)
        await drainMainActorTasks()
        XCTAssertEqual(session.discoverCount, 0)
        XCTAssertEqual(model.document.saved.connectOnLaunch, false)

        _ = model.refreshPermission()
        model.setConnectOnLaunch(true)
        let enabledForNextLaunch = await eventually {
            model.document.draft.connectOnLaunch && model.isDirty
        }

        XCTAssertTrue(enabledForNextLaunch)
        XCTAssertEqual(session.discoverCount, 0)
    }

    func testStartupAttemptIsNotRetriedAfterMissingOrUnsupportedCandidate() async throws {
        for (phase, controls) in [
            (BoltPhase.failed, Set<MouseControl>()),
            (.ready, Set<MouseControl>())
        ] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("config.toml")
            try await writeConfiguration(.empty, to: url)
            let session = StartupBindingSession(discoveryPhase: phase, availableControls: controls)
            let model = makeModel(url: url, session: session)

            let attempted = await eventually { !model.isLoading && session.discoverCount == 1 }
            XCTAssertTrue(attempted)
            _ = model.refreshPermission()
            model.requestReload()
            let reloaded = await eventually { !model.isLoading }

            XCTAssertTrue(reloaded)
            await drainMainActorTasks()
            XCTAssertEqual(session.discoverCount, 1)
        }
    }

    func testEnablingPreferenceDuringInitialLoadDoesNotStartThisLaunchWhenSavedOff() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var configuration = AppConfiguration.empty
        configuration.connectOnLaunch = false
        try await writeConfiguration(configuration, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        model.setConnectOnLaunch(true)
        let edited = await eventually {
            !model.isLoading && model.document.draft.connectOnLaunch && model.isDirty
        }

        XCTAssertTrue(edited)
        XCTAssertEqual(session.discoverCount, 0)
    }

    func testMalformedConfigurationSkipsStartupDiscovery() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid toml = [".utf8).write(to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        let failed = await eventually { !model.isLoading && model.configurationLoadFailed }

        XCTAssertTrue(failed)
        XCTAssertEqual(session.discoverCount, 0)
    }

    func testDisconnectBeforeInitialLoadCompletesSuppressesStartupButLoadsConfiguration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var configuration = AppConfiguration.empty
        configuration.connectOnLaunch = true
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 12))
        try await writeConfiguration(configuration, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        model.disconnect()
        let loaded = await eventually { !model.isLoading }

        XCTAssertTrue(loaded)
        XCTAssertEqual(model.document.saved, configuration)
        XCTAssertEqual(session.discoverCount, 0)
    }

    func testManualConnectBeforeInitialLoadCompletesCancelsPendingStartup() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try await writeConfiguration(.empty, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        model.connect()
        let loaded = await eventually { !model.isLoading }

        XCTAssertTrue(loaded)
        await drainMainActorTasks()
        XCTAssertEqual(session.discoverCount, 0)
    }

    func testSleepPreparationBeforeInitialLoadCompletesCancelsPendingStartup() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try await writeConfiguration(.empty, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        model.prepareForLifecycleStop()
        await model.stopForSleep()
        let loaded = await eventually { !model.isLoading }

        XCTAssertTrue(loaded)
        XCTAssertEqual(session.discoverCount, 0)
    }

    func testRestartDefersConfigurationMutationAndNeverStartsAfterCancellation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 12))
        try await writeConfiguration(configuration, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        model.setRestarting(true)
        let loadDeferred = await eventually { !model.isLoading }

        XCTAssertTrue(loadDeferred)
        XCTAssertEqual(model.document.saved, .empty)
        model.setRestarting(false)
        let loaded = await eventually { !model.isLoading && model.document.saved == configuration }

        XCTAssertTrue(loaded)
        XCTAssertEqual(session.discoverCount, 0)
    }

    func testQuitBeforeInitialLoadCompletesDoesNotApplyLoadedConfiguration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 12))
        try await writeConfiguration(configuration, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)
        var terminationCount = 0
        let coordinator = TerminationCoordinator(
            prepareForQuit: { model.setRestarting(true) },
            cleanupForQuit: { await model.stopForTermination() },
            cancelQuit: { model.setRestarting(false) },
            terminate: { terminationCount += 1 }
        )

        XCTAssertEqual(coordinator.applicationShouldTerminate(), .terminateCancel)
        let completed = await eventually { !model.isLoading && terminationCount == 1 }

        XCTAssertTrue(completed)
        XCTAssertEqual(model.document.saved, .empty)
        XCTAssertEqual(session.discoverCount, 0)
        let persisted = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(persisted.configuration, configuration)
    }

    func testRestartBeforeInitialLoadCompletesDoesNotWriteDefaultConfiguration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 12))
        try await writeConfiguration(configuration, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)
        var terminationCount = 0
        let coordinator = RestartCoordinator(
            cleanup: { await model.stopForRestart() },
            launch: {},
            beginRestart: {
                model.setRestarting(true)
                return true
            },
            cancelRestart: { model.setRestarting(false) },
            terminate: { terminationCount += 1 },
            reportError: { _ in }
        )

        coordinator.requestRestart()
        let completed = await eventually { !model.isLoading && terminationCount == 1 }

        XCTAssertTrue(completed)
        XCTAssertEqual(model.document.saved, .empty)
        XCTAssertEqual(session.discoverCount, 0)
        let persisted = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(persisted.configuration, configuration)
    }

    func testRestartFlushesBeforeLaunchingSuccessorThatObeysSavedPreference() async throws {
        for connectOnLaunch in [true, false] {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("config.toml")
            let oldSession = StartupBindingSession()
            let oldModel = AppModel(
                configurationURL: url,
                store: ConfigurationStore(url: url),
                bolt: oldSession,
                sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
                loadImmediately: false,
                observeSleep: false
            )
            var edited = AppConfiguration.empty
            edited.connectOnLaunch = connectOnLaunch
            edited.devices[0].wheelInverted = true
            oldModel.updateDraft(edited)
            oldSession.pauseNextRestartCleanup()
            let successorSession = StartupBindingSession()
            var successor: AppModel?
            var launchCount = 0
            var terminationCount = 0
            var reportedError: String?
            let coordinator = RestartCoordinator(
                cleanup: { await oldModel.stopForRestart() },
                launch: {
                    launchCount += 1
                    successor = self.makeModel(url: url, session: successorSession)
                },
                beginRestart: {
                    oldModel.setRestarting(true)
                    return true
                },
                cancelRestart: { oldModel.setRestarting(false) },
                terminate: { terminationCount += 1 },
                reportError: { reportedError = $0 }
            )

            coordinator.requestRestart()
            let cleanupPending = await eventually { oldSession.restartCleanupIsPending }
            XCTAssertTrue(cleanupPending)
            XCTAssertTrue(oldModel.isRestarting)
            XCTAssertEqual(launchCount, 0)
            XCTAssertNil(successor)
            XCTAssertEqual(oldModel.document.saved, edited)
            let savedBeforeCleanup = try await ConfigurationStore(url: url).load()
            XCTAssertEqual(savedBeforeCleanup.configuration, edited)

            oldSession.completeRestartCleanup(returning: true)
            let successorLoaded = await eventually {
                guard let successor else { return false }
                return !successor.isLoading && terminationCount == 1
            }

            XCTAssertTrue(successorLoaded)
            XCTAssertNil(reportedError)
            XCTAssertEqual(launchCount, 1)
            XCTAssertEqual(successor?.document.saved, edited)
            XCTAssertEqual(successorSession.discoverCount, connectOnLaunch ? 1 : 0)
        }
    }

    func testDisablingPreferenceDuringInitialLoadSavesForNextLaunchOnly() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try await writeConfiguration(.empty, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        model.setConnectOnLaunch(false)
        let edited = await eventually { !model.isLoading && model.document.draft.connectOnLaunch == false && model.isDirty }

        XCTAssertTrue(edited)
        XCTAssertEqual(session.discoverCount, 0)
        let saved = await eventually { !model.isDirty && model.document.saved.connectOnLaunch == false }

        XCTAssertTrue(saved)
        XCTAssertEqual(session.discoverCount, 0)
        let persisted = try await ConfigurationStore(url: url).load()
        XCTAssertFalse(persisted.configuration.connectOnLaunch)
    }

    func testChangingPreferenceAfterStartupDoesNotDisconnectCurrentSession() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        try await writeConfiguration(.empty, to: url)
        let session = StartupBindingSession()
        let model = makeModel(url: url, session: session)

        let discovered = await eventually { !model.isLoading && session.discoverCount == 1 }
        XCTAssertTrue(discovered)
        model.setConnectOnLaunch(false)
        await drainMainActorTasks()

        XCTAssertEqual(session.discoverCount, 1)
        XCTAssertEqual(session.stopCount, 0)
    }

    private func makeModel(
        url: URL,
        session: StartupBindingSession,
        eventPostingAllowed: Bool = true
    ) -> AppModel {
        AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: ShortcutSender(
                preflight: { eventPostingAllowed },
                request: { eventPostingAllowed },
                postPair: { _ in }
            ),
            loadImmediately: true,
            observeSleep: false
        )
    }

    private func writeConfiguration(_ configuration: AppConfiguration, to url: URL) async throws {
        let store = ConfigurationStore(url: url)
        let revision = try await store.load().revision
        _ = try await store.save(configuration, expecting: revision)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggStartupConnectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<250 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func drainMainActorTasks() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

private final class StartupBindingSession: BindingSession, @unchecked Sendable {
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private let discoveryPhase: BoltPhase
    private let availableControls: Set<MouseControl>
    private var generation: UInt64 = 0
    private var discoverCalls = 0
    private var stopCalls = 0
    private var pauseRestartCleanup = false
    private var restartCleanupCalls = 0
    private var restartCleanupPendingValue = false
    private var restartCleanupContinuation: CheckedContinuation<Bool, Never>?

    init(
        discoveryPhase: BoltPhase = .ready,
        availableControls: Set<MouseControl> = Set(MouseControl.allCases)
    ) {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        self.discoveryPhase = discoveryPhase
        self.availableControls = availableControls
    }

    var discoverCount: Int { locked { discoverCalls } }
    var stopCount: Int { locked { stopCalls } }
    var restartCleanupIsPending: Bool { locked { restartCleanupPendingValue } }

    func discover() async {
        let status = locked { () -> BoltStatus in
            discoverCalls += 1
            generation &+= 1
            return BoltStatus(
                phase: discoveryPhase,
                message: "Synthetic candidate ready",
                availableControls: availableControls,
                generation: generation,
                cleanupUncertain: false
            )
        }
        continuation.yield(.status(status))
    }

    func enable() async {}
    func disable() async {}

    func stop() async {
        locked { stopCalls += 1 }
    }

    func stopForRestart() async -> Bool {
        let shouldPause = locked {
            restartCleanupCalls += 1
            return pauseRestartCleanup
        }
        guard shouldPause else { return true }
        return await withCheckedContinuation { continuation in
            locked {
                restartCleanupPendingValue = true
                restartCleanupContinuation = continuation
            }
        }
    }

    func pauseNextRestartCleanup() {
        locked { pauseRestartCleanup = true }
    }

    func completeRestartCleanup(returning result: Bool) {
        let continuation = locked { () -> CheckedContinuation<Bool, Never>? in
            pauseRestartCleanup = false
            restartCleanupPendingValue = false
            let current = restartCleanupContinuation
            restartCleanupContinuation = nil
            return current
        }
        continuation?.resume(returning: result)
    }

    func withPressAdmission(
        generation requestedGeneration: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }

    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
