import Foundation
import XCTest
@testable import HidhoggCore

final class IPCServiceBindingTests: XCTestCase {
    func testCommandLineParserProducesOnlyTypedCommands() throws {
        let status = try IPCCommandLineParser.parse(["--runtime-dir", "/tmp/runtime", "status"])
        XCTAssertEqual(status.runtimeDirectory, "/tmp/runtime")
        guard case .status = status.command else { return XCTFail("expected typed status command") }

        let emit = try IPCCommandLineParser.parse([
            "--runtime-dir", "/tmp/runtime", "notifications", "emit",
            "--source", "alerts.v2", "--text", "Ready", "--ttl-seconds", "30",
        ])
        guard case let .emitNotification(source, text, ttl) = emit.command else {
            return XCTFail("expected typed notification command")
        }
        XCTAssertEqual(source, "alerts.v2")
        XCTAssertEqual(text, "Ready")
        XCTAssertEqual(ttl, 30)

        XCTAssertThrowsError(try IPCCommandLineParser.parse([
            "--runtime-dir", "/tmp/runtime", "notifications", "emit",
            "--source", "alerts", "--source", "other", "--text", "Ready",
        ]))
        XCTAssertThrowsError(try IPCCommandLineParser.parse(["--runtime-dir", "/tmp/runtime", "status", "extra"]))
    }

    func testServiceBindsStatusProfilesAndSixFieldPositionReadToRuntimeAndSource() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let configURL = temporary.appendingPathComponent("config.toml")
        let source = Self.configurationSource
        try Data(source.utf8).write(to: configURL)
        let configuration = try HidhoggConfigurationDecoder.decode(Data(source.utf8))
        let coordinator = try RuntimeCoordinator(configuration: configuration, selection: .simulated)
        try await coordinator.start()
        defer { Task { _ = await coordinator.stop() } }
        let binding = try IPCServiceBinding(coordinator: coordinator, configurationPath: configURL.path)

        let statusRequest = try Self.request(.status)
        let status = await binding.handle(statusRequest)
        XCTAssertTrue(IPCProtocol.validate(status, for: statusRequest))
        XCTAssertEqual(status.result?.value(for: "state")?.stringValue, "ready")

        let profileRequest = try Self.request(.profilesList)
        let profiles = await binding.handle(profileRequest)
        XCTAssertTrue(IPCProtocol.validate(profiles, for: profileRequest))
        XCTAssertEqual(profiles.result?.value(for: "profiles")?.arrayValues?.count, 1)

        let digest = ConfigurationStore.digest(Data(source.utf8)).description
        let positionRequest = try Self.request(.editorPosition(sourceDigest: digest, profileID: "default", positionID: "0_0"))
        let position = await binding.handle(positionRequest)
        XCTAssertTrue(IPCProtocol.validate(position, for: positionRequest))
        XCTAssertEqual(position.result?.value(for: "label")?.stringValue, "Default button")
        XCTAssertEqual(position.result?.value(for: "background")?.stringValue, "#000000")
        XCTAssertEqual(position.result?.value(for: "label_alignment")?.stringValue, "bottom")
        XCTAssertEqual(position.result?.value(for: "label_size")?.integerValue, 10)
        XCTAssertEqual(position.result?.value(for: "notification_sources")?.arrayValues?.count, 0)
        XCTAssertEqual(IPCProtocol.decodeAction(position.result?.value(for: "action") ?? .null), .keyPress(key: "enter", gesture: .release))

        let patch = ConfigurationPositionPatch(
            label: .set("Updated"),
            background: .set("#102030"),
            labelAlignment: .set("center"),
            labelSize: .set(14),
            notificationSources: .set(["alerts"]),
            action: .set(.typeText(text: "Ready", gesture: .press))
        )
        let editRequest = try Self.request(.editorPatchPosition(
            expectedDigest: digest,
            profileID: "default",
            positionID: "0_0",
            patch: patch
        ))
        let edit = await binding.handle(editRequest)
        XCTAssertTrue(IPCProtocol.validate(edit, for: editRequest))
        XCTAssertEqual(edit.result?.value(for: "file_commit")?.stringValue, "committed")
        XCTAssertEqual(edit.result?.value(for: "reload_outcome")?.stringValue, "changed")

        let updatedBytes = try Data(contentsOf: configURL)
        let updated = try HidhoggConfigurationDecoder.decode(updatedBytes)
        let positionModel = try XCTUnwrap(updated.profile(id: "default")?.position(named: "0_0"))
        XCTAssertEqual(positionModel.label, "Updated")
        XCTAssertEqual(positionModel.background, "#102030")
        XCTAssertEqual(positionModel.labelAlignment, "center")
        XCTAssertEqual(positionModel.labelSize, 14)
        XCTAssertEqual(positionModel.notificationSources, ["alerts"])
        XCTAssertEqual(positionModel.action, .typeText(text: "Ready", gesture: .press))

        let staleRequest = try Self.request(.editorPosition(sourceDigest: digest, profileID: "default", positionID: "0_0"))
        let stale = await binding.handle(staleRequest)
        XCTAssertEqual(stale.failure?.code, "stale_source")
    }

    func testConfigurationReloadDoesNotFollowSymlinkAndRetainsSafeStatus() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let target = temporary.appendingPathComponent("source.toml")
        let link = temporary.appendingPathComponent("config.toml")
        try Data(Self.configurationSource.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let coordinator = try RuntimeCoordinator(
            configuration: HidhoggConfigurationDecoder.decode(Data(Self.configurationSource.utf8)),
            selection: .simulated
        )
        try await coordinator.start()
        defer { Task { _ = await coordinator.stop() } }
        let binding = try IPCServiceBinding(coordinator: coordinator, configurationPath: link.path)

        let reloadRequest = try Self.request(.configReload)
        let reload = await binding.handle(reloadRequest)
        XCTAssertEqual(reload.failure?.code, "reload_rejected")

        let statusRequest = try Self.request(.configStatus)
        let status = await binding.handle(statusRequest)
        XCTAssertTrue(IPCProtocol.validate(status, for: statusRequest))
        XCTAssertEqual(status.result?.value(for: "outcome")?.stringValue, "rejected")
        XCTAssertEqual(status.result?.value(for: "diagnostic")?.value(for: "category")?.stringValue, "read-invalid")
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.profileID, "default")
    }

    func testConfigurationStatusRemainsReloadingAcrossQueuedEditorMutation() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let configURL = temporary.appendingPathComponent("config.toml")
        let initial = Data(Self.configurationSource.utf8)
        try initial.write(to: configURL)

        let session = IPCBindingPausedSession()
        let coordinator = try RuntimeCoordinator(
            configuration: HidhoggConfigurationDecoder.decode(initial),
            session: session,
            clock: SystemRuntimeMonotonicClock()
        )
        try await coordinator.start()
        defer { Task { _ = await coordinator.stop() } }
        let binding = try IPCServiceBinding(coordinator: coordinator, configurationPath: configURL.path)

        let firstSource = Self.configurationSource.replacingOccurrences(of: "label = \"Default button\"", with: "label = \"First\"")
        try Data(firstSource.utf8).write(to: configURL)
        let firstGate = IPCBindingPauseGate()
        let secondGate = IPCBindingPauseGate()
        await session.pauseNextPerform(using: firstGate)
        let reloadRequest = try Self.request(.configReload)
        let reloadTask = Task { await binding.handle(reloadRequest) }
        await firstGate.waitUntilEntered()

        await session.pauseNextPerform(using: secondGate)
        let digest = ConfigurationStore.digest(Data(firstSource.utf8)).description
        let editRequest = try Self.request(.editorPatchPosition(
            expectedDigest: digest,
            profileID: "default",
            positionID: "0_0",
            patch: ConfigurationPositionPatch(label: .set("Second"))
        ))
        let editTask = Task { await binding.handle(editRequest) }
        var bothOperationsPending = false
        for _ in 0..<1_000 {
            if await binding.pendingConfigurationOperations == 2 {
                bothOperationsPending = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(bothOperationsPending)

        await firstGate.resume()
        let reload = await reloadTask.value
        XCTAssertTrue(IPCProtocol.validate(reload, for: reloadRequest))
        await secondGate.waitUntilEntered()
        let pendingAfterReload = await binding.pendingConfigurationOperations
        XCTAssertEqual(pendingAfterReload, 1)

        let statusRequest = try Self.request(.configStatus)
        let status = await binding.handle(statusRequest)
        XCTAssertTrue(IPCProtocol.validate(status, for: statusRequest))
        XCTAssertEqual(status.result?.value(for: "state")?.stringValue, "reloading")

        await secondGate.resume()
        let edit = await editTask.value
        XCTAssertTrue(IPCProtocol.validate(edit, for: editRequest))
        XCTAssertEqual(edit.result?.value(for: "reload_outcome")?.stringValue, "changed")
        _ = await coordinator.stop()
    }

    func testExecutionHistoryTimestampsUseTheRuntimeWallMonotonicAnchor() async throws {
        let clock = IPCBindingFixedClock()
        let wallAnchor = Date(timeIntervalSince1970: 1_700_000_000.125)
        let services = RuntimeActionServices(
            runner: RuntimeFakeProcessRunner(termination: .exited(0)),
            nativeInputBackend: RuntimeFakeNativeInputBackend(),
            clock: clock,
            wallDateAnchor: wallAnchor
        )
        let coordinator = try RuntimeCoordinator(
            configuration: HidhoggConfigurationDecoder.decode(Data(Self.configurationSource.utf8)),
            session: IPCBindingPausedSession(),
            clock: clock,
            actionServices: services
        )
        try await coordinator.start()
        defer { Task { _ = await coordinator.stop() } }
        let binding = try IPCServiceBinding(coordinator: coordinator, configurationPath: "/tmp/synthetic-config.toml")

        services.admit(RuntimeServiceTestValues.executeRequest())
        let recorded = await RuntimeServiceTestValues.eventually {
            (try? services.execution.listSummaries(limit: 1).first?.state) == .exited
        }
        XCTAssertTrue(recorded)

        let request = try Self.request(.executionsList(limit: 10))
        let response = await binding.handle(request)
        XCTAssertTrue(IPCProtocol.validate(response, for: request))
        let execution = try XCTUnwrap(response.result?.value(for: "executions")?.arrayValues?.first)
        XCTAssertEqual(execution.value(for: "submitted_at")?.stringValue, "2023-11-14T22:13:20.125Z")
        XCTAssertEqual(execution.value(for: "started_at")?.stringValue, "2023-11-14T22:13:20.125Z")
        XCTAssertEqual(execution.value(for: "finished_at")?.stringValue, "2023-11-14T22:13:20.125Z")
        _ = await coordinator.stop()
    }

    private static func request(_ command: IPCCommand) throws -> IPCWireRequest {
        let frame = try IPCProtocol.encodeRequest(
            requestID: "11111111-1111-4111-8111-111111111111",
            command: command,
            instanceID: "22222222-2222-4222-8222-222222222222"
        )
        guard case let .success(request) = IPCProtocol.decodeRequest(frame) else {
            throw IPCFrameError.invalidFrame
        }
        return request
    }

    private static let configurationSource = """
    schema_version = 4
    adapter = "ulanzi.d200x"
    brightness = 80
    default_profile_id = "default"

    [profiles.default]
    label = "Default"

    [profiles.default.positions."0_0"]
    label = "Default button"
    action = { type = "key_press", key = "enter" }
    """
}

private actor IPCBindingPauseGate {
    private var entered = false
    private var resumed = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var enteredWaiters = [CheckedContinuation<Void, Never>]()

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !resumed else { return }
        await withCheckedContinuation { continuation in blocked = continuation }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func resume() {
        resumed = true
        blocked?.resume()
        blocked = nil
    }
}

private actor IPCBindingPausedSession: D200XDeviceSession {
    private let candidate = D200XDeviceCandidate(
        registryID: 9,
        vendorID: 0x2207,
        productID: 0x0019,
        interfaceNumber: 0,
        usagePage: 0x000c,
        usage: 0x0001,
        maximumOutputReportSize: D200XFrameCodec.packetSize
    )
    private var nextGate: IPCBindingPauseGate?

    func candidates() async throws -> [D200XDeviceCandidate] { [candidate] }

    func open(
        _ candidate: D200XDeviceCandidate,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void,
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void
    ) async throws {}

    func perform(_ batch: D200XOutboundBatch) async throws {
        let gate = nextGate
        nextGate = nil
        await gate?.pause()
    }

    nonisolated func stop() {}

    func waitUntilStopped() async -> D200XSessionStopOutcome { .closed }

    func pauseNextPerform(using gate: IPCBindingPauseGate) {
        nextGate = gate
    }
}

private struct IPCBindingFixedClock: RuntimeMonotonicClock {
    let instant = RuntimeMonotonicInstant(durationFromOrigin: .seconds(7))

    func now() -> RuntimeMonotonicInstant { instant }

    func sleep(until deadline: RuntimeMonotonicInstant) async throws {
        guard deadline > instant else { return }
        try await Task.sleep(for: .seconds(300))
    }
}
