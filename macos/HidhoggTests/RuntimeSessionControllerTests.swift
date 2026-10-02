import Darwin
import Foundation
import XCTest
@testable import Hidhogg

@MainActor
final class RuntimeSessionControllerTests: XCTestCase {
    func testValidAbsolutePathPersistsThroughInjectableStore() {
        let store = TestPreferencesStore()
        let path = "/private/tmp/hidhogg-config.toml"

        let preferences = AppPreferences(configurationPath: path)
        preferences.save(to: store)

        XCTAssertEqual(store.string(forKey: AppPreferences.configurationPathKey), path)
        XCTAssertEqual(AppPreferences(store: store).configurationPath, path)
    }

    func testInvalidStoredPathDoesNotCreateSupervisor() async {
        let store = TestPreferencesStore(configurationPath: "relative.toml")
        let preferences = AppPreferences(store: store)
        let recorder = RuntimeFactoryRecorder()
        let controller = makeController(recorder: recorder)

        XCTAssertEqual(preferences.persistedConfigurationPath, "relative.toml")
        XCTAssertNil(preferences.configurationPath)

        controller.start(configurationPath: preferences.configurationPath)
        await controller.waitForTransition()

        XCTAssertEqual(recorder.factoryPaths, [])
        XCTAssertEqual(controller.lifecycleState, .configurationRequired)
        XCTAssertFalse(controller.canStartManually)
        await controller.quit()
    }

    func testManualStartWaitsForRestartExhaustionAndRestartsSamePathToReady() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let retryClock = GatedRestartClock()
        let harness = ManualStartSupervisorFactory(root: root, retryClock: retryClock)
        let controller = makeController(harness: harness)
        let model = makeModel(controller: controller)
        let firstPath = "/private/tmp/profile-a.toml"

        XCTAssertFalse(model.canStartRuntime)
        controller.start(configurationPath: firstPath)
        await controller.waitForTransition()
        await retryClock.waitUntilWaiting()
        try await waitUntilLifecycle(controller) { state in
            if case .failed(.launch) = state { return true }
            return false
        }

        XCTAssertFalse(controller.canStartManually)
        XCTAssertFalse(model.canStartRuntime)
        model.startRuntime()
        await controller.waitForTransition()
        XCTAssertEqual(harness.factoryPaths, [firstPath])

        await retryClock.release()
        try await waitUntilLifecycle(controller) { $0 == .failed(.restartExhausted) }
        XCTAssertNil(controller.endpoint)
        XCTAssertTrue(model.canStartRuntime)
        let failureDetail = "D200X_HID_OPEN_PATH_FAILED: attempt failed"
        XCTAssertEqual(controller.lastFailureDetail, failureDetail)
        XCTAssertEqual(
            HidhoggAppModel.runtimeFailureHealthText(
                failure: .restartExhausted,
                lastFailureDetail: controller.lastFailureDetail
            ),
            "runtime failed after one restart\nLast failure: \(failureDetail)"
        )

        model.startRuntime()
        XCTAssertFalse(controller.canStartManually)
        model.startRuntime()
        await controller.waitForTransition()
        XCTAssertNil(controller.lastFailureDetail)
        try await waitUntilReady(controller)

        XCTAssertEqual(harness.factoryPaths, [firstPath, firstPath])
        XCTAssertEqual(controller.configurationPath, firstPath)
        XCTAssertNotNil(controller.endpoint)
        XCTAssertFalse(controller.canStartManually)
        XCTAssertFalse(model.canStartRuntime)

        await model.quit()
        XCTAssertFalse(model.canStartRuntime)
        XCTAssertEqual(controller.lifecycleState, .stopped)
        XCTAssertNil(controller.endpoint)
    }

    func testConfigurationPathChangedWhileManualStartIsQueuedUsesLatestPath() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let retryClock = GatedRestartClock()
        let harness = ManualStartSupervisorFactory(root: root, retryClock: retryClock)
        let controller = makeController(harness: harness)
        let firstPath = "/private/tmp/profile-a.toml"
        let selectedPath = "/private/tmp/profile-b.toml"

        controller.start(configurationPath: firstPath)
        await controller.waitForTransition()
        await retryClock.waitUntilWaiting()
        await retryClock.release()
        try await waitUntilLifecycle(controller) { $0 == .failed(.restartExhausted) }

        controller.requestManualStart()
        controller.setConfigurationPath(selectedPath)
        await controller.waitForTransition()
        try await waitUntilReady(controller)

        XCTAssertEqual(harness.factoryPaths, [firstPath, selectedPath])
        XCTAssertEqual(controller.configurationPath, selectedPath)
        XCTAssertNotNil(controller.endpoint)

        await controller.quit()
    }

    func testConfigurationChangeDoesNotStartReplacementWhenCleanupFails() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RuntimeFactoryRecorder()
        let factory: RuntimeSessionController.SupervisorFactory = { configuration in
            recorder.recordFactory(configuration.configurationPath)
            let process = RecordingManagedProcess {
                recorder.record("terminate:\(configuration.configurationPath)")
            }
            let launcher = ContaminatingRecordingLauncher(process: process) { request in
                recorder.record("launch:\(configuration.configurationPath)")
                let generation = URL(fileURLWithPath: request.arguments[1]).deletingLastPathComponent()
                try Data([0x01]).write(to: generation.appendingPathComponent("unexpected"))
            }
            return ProcessSupervisor(
                configuration: ProcessSupervisorConfiguration(
                    executablePath: configuration.executablePath,
                    configurationPath: configuration.configurationPath,
                    readinessTimeoutNanoseconds: 20_000_000,
                    readinessPollNanoseconds: 1_000_000,
                    terminateGraceNanoseconds: 1_000_000,
                    killGraceNanoseconds: 1_000_000
                ),
                directoryFactory: DefaultGenerationDirectoryFactory(root: root, rootPolicy: .injected),
                launcher: launcher,
                clock: SystemHidhoggClock(),
                requestIDProvider: FixedRequestIDProvider(),
                healthClientFactory: ReadyHealthFactory(),
                socketIdentityValidator: FixedSocketIdentityValidator()
            )
        }
        let controller = RuntimeSessionController(
            executablePath: "/private/tmp/hidhogg-runtime",
            supervisorFactory: factory,
            snapshotPollNanoseconds: 1_000_000
        )
        let oldPath = "/private/tmp/profile-a.toml"

        controller.start(configurationPath: oldPath)
        await controller.waitForTransition()
        try await waitUntilReady(controller)
        let oldEndpoint = try XCTUnwrap(controller.endpoint)

        controller.setConfigurationPath("/private/tmp/profile-b.toml")
        await controller.waitForTransition()

        guard case .failed(.cleanup(let message)) = controller.lifecycleState else {
            XCTFail("cleanup failure was replaced by a new runtime: \(controller.lifecycleState)")
            return
        }
        XCTAssertTrue(message.contains("notEmpty"))
        XCTAssertNotNil(oldEndpoint)
        XCTAssertNil(controller.endpoint)
        XCTAssertEqual(recorder.factoryPaths, [oldPath])
        XCTAssertTrue(recorder.events.contains("terminate:\(oldPath)"))

        controller.setConfigurationPath("/private/tmp/profile-c.toml")
        await controller.waitForTransition()

        guard case .failed(.cleanup(let subsequentMessage)) = controller.lifecycleState else {
            XCTFail("a later configuration change discarded the retirement failure: \(controller.lifecycleState)")
            return
        }
        XCTAssertEqual(subsequentMessage, message)
        XCTAssertNil(controller.endpoint)
        XCTAssertEqual(recorder.factoryPaths, [oldPath])

        await controller.quit()
    }

    func testQuitBeforeQueuedManualStartDoesNotCreateAnotherSupervisor() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let retryClock = GatedRestartClock()
        let harness = ManualStartSupervisorFactory(root: root, retryClock: retryClock)
        let controller = makeController(harness: harness)
        let path = "/private/tmp/profile-a.toml"

        controller.start(configurationPath: path)
        await controller.waitForTransition()
        await retryClock.waitUntilWaiting()
        await retryClock.release()
        try await waitUntilLifecycle(controller) { $0 == .failed(.restartExhausted) }

        controller.requestManualStart()
        XCTAssertFalse(controller.canStartManually)
        await controller.quit()

        XCTAssertEqual(harness.factoryPaths, [path])
        XCTAssertEqual(controller.lifecycleState, .stopped)
        XCTAssertNil(controller.endpoint)
        XCTAssertFalse(controller.canStartManually)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testBootstrapErrorHidesManualStartForRestartExhaustedController() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let retryClock = GatedRestartClock()
        let harness = ManualStartSupervisorFactory(root: root, retryClock: retryClock)
        let controller = makeController(harness: harness)
        let path = "/private/tmp/profile-a.toml"
        controller.start(configurationPath: path)
        await controller.waitForTransition()
        await retryClock.waitUntilWaiting()
        await retryClock.release()
        try await waitUntilLifecycle(controller) { $0 == .failed(.restartExhausted) }

        let homeBlocker = root.appendingPathComponent("home-is-a-file")
        try Data("blocking file".utf8).write(to: homeBlocker)
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: nil,
            homeDirectory: homeBlocker,
            templateData: Data()
        )
        let model = makeModel(controller: controller) { bootstrap }

        XCTAssertTrue(controller.canStartManually)
        model.start()

        XCTAssertTrue(model.healthText.contains("Configuration error"))
        XCTAssertTrue(controller.canStartManually)
        XCTAssertFalse(model.canStartRuntime)

        await model.quit()
    }

    func testRestartExhaustionHealthTextFallsBackWithoutStderrAndOnlyShowsDetailForExhaustion() {
        let detail = "D200X_HID_OPEN_PATH_FAILED: device unavailable"

        XCTAssertEqual(
            HidhoggAppModel.runtimeFailureHealthText(
                failure: .restartExhausted,
                lastFailureDetail: nil
            ),
            "runtime failed after one restart"
        )
        XCTAssertEqual(
            HidhoggAppModel.runtimeFailureHealthText(
                failure: .restartExhausted,
                lastFailureDetail: detail
            ),
            "runtime failed after one restart\nLast failure: \(detail)"
        )
        XCTAssertEqual(
            HidhoggAppModel.runtimeFailureHealthText(
                failure: .readinessTimedOut,
                lastFailureDetail: detail
            ),
            "runtime did not become ready"
        )
    }

    func testRapidPreStartPathChangesConvergeOnLatestPath() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RuntimeFactoryRecorder()
        let controller = makeController(recorder: recorder, root: root)

        controller.start(configurationPath: "/private/tmp/profile-a.toml")
        controller.setConfigurationPath("/private/tmp/profile-b.toml")
        await controller.waitForTransition()
        try await waitUntilReady(controller)

        XCTAssertEqual(recorder.factoryPaths, ["/private/tmp/profile-b.toml"])
        await controller.quit()
    }

    func testActivePathChangeStopsAndCleansPreviousGenerationBeforeStartingNewOne() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RuntimeFactoryRecorder()
        let controller = makeController(recorder: recorder, root: root)

        controller.start(configurationPath: "/private/tmp/profile-a.toml")
        await controller.waitForTransition()
        try await waitUntilReady(controller)

        controller.setConfigurationPath("/private/tmp/profile-b.toml")
        await controller.waitForTransition()
        try await waitUntilReady(controller)

        XCTAssertEqual(recorder.factoryPaths, [
            "/private/tmp/profile-a.toml",
            "/private/tmp/profile-b.toml"
        ])
        let events = recorder.events
        let stopIndex = try XCTUnwrap(events.firstIndex(of: "terminate:/private/tmp/profile-a.toml"))
        let replacementIndex = try XCTUnwrap(events.firstIndex(of: "factory:/private/tmp/profile-b.toml"))
        XCTAssertLessThan(stopIndex, replacementIndex)

        await controller.quit()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testReplacementWithdrawsReadyEndpointBeforeDelayedTerminationCompletes() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = DelayedSupervisorFactory(root: root)
        let controller = makeController(harness: harness)

        controller.start(configurationPath: "/private/tmp/profile-a.toml")
        await controller.waitForTransition()
        try await waitUntilReady(controller)
        let oldEndpoint = try XCTUnwrap(controller.endpoint)

        controller.setConfigurationPath("/private/tmp/profile-b.toml")
        var observedStopping = false
        for _ in 0..<200 {
            if controller.lifecycleState == .stopping,
               controller.endpoint == nil,
               harness.firstProcess.terminationRequested {
                observedStopping = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertTrue(observedStopping)
        XCTAssertEqual(controller.lifecycleState, .stopping)
        XCTAssertNil(controller.endpoint)
        XCTAssertNotNil(oldEndpoint)
        XCTAssertEqual(harness.recorder.factoryPaths, ["/private/tmp/profile-a.toml"])

        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(controller.lifecycleState, .stopping)
        XCTAssertNil(controller.endpoint)

        harness.firstProcess.allowTermination()
        await controller.waitForTransition()
        try await waitUntilReady(controller)
        XCTAssertNotNil(controller.endpoint)

        await controller.quit()
        XCTAssertEqual(controller.lifecycleState, .stopped)
        XCTAssertNil(controller.endpoint)
    }

    func testQuitWithdrawsReadyEndpointBeforeDelayedTerminationCompletes() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = DelayedSupervisorFactory(root: root)
        let controller = makeController(harness: harness)

        controller.start(configurationPath: "/private/tmp/profile-a.toml")
        await controller.waitForTransition()
        try await waitUntilReady(controller)

        let quitTask = Task { @MainActor in
            await controller.quit()
        }
        var observedStopping = false
        for _ in 0..<200 {
            if controller.lifecycleState == .stopping,
               controller.endpoint == nil,
               harness.firstProcess.terminationRequested {
                observedStopping = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertTrue(observedStopping)
        XCTAssertEqual(controller.lifecycleState, .stopping)
        XCTAssertNil(controller.endpoint)

        harness.firstProcess.allowTermination()
        await quitTask.value
        XCTAssertEqual(controller.lifecycleState, .stopped)
        XCTAssertNil(controller.endpoint)
    }

    func testQuitDuringPendingReplacementStopsActiveGenerationWithoutStartingReplacement() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RuntimeFactoryRecorder()
        let controller = makeController(recorder: recorder, root: root)

        controller.start(configurationPath: "/private/tmp/profile-a.toml")
        await controller.waitForTransition()
        try await waitUntilReady(controller)

        controller.setConfigurationPath("/private/tmp/profile-b.toml")
        await controller.quit()

        XCTAssertEqual(recorder.factoryPaths, ["/private/tmp/profile-a.toml"])
        XCTAssertEqual(controller.lifecycleState, .stopped)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func makeController(
        recorder: RuntimeFactoryRecorder,
        root: URL? = nil
    ) -> RuntimeSessionController {
        let root = root ?? URL(fileURLWithPath: "/private/tmp")
        let factory: RuntimeSessionController.SupervisorFactory = { configuration in
            recorder.recordFactory(configuration.configurationPath)
            let process = RecordingManagedProcess {
                recorder.record("terminate:\(configuration.configurationPath)")
            }
            let launcher = RecordingLauncher(process: process) {
                recorder.record("launch:\(configuration.configurationPath)")
            }
            return ProcessSupervisor(
                configuration: ProcessSupervisorConfiguration(
                    executablePath: configuration.executablePath,
                    configurationPath: configuration.configurationPath,
                    readinessTimeoutNanoseconds: 20_000_000,
                    readinessPollNanoseconds: 1_000_000,
                    terminateGraceNanoseconds: 1_000_000,
                    killGraceNanoseconds: 1_000_000
                ),
                directoryFactory: DefaultGenerationDirectoryFactory(root: root, rootPolicy: .injected),
                launcher: launcher,
                clock: SystemHidhoggClock(),
                requestIDProvider: FixedRequestIDProvider(),
                healthClientFactory: ReadyHealthFactory(),
                socketIdentityValidator: FixedSocketIdentityValidator()
            )
        }
        return RuntimeSessionController(
            executablePath: "/private/tmp/hidhogg-runtime",
            supervisorFactory: factory,
            snapshotPollNanoseconds: 1_000_000
        )
    }

    private func makeController(harness: DelayedSupervisorFactory) -> RuntimeSessionController {
        RuntimeSessionController(
            executablePath: "/private/tmp/hidhogg-runtime",
            supervisorFactory: { configuration in
                harness.makeSupervisor(configuration)
            },
            snapshotPollNanoseconds: 1_000_000
        )
    }

    private func makeController(harness: ManualStartSupervisorFactory) -> RuntimeSessionController {
        RuntimeSessionController(
            executablePath: "/private/tmp/hidhogg-runtime",
            supervisorFactory: { configuration in
                harness.makeSupervisor(configuration)
            },
            snapshotPollNanoseconds: 1_000_000
        )
    }

    private func makeModel(
        controller: RuntimeSessionController,
        configurationBootstrapFactory: @escaping @Sendable () -> DefaultConfigurationBootstrap = {
            DefaultConfigurationBootstrap(
                xdgConfigHome: nil,
                homeDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                templateData: Data()
            )
        }
    ) -> HidhoggAppModel {
        HidhoggAppModel(
            executablePath: "/private/tmp/hidhogg-runtime",
            preferencesStore: TestPreferencesStore(),
            runtimeSession: controller,
            profileMappingStore: EmptyProfileMappingStore(),
            displayPowerCoordinator: HostDisplayPowerCoordinator(
                observer: EmptyHostDisplayPowerObserver()
            ),
            foregroundObserver: EmptyForegroundApplicationObserver(),
            configurationBootstrapFactory: configurationBootstrapFactory
        )
    }

    private func waitUntilReady(_ controller: RuntimeSessionController) async throws {
        for _ in 0..<200 {
            if controller.lifecycleState == .ready { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("runtime did not become ready: \(controller.lifecycleState)")
    }

    private func waitUntilLifecycle(
        _ controller: RuntimeSessionController,
        matches predicate: (LifecycleState) -> Bool
    ) async throws {
        for _ in 0..<200 {
            if predicate(controller.lifecycleState) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("runtime did not reach the expected lifecycle state: \(controller.lifecycleState)")
    }

    private func makeTemporaryRoot() throws -> URL {
        for _ in 0..<32 {
            let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            let root = URL(fileURLWithPath: "/private/tmp/hh-controller-\(suffix)", isDirectory: true)
            let result = root.path.withCString { Darwin.mkdir($0, 0o700) }
            if result == 0 { return root }
            guard errno == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        throw NSError(domain: "HidhoggTests", code: 1)
    }
}

private final class TestPreferencesStore: @unchecked Sendable, AppPreferencesStore {
    private let lock = NSLock()
    private var values: [String: String]

    init(configurationPath: String? = nil) {
        values = configurationPath.map { [AppPreferences.configurationPathKey: $0] } ?? [:]
    }

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }
}

private final class RuntimeFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedFactoryPaths: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var factoryPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFactoryPaths
    }

    func recordFactory(_ path: String) {
        lock.lock()
        recordedFactoryPaths.append(path)
        recordedEvents.append("factory:\(path)")
        lock.unlock()
    }

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

@MainActor
private final class EmptyForegroundApplicationObserver: ForegroundApplicationObserving {
    func start(handler: @escaping ForegroundApplicationHandler) {}

    func stop() {}
}

@MainActor
private final class EmptyHostDisplayPowerObserver: HostDisplayPowerObserving {
    var lastKnownDisplayAwake: Bool? { nil }

    func start(
        stateHandler: @escaping HostDisplayPowerStateHandler,
        errorHandler: @escaping HostDisplayPowerErrorHandler
    ) {}

    func reconcileIfUnknown() {}

    func stop() {}
}

private final class EmptyProfileMappingStore: @unchecked Sendable, ProfileMappingPreferencesStore {
    func dictionary(forKey key: String) -> [String: String]? { nil }

    func set(_ value: [String: String]?, forKey key: String) {}
}

private actor GatedRestartClock: HidhoggClock {
    private var isReleased = false
    private var hasWaited = false
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(nanoseconds: UInt64) async throws {
        guard !isReleased else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            hasWaited = true
        }
    }

    func waitUntilWaiting() async {
        while !hasWaited {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ExpectedLaunchFailure: Error, CustomStringConvertible {
    var description: String { "expected launch failure" }
}

private final class FailingLauncher: @unchecked Sendable, ProcessLaunching {
    private let onLaunch: () -> Void
    private let stderrOutput: String?

    init(stderrOutput: String? = nil, onLaunch: @escaping () -> Void) {
        self.onLaunch = onLaunch
        self.stderrOutput = stderrOutput
    }

    func launch(
        request: LaunchRequest,
        standardOutputTail: OutputTail,
        standardErrorTail: OutputTail
    ) throws -> any ManagedProcess {
        onLaunch()
        if let stderrOutput {
            standardErrorTail.append(Data(stderrOutput.utf8))
        }
        throw ExpectedLaunchFailure()
    }
}

private final class ContaminatingRecordingLauncher: @unchecked Sendable, ProcessLaunching {
    private let process: any ManagedProcess
    private let onLaunch: (LaunchRequest) throws -> Void

    init(
        process: any ManagedProcess,
        onLaunch: @escaping (LaunchRequest) throws -> Void
    ) {
        self.process = process
        self.onLaunch = onLaunch
    }

    func launch(
        request: LaunchRequest,
        standardOutputTail: OutputTail,
        standardErrorTail: OutputTail
    ) throws -> any ManagedProcess {
        try onLaunch(request)
        return process
    }
}

private final class ManualStartSupervisorFactory: @unchecked Sendable {
    private let root: URL
    private let retryClock: GatedRestartClock
    private let recorder = RuntimeFactoryRecorder()
    private let lock = NSLock()
    private var nextSupervisorIndex = 0

    var factoryPaths: [String] { recorder.factoryPaths }

    init(root: URL, retryClock: GatedRestartClock) {
        self.root = root
        self.retryClock = retryClock
    }

    func makeSupervisor(_ configuration: ProcessSupervisorConfiguration) -> ProcessSupervisor {
        lock.lock()
        let index = nextSupervisorIndex
        nextSupervisorIndex += 1
        lock.unlock()

        recorder.recordFactory(configuration.configurationPath)
        let launcher: any ProcessLaunching
        let clock: any HidhoggClock
        if index == 0 {
            launcher = FailingLauncher(stderrOutput: "D200X_HID_OPEN_PATH_FAILED: attempt failed\n") {
                self.recorder.record("launch:\(configuration.configurationPath)")
            }
            clock = retryClock
        } else {
            let process = RecordingManagedProcess {
                self.recorder.record("terminate:\(configuration.configurationPath)")
            }
            launcher = RecordingLauncher(process: process) {
                self.recorder.record("launch:\(configuration.configurationPath)")
            }
            clock = SystemHidhoggClock()
        }

        return ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: configuration.executablePath,
                configurationPath: configuration.configurationPath,
                readinessTimeoutNanoseconds: 20_000_000,
                readinessPollNanoseconds: 1_000_000,
                restartDelayNanoseconds: 1_000_000_000,
                terminateGraceNanoseconds: 1_000_000,
                killGraceNanoseconds: 1_000_000
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root, rootPolicy: .injected),
            launcher: launcher,
            clock: clock,
            requestIDProvider: FixedRequestIDProvider(),
            healthClientFactory: ReadyHealthFactory(),
            socketIdentityValidator: FixedSocketIdentityValidator()
        )
    }
}

private final class RecordingManagedProcess: @unchecked Sendable, ManagedProcess {
    private let lock = NSLock()
    private let onTerminate: () -> Void
    private var runningStorage = true

    init(onTerminate: @escaping () -> Void) {
        self.onTerminate = onTerminate
    }

    var processIdentifier: Int32 { 42 }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return runningStorage
    }

    var exit: ProcessExit? {
        lock.lock()
        defer { lock.unlock() }
        return runningStorage ? nil : .exit(status: 0)
    }

    func terminate() {
        lock.lock()
        let wasRunning = runningStorage
        runningStorage = false
        lock.unlock()
        if wasRunning { onTerminate() }
    }

    func forceTerminate() {
        lock.lock()
        runningStorage = false
        lock.unlock()
    }
}

private final class RecordingLauncher: @unchecked Sendable, ProcessLaunching {
    private let process: any ManagedProcess
    private let onLaunch: () -> Void

    init(process: any ManagedProcess, onLaunch: @escaping () -> Void) {
        self.process = process
        self.onLaunch = onLaunch
    }

    func launch(
        request: LaunchRequest,
        standardOutputTail: OutputTail,
        standardErrorTail: OutputTail
    ) throws -> any ManagedProcess {
        onLaunch()
        return process
    }
}

private final class DelayedTerminationManagedProcess: @unchecked Sendable, ManagedProcess {
    private let lock = NSLock()
    private var runningStorage = true
    private var terminationRequestedStorage = false

    var processIdentifier: Int32 { 42 }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return runningStorage
    }

    var exit: ProcessExit? {
        lock.lock()
        defer { lock.unlock() }
        return runningStorage ? nil : .exit(status: 0)
    }

    var terminationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequestedStorage
    }

    func terminate() {
        lock.lock()
        terminationRequestedStorage = true
        lock.unlock()
    }

    func forceTerminate() {
        lock.lock()
        runningStorage = false
        lock.unlock()
    }

    func allowTermination() {
        lock.lock()
        runningStorage = false
        lock.unlock()
    }
}

private final class DelayedSupervisorFactory: @unchecked Sendable {
    let firstProcess = DelayedTerminationManagedProcess()
    let recorder = RuntimeFactoryRecorder()
    private let root: URL
    private let processes: [any ManagedProcess]
    private let lock = NSLock()
    private var nextProcess = 0

    init(root: URL) {
        self.root = root
        processes = [firstProcess, RecordingManagedProcess {}]
    }

    func makeSupervisor(_ configuration: ProcessSupervisorConfiguration) -> ProcessSupervisor {
        lock.lock()
        let process = processes[min(nextProcess, processes.count - 1)]
        nextProcess += 1
        lock.unlock()

        recorder.recordFactory(configuration.configurationPath)
        let launcher = RecordingLauncher(process: process) {
            self.recorder.record("launch:\(configuration.configurationPath)")
        }
        return ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: configuration.executablePath,
                configurationPath: configuration.configurationPath,
                readinessTimeoutNanoseconds: 20_000_000,
                readinessPollNanoseconds: 1_000_000,
                terminateGraceNanoseconds: 5_000_000_000,
                killGraceNanoseconds: 1_000_000
            ),
            directoryFactory: DefaultGenerationDirectoryFactory(root: root, rootPolicy: .injected),
            launcher: launcher,
            clock: SystemHidhoggClock(),
            requestIDProvider: FixedRequestIDProvider(),
            healthClientFactory: ReadyHealthFactory(),
            socketIdentityValidator: FixedSocketIdentityValidator()
        )
    }
}

private struct ReadyHealthFactory: RuntimeHealthClientCreating, Sendable {
    func make(socketPath: String, instanceID: String) throws -> any RuntimeHealthChecking {
        ReadyHealthClient(instanceID: instanceID)
    }
}

private struct ReadyHealthClient: RuntimeHealthChecking, Sendable {
    let instanceID: String

    func health(requestID: String) throws -> RuntimeResponse {
        RuntimeResponse(
            requestID: requestID,
            instanceID: instanceID,
            state: "ready",
            protocolVersion: nil,
            error: nil
        )
    }
}

private struct FixedRequestIDProvider: RequestIDProviding, Sendable {
    func makeRequestID() -> String { "11111111-1111-4111-8111-111111111111" }
}

private struct FixedSocketIdentityValidator: SocketIdentityValidating, Sendable {
    func validateSocket(_ socket: URL) throws -> FileIdentity {
        FileIdentity(device: 1, inode: 1)
    }
}
