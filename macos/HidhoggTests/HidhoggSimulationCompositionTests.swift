import AppKit
import Foundation
import XCTest
@testable import Hidhogg

@MainActor
final class HidhoggSimulationCompositionTests: XCTestCase {
    func testTestHostDelegateUsesInertSimulatedComposition() {
        let model = HidhoggApplicationDelegate().model

        XCTAssertTrue(model.runtimeSession.usesSimulatedBackend)
        XCTAssertFalse(model.allowsConfigurationSelection)
        XCTAssertNil(model.runtimeSession.endpoint)
        XCTAssertEqual(model.runtimeSession.lifecycleState, .configurationRequired)
        XCTAssertNil(model.runtimeSession.simulationDiagnostics)
    }

    func testSimulatorFactorySelectsExplicitBackendAndConfigurationBeforeStartup() {
        let configurationPath = "/Volumes/Data/tmp/hidhogg-simulation/config.toml"
        let runtimeRoot = "/Volumes/Data/tmp/hidhogg-simulation/runtime"
        let model = HidhoggAppModel.simulated(
            configurationPath: configurationPath,
            runtimeRoot: runtimeRoot
        )

        XCTAssertTrue(model.runtimeSession.usesSimulatedBackend)
        XCTAssertFalse(model.allowsConfigurationSelection)
        XCTAssertEqual(model.selectedConfigurationPath, configurationPath)
        XCTAssertNil(model.runtimeSession.endpoint)
        XCTAssertEqual(model.runtimeSession.lifecycleState, .configurationRequired)
        XCTAssertNil(model.runtimeSession.simulationDiagnostics)
    }

    func testProductionArgumentsAndUncontrolledSimulationDoNotEnableDiagnostics() {
        XCTAssertEqual(HidhoggSimulationArguments.parse(["Hidhogg"]), .production)

        let model = HidhoggAppModel.simulated(
            configurationPath: "/Volumes/Data/tmp/hidhogg-simulation/config.toml",
            runtimeRoot: "/Volumes/Data/tmp/hidhogg-simulation/runtime"
        )

        XCTAssertNil(model.runtimeSession.simulationDiagnostics)
    }

    func testSimulatedModelQuitReportsOrderedShutdownStagesWithoutStartingRuntime() async {
        let diagnostics = HidhoggSimulationDiagnosticRecorder()
        let model = HidhoggAppModel.simulated(
            configurationPath: "/Volumes/Data/tmp/hidhogg-simulation/config.toml",
            runtimeRoot: "/Volumes/Data/tmp/hidhogg-simulation/runtime",
            diagnostics: diagnostics.sink
        )

        await model.quit()

        XCTAssertEqual(
            diagnostics.events,
            [
                .modelQuitEntered,
                .modelQuitTaskStarted,
                .profileCoordinatorShutdownBegan,
                .profileCoordinatorShutdownCompleted,
                .displayPowerShutdownBegan,
                .displayPowerShutdownCompleted,
            ]
        )
        XCTAssertEqual(model.runtimeSession.lifecycleState, .stopped)
    }

    func testApplicationTerminationKeepsRunLoopAvailableUntilCleanupCompletes() async {
        let diagnostics = HidhoggSimulationDiagnosticRecorder()
        let model = HidhoggAppModel.simulated(
            configurationPath: "/Volumes/Data/tmp/hidhogg-simulation/config.toml",
            runtimeRoot: "/Volumes/Data/tmp/hidhogg-simulation/runtime",
            diagnostics: diagnostics.sink
        )
        let cleanupRequested = expectation(description: "cleanup requests termination again")
        var delegate: HidhoggApplicationDelegate!
        var repeatedTerminationReply: NSApplication.TerminateReply?
        var terminationRequestCount = 0
        delegate = HidhoggApplicationDelegate(
            model: model,
            simulationDiagnostics: diagnostics.sink,
            requestTermination: { application in
                terminationRequestCount += 1
                repeatedTerminationReply = delegate.applicationShouldTerminate(application)
                cleanupRequested.fulfill()
            }
        )

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)

        await fulfillment(of: [cleanupRequested], timeout: 2)

        XCTAssertEqual(repeatedTerminationReply, .terminateNow)
        XCTAssertEqual(terminationRequestCount, 1)
        XCTAssertEqual(
            diagnostics.events,
            [
                .applicationQuitBegan,
                .applicationQuitTaskStarted,
                .modelQuitEntered,
                .modelQuitTaskStarted,
                .profileCoordinatorShutdownBegan,
                .profileCoordinatorShutdownCompleted,
                .displayPowerShutdownBegan,
                .displayPowerShutdownCompleted,
                .applicationQuitCompleted,
            ]
        )
    }

    func testRestartStopsRuntimeBeforeLaunchingExactBundleAndTerminatesAfterSuccess() async {
        let stopGate = RestartTestStopGate()
        let runtimeSession = RuntimeSessionController(
            backendSelection: .native,
            generationFactory: { _, _ in
                RestartTestRuntimeGeneration(stopOutcome: .closed, stopGate: stopGate)
            },
            configurationWatcherFactory: { _, _ in RestartTestConfigurationWatcher() }
        )
        runtimeSession.start(configurationPath: "/synthetic/config.toml")
        await runtimeSession.waitForTransition()
        XCTAssertEqual(runtimeSession.lifecycleState, .ready)

        var model: HidhoggAppModel!
        var events = [String]()
        var launchedBundleURL: URL?
        var lifecycleAtLaunch: LifecycleState?
        var createsNewInstance = false
        var allowsSubstitution = true
        model = makeRestartModel(
            runtimeSession: runtimeSession,
            launchApplication: { bundleURL, configuration in
                events.append("launch")
                launchedBundleURL = bundleURL
                lifecycleAtLaunch = model.runtimeSession.lifecycleState
                createsNewInstance = configuration.createsNewApplicationInstance
                allowsSubstitution = configuration.allowsRunningApplicationSubstitution
                return true
            },
            terminateApplication: {
                events.append("terminate")
            }
        )

        let restartRequest = Task { await model.restartApplication() }
        await stopGate.waitUntilEntered()

        XCTAssertEqual(events, [])
        XCTAssertTrue(model.isRestartingApplication)
        XCTAssertFalse(model.canStartRuntime)
        await model.restartApplication()
        XCTAssertEqual(events, [])

        await stopGate.open()
        await restartRequest.value

        XCTAssertEqual(events, ["launch", "terminate"])
        XCTAssertEqual(launchedBundleURL, Bundle.main.bundleURL)
        XCTAssertEqual(lifecycleAtLaunch, .stopped)
        XCTAssertTrue(createsNewInstance)
        XCTAssertFalse(allowsSubstitution)
        XCTAssertTrue(model.isRestartingApplication)
        XCTAssertFalse(model.canStartRuntime)
        XCTAssertNil(model.applicationRestartErrorText)
    }

    func testRestartDoesNotLaunchWhenRuntimeCleanupIsUncertain() async {
        let runtimeSession = RuntimeSessionController(
            backendSelection: .native,
            generationFactory: { _, _ in
                RestartTestRuntimeGeneration(stopOutcome: .cleanupUncertain)
            },
            configurationWatcherFactory: { _, _ in RestartTestConfigurationWatcher() }
        )
        runtimeSession.start(configurationPath: "/synthetic/config.toml")
        await runtimeSession.waitForTransition()
        XCTAssertEqual(runtimeSession.lifecycleState, .ready)

        var launchCount = 0
        var terminateCount = 0
        let model = makeRestartModel(
            runtimeSession: runtimeSession,
            launchApplication: { _, _ in
                launchCount += 1
                return true
            },
            terminateApplication: {
                terminateCount += 1
            }
        )

        await model.restartApplication()

        guard case .failed = runtimeSession.lifecycleState else {
            XCTFail("uncertain runtime cleanup was not preserved")
            return
        }
        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(terminateCount, 0)
        XCTAssertFalse(model.isRestartingApplication)
        XCTAssertFalse(model.canStartRuntime)
        XCTAssertEqual(
            model.applicationRestartErrorText,
            "Hidhogg could not confirm that the runtime stopped. The current application was left open."
        )
    }

    func testRestartLaunchFailureLeavesCurrentApplicationOpen() async {
        var terminateCount = 0
        let model = makeRestartModel(
            launchApplication: { _, _ in false },
            terminateApplication: {
                terminateCount += 1
            }
        )

        await model.restartApplication()

        XCTAssertEqual(model.runtimeSession.lifecycleState, .stopped)
        XCTAssertEqual(terminateCount, 0)
        XCTAssertFalse(model.isRestartingApplication)
        XCTAssertEqual(
            model.applicationRestartErrorText,
            "Could not start a new Hidhogg instance. The current application was left open."
        )
    }

    func testRestartIgnoresDuplicateRequestsWhileLaunchIsPending() async {
        let launchStarted = expectation(description: "fresh application launch started")
        var resumeLaunch: CheckedContinuation<Bool, Never>?
        var launchCount = 0
        var terminateCount = 0
        let model = makeRestartModel(
            launchApplication: { _, _ in
                launchCount += 1
                launchStarted.fulfill()
                return await withCheckedContinuation { continuation in
                    resumeLaunch = continuation
                }
            },
            terminateApplication: {
                terminateCount += 1
            }
        )

        let firstRequest = Task { await model.restartApplication() }
        await fulfillment(of: [launchStarted], timeout: 2)
        await model.restartApplication()

        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(terminateCount, 0)
        XCTAssertTrue(model.isRestartingApplication)
        XCTAssertFalse(model.canStartRuntime)

        resumeLaunch?.resume(returning: true)
        await firstRequest.value

        XCTAssertEqual(terminateCount, 1)
    }

    func testSimulatedRestartIsDisabledAndDoesNotLaunch() async {
        let runtimeSession = RuntimeSessionController(backendSelection: .simulated)
        var launchCount = 0
        var terminateCount = 0
        let model = makeRestartModel(
            runtimeSession: runtimeSession,
            launchApplication: { _, _ in
                launchCount += 1
                return true
            },
            terminateApplication: {
                terminateCount += 1
            }
        )

        XCTAssertFalse(model.canRestartApplication)
        XCTAssertEqual(model.restartUnavailableMessage, "Restart is unavailable in simulated and test runs.")
        await model.restartApplication()

        XCTAssertEqual(launchCount, 0)
        XCTAssertEqual(terminateCount, 0)
        XCTAssertEqual(runtimeSession.lifecycleState, .configurationRequired)
    }

    private func makeRestartModel(
        runtimeSession: RuntimeSessionController = RuntimeSessionController(backendSelection: .native),
        launchApplication: @escaping HidhoggApplicationLaunching,
        terminateApplication: @escaping HidhoggApplicationTerminating
    ) -> HidhoggAppModel {
        HidhoggAppModel(
            preferencesStore: RestartTestAppPreferencesStore(),
            runtimeSession: runtimeSession,
            profileMappingStore: RestartTestProfileMappingPreferencesStore(),
            displayPowerCoordinator: HostDisplayPowerCoordinator(
                observer: RestartTestHostDisplayPowerObserver()
            ),
            foregroundObserver: RestartTestForegroundApplicationObserver(),
            allowsConfigurationSelection: false,
            launchApplication: launchApplication,
            terminateApplication: terminateApplication,
            configurationBootstrapFactory: {
                DefaultConfigurationBootstrap(
                    xdgConfigHome: nil,
                    homeDirectory: URL(fileURLWithPath: "/private/tmp", isDirectory: true),
                    templateData: Data()
                )
            }
        )
    }

    func testSimulationControlArgumentsRequireFreshDistinctNormalizedMarkerPair() throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("hidhogg-markers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let readyMarkerPath = directory.appendingPathComponent("ready").path
        let stopMarkerPath = directory.appendingPathComponent("stop").path
        let arguments = [
            "Hidhogg",
            "--hidhogg-simulated",
            "--hidhogg-config",
            directory.appendingPathComponent("c.toml").path,
            "--hidhogg-runtime-root",
            directory.appendingPathComponent("r").path,
            "--hidhogg-ready-marker",
            readyMarkerPath,
            "--hidhogg-stop-marker",
            stopMarkerPath,
        ]

        XCTAssertEqual(
            HidhoggSimulationArguments.parse(arguments),
            .simulatedControlled(
                configurationPath: directory.appendingPathComponent("c.toml").path,
                runtimeRoot: directory.appendingPathComponent("r").path,
                readyMarkerPath: readyMarkerPath,
                stopMarkerPath: stopMarkerPath
            )
        )

        let invalidArguments = [
            ["Hidhogg", "--hidhogg-ready-marker", readyMarkerPath],
            Array(arguments.dropLast(2)),
            arguments + ["--hidhogg-unknown", "value"],
            Array(arguments.dropLast(2)) + ["--hidhogg-stop-marker", readyMarkerPath],
            arguments + ["--hidhogg-ready-marker", readyMarkerPath],
        ]
        for invalid in invalidArguments {
            guard case .invalid = HidhoggSimulationArguments.parse(invalid) else {
                XCTFail("invalid simulator marker arguments were accepted: \(invalid)")
                continue
            }
        }

        let nonNormalizedArguments = arguments.enumerated().map { index, argument in
            index == arguments.count - 3 ? "\(directory.path)/sub/../other" : argument
        }
        guard case .invalid = HidhoggSimulationArguments.parse(nonNormalizedArguments) else {
            XCTFail("a non-normalized marker path was accepted")
            return
        }

        var caseAliasArguments = arguments
        caseAliasArguments[arguments.count - 1] = directory.appendingPathComponent("READY").path
        guard case .invalid = HidhoggSimulationArguments.parse(caseAliasArguments) else {
            XCTFail("case-insensitive marker aliases were accepted")
            return
        }

        let symbolicParent = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: symbolicParent.path,
            withDestinationPath: directory.path
        )
        var symbolicParentArguments = arguments
        symbolicParentArguments[arguments.count - 1] = symbolicParent.appendingPathComponent("ready").path
        guard case .invalid = HidhoggSimulationArguments.parse(symbolicParentArguments) else {
            XCTFail("ready and stop paths aliased through a symbolic-link parent were accepted")
            return
        }

        try Data().write(to: URL(fileURLWithPath: readyMarkerPath))
        guard case .invalid = HidhoggSimulationArguments.parse(arguments) else {
            XCTFail("an existing readiness marker path was accepted")
            return
        }
    }

    func testSimulationReadyMarkerIsPrivateAtomicAndContainsExactEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketPath = directory
            .appendingPathComponent("runtime/generation-1/runtime.sock")
            .path
        let endpoint = RuntimeSessionController.RuntimeEndpoint(
            instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            socketPath: socketPath
        )
        let markerPath = directory.appendingPathComponent("ready").path

        XCTAssertTrue(HidhoggSimulationLaunchControl.publishReadyMarker(at: markerPath, endpoint: endpoint))
        XCTAssertFalse(HidhoggSimulationLaunchControl.publishReadyMarker(at: markerPath, endpoint: endpoint))
        XCTAssertEqual(
            try String(contentsOfFile: markerPath, encoding: .utf8),
            """
            state=ready
            instance_id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
            generation_directory=\(directory.appendingPathComponent("runtime/generation-1").path)
            socket_path=\(socketPath)
            """
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: markerPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["ready"])
    }

    func testSimulationLaunchControlPublishesReadyThenTerminatesForStopMarker() async {
        let endpoint = RuntimeSessionController.RuntimeEndpoint(
            instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            socketPath: "/tmp/runtime/generation-2/runtime.sock"
        )
        var publishedEndpoint: RuntimeSessionController.RuntimeEndpoint?
        var stopRequested = false
        var terminationCount = 0
        let diagnostics = HidhoggSimulationDiagnosticRecorder()
        let control = HidhoggSimulationLaunchControl(
            readyMarkerPath: "/tmp/ready",
            stopMarkerPath: "/tmp/stop",
            diagnostics: diagnostics.sink,
            maximumPollCount: 5,
            pollIntervalNanoseconds: 1,
            readiness: { endpoint },
            publishReady: { readyEndpoint in
                publishedEndpoint = readyEndpoint
                return true
            },
            stopRequested: { stopRequested },
            pause: { _ in
                await Task.yield()
                if publishedEndpoint != nil {
                    stopRequested = true
                }
            },
            terminate: { terminationCount += 1 }
        )

        control.start()
        await control.waitForMonitoring()

        XCTAssertEqual(publishedEndpoint, endpoint)
        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(control.state, .completed)
        XCTAssertEqual(
            diagnostics.events,
            [.launchControlStarted, .readyMarkerPublished, .stopMarkerDetected]
        )
    }

    func testSimulationLaunchControlKeepsWatchingStopAfterReadinessDeadline() async {
        let endpoint = RuntimeSessionController.RuntimeEndpoint(
            instanceID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            socketPath: "/tmp/runtime/generation-3/runtime.sock"
        )
        var publishedEndpoint: RuntimeSessionController.RuntimeEndpoint?
        var stopRequested = false
        var pauseCount = 0
        var terminationCount = 0
        let diagnostics = HidhoggSimulationDiagnosticRecorder()
        let control = HidhoggSimulationLaunchControl(
            readyMarkerPath: "/tmp/ready",
            stopMarkerPath: "/tmp/stop",
            diagnostics: diagnostics.sink,
            maximumPollCount: 2,
            pollIntervalNanoseconds: 1,
            readiness: { endpoint },
            publishReady: { readyEndpoint in
                publishedEndpoint = readyEndpoint
                return true
            },
            stopRequested: { stopRequested },
            pause: { _ in
                pauseCount += 1
                await Task.yield()
                if pauseCount == 2, publishedEndpoint != nil {
                    stopRequested = true
                }
            },
            terminate: { terminationCount += 1 }
        )

        control.start()
        await control.waitForMonitoring()

        XCTAssertEqual(pauseCount, 2)
        XCTAssertEqual(publishedEndpoint, endpoint)
        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(control.state, .completed)
        XCTAssertEqual(
            diagnostics.events,
            [.launchControlStarted, .readyMarkerPublished, .stopMarkerDetected]
        )
    }

    func testSimulationLaunchControlTimesOutUnresolvedReadinessAndRejectsLateResult() async {
        let endpoint = RuntimeSessionController.RuntimeEndpoint(
            instanceID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            socketPath: "/tmp/runtime/generation-4/runtime.sock"
        )
        let timeoutReached = expectation(description: "readiness deadline is reached")
        let readinessReturned = expectation(description: "late readiness result returns")
        var resumeReadiness: ((RuntimeSessionController.RuntimeEndpoint?) -> Void)?
        var publicationCount = 0
        var didSignalTimeout = false
        let diagnostics = HidhoggSimulationDiagnosticRecorder()
        let control = HidhoggSimulationLaunchControl(
            readyMarkerPath: "/tmp/ready",
            stopMarkerPath: "/tmp/stop",
            diagnostics: diagnostics.sink,
            maximumPollCount: 2,
            pollIntervalNanoseconds: 1,
            readiness: {
                let result = await withCheckedContinuation {
                    (continuation: CheckedContinuation<RuntimeSessionController.RuntimeEndpoint?, Never>) in
                    resumeReadiness = { continuation.resume(returning: $0) }
                }
                readinessReturned.fulfill()
                return result
            },
            publishReady: { _ in
                publicationCount += 1
                return true
            },
            stopRequested: { false },
            pause: { _ in
                if !didSignalTimeout, diagnostics.events.contains(.readinessTimedOut) {
                    didSignalTimeout = true
                    timeoutReached.fulfill()
                }
                await Task.yield()
            }
        )

        control.start()
        await fulfillment(of: [timeoutReached], timeout: 2)

        XCTAssertEqual(control.state, .timedOut)
        XCTAssertEqual(diagnostics.events, [.launchControlStarted, .readinessTimedOut])
        resumeReadiness?(endpoint)
        await fulfillment(of: [readinessReturned], timeout: 2)
        await Task.yield()
        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(control.state, .timedOut)

        control.cancel()
        await control.waitForMonitoring()
        XCTAssertEqual(control.state, .cancelled)
    }

    func testSimulationLaunchControlStopsBeforePublishingReadyAndIgnoresDuplicateStarts() async {
        let endpoint = RuntimeSessionController.RuntimeEndpoint(
            instanceID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            socketPath: "/tmp/runtime/generation-5/runtime.sock"
        )
        var publicationCount = 0
        var terminationCount = 0
        let diagnostics = HidhoggSimulationDiagnosticRecorder()
        let control = HidhoggSimulationLaunchControl(
            readyMarkerPath: "/tmp/ready",
            stopMarkerPath: "/tmp/stop",
            diagnostics: diagnostics.sink,
            readiness: { endpoint },
            publishReady: { _ in
                publicationCount += 1
                return true
            },
            stopRequested: { true },
            terminate: { terminationCount += 1 }
        )

        control.start()
        control.start()
        await control.waitForMonitoring()
        control.start()

        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(control.state, .completed)
        XCTAssertEqual(diagnostics.events, [.launchControlStarted, .stopMarkerDetected])
    }

    func testSimulationLaunchControlLeavesReadinessFailureUnpublishedAndCanBeCancelled() async {
        var publicationCount = 0
        var terminationCount = 0
        let failureHandled = expectation(description: "readiness failure is recorded")
        var didSignalFailure = false
        let diagnostics = HidhoggSimulationDiagnosticRecorder()
        let failedControl = HidhoggSimulationLaunchControl(
            readyMarkerPath: "/tmp/ready",
            stopMarkerPath: "/tmp/stop",
            diagnostics: diagnostics.sink,
            maximumPollCount: 3,
            pollIntervalNanoseconds: 1,
            readiness: { nil },
            publishReady: { _ in
                publicationCount += 1
                return true
            },
            stopRequested: { false },
            pause: { _ in
                if !didSignalFailure, diagnostics.events.contains(.readinessFailed) {
                    didSignalFailure = true
                    failureHandled.fulfill()
                }
                await Task.yield()
            },
            terminate: { terminationCount += 1 }
        )
        failedControl.start()
        await fulfillment(of: [failureHandled], timeout: 2)
        XCTAssertEqual(failedControl.state, .readinessFailed)
        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(terminationCount, 0)
        XCTAssertEqual(diagnostics.events, [.launchControlStarted, .readinessFailed])
        failedControl.cancel()
        await failedControl.waitForMonitoring()
        XCTAssertEqual(failedControl.state, .cancelled)

        let cancelledControl = HidhoggSimulationLaunchControl(
            readyMarkerPath: "/tmp/ready",
            stopMarkerPath: "/tmp/stop",
            readiness: { nil },
            stopRequested: { false },
            terminate: { terminationCount += 1 }
        )
        cancelledControl.start()
        cancelledControl.cancel()
        await cancelledControl.waitForMonitoring()
        XCTAssertEqual(cancelledControl.state, .cancelled)
        XCTAssertEqual(terminationCount, 0)
    }

    func testSimulationStopMarkerMustBePrivateRegularFileOwnedByCurrentUser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let stopPath = directory.appendingPathComponent("stop").path
        XCTAssertFalse(HidhoggSimulationLaunchControl.hasValidStopMarker(at: stopPath))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: stopPath,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ))
        XCTAssertTrue(HidhoggSimulationLaunchControl.hasValidStopMarker(at: stopPath))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stopPath)
        XCTAssertFalse(HidhoggSimulationLaunchControl.hasValidStopMarker(at: stopPath))
        try FileManager.default.removeItem(atPath: stopPath)
        try FileManager.default.createSymbolicLink(atPath: stopPath, withDestinationPath: "missing-target")
        XCTAssertFalse(HidhoggSimulationLaunchControl.hasValidStopMarker(at: stopPath))
    }

    func testExplicitSimulationCompositionStartsReadyAndQuitsGracefully() async throws {
        let root = URL(fileURLWithPath: "/Volumes/Data/tmp", isDirectory: true)
            .appendingPathComponent("hidhogg-u01-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let configurationURL = root.appendingPathComponent("synthetic-config.toml")
        try FileManager.default.createDirectory(
            at: runtimeRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(Self.syntheticConfiguration.utf8).write(to: configurationURL)

        let arguments = [
            "Hidhogg",
            "--hidhogg-simulated",
            "--hidhogg-config",
            configurationURL.path,
            "--hidhogg-runtime-root",
            runtimeRoot.path,
        ]
        guard case .simulated(let selectedConfiguration, let selectedRuntimeRoot) =
                HidhoggSimulationArguments.parse(arguments) else {
            XCTFail("explicit synthetic launch arguments were not accepted")
            return
        }
        let model = HidhoggAppModel.simulated(
            configurationPath: selectedConfiguration,
            runtimeRoot: selectedRuntimeRoot
        )

        XCTAssertTrue(model.runtimeSession.usesSimulatedBackend)
        XCTAssertFalse(model.allowsConfigurationSelection)

        model.start()
        await model.runtimeSession.waitForTransition()

        XCTAssertEqual(model.runtimeSession.lifecycleState, .ready, model.runtimeSession.lastFailureDetail ?? "")
        let endpoint = try XCTUnwrap(model.runtimeSession.endpoint)
        let client = try UnixSocketClient(socketPath: endpoint.socketPath, instanceID: endpoint.instanceID)
        let health = try client.health(requestID: UUID().uuidString.lowercased())
        XCTAssertEqual(health.instanceID, endpoint.instanceID)
        XCTAssertEqual(health.state, "ready")

        await model.quit()

        XCTAssertEqual(model.runtimeSession.lifecycleState, .stopped)
        XCTAssertNil(model.runtimeSession.endpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.socketPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtimeRoot.path), [])
    }

    private static let syntheticConfiguration = """
    schema_version = 4
    adapter = "ulanzi.d200x"
    brightness = 80
    default_profile_id = "default"

    [profiles.default]
    label = "Synthetic"
    positions = { "0_0" = { label = "Ready" } }
    """
}

private actor RestartTestRuntimeGeneration: RuntimeSessionGeneration {
    private let stopOutcome: RuntimeGenerationStopOutcome
    private let stopGate: RestartTestStopGate?
    private var running = false

    init(stopOutcome: RuntimeGenerationStopOutcome, stopGate: RestartTestStopGate? = nil) {
        self.stopOutcome = stopOutcome
        self.stopGate = stopGate
    }

    func start() async throws -> RuntimeSessionController.RuntimeEndpoint {
        running = true
        return RuntimeSessionController.RuntimeEndpoint(
            instanceID: "restart-test",
            socketPath: "/private/tmp/restart-test.sock"
        )
    }

    func isRunning() async -> Bool { running }
    func reloadConfiguration() async {}

    func stop() async -> RuntimeGenerationStopOutcome {
        await stopGate?.suspendStop()
        running = false
        return stopOutcome
    }
}

private actor RestartTestStopGate {
    private var didEnter = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendStop() async {
        didEnter = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func open() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class RestartTestConfigurationWatcher: RuntimeConfigurationWatching {
    func start() throws {}
    func stop() {}
}

private struct RestartTestAppPreferencesStore: AppPreferencesStore {
    func string(forKey key: String) -> String? { nil }
    func set(_ value: String?, forKey key: String) {}
}

private struct RestartTestProfileMappingPreferencesStore: ProfileMappingPreferencesStore {
    func dictionary(forKey key: String) -> [String: String]? { nil }
    func set(_ value: [String: String]?, forKey key: String) {}
}

@MainActor
private final class RestartTestHostDisplayPowerObserver: HostDisplayPowerObserving {
    var lastKnownDisplayAwake: Bool? { nil }

    func start(
        stateHandler: @escaping HostDisplayPowerStateHandler,
        errorHandler: @escaping HostDisplayPowerErrorHandler
    ) {}

    func reconcileIfUnknown() {}
    func stop() {}
}

@MainActor
private final class RestartTestForegroundApplicationObserver: ForegroundApplicationObserving {
    func start(handler: @escaping ForegroundApplicationHandler) {}
    func stop() {}
}

private final class HidhoggSimulationDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents = [HidhoggSimulationDiagnosticEvent]()

    var sink: HidhoggSimulationDiagnostics {
        HidhoggSimulationDiagnostics { [weak self] event in
            self?.record(event)
        }
    }

    var events: [HidhoggSimulationDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    private func record(_ event: HidhoggSimulationDiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
    }
}
