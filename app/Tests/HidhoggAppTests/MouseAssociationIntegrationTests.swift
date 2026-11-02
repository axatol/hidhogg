import Foundation
@testable import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class MouseAssociationIntegrationTests: XCTestCase {
    func testStartupRetainsUnboundSettingsWithoutDiscoveryOrSelector() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var configuration = AppConfiguration.defaultConfiguration
        configuration.connectOnLaunch = true
        configuration.devices[0].wheelInverted = true
        _ = try await store.save(WorkspaceConfiguration(legacy: configuration), expecting: .missing)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { !model.isLoading }
        XCTAssertTrue(model.needsMouseEndpointSelection)
        XCTAssertFalse(model.isMouseSelectorPresented)
        XCTAssertEqual(model.wheelPreferenceDraft, true)
        XCTAssertEqual(session.targets.count, 0)
        model.connect()
        await waitUntil { !model.isLogitechSetupLoading }
        XCTAssertEqual(model.navigation.current.route, .logitechSetup)
        XCTAssertEqual(model.logitechSetupDestination, .reassociate(model.registeredDevices[0].id))
        XCTAssertEqual(session.targets.count, 0)
    }

    func testAssociationPersistsIdentityAndPreferenceBeforeDiscoveryRetainingSettings() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { !model.isLoading }
        let id = try XCTUnwrap(model.selectedMouseID)
        model.setWheelPreference(true)
        _ = await model.flushPendingSave()
        model.presentMouseSelector()
        await waitUntil { !model.isMouseSelectorLoading }
        let candidate = try XCTUnwrap(model.mouseConnectionChoices.first)
        model.associateMouse(candidateID: candidate.id)
        await waitUntil { session.targets.count == 1 && model.presentedMouseOwnerID == id }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.workspace.preferredMouseID, id)
        XCTAssertEqual(loaded.workspace.devices.first { $0.id == id }?.logitechAssociation?.identity, candidate.identity)
        XCTAssertEqual(loaded.workspace.configuration(forMouseID: id).mouse?.wheelInverted, true)
        XCTAssertEqual(session.targets.first?.association.identity, candidate.identity)
        XCTAssertEqual(session.targets.first?.candidateID, candidate.id)
        XCTAssertEqual(model.presentedMouseOwnerID, id)
    }

    func testSaveFailureNeverDiscoversOrAdmitsSettings() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url, beforeRegistryPublication: { throw ConfigurationError.filesystemAccessFailed })
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { !model.isLoading }
        model.presentMouseSelector()
        await waitUntil { !model.isMouseSelectorLoading }
        let candidate = try XCTUnwrap(model.mouseConnectionChoices.first)
        model.associateMouse(candidateID: candidate.id)
        await waitUntil { model.configurationSaveError != nil }
        XCTAssertTrue(session.targets.isEmpty)
        XCTAssertEqual(session.writeCount, 0)
        XCTAssertNil(model.presentedMouseOwnerID)
        XCTAssertFalse(model.canDiscover)
    }

    func testStaleCandidateSnapshotCannotAssociateAfterEditorChange() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, session: session)
        await waitUntil { !model.isLoading }
        model.presentMouseSelector()
        await waitUntil { !model.isMouseSelectorLoading }
        let candidate = try XCTUnwrap(model.mouseConnectionChoices.first)
        model.addDevice(.mxMaster3S)
        model.associateMouse(candidateID: candidate.id)
        await drain()
        XCTAssertTrue(model.registeredDevices.allSatisfy { $0.logitechAssociation == nil })
        XCTAssertTrue(session.targets.isEmpty)
        _ = await model.flushPendingSave()
    }

    func testPreferredAssociatedStartupIgnoresEditorOrderAndReconnectsSameIdentity() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var workspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
        var associated = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        associated.logitechAssociation = AssociatedMouseSession.association
        workspace.devices.append(associated)
        workspace.preferredMouseID = associated.id
        workspace.connectOnLaunch = true
        _ = try await store.save(workspace, expecting: .missing)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { session.targets.count == 1 && model.presentedMouseOwnerID == associated.id }
        XCTAssertNotEqual(model.selectedMouseID, associated.id)
        XCTAssertEqual(model.presentedMouseOwnerID, associated.id)
        XCTAssertTrue(model.canDiscover)
        session.failConnection()
        await waitUntil { session.targets.count == 2 }
        XCTAssertTrue(session.targets.allSatisfy { $0.association == associated.logitechAssociation })
        model.disconnect()
    }

    func testDisabledPreferredSuspendsInsteadOfAdoptingAnotherAssociation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var workspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
        workspace.devices[0].logitechAssociation = AssociatedMouseSession.association
        workspace.devices[0].isEnabled = false
        workspace.preferredMouseID = workspace.devices[0].id
        var second = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        second.logitechAssociation = .init(identity: .init(unitID: "11223344", modelID: "556677889900"), preferredConnection: .bluetooth)
        workspace.devices.append(second)
        workspace.connectOnLaunch = true
        _ = try await store.save(workspace, expecting: .missing)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { !model.isLoading }
        XCTAssertTrue(session.targets.isEmpty)
        XCTAssertFalse(model.canDiscover)
        model.removeDevice(workspace.devices[0].id)
        XCTAssertNil(model.workspace.preferredMouseID)
        _ = await model.flushPendingSave()
    }

    func testMX4ReadOnlyConnectionNeverAppliesConfiguredControls() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var registration = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster4))
        registration.logitechAssociation = AssociatedMouseSession.association
        if case .mouse(var configuration) = registration.configuration {
            configuration.wheelInverted = true
            configuration.thumbwheelInverted = true
            configuration.defaults["back"] = .key(.init(keyCode: 12))
            registration.configuration = .mouse(configuration)
        }
        let workspace = WorkspaceConfiguration(connectOnLaunch: true, devices: [registration], preferredMouseID: registration.id)
        _ = try await store.save(workspace, expecting: .missing)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { session.targets.count == 1 && model.presentedMouseOwnerID != nil }
        await drain()
        XCTAssertEqual(model.selectedMouseStatus.phase, .ready)
        XCTAssertFalse(model.selectedMouseSupportsManagement)
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertEqual(session.writeCount, 0)
        XCTAssertTrue(model.canRefreshDeviceInformation)
    }

    func testRemovingPreferredDoesNotAdoptRemainingAssociatedMouseAfterStartup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var workspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
        workspace.devices[0].logitechAssociation = AssociatedMouseSession.association
        workspace.devices[0].isEnabled = false
        let removedID = workspace.devices[0].id
        workspace.preferredMouseID = removedID
        var remaining = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        remaining.logitechAssociation = .init(identity: .init(unitID: "11223344", modelID: "556677889900"), preferredConnection: .bluetooth)
        workspace.devices.append(remaining)
        workspace.connectOnLaunch = true
        _ = try await store.save(workspace, expecting: .missing)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { !model.isLoading }
        model.removeDevice(removedID)
        XCTAssertNil(model.workspace.preferredMouseID)
        XCTAssertFalse(model.canDiscover)
        XCTAssertTrue(session.targets.isEmpty)
        XCTAssertEqual(session.writeCount, 0)
        let saved = await model.flushPendingSave()
        XCTAssertTrue(saved)

        let restartedSession = AssociatedMouseSession()
        let restarted = makeModel(url: url, store: store, session: restartedSession)
        await waitUntil { !restarted.isLoading }
        await drain()
        XCTAssertTrue(restarted.workspace.connectOnLaunch)
        XCTAssertNil(restarted.workspace.preferredMouseID)
        XCTAssertEqual(restarted.registeredDevices.filter { $0.family.isLogitechMouse }, [remaining])
        XCTAssertEqual(restarted.registeredDevices.filter { !$0.family.isLogitechMouse },
                       workspace.devices.filter { !$0.family.isLogitechMouse })
        XCTAssertFalse(restarted.canDiscover)
        XCTAssertNil(restarted.presentedMouseOwnerID)
        XCTAssertTrue(restartedSession.targets.isEmpty)
        XCTAssertEqual(restartedSession.writeCount, 0)
    }

    func testMismatchedPostConnectIdentityNeverAdmitsConfiguredWrites() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var workspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
        workspace.devices[0].logitechAssociation = AssociatedMouseSession.association
        workspace.preferredMouseID = workspace.devices[0].id
        if case .mouse(var configuration) = workspace.devices[0].configuration {
            configuration.wheelInverted = true
            workspace.devices[0].configuration = .mouse(configuration)
        }
        workspace.connectOnLaunch = true
        _ = try await store.save(workspace, expecting: .missing)
        let session = AssociatedMouseSession(mismatchedIdentity: true)
        let model = makeModel(url: url, store: store, session: session,
                              wakeDelay: { _ in try await Task.sleep(for: .seconds(30)) })
        await waitUntil { model.boltStatus.failure?.code == .identityMismatch }
        await drain()
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertEqual(session.writeCount, 0)
        XCTAssertEqual(model.connectionPresentationPhase, .failed)
        XCTAssertTrue(model.connectionMessage.contains("does not match"))
        XCTAssertEqual(model.connectionTitle, "Association needs attention")
        XCTAssertEqual(model.selectedMouseStatus.phase, .failed)
        XCTAssertNil(model.selectedMouseStatus.deviceInformation.battery)
        XCTAssertTrue(model.selectedMouseStatus.deviceInformation.firmware.isEmpty)
        XCTAssertNil(model.presentedMouseOwnerID)
        model.disconnect()
    }

    func testSameSavedTargetRecoversAfterUncertainSleepCleanupAndManualRetry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var workspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
        workspace.devices[0].logitechAssociation = AssociatedMouseSession.association
        let id = workspace.devices[0].id
        workspace.preferredMouseID = id
        workspace.connectOnLaunch = true
        _ = try await store.save(workspace, expecting: .missing)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { model.presentedMouseOwnerID == id && session.writeCount == 3 }
        let initialWrites = session.writeCount
        session.setRecoverableCleanupFailure()
        model.systemWillSleep()
        await waitUntil { model.boltStatus.cleanupUncertain }
        XCTAssertNil(model.presentedMouseOwnerID)
        XCTAssertEqual(session.writeCount, initialWrites)
        model.systemDidWake()
        await waitUntil {
            session.targets.count == 2 && model.presentedMouseOwnerID == id &&
                !model.boltStatus.cleanupUncertain && session.writeCount == initialWrites + 3
        }
        XCTAssertTrue(session.targets.allSatisfy { $0.model == .mxMaster3S && $0.association == AssociatedMouseSession.association })
        XCTAssertEqual(session.catalogCount, 0)
        XCTAssertEqual(session.writeCount, initialWrites + 3)

        let recoveredWrites = session.writeCount
        session.setRecoverableCleanupFailure()
        model.disconnect()
        await waitUntil { model.boltStatus.cleanupUncertain }
        XCTAssertEqual(session.writeCount, recoveredWrites)
        model.connect()
        await waitUntil {
            session.targets.count == 3 && model.presentedMouseOwnerID == id &&
                !model.boltStatus.cleanupUncertain && session.writeCount == recoveredWrites + 3
        }
        XCTAssertTrue(session.targets.allSatisfy { $0.association == AssociatedMouseSession.association })
        XCTAssertEqual(session.writeCount, recoveredWrites + 3)
        model.disconnect()
    }

    func testUncertainSavedEndpointNeverRetriesDifferentRegistrationOrCatalog() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var workspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
        workspace.devices[0].logitechAssociation = AssociatedMouseSession.association
        let ownerID = workspace.devices[0].id
        workspace.preferredMouseID = ownerID
        var other = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        other.logitechAssociation = .init(identity: .init(unitID: "11223344", modelID: "556677889900"), preferredConnection: .bluetooth)
        workspace.devices.append(other)
        workspace.connectOnLaunch = true
        _ = try await store.save(workspace, expecting: .missing)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { model.presentedMouseOwnerID == ownerID && session.writeCount > 0 }
        let initialWrites = session.writeCount
        session.setCleanupFailure()
        model.disconnect()
        await waitUntil { model.boltStatus.cleanupUncertain }
        model.navigate(to: .mouse(other.id))
        model.connect()
        await waitUntil { !model.isMouseSelectorLoading && model.mouseSelectorMessage != nil }
        XCTAssertEqual(session.targets.count, 1)
        XCTAssertEqual(model.workspace.preferredMouseID, ownerID)
        XCTAssertEqual(session.writeCount, initialWrites)
        XCTAssertNil(model.presentedMouseOwnerID)
        model.presentMouseSelector()
        await waitUntil { !model.isMouseSelectorLoading }
        XCTAssertEqual(session.catalogCount, 0)
        XCTAssertEqual(session.targets.count, 1)
        XCTAssertEqual(session.writeCount, initialWrites)
        model.dismissMouseSelector()
    }

    func testSwitchingFromActiveMouseCleansBeforeCatalogAndCanSelectAnotherRegistration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var workspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
        workspace.devices[0].logitechAssociation = AssociatedMouseSession.association
        workspace.preferredMouseID = workspace.devices[0].id
        workspace.connectOnLaunch = true
        _ = try await store.save(workspace, expecting: .missing)
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { model.presentedMouseOwnerID == workspace.preferredMouseID }
        model.addDevice(.mxMaster3S)
        let secondID = try XCTUnwrap(model.selectedMouseID)
        XCTAssertNotEqual(secondID, workspace.preferredMouseID)
        XCTAssertFalse(model.isSelectedMouseRuntimeTarget)
        session.pauseStop()
        model.presentMouseSelector()
        await waitUntil { session.stopIsPending }
        XCTAssertEqual(session.catalogCount, 0)
        session.resumeStop()
        await waitUntil { !model.isMouseSelectorLoading }
        XCTAssertEqual(session.catalogCount, 1)
        XCTAssertFalse(session.catalogProbedManagedEndpoint)
        XCTAssertNil(model.presentedMouseOwnerID)
        model.dismissMouseSelector()
        _ = await model.flushPendingSave()
    }

    func testUncertainCleanupNeverInventoriesOrSwitchesMouse() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, session: session)
        await waitUntil { !model.isLoading }
        session.setCleanupFailure()
        model.presentMouseSelector()
        await waitUntil { !model.isMouseSelectorLoading }
        XCTAssertEqual(session.catalogCount, 0)
        XCTAssertTrue(session.targets.isEmpty)
        XCTAssertNotNil(model.mouseSelectorMessage)
        model.dismissMouseSelector()
    }

    func testClosingSelectorDuringAssociationSavePreventsActivation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let gate = AssociationSaveGate()
        let store = ConfigurationStore(url: url, beforeRegistryPublication: { gate.wait() })
        let session = AssociatedMouseSession()
        let model = makeModel(url: url, store: store, session: session)
        await waitUntil { !model.isLoading }
        model.presentMouseSelector()
        await waitUntil { !model.isMouseSelectorLoading }
        let candidate = try XCTUnwrap(model.mouseConnectionChoices.first)
        model.associateMouse(candidateID: candidate.id)
        await waitUntil { gate.hasEntered }
        model.dismissMouseSelector()
        gate.release()
        await waitUntil { !model.isSaving }
        await drain()
        XCTAssertTrue(session.targets.isEmpty)
        XCTAssertNil(model.presentedMouseOwnerID)
    }

    private func makeModel(url: URL, store: ConfigurationStore? = nil, session: AssociatedMouseSession,
                           wakeDelay: @escaping WakeRecoveryCoordinator.Delay = { _ in await Task.yield() }) -> AppModel {
        AppModel(configurationURL: url, store: store ?? ConfigurationStore(url: url), bolt: session,
                 sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
                 loadImmediately: true, observeSleep: false,
                 wakeDelay: wakeDelay, frontmostApplication: { nil })
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic condition did not settle", file: file, line: line)
    }

    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }
}

private final class AssociatedMouseSession: BindingSession, @unchecked Sendable {
    static let association = LogitechAssociation(identity: .init(unitID: "12345678", modelID: "123456789abc"), preferredConnection: .bolt)
    let requiresExplicitAssociation = true
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var generation: UInt64 = 1
    private var recordedTargets: [LogitechConnectionTarget] = []
    private var writes = 0
    private var managed = false
    private var catalogs = 0
    private var probedManaged = false
    private var pauseNextStop = false
    private var stopWait: CheckedContinuation<Void, Never>?
    private var cleanupSucceeded = true
    private var recoverOnDiscovery = false
    private let mismatchedIdentity: Bool
    private let candidate = LogitechEndpointCandidate(id: UUID(), connection: .bolt, model: .mxMaster3S,
                                                     identity: AssociatedMouseSession.association.identity, information: .init())

    init(mismatchedIdentity: Bool = false) {
        let stream = AsyncStream<BoltEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        self.mismatchedIdentity = mismatchedIdentity
    }

    var targets: [LogitechConnectionTarget] { lock.withLock { recordedTargets } }
    var writeCount: Int { lock.withLock { writes } }
    var catalogCount: Int { lock.withLock { catalogs } }
    var catalogProbedManagedEndpoint: Bool { lock.withLock { probedManaged } }
    var stopIsPending: Bool { lock.withLock { stopWait != nil } }

    func existingConnections() async -> [LogitechEndpointCandidate] {
        lock.withLock { catalogs += 1; probedManaged = probedManaged || managed }
        return [candidate]
    }
    func discover() async { XCTFail("Associated session used legacy discovery") }
    func discover(target: LogitechConnectionTarget) async {
        lock.withLock {
            recordedTargets.append(target)
            managed = true
            if recoverOnDiscovery { cleanupSucceeded = true; recoverOnDiscovery = false }
        }
        emit(mismatchedIdentity ? .failed : .ready, target: target,
             failure: mismatchedIdentity ? .identityMismatch : nil)
    }
    func enable() async { lock.withLock { writes += 1 } }
    func disable() async { lock.withLock { writes += 1 } }
    func stop() async {
        await withCheckedContinuation { continuation in
            let paused = lock.withLock {
                guard pauseNextStop else { return false }
                pauseNextStop = false
                stopWait = continuation
                return true
            }
            if !paused { continuation.resume() }
        }
        lock.withLock { if cleanupSucceeded { managed = false } }
        emit(.idle)
    }
    func stopForRestart() async -> Bool { await stop(); return lock.withLock { cleanupSucceeded } }
    func pauseStop() { lock.withLock { pauseNextStop = true } }
    func resumeStop() {
        let wait = lock.withLock { let value = stopWait; stopWait = nil; return value }
        wait?.resume()
    }
    func setCleanupFailure() { lock.withLock { cleanupSucceeded = false } }
    func setRecoverableCleanupFailure() { lock.withLock { cleanupSucceeded = false; recoverOnDiscovery = true } }
    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool { false }
    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                               amount: Double?, scrollPostingAllowed: Bool) async { lock.withLock { writes += 1 } }
    func applyThumbwheelPreferences(inverted: Bool?, amount: Double?, restorePreviousSettingsOnDisconnect: Bool,
                                    scrollPostingAllowed: Bool) async { lock.withLock { writes += 1 } }
    func failConnection() { emit(.failed) }

    private func emit(_ phase: BoltPhase, target: LogitechConnectionTarget? = nil, failure: BoltFailureCode? = nil) {
        let next = lock.withLock { generation += 1; return generation }
        let identity = mismatchedIdentity ? LogitechIdentity(unitID: "99887766", modelID: "123456789abc") : target?.association.identity
        continuation.yield(.status(BoltStatus(phase: phase, message: "Synthetic association session",
                                             availableControls: Set(MouseControl.allCases), generation: next,
                                             cleanupUncertain: lock.withLock { !cleanupSucceeded }, wheel: .init(support: .supported),
                                             failure: failure.map { .init(code: $0, sourceFileID: #fileID, sourceLine: #line) },
                                             supportsManagement: target?.model != .mxMaster4,
                                             model: target?.model, connection: target?.association.preferredConnection,
                                             verifiedIdentity: identity)))
    }
}

private final class AssociationSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    var hasEntered: Bool { lock.withLock { entered } }
    func wait() { lock.withLock { entered = true }; semaphore.wait() }
    func release() { semaphore.signal() }
}
