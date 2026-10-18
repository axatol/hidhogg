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

    func testSimulationLaunchControlLeavesReadinessFailureUnpublishedAndCanBeCancelled() async {
        var publicationCount = 0
        var terminationCount = 0
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
            pause: { _ in await Task.yield() },
            terminate: { terminationCount += 1 }
        )
        failedControl.start()
        await failedControl.waitForMonitoring()
        XCTAssertEqual(failedControl.state, .readinessFailed)
        XCTAssertEqual(publicationCount, 0)
        XCTAssertEqual(terminationCount, 0)
        XCTAssertEqual(diagnostics.events, [.launchControlStarted, .readinessFailed])

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
