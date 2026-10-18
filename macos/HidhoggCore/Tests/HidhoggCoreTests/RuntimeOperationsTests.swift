import Foundation
import XCTest
@testable import HidhoggCore

final class RuntimeOperationsTests: XCTestCase {
    func testCloneWithOmittedSourceChecksStaleDigestBeforeDecodingChangedSource() async throws {
        let fixture = try RuntimeOperationsFixture()
        defer { fixture.remove() }
        try await fixture.coordinator.start()
        let snapshot = try await fixture.operations.editorSnapshot()
        let changedBytes = Data("schema_version = 0".utf8)
        try changedBytes.write(to: fixture.configurationURL)
        let binding = IPCServiceBinding(operations: fixture.operations)
        let request = try Self.request(.editorCreateProfile(expectedDigest: snapshot.sourceDigest, profileID: "copy", label: "Copy", sourceProfileID: nil))
        let response = await binding.handle(request)
        XCTAssertEqual(response.failure?.code, "stale_source")
        XCTAssertEqual(try Data(contentsOf: fixture.configurationURL), changedBytes)
        await fixture.operations.retire()
        _ = await fixture.coordinator.stop()
    }

    func testDiskEditorViewStaysDistinctFromLiveCatalogUntilSharedReload() async throws {
        let fixture = try RuntimeOperationsFixture()
        defer { fixture.remove() }
        try await fixture.coordinator.start()
        let operations = fixture.operations
        let source = try String(contentsOf: fixture.configurationURL, encoding: .utf8)
        try Data(source.replacingOccurrences(of: "label = \"Default\"", with: "label = \"Disk\"").utf8).write(to: fixture.configurationURL)
        let liveBefore = try await operations.profiles()
        XCTAssertEqual(liveBefore.first?.label, "Default")
        let snapshot = try await operations.editorSnapshot()
        let diskProfile = try await operations.editorProfile(sourceDigest: snapshot.sourceDigest, profileID: "default")
        XCTAssertEqual(diskProfile.label, "Disk")
        let reload = try await operations.reloadConfiguration()
        XCTAssertTrue(reload.changed)
        XCTAssertTrue(reload.effects.catalogChanged)
        let binding = IPCServiceBinding(operations: operations)
        let profiles = await binding.handle(try Self.request(.profilesList))
        XCTAssertEqual(profiles.result?.value(for: "profiles")?.arrayValues?.first?.value(for: "label")?.stringValue, "Disk")
        let status = await binding.handle(try Self.request(.configStatus))
        XCTAssertEqual(status.result?.value(for: "outcome")?.stringValue, "changed")

        try Data("schema_version = 0".utf8).write(to: fixture.configurationURL)
        do {
            _ = try await operations.reloadConfiguration()
            XCTFail("expected safe candidate rejection")
        } catch { XCTAssertEqual(error as? RuntimeOperationError, .reloadRejected) }
        let rejectedStatus = await binding.handle(try Self.request(.configStatus))
        XCTAssertEqual(rejectedStatus.result?.value(for: "outcome")?.stringValue, "rejected")
        XCTAssertEqual(rejectedStatus.result?.value(for: "diagnostic")?.value(for: "category")?.stringValue, "schema-version")
        let liveAfterRejection = try await operations.profiles()
        XCTAssertEqual(liveAfterRejection.first?.label, "Disk")
        await operations.retire()
        _ = await fixture.coordinator.stop()
    }

    func testDirectAndIPCShareReloadStatusAndEditorTransactions() async throws {
        let fixture = try RuntimeOperationsFixture()
        defer { fixture.remove() }
        try await fixture.coordinator.start()
        let operations = fixture.operations
        let binding = IPCServiceBinding(operations: operations)
        do {
            let snapshot = try await operations.editorSnapshot()
            let direct = try await operations.edit(expectedDigest: snapshot.sourceDigest, edit: .setProfileLabel(profileID: "default", label: "Direct"))
            XCTAssertEqual(direct.fileCommit, .committed)
            let statusRequest = try Self.request(.configStatus)
            let status = await binding.handle(statusRequest)
            XCTAssertTrue(IPCProtocol.validate(status, for: statusRequest))
            XCTAssertEqual(status.result?.value(for: "outcome")?.stringValue, "changed")
            XCTAssertEqual(status.result?.value(for: "revision")?.integerValue, Int64(direct.revision))

            let editRequest = try Self.request(.editorPatchPosition(expectedDigest: direct.sourceDigest, profileID: "default", positionID: "0_0", patch: ConfigurationPositionPatch(label: .set("Socket"))))
            let edit = await binding.handle(editRequest)
            XCTAssertTrue(IPCProtocol.validate(edit, for: editRequest))
            let updatedDigest = try XCTUnwrap(edit.result?.value(for: "source_digest")?.stringValue)
            let position = try await operations.editorPosition(sourceDigest: updatedDigest, profileID: "default", positionID: "0_0")
            XCTAssertEqual(position.label, "Socket")
            let directStatus = try await operations.configurationStatus()
            XCTAssertEqual(directStatus.outcome, .changed)
            XCTAssertEqual(directStatus.revision, UInt64(try XCTUnwrap(edit.result?.value(for: "revision")?.integerValue)))

            do {
                _ = try await operations.edit(expectedDigest: snapshot.sourceDigest, edit: .setProfileLabel(profileID: "default", label: "Stale"))
                XCTFail("expected stale source")
            } catch { XCTAssertEqual(error as? RuntimeOperationError, .staleSource) }
            let profile = try await operations.editorProfile(sourceDigest: updatedDigest, profileID: "default")
            XCTAssertEqual(profile.label, "Direct")
        } catch {
            await operations.retire()
            _ = await fixture.coordinator.stop()
            throw error
        }
        await operations.retire()
        _ = await fixture.coordinator.stop()
    }

    func testCallerCancellationBeforeAdmissionDoesNotCommit() async throws {
        let fixture = try RuntimeOperationsFixture()
        defer { fixture.remove() }
        try await fixture.coordinator.start()
        let operations = fixture.operations
        let digest = try await operations.editorSnapshot().sourceDigest
        let gate = RuntimeOperationsGate()
        await fixture.session.pauseNextPerform(gate)
        let admitted = Task {
            try await operations.edit(expectedDigest: digest, edit: .patchPosition(profileID: "default", coordinate: "0_0", patch: ConfigurationPositionPatch(label: .set("Admitted"))))
        }
        await gate.waitUntilEntered()
        let committedDigest = ConfigurationStore.digest(try Data(contentsOf: fixture.configurationURL)).description
        let queued = Task {
            try await operations.edit(expectedDigest: committedDigest, edit: .setProfileLabel(profileID: "default", label: "Cancelled"))
        }
        let isQueued = await Self.waitForAdmission(fixture.coordinator)
        XCTAssertTrue(isQueued)
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("expected cancellation before admission")
        } catch { XCTAssertEqual(error as? RuntimeOperationError, .cancelledBeforeAdmission) }
        await gate.resume()
        let result = try await admitted.value
        XCTAssertEqual(result.fileCommit, .committed)
        XCTAssertEqual(result.reloadOutcome, .reloaded)
        let profile = try await operations.editorProfile(sourceDigest: result.sourceDigest, profileID: "default")
        XCTAssertEqual(profile.label, "Default")
        await operations.retire()
        _ = await fixture.coordinator.stop()
    }

    func testConcurrentRetirementCancelsQueuedWorkAndBothCallsDrainAdmittedCommit() async throws {
        let fixture = try RuntimeOperationsFixture()
        defer { fixture.remove() }
        try await fixture.coordinator.start()
        let operations = fixture.operations
        let digest = try await operations.editorSnapshot().sourceDigest
        let gate = RuntimeOperationsGate()
        await fixture.session.pauseNextPerform(gate)
        let admitted = Task {
            try await operations.edit(expectedDigest: digest, edit: .patchPosition(profileID: "default", coordinate: "0_0", patch: ConfigurationPositionPatch(label: .set("Committed"))))
        }
        await gate.waitUntilEntered()
        let committedDigest = ConfigurationStore.digest(try Data(contentsOf: fixture.configurationURL)).description
        let queued = Task {
            try await operations.edit(expectedDigest: committedDigest, edit: .setProfileLabel(profileID: "default", label: "Retired"))
        }
        let isQueued = await Self.waitForAdmission(fixture.coordinator)
        XCTAssertTrue(isQueued)
        let firstMarker = RuntimeOperationsCompletion()
        let secondMarker = RuntimeOperationsCompletion()
        let firstRetire = Task { await operations.retire(); await firstMarker.finish() }
        do {
            _ = try await queued.value
            XCTFail("expected retirement cancellation before admission")
        } catch { XCTAssertEqual(error as? RuntimeOperationError, .cancelledBeforeAdmission) }
        let secondRetire = Task { await operations.retire(); await secondMarker.finish() }
        let bothRetirementsEntered = await Self.waitForRetirements(operations)
        XCTAssertTrue(bothRetirementsEntered)
        let firstFinishedEarly = await firstMarker.finished
        let secondFinishedEarly = await secondMarker.finished
        XCTAssertFalse(firstFinishedEarly)
        XCTAssertFalse(secondFinishedEarly)
        do {
            _ = try await operations.editorSnapshot()
            XCTFail("retired operations must reject fresh work")
        } catch { XCTAssertEqual(error as? RuntimeOperationError, .closed) }
        await gate.resume()
        let result = try await admitted.value
        XCTAssertEqual(result.fileCommit, .committed)
        XCTAssertEqual(result.reloadOutcome, .reloaded)
        await firstRetire.value
        await secondRetire.value
        let configuration = try HidhoggConfigurationDecoder.decode(Data(contentsOf: fixture.configurationURL))
        XCTAssertEqual(configuration.profile(id: "default")?.label, "Default")
        XCTAssertEqual(configuration.profile(id: "default")?.position(named: "0_0")?.label, "Committed")
        let binding = IPCServiceBinding(operations: operations)
        let status = await binding.handle(try Self.request(.status))
        XCTAssertEqual(status.failure?.code, "shutting_down")
        _ = await fixture.coordinator.stop()
    }

    func testCommitRemainsExplicitWhenReloadDeviceWriteFails() async throws {
        let fixture = try RuntimeOperationsFixture()
        defer { fixture.remove() }
        try await fixture.coordinator.start()
        let digest = try await fixture.operations.editorSnapshot().sourceDigest
        await fixture.session.failNextPerform()
        let result = try await fixture.operations.edit(expectedDigest: digest, edit: .patchPosition(profileID: "default", coordinate: "0_0", patch: ConfigurationPositionPatch(label: .set("Persisted"))))
        XCTAssertEqual(result.fileCommit, .committed)
        XCTAssertEqual(result.reloadOutcome, .runtimeFailed)
        XCTAssertEqual(result.reason, .deviceWriteFailed)
        XCTAssertEqual(result.sourceDigest, ConfigurationStore.digest(try Data(contentsOf: fixture.configurationURL)).description)
        let configuration = try HidhoggConfigurationDecoder.decode(Data(contentsOf: fixture.configurationURL))
        XCTAssertEqual(configuration.profile(id: "default")?.position(named: "0_0")?.label, "Persisted")
        await fixture.operations.retire()
        _ = await fixture.coordinator.stop()
    }

    private static func waitForAdmission(_ coordinator: RuntimeCoordinator) async -> Bool {
        for _ in 0..<1_000 {
            if await coordinator.pendingAdmissionCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private static func waitForRetirements(_ operations: RuntimeOperations) async -> Bool {
        for _ in 0..<1_000 {
            if await operations.pendingRetirementCount == 2 { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private static func request(_ command: IPCCommand) throws -> IPCWireRequest {
        let frame = try IPCProtocol.encodeRequest(requestID: "11111111-1111-4111-8111-111111111111", command: command, instanceID: "22222222-2222-4222-8222-222222222222")
        guard case let .success(request) = IPCProtocol.decodeRequest(frame) else { throw IPCFrameError.invalidFrame }
        return request
    }
}

private struct RuntimeOperationsFixture {
    let directory: URL
    let configurationURL: URL
    let session: RuntimeOperationsSession
    let coordinator: RuntimeCoordinator
    let operations: RuntimeOperations

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configurationURL = directory.appendingPathComponent("synthetic.toml")
        let source = Data("""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 80
        default_profile_id = "default"
        [profiles.default]
        label = "Default"
        [profiles.default.positions."0_0"]
        label = "Original"
        """.utf8)
        try source.write(to: configurationURL)
        session = RuntimeOperationsSession()
        coordinator = try RuntimeCoordinator(configuration: HidhoggConfigurationDecoder.decode(source), session: session, clock: SystemRuntimeMonotonicClock())
        operations = try RuntimeOperations(coordinator: coordinator, configurationPath: configurationURL.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor RuntimeOperationsCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

private actor RuntimeOperationsGate {
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
        await withCheckedContinuation { blocked = $0 }
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

private actor RuntimeOperationsSession: D200XDeviceSession {
    private let candidate = D200XDeviceCandidate(registryID: 9, vendorID: 0x2207, productID: 0x0019, interfaceNumber: 0, usagePage: 0x000c, usage: 0x0001, maximumOutputReportSize: D200XFrameCodec.packetSize)
    private var nextGate: RuntimeOperationsGate?
    private var shouldFail = false

    func candidates() async throws -> [D200XDeviceCandidate] { [candidate] }

    func open(_ candidate: D200XDeviceCandidate, onInput: @escaping @Sendable (D200XInputEvent) -> Void, onFailure: @escaping @Sendable (D200XSessionFailure) -> Void) async throws {}

    func perform(_ batch: D200XOutboundBatch) async throws {
        let gate = nextGate
        nextGate = nil
        await gate?.pause()
        if shouldFail {
            shouldFail = false
            throw D200XSessionError.writeFailed
        }
    }

    nonisolated func stop() {}
    func waitUntilStopped() async -> D200XSessionStopOutcome { .closed }
    func pauseNextPerform(_ gate: RuntimeOperationsGate) { nextGate = gate }
    func failNextPerform() { shouldFail = true }
}
