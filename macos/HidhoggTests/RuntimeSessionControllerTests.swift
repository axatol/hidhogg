import Darwin
import Foundation
import XCTest
import HidhoggCore
@testable import Hidhogg

@MainActor
final class RuntimeSessionControllerTests: XCTestCase {
    func testRestartExhaustedFailureHasStableDescription() {
        XCTAssertEqual(SupervisorFailure.restartExhausted.description, "runtime failed after one restart")
    }

    func testInvalidPathNeverCreatesRuntimeGeneration() async {
        let recorder = RuntimeGenerationRecorder()
        let controller = makeController(recorder: recorder)

        controller.start(configurationPath: "relative.toml")
        await controller.waitForTransition()

        XCTAssertEqual(recorder.paths, [])
        XCTAssertEqual(controller.lifecycleState, .configurationRequired)
        XCTAssertFalse(controller.canStartManually)
        await controller.quit()
    }

    func testReadinessWaitsForRuntimeStartupAndPublishesEndpointAfterWatcherStarts() async throws {
        let startGate = AsyncGate()
        let recorder = RuntimeGenerationRecorder(startGate: startGate)
        let watcher = TestConfigurationWatcher()
        let controller = makeController(
            recorder: recorder,
            watcherFactory: { _, _ in watcher }
        )

        controller.start(configurationPath: "/synthetic/config.toml")
        await waitUntil { recorder.count == 1 }
        let generation = try XCTUnwrap(recorder.generation(at: 0))
        await generation.waitForStart()

        XCTAssertEqual(controller.lifecycleState, .starting)
        XCTAssertNil(controller.endpoint)

        await startGate.open()
        await controller.waitForTransition()

        XCTAssertEqual(controller.lifecycleState, .ready)
        XCTAssertNotNil(controller.endpoint)
        XCTAssertEqual(watcher.startCount, 1)
        let reloadCount = await generation.reloadCount()
        XCTAssertEqual(reloadCount, 1)
        await controller.quit()
        XCTAssertEqual(watcher.stopCount, 1)
    }

    func testPathReplacementWaitsForConfirmedRetirement() async throws {
        let stopGate = AsyncGate()
        let recorder = RuntimeGenerationRecorder(stopGate: stopGate)
        let controller = makeController(recorder: recorder)

        controller.start(configurationPath: "/synthetic/first.toml")
        await controller.waitForTransition()
        let firstGeneration = try XCTUnwrap(recorder.generation(at: 0))

        controller.setConfigurationPath("/synthetic/second.toml")
        await firstGeneration.waitForStop()

        XCTAssertEqual(controller.lifecycleState, .stopping)
        XCTAssertNil(controller.endpoint)
        XCTAssertEqual(recorder.paths, ["/synthetic/first.toml"])

        await stopGate.open()
        await controller.waitForTransition()

        XCTAssertEqual(recorder.paths, ["/synthetic/first.toml", "/synthetic/second.toml"])
        XCTAssertEqual(controller.lifecycleState, .ready)
        await controller.quit()
    }

    func testUncertainRetirementKeepsGenerationAndPermanentlyRefusesReplacement() async {
        let recorder = RuntimeGenerationRecorder(stopOutcome: .cleanupUncertain)
        let controller = makeController(recorder: recorder)

        controller.start(configurationPath: "/synthetic/first.toml")
        await controller.waitForTransition()
        controller.setConfigurationPath("/synthetic/second.toml")
        await controller.waitForTransition()

        guard case .failed(.cleanup) = controller.lifecycleState else {
            XCTFail("uncertain retirement did not remain visible")
            return
        }
        XCTAssertNil(controller.endpoint)
        XCTAssertEqual(recorder.paths, ["/synthetic/first.toml"])
        XCTAssertFalse(controller.canStartManually)

        controller.setConfigurationPath("/synthetic/third.toml")
        await controller.waitForTransition()
        await controller.quit()

        XCTAssertEqual(recorder.paths, ["/synthetic/first.toml"])
        XCTAssertEqual(controller.lifecycleState, .failed(.cleanup("Core runtime or IPC cleanup is uncertain")))
    }

    func testConcurrentQuitWaitsForRetirementAndStopsOnlyOnce() async throws {
        let stopGate = AsyncGate()
        let recorder = RuntimeGenerationRecorder(stopGate: stopGate)
        let controller = makeController(recorder: recorder)

        controller.start(configurationPath: "/synthetic/config.toml")
        await controller.waitForTransition()
        let generation = try XCTUnwrap(recorder.generation(at: 0))
        let firstQuit = Task { await controller.quit() }
        let secondQuit = Task { await controller.quit() }

        await generation.waitForStop()
        XCTAssertEqual(controller.lifecycleState, .stopping)
        XCTAssertNotEqual(controller.lifecycleState, .stopped)

        await stopGate.open()
        await firstQuit.value
        await secondQuit.value

        XCTAssertEqual(controller.lifecycleState, .stopped)
        XCTAssertNil(controller.endpoint)
        let stopCount = await generation.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testParentAndFileWatchersReloadDirectAndAtomicConfigurationSaves() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationURL = root.appendingPathComponent("config.toml")
        try Data("initial".utf8).write(to: configurationURL)
        let recorder = RuntimeGenerationRecorder()
        let controller = makeController(
            recorder: recorder,
            watcherFactory: { path, onChange in
                ConfigurationFileWatcher(path: path, onChange: onChange)
            }
        )

        controller.start(configurationPath: configurationURL.path)
        await controller.waitForTransition()
        let generation = try XCTUnwrap(recorder.generation(at: 0))
        let initialReloadCount = await generation.reloadCount()

        let file = try FileHandle(forWritingTo: configurationURL)
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: Data("direct save".utf8))
        try file.close()
        await waitUntil { await generation.reloadCount() > initialReloadCount }
        let directReloadCount = await generation.reloadCount()

        let replacementURL = root.appendingPathComponent("config.toml.next")
        try Data("atomic save".utf8).write(to: replacementURL)
        let renameResult = replacementURL.path.withCString { source in
            configurationURL.path.withCString { destination in Darwin.rename(source, destination) }
        }
        XCTAssertEqual(renameResult, 0)
        await waitUntil { await generation.reloadCount() > directReloadCount }

        await controller.quit()
    }

    func testSimulationArgumentsRequireExplicitAbsoluteSyntheticPaths() {
        XCTAssertEqual(
            HidhoggSimulationArguments.parse(["Hidhogg"]),
            .production
        )
        XCTAssertEqual(
            HidhoggSimulationArguments.parse([
                "Hidhogg",
                "--hidhogg-simulated",
                "--hidhogg-config",
                "/Volumes/Data/tmp/synthetic/config.toml",
                "--hidhogg-runtime-root",
                "/Volumes/Data/tmp/synthetic/runtime"
            ]),
            .simulated(
                configurationPath: "/Volumes/Data/tmp/synthetic/config.toml",
                runtimeRoot: "/Volumes/Data/tmp/synthetic/runtime"
            )
        )
        guard case .invalid = HidhoggSimulationArguments.parse([
            "Hidhogg",
            "--hidhogg-simulated",
            "--hidhogg-config",
            "relative.toml",
            "--hidhogg-runtime-root",
            "/Volumes/Data/tmp/synthetic/runtime"
        ]) else {
            XCTFail("relative simulator paths were accepted")
            return
        }
    }

    private func makeController(
        recorder: RuntimeGenerationRecorder,
        selection: RuntimeBackendSelection = .native,
        watcherFactory: @escaping RuntimeConfigurationWatcherFactory = { _, _ in TestConfigurationWatcher() }
    ) -> RuntimeSessionController {
        RuntimeSessionController(
            backendSelection: selection,
            generationFactory: { path, backendSelection in
                recorder.make(path: path, selection: backendSelection)
            },
            configurationWatcherFactory: watcherFactory,
            snapshotPollNanoseconds: 1_000_000
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-watch-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: () async -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition did not become true before timeout")
    }
}

private final class RuntimeGenerationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var generations = [TestRuntimeSessionGeneration]()
    private var recordedPaths = [String]()
    private var simulatedSelections = [Bool]()
    private let startGate: AsyncGate?
    private let stopGate: AsyncGate?
    private let stopOutcome: RuntimeGenerationStopOutcome

    init(
        startGate: AsyncGate? = nil,
        stopGate: AsyncGate? = nil,
        stopOutcome: RuntimeGenerationStopOutcome = .closed
    ) {
        self.startGate = startGate
        self.stopGate = stopGate
        self.stopOutcome = stopOutcome
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return generations.count
    }

    var receivedSimulatedSelection: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return simulatedSelections
    }

    func generation(at index: Int) -> TestRuntimeSessionGeneration? {
        lock.lock()
        defer { lock.unlock() }
        guard generations.indices.contains(index) else { return nil }
        return generations[index]
    }

    func make(path: String, selection: RuntimeBackendSelection) -> any RuntimeSessionGeneration {
        lock.lock()
        defer { lock.unlock() }
        let generation = TestRuntimeSessionGeneration(
            endpoint: RuntimeSessionController.RuntimeEndpoint(
                instanceID: UUID().uuidString.lowercased(),
                socketPath: "/private/tmp/hidhogg-test-\(generations.count).sock"
            ),
            startGate: startGate,
            stopGate: stopGate,
            stopOutcome: stopOutcome
        )
        generations.append(generation)
        recordedPaths.append(path)
        if case .simulated = selection {
            simulatedSelections.append(true)
        } else {
            simulatedSelections.append(false)
        }
        return generation
    }
}

private actor AsyncGate {
    private var openState = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !openState else { return }
        openState = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor TestRuntimeSessionGeneration: RuntimeSessionGeneration {
    private let endpoint: RuntimeSessionController.RuntimeEndpoint
    private let startGate: AsyncGate?
    private let stopGate: AsyncGate?
    private let stopOutcome: RuntimeGenerationStopOutcome
    private let startCalled = AsyncGate()
    private let stopCalled = AsyncGate()
    private var running = false
    private var reloads = 0
    private var stops = 0

    init(
        endpoint: RuntimeSessionController.RuntimeEndpoint,
        startGate: AsyncGate?,
        stopGate: AsyncGate?,
        stopOutcome: RuntimeGenerationStopOutcome
    ) {
        self.endpoint = endpoint
        self.startGate = startGate
        self.stopGate = stopGate
        self.stopOutcome = stopOutcome
    }

    func start() async throws -> RuntimeSessionController.RuntimeEndpoint {
        await startCalled.open()
        await startGate?.wait()
        running = true
        return endpoint
    }

    func isRunning() async -> Bool { running }

    func reloadConfiguration() async { reloads += 1 }

    func stop() async -> RuntimeGenerationStopOutcome {
        stops += 1
        await stopCalled.open()
        await stopGate?.wait()
        running = false
        return stopOutcome
    }

    func waitForStart() async { await startCalled.wait() }
    func waitForStop() async { await stopCalled.wait() }
    func reloadCount() -> Int { reloads }
    func stopCount() -> Int { stops }
}

private final class TestConfigurationWatcher: RuntimeConfigurationWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    func start() throws {
        lock.lock()
        starts += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }
}
