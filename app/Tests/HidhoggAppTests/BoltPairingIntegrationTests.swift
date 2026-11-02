import Foundation
@testable import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class BoltPairingIntegrationTests: XCTestCase {
    func testOrdinaryModelHasNoNativePairingSession() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: PairingBindingSession())
        await waitUntil { !model.isLoading }
        XCTAssertFalse(model.canPairNewMouse)
        model.presentBoltPairing()
        XCTAssertFalse(model.isBoltPairingPresented)
    }

    func testReceiverInventoryWaitsForVerifiedManagementCleanup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession()
        let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }
        binding.pauseStop()
        model.presentBoltPairing()
        await waitUntil { binding.stopIsPending }
        XCTAssertEqual(pairing.receiverReads, 0)
        XCTAssertTrue(model.isBoltPairingLoading)
        XCTAssertFalse(model.canDiscover)
        XCTAssertFalse(model.canSelectExistingMouse)
        model.presentMouseSelector()
        XCTAssertEqual(binding.catalogReads, 0)
        binding.resumeStop()
        await waitUntil { pairing.receiverReads == 1 && !model.isBoltPairingLoading }
        XCTAssertFalse(binding.catalogProbedManagedEndpoint)
        model.dismissBoltPairing()
        await waitUntil { pairing.closeCount == 1 }
    }

    func testPairingPhaseProgressReplacesReceiverLoadingIndicator() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pairing = SyntheticBoltPairingSession(discoveringOnStart: true)
        let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: PairingBindingSession(), pairing: pairing)
        await waitUntil { !model.isLoading }

        model.presentBoltPairing()
        await waitUntil { pairing.receiverReads == 1 && !model.isBoltPairingLoading }
        model.selectBoltPairingReceiver(pairing.receiver.id)
        await waitUntil { model.boltPairingStatus?.phase == .discovering }
        XCTAssertTrue(model.isBoltPairingPresented)
        XCTAssertFalse(model.isBoltPairingLoading)

        pairing.emitAwaitingSelection()
        await waitUntil { model.boltPairingStatus?.phase == .awaitingSelection }
        model.selectBoltPairingCandidate(pairing.candidate.id)
        await waitUntil { model.boltPairingStatus?.phase == .authenticating }
        XCTAssertFalse(model.isBoltPairingLoading)
        XCTAssertFalse(model.shouldShowLogitechSetupRecoveryButton)

        pairing.emitVerifying()
        await waitUntil { model.boltPairingStatus?.phase == .verifying }
        XCTAssertFalse(model.isBoltPairingLoading)
        XCTAssertFalse(model.shouldShowLogitechSetupRecoveryButton)
        model.dismissBoltPairing()
        await waitUntil { pairing.closeCount == 1 }
    }

    func testUncertainCleanupNeverInventoriesReceiver() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = PairingBindingSession(cleanupSucceeds: false)
        let pairing = SyntheticBoltPairingSession()
        let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }
        model.presentBoltPairing()
        await waitUntil { pairing.closeCount == 1 }
        XCTAssertEqual(pairing.receiverReads, 0)
        XCTAssertTrue(binding.targets.isEmpty)
        XCTAssertTrue(model.boltPairingMessage?.contains("released safely") == true)
    }

    func testVerifiedPairingClosesAndSavesBeforeTargetedConnectionRetainingSettings() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession()
        let model = makeModel(url: url, store: store, binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }
        model.setWheelPreference(true)
        _ = await model.flushPendingSave()
        let id = try XCTUnwrap(model.selectedMouseID)
        let configuration = model.registration(id: id)?.configuration
        try await beginPairing(model, pairing: pairing)
        pairing.pauseClose()
        pairing.emitVerified()
        await waitUntil { pairing.closeIsPending }
        XCTAssertNil(model.registration(id: id)?.logitechAssociation)
        XCTAssertTrue(binding.targets.isEmpty)
        pairing.resumeClose()
        await waitUntil { binding.targets.count == 1 }
        let saved = try await store.load()
        XCTAssertEqual(saved.workspace.preferredMouseID, id)
        XCTAssertEqual(saved.workspace.devices.first { $0.id == id }?.configuration, configuration)
        XCTAssertEqual(saved.workspace.devices.first { $0.id == id }?.logitechAssociation?.identity, pairing.verified.identity)
        XCTAssertEqual(binding.targets.first?.association.identity, pairing.verified.identity)
        XCTAssertNil(binding.targets.first?.candidateID)
        XCTAssertFalse(model.isBoltPairingPresented)
        model.disconnect()
    }

    func testCancelledSetupSurfacesReceiverCleanupUncertainty() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pairing = SyntheticBoltPairingSession(notificationCleanupRequiresAttention: true)
        let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: PairingBindingSession(), pairing: pairing)
        await waitUntil { !model.isLoading }

        model.addDeviceAndPair(.mxMaster3S)
        await waitUntil { !model.isLogitechSetupLoading }
        model.pairLogitechSetup()
        await waitUntil { model.boltPairingStatus?.phase == .awaitingSelection }
        model.reportError("An earlier operation failed.")
        model.cancelLogitechSetupPairing()
        await waitUntil {
            model.diagnosticEvent?.code == .boltCleanupUncertain &&
                model.errorMessage?.contains("The Bolt receiver notification cleanup could not be verified.") == true &&
                !model.isBoltPairingLoading && !model.isLogitechSetupLoading &&
                model.boltPairingStatus == nil
        }

        XCTAssertEqual(model.navigation.current.route, .logitechSetup)
        XCTAssertNil(model.boltPairingStatus)
        XCTAssertEqual(model.errorMessage, "An earlier operation failed.\n\nThe Bolt receiver notification cleanup could not be verified. Review receiver state before pairing again.")
        XCTAssertEqual(model.diagnosticEvent?.code, .boltCleanupUncertain)
        XCTAssertEqual(model.diagnosticEvent?.message, "Bolt pairing receiver notification cleanup could not be verified.")
        XCTAssertTrue(model.registeredDevices.allSatisfy { $0.logitechAssociation == nil })
    }

    func testVerifiedSetupPersistsAndActivatesWhenCleanupWarningIsReported() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession(notificationCleanupRequiresAttention: true)
        let model = makeModel(url: url, store: store, binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }

        model.addDeviceAndPair(.mxMaster3S)
        await waitUntil { !model.isLogitechSetupLoading }
        model.pairLogitechSetup()
        await waitUntil { model.boltPairingStatus?.phase == .awaitingSelection }
        pairing.emitVerified()
        await waitUntil { binding.targets.count == 1 && model.errorMessage != nil }

        let saved = try await store.load()
        let id = try XCTUnwrap(saved.workspace.preferredMouseID)
        XCTAssertEqual(saved.workspace.devices.first { $0.id == id }?.logitechAssociation?.identity, pairing.verified.identity)
        XCTAssertEqual(model.registration(id: id)?.logitechAssociation?.identity, pairing.verified.identity)
        XCTAssertEqual(model.navigation.current.route, .mouse(id))
        XCTAssertFalse(model.isBoltPairingPresented)
        XCTAssertEqual(model.boltPairingStatus?.phase, .verified)
        XCTAssertEqual(model.errorMessage, "The Bolt receiver notification cleanup could not be verified. Review receiver state before pairing again.")
        XCTAssertEqual(model.diagnosticEvent?.code, .boltCleanupUncertain)
        XCTAssertEqual(model.diagnosticEvent?.message, "Bolt pairing receiver notification cleanup could not be verified.")
        XCTAssertEqual(binding.targets.first?.association.identity, pairing.verified.identity)
        model.disconnect()
    }

    func testCancellationRacingVerifiedCloseDoesNotSaveOrActivate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession()
        let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }
        try await beginPairing(model, pairing: pairing)
        pairing.pauseClose()
        pairing.emitVerified()
        await waitUntil { pairing.closeIsPending }
        model.dismissBoltPairing()
        pairing.resumeClose()
        await waitUntil { model.boltPairingMessage?.contains("not added") == true }
        XCTAssertTrue(model.registeredDevices.allSatisfy { $0.logitechAssociation == nil })
        XCTAssertTrue(binding.targets.isEmpty)
        XCTAssertEqual(binding.writeCount, 0)
        XCTAssertFalse(model.isBoltPairingPresented)
    }

    func testSaveFailureRetainsSettingsAndReportsPairedButNotAdded() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let gate = PairingPublicationGate()
        let store = ConfigurationStore(url: url, beforeRegistryPublication: { try gate.enter() })
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession()
        let model = makeModel(url: url, store: store, binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }
        model.setWheelPreference(true)
        try await beginPairing(model, pairing: pairing)
        let before = model.workspace
        gate.failNextPublication()
        pairing.emitVerified()
        await waitUntil { model.boltPairingMessage?.contains("not added") == true }
        XCTAssertEqual(model.workspace, before)
        XCTAssertTrue(binding.targets.isEmpty)
        XCTAssertEqual(binding.writeCount, 0)
        let saved = try await store.load()
        XCTAssertTrue(saved.workspace.devices.allSatisfy { $0.logitechAssociation == nil })
    }

    func testCancelDuringAdmittedPublicationReportsSavedAssociationWithoutActivation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let gate = PairingPublicationGate()
        let store = ConfigurationStore(url: url, beforeRegistryPublication: { try gate.enter() })
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession()
        let model = makeModel(url: url, store: store, binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }
        try await beginPairing(model, pairing: pairing)
        gate.pauseNextPublication()
        pairing.emitVerified()
        await waitUntil { gate.hasEntered }
        model.dismissBoltPairing()
        gate.release()
        await waitUntil { model.boltPairingMessage?.contains("Paired and saved") == true }
        let saved = try await store.load()
        XCTAssertEqual(saved.workspace.devices.first { $0.id == model.selectedMouseID }?.logitechAssociation?.identity, pairing.verified.identity)
        XCTAssertTrue(binding.targets.isEmpty)
        XCTAssertEqual(binding.writeCount, 0)
    }

    func testEditorSleepDisableAndRemovalRevokePendingPairing() async throws {
        for action in ["editor", "sleep", "disable", "remove"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let binding = PairingBindingSession()
            let pairing = SyntheticBoltPairingSession(lateSuccessOnCancel: true)
            let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: binding, pairing: pairing)
            await waitUntil { !model.isLoading }
            let id = try XCTUnwrap(model.selectedMouseID)
            try await beginPairing(model, pairing: pairing)
            switch action {
            case "editor": model.setWheelPreference(true)
            case "sleep": model.systemWillSleep()
            case "disable": model.setDeviceEnabled(id, enabled: false)
            default: model.removeDevice(id)
            }
            await waitUntil { model.boltPairingMessage?.contains("not added") == true }
            XCTAssertTrue(model.registeredDevices.allSatisfy { $0.logitechAssociation == nil }, action)
            XCTAssertTrue(binding.targets.isEmpty, action)
            XCTAssertEqual(binding.writeCount, 0, action)
            _ = await model.flushPendingSave()
        }
    }

    func testModelMismatchCannotSelectCandidateOrSaveVerifiedResult() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession(model: .mxMaster4)
        let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }
        try await beginPairing(model, pairing: pairing)
        model.selectBoltPairingCandidate(pairing.candidate.id)
        await drain()
        XCTAssertEqual(pairing.selectionCount, 0)
        pairing.emitVerified()
        await waitUntil { model.boltPairingMessage?.contains("not added") == true }
        XCTAssertTrue(model.registeredDevices.allSatisfy { $0.logitechAssociation == nil })
        XCTAssertTrue(binding.targets.isEmpty)
    }

    func testMX4PairingUsesSameFlowAndRemainsReadOnly() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession(model: .mxMaster4)
        let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: binding, pairing: pairing)
        await waitUntil { !model.isLoading }
        model.addDeviceAndPair(.mxMaster4)
        XCTAssertEqual(model.navigation.current.route, .logitechSetup)
        await waitUntil { !model.isLogitechSetupLoading }
        XCTAssertEqual(pairing.receiverReads, 0)
        model.pairLogitechSetup()
        await waitUntil { model.boltPairingStatus?.phase == .awaitingSelection }
        model.selectBoltPairingCandidate(pairing.candidate.id)
        await waitUntil { pairing.selectionCount == 1 }
        pairing.emitVerified()
        await waitUntil { binding.targets.count == 1 }
        await drain()
        XCTAssertEqual(binding.targets.first?.model, .mxMaster4)
        XCTAssertFalse(model.selectedMouseSupportsManagement)
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertEqual(binding.writeCount, 0)
        model.disconnect()
    }

    func testCancellationRestoresExactPriorSavedRuntimePreference() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var workspace = WorkspaceConfiguration(legacy: .defaultConfiguration)
        workspace.devices[0].logitechAssociation = LogitechAssociation(identity: SyntheticBoltPairingSession.identity, preferredConnection: .bolt)
        workspace.preferredMouseID = workspace.devices[0].id
        workspace.connectOnLaunch = true
        _ = try await store.save(workspace, expecting: .missing)
        let binding = PairingBindingSession()
        let pairing = SyntheticBoltPairingSession()
        let model = makeModel(url: url, store: store, binding: binding, pairing: pairing)
        await waitUntil { binding.targets.count == 1 && model.presentedMouseOwnerID == workspace.preferredMouseID }
        model.presentBoltPairing()
        await waitUntil { pairing.receiverReads == 1 && !model.isBoltPairingLoading }
        model.dismissBoltPairing()
        await waitUntil { binding.targets.count == 2 }
        XCTAssertEqual(model.workspace, workspace)
        XCTAssertEqual(binding.targets[0].association, binding.targets[1].association)
        model.disconnect()
    }

    func testAsyncStopPathsWaitForPairingClosureWithoutSavingOrActivatingLateSuccess() async throws {
        for action in ["restart", "termination", "sleep"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let binding = PairingBindingSession()
            let pairing = SyntheticBoltPairingSession(lateSuccessOnCancel: true)
            let model = makeModel(url: root.appendingPathComponent("config.toml"), binding: binding, pairing: pairing)
            await waitUntil { !model.isLoading }
            try await beginPairing(model, pairing: pairing)
            pairing.pauseClose()
            var didReturn = false
            let stop = Task {
                switch action {
                case "restart": _ = await model.stopForRestart()
                case "termination": _ = await model.stopForTermination()
                default: await model.stopForSleep()
                }
                didReturn = true
            }
            await waitUntil { pairing.closeIsPending }
            await drain()
            XCTAssertFalse(didReturn, action)
            XCTAssertTrue(model.registeredDevices.allSatisfy { $0.logitechAssociation == nil }, action)
            XCTAssertTrue(binding.targets.isEmpty, action)
            pairing.resumeClose()
            await stop.value
            XCTAssertTrue(didReturn, action)
            XCTAssertTrue(model.boltPairingMessage?.contains("not added") == true, action)
            XCTAssertTrue(model.registeredDevices.allSatisfy { $0.logitechAssociation == nil }, action)
            XCTAssertTrue(binding.targets.isEmpty, action)
            XCTAssertEqual(binding.writeCount, 0, action)
        }
    }

    private func beginPairing(_ model: AppModel, pairing: SyntheticBoltPairingSession) async throws {
        model.presentBoltPairing()
        await waitUntil { pairing.receiverReads == 1 && !model.isBoltPairingLoading }
        model.selectBoltPairingReceiver(pairing.receiver.id)
        await waitUntil { model.boltPairingStatus?.phase == .awaitingSelection }
    }

    private func makeModel(url: URL, store: ConfigurationStore? = nil, binding: PairingBindingSession,
                           pairing: SyntheticBoltPairingSession? = nil) -> AppModel {
        let factory: (@Sendable () -> any BoltPairingManaging)?
        if let pairing {
            factory = { @Sendable in pairing }
        } else {
            factory = nil
        }
        return AppModel(configurationURL: url, store: store ?? ConfigurationStore(url: url), bolt: binding,
                        makeBoltPairingSession: factory,
                        sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
                        loadImmediately: true, observeSleep: false,
                        wakeDelay: { _ in try await Task.sleep(for: .seconds(30)) }, frontmostApplication: { nil })
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
        XCTFail("Synthetic pairing condition did not settle", file: file, line: line)
    }

    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }
}

final class SyntheticBoltPairingSession: BoltPairingManaging, @unchecked Sendable {
    static let identity = LogitechIdentity(unitID: "12345678", modelID: "123456789abc")
    let receiver = BoltReceiverCandidate(id: UUID(), label: "Logi Bolt receiver")
    let candidate: BoltPairingCandidate
    let verified: LogitechEndpointCandidate
    let events: AsyncStream<BoltPairingStatus>
    private let continuation: AsyncStream<BoltPairingStatus>.Continuation
    private let lock = NSLock()
    private var status = BoltPairingStatus(phase: .idle, message: "Synthetic pairing")
    private var receiversRead = 0
    private var selections = 0
    private var closes = 0
    private var pauseNextClose = false
    private var closeWait: CheckedContinuation<Void, Never>?
    private let lateSuccessOnCancel: Bool
    private let receiverCount: Int
    private let discoveringOnStart: Bool
    private let cleanupRequiresAttention: Bool

    init(model: LogitechMouseModel = .mxMaster3S, lateSuccessOnCancel: Bool = false, receiverCount: Int = 1,
         discoveringOnStart: Bool = false, notificationCleanupRequiresAttention: Bool = false) {
        candidate = BoltPairingCandidate(id: UUID(), name: nil, model: model)
        verified = LogitechEndpointCandidate(id: UUID(), connection: .bolt, model: model, identity: Self.identity, information: .init())
        self.lateSuccessOnCancel = lateSuccessOnCancel
        self.receiverCount = receiverCount
        self.discoveringOnStart = discoveringOnStart
        cleanupRequiresAttention = notificationCleanupRequiresAttention
        let stream = AsyncStream<BoltPairingStatus>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    var receiverReads: Int { lock.withLock { receiversRead } }
    var selectionCount: Int { lock.withLock { selections } }
    var closeCount: Int { lock.withLock { closes } }
    var closeIsPending: Bool { lock.withLock { closeWait != nil } }
    func receivers() async throws -> [BoltReceiverCandidate] {
        lock.withLock { receiversRead += 1 }
        return (0..<receiverCount).map { $0 == 0 ? receiver : BoltReceiverCandidate(id: UUID(), label: "Logi Bolt receiver \($0 + 1)") }
    }
    func start(receiverID: UUID) async {
        if discoveringOnStart {
            emit(.init(phase: .discovering, message: "Synthetic discovery"))
            return
        }
        emitAwaitingSelection()
    }
    func select(candidateID: UUID) async { lock.withLock { selections += 1 }; emit(.init(phase: .authenticating, message: "Synthetic authentication")) }
    func cancel() async {
        if lateSuccessOnCancel { emitVerified() }
        else if !lock.withLock({ status.pairingMayHaveSucceeded }) { emit(.init(phase: .cancelled, message: "Pairing cancelled")) }
    }
    func close() async {
        await withCheckedContinuation { continuation in
            let paused = lock.withLock {
                closes += 1
                guard pauseNextClose else { return false }
                pauseNextClose = false
                closeWait = continuation
                return true
            }
            if !paused { continuation.resume() }
        }
    }
    func currentStatus() async -> BoltPairingStatus { lock.withLock { status } }
    func pauseClose() { lock.withLock { pauseNextClose = true } }
    func resumeClose() { let wait = lock.withLock { let value = closeWait; closeWait = nil; return value }; wait?.resume() }
    func emitAwaitingSelection() { emit(.init(phase: .awaitingSelection, message: "Synthetic candidate", candidates: [candidate])) }
    func emitVerifying() { emit(.init(phase: .verifying, message: "Synthetic verification")) }
    func emitVerified() { emit(.init(phase: .verified, message: "Mouse paired and verified", verifiedCandidate: verified, pairingMayHaveSucceeded: true)) }
    private func emit(_ next: BoltPairingStatus) {
        let status = BoltPairingStatus(
            phase: next.phase,
            message: next.message,
            candidates: next.candidates,
            challenge: next.challenge,
            verifiedCandidate: next.verifiedCandidate,
            pairingMayHaveSucceeded: next.pairingMayHaveSucceeded,
            discoveryDiagnostics: next.discoveryDiagnostics,
            nativeInputDiagnostics: next.nativeInputDiagnostics,
            notificationSetupMessage: next.notificationSetupMessage,
            notificationCleanupMessage: next.notificationCleanupMessage,
            notificationCleanupRequiresAttention: cleanupRequiresAttention || next.notificationCleanupRequiresAttention
        )
        lock.withLock { self.status = status }
        continuation.yield(status)
    }
}

final class PairingBindingSession: BindingSession, @unchecked Sendable {
    let requiresExplicitAssociation = true
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var recordedTargets: [LogitechConnectionTarget] = []
    private var writes = 0
    private var catalogs = 0
    private var stops = 0
    private var managed = false
    private var probedManaged = false
    private let cleanupSucceeds: Bool
    private var pauseNextStop = false
    private var stopWait: CheckedContinuation<Void, Never>?
    private var candidates: [LogitechEndpointCandidate]
    private var pauseNextCatalog = false
    private var failNextCatalog = false
    private var catalogWait: CheckedContinuation<Void, Never>?

    init(cleanupSucceeds: Bool = true, candidates: [LogitechEndpointCandidate] = []) {
        self.cleanupSucceeds = cleanupSucceeds
        self.candidates = candidates
        let stream = AsyncStream<BoltEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    var targets: [LogitechConnectionTarget] { lock.withLock { recordedTargets } }
    var writeCount: Int { lock.withLock { writes } }
    var catalogReads: Int { lock.withLock { catalogs } }
    var stopCount: Int { lock.withLock { stops } }
    var catalogProbedManagedEndpoint: Bool { lock.withLock { probedManaged } }
    var stopIsPending: Bool { lock.withLock { stopWait != nil } }
    var catalogIsPending: Bool { lock.withLock { catalogWait != nil } }
    func pauseCatalog() { lock.withLock { pauseNextCatalog = true } }
    func failNextCatalogRead() { lock.withLock { failNextCatalog = true } }
    func resumeCatalog() { let wait = lock.withLock { let value = catalogWait; catalogWait = nil; return value }; wait?.resume() }
    func pauseStop() { lock.withLock { pauseNextStop = true } }
    func resumeStop() { let wait = lock.withLock { let value = stopWait; stopWait = nil; return value }; wait?.resume() }
    func updateCandidates(_ candidates: [LogitechEndpointCandidate]) { lock.withLock { self.candidates = candidates } }
    func existingConnections() async throws -> [LogitechEndpointCandidate] {
        let (candidates, shouldFail) = lock.withLock { () -> ([LogitechEndpointCandidate], Bool) in
            catalogs += 1
            probedManaged = managed
            let shouldFail = failNextCatalog
            failNextCatalog = false
            return (self.candidates, shouldFail)
        }
        await withCheckedContinuation { continuation in
            let paused = lock.withLock {
                guard pauseNextCatalog else { return false }
                pauseNextCatalog = false
                catalogWait = continuation
                return true
            }
            if !paused { continuation.resume() }
        }
        if shouldFail { throw PairingBindingError.inventoryUnavailable }
        return candidates
    }
    func discover() async { XCTFail("Pairing used legacy discovery") }
    func discover(target: LogitechConnectionTarget) async { lock.withLock { recordedTargets.append(target); managed = true }; emit(.ready, target: target) }
    func enable() async { lock.withLock { writes += 1 } }
    func disable() async { lock.withLock { writes += 1 } }
    func stop() async {
        lock.withLock { stops += 1 }
        await withCheckedContinuation { continuation in
            let paused = lock.withLock {
                guard pauseNextStop else { return false }
                pauseNextStop = false
                stopWait = continuation
                return true
            }
            if !paused { continuation.resume() }
        }
        lock.withLock { managed = false }
        emit(.idle)
    }
    func stopForRestart() async -> Bool { await stop(); return cleanupSucceeds }
    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool { false }
    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                               amount: Double?, scrollPostingAllowed: Bool) async { lock.withLock { writes += 1 } }
    func applyThumbwheelPreferences(inverted: Bool?, amount: Double?, restorePreviousSettingsOnDisconnect: Bool,
                                    scrollPostingAllowed: Bool) async { lock.withLock { writes += 1 } }
    private func emit(_ phase: BoltPhase, target: LogitechConnectionTarget? = nil) {
        let next = lock.withLock { generation += 1; return generation }
        continuation.yield(.status(.init(phase: phase, message: "Synthetic pairing management", availableControls: [],
                                        generation: next, cleanupUncertain: !cleanupSucceeds,
                                        wheel: .init(support: .supported), supportsManagement: target?.model != .mxMaster4,
                                        model: target?.model, connection: target?.association.preferredConnection,
                                        verifiedIdentity: target?.association.identity)))
    }
}

final class PairingPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var shouldPause = false
    private var shouldFail = false
    private var entered = false
    var hasEntered: Bool { lock.withLock { entered } }
    func pauseNextPublication() { lock.withLock { shouldPause = true } }
    func failNextPublication() { lock.withLock { shouldFail = true } }
    func enter() throws {
        let decision = lock.withLock { () -> (Bool, Bool) in
            let result = (shouldPause, shouldFail)
            shouldPause = false
            shouldFail = false
            if result.0 { entered = true }
            return result
        }
        if decision.0 { semaphore.wait() }
        if decision.1 { throw ConfigurationError.filesystemAccessFailed }
    }
    func release() { semaphore.signal() }
}

private enum PairingBindingError: Error {
    case inventoryUnavailable
}
