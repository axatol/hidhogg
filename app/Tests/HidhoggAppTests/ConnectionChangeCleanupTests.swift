import Foundation
@testable import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class ConnectionChangeCleanupTests: XCTestCase {
    func testBlockedLocalStopDoesNotReadInventoryOrStartPairing() async throws {
        let device = try makeDevice()
        let pairing = ConnectionChangePairingSession()
        let fixture = try await makeFixture(devices: [device], stopResult: .blocked, pairing: pairing)
        defer { fixture.remove() }

        fixture.model.presentLogitechSetup(destination: .reassociate(device.id))
        await waitUntil { !fixture.model.isLogitechSetupLoading }

        XCTAssertEqual(fixture.binding.connectionChangeStopCount, 1)
        XCTAssertEqual(fixture.binding.inventoryReadCount, 0)
        XCTAssertTrue(fixture.model.logitechSetupMessage?.contains("not started") == true)

        fixture.model.pairLogitechSetup()
        await waitUntil {
            fixture.binding.connectionChangeStopCount == 2 && !fixture.model.isBoltPairingInProgress
        }

        XCTAssertEqual(pairing.receiverReadCount, 0)
        XCTAssertEqual(fixture.binding.inventoryReadCount, 0)
        XCTAssertEqual(fixture.model.registration(id: device.id)?.logitechAssociation, device.logitechAssociation)
    }

    func testUnverifiedRemoteCleanupAllowsPairingAndClearsWarningOnlyAfterFreshReadyGeneration() async throws {
        try await assertSameIdentityReplacement(model: .mxMaster3S, generation: 71)
    }

    func testMXMaster4ReplacementRetainsRegistrationAndSettingsUntilFreshReady() async throws {
        try await assertSameIdentityReplacement(model: .mxMaster4, generation: 72)
    }

    private func assertSameIdentityReplacement(model: LogitechMouseModel, generation: UInt64) async throws {
        let device = try makeDevice(model: model)
        let association = try XCTUnwrap(device.logitechAssociation)
        let candidate = endpoint(identity: association.identity, model: model)
        let target = LogitechConnectionTarget(model: model, association: association)
        let pairing = ConnectionChangePairingSession(verifiedCandidate: candidate)
        let fixture = try await makeFixture(
            devices: [device],
            candidates: [],
            stopResult: .locallyStopped(generation: generation, remoteCleanup: .unverified(target: target)),
            pairing: pairing
        )
        defer { fixture.remove() }

        fixture.model.presentLogitechSetup(destination: .reassociate(device.id))
        await waitUntil { !fixture.model.isLogitechSetupLoading && fixture.model.logitechCleanupWarning != nil }
        XCTAssertEqual(fixture.binding.inventoryReadCount, 1)
        XCTAssertTrue(fixture.model.logitechSetupCandidates.isEmpty)

        await beginPairing(fixture)
        XCTAssertEqual(pairing.receiverReadCount, 1)
        XCTAssertEqual(pairing.candidateSelectionCount, 1)
        XCTAssertTrue(fixture.binding.candidates.isEmpty)

        pairing.emitVerified(candidate)
        await waitUntil {
            fixture.model.navigation.current.route == .mouse(device.id) &&
                fixture.binding.discoveredTargets.count == 1
        }

        let saved = try await fixture.store.load()
        let updated = try XCTUnwrap(saved.workspace.devices.first { $0.id == device.id })
        XCTAssertEqual(updated.id, device.id)
        XCTAssertEqual(updated.displayName, device.displayName)
        XCTAssertEqual(updated.configuration, device.configuration)
        XCTAssertEqual(updated.logitechAssociation, association)
        XCTAssertEqual(updated.mouseModel, model)
        XCTAssertEqual(fixture.model.presentedMouseOwnerID, nil)

        fixture.binding.emitStatus(.ready, generation: generation, target: target)
        await waitUntil { fixture.model.boltStatus.phase == .ready && fixture.model.boltStatus.generation == generation }
        XCTAssertNotNil(fixture.model.logitechCleanupWarning)

        fixture.binding.emitStatus(.ready, generation: generation + 1, target: target)
        await waitUntil {
            fixture.model.logitechCleanupWarning == nil &&
                fixture.model.selectedMouseStatus.phase == .ready &&
                fixture.model.presentedMouseOwnerID == device.id
        }
    }

    func testRefreshRaisesPendingGenerationFloorBeforeDelayedReadyCanClearOrReassociate() async throws {
        let targetGeneration: UInt64 = 10
        let device = try makeDevice()
        let association = try XCTUnwrap(device.logitechAssociation)
        let target = LogitechConnectionTarget(model: .mxMaster3S, association: association)
        let replacementIdentity = LogitechIdentity(unitID: "87654321", modelID: "123456789abc")
        let differentCandidate = endpoint(identity: replacementIdentity)
        let replacementTarget = LogitechConnectionTarget(
            model: .mxMaster3S,
            association: LogitechAssociation(identity: replacementIdentity, preferredConnection: .bolt)
        )
        let pairing = ConnectionChangePairingSession()
        let fixture = try await makeFixture(
            devices: [device],
            connectOnLaunch: true,
            preferredMouseID: device.id,
            stopResult: .locallyStopped(generation: targetGeneration, remoteCleanup: .unverified(target: target)),
            pairing: pairing
        )
        defer { fixture.remove() }

        await waitUntil { fixture.binding.discoveredTargets.count == 1 }

        fixture.model.presentLogitechSetup(destination: .reassociate(device.id))
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && fixture.model.logitechCleanupWarning != nil &&
                fixture.model.boltStatus.generation == targetGeneration
        }

        fixture.binding.bufferStatus(.ready, generation: targetGeneration + 1, target: target)
        fixture.binding.updateStopResult(
            .locallyStopped(generation: targetGeneration + 2, remoteCleanup: .unverified(target: replacementTarget))
        )
        fixture.binding.bufferNextConnectionChangeStatus()
        fixture.binding.updateCandidates([differentCandidate])
        fixture.model.refreshLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && fixture.binding.inventoryReadCount == 2 &&
                fixture.model.logitechSetupCandidates == [differentCandidate]
        }

        fixture.binding.emitBufferedStatus(generation: targetGeneration + 1)
        await waitUntil { fixture.model.boltStatus.generation == targetGeneration + 1 }
        XCTAssertNotNil(fixture.model.logitechCleanupWarning)

        fixture.model.addLogitechSetupCandidate(differentCandidate.id)
        await waitUntil {
            !fixture.model.isLogitechSetupLoading &&
                fixture.model.logitechSetupMessage?.contains("unresolved cleanup") == true
        }
        XCTAssertEqual(fixture.model.registration(id: device.id)?.logitechAssociation, association)
        XCTAssertEqual(fixture.model.registeredDevices.map(\.id), [device.id])
        XCTAssertEqual(fixture.binding.discoveredTargets.count, 1)
        XCTAssertNotNil(fixture.model.logitechCleanupWarning)

        fixture.binding.emitBufferedStatus(generation: targetGeneration + 2)
        await waitUntil { fixture.model.boltStatus.generation == targetGeneration + 2 }
        XCTAssertNotNil(fixture.model.logitechCleanupWarning)

        fixture.binding.emitStatus(.ready, generation: targetGeneration + 3, target: target)
        await waitUntil { fixture.model.logitechCleanupWarning == nil }
    }

    func testRemovingAndReaddingSameIdentityRemapsRecoveryToNewRegistrationID() async throws {
        let generation: UInt64 = 81
        let device = try makeDevice()
        let association = try XCTUnwrap(device.logitechAssociation)
        let target = LogitechConnectionTarget(model: .mxMaster3S, association: association)
        let candidate = endpoint(identity: association.identity)
        let pairing = ConnectionChangePairingSession(verifiedCandidate: candidate)
        let clock = ConnectionChangeTestClock()
        let fixture = try await makeFixture(
            devices: [device],
            stopResult: .locallyStopped(generation: generation, remoteCleanup: .unverified(target: target)),
            pairing: pairing,
            clock: clock
        )
        defer { fixture.remove() }

        let priorRoute = fixture.model.navigation.current.route
        fixture.model.presentLogitechSetup(destination: .reassociate(device.id))
        await waitUntil { !fixture.model.isLogitechSetupLoading && fixture.model.logitechCleanupWarning != nil }
        fixture.model.cancelLogitechSetup()
        await waitUntil { fixture.model.navigation.current.route == priorRoute }

        fixture.model.removeDevice(device.id)
        let removalSaved = await fixture.model.flushPendingSave()
        XCTAssertTrue(removalSaved)
        let afterRemoval = try await fixture.store.load()
        XCTAssertTrue(afterRemoval.workspace.devices.isEmpty)

        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading && fixture.model.logitechCleanupWarning != nil }
        await beginPairing(fixture)
        pairing.emitVerified(candidate)
        await waitUntil {
            fixture.model.selectedMouseID != nil &&
                fixture.model.selectedMouseID != device.id &&
                fixture.binding.discoveredTargets.count == 1
        }

        let replacementID = try XCTUnwrap(fixture.model.selectedMouseID)
        let saved = try await fixture.store.load()
        XCTAssertEqual(saved.workspace.devices.map(\.id), [replacementID])
        XCTAssertEqual(saved.workspace.devices.first?.logitechAssociation, association)
        XCTAssertEqual(fixture.model.logitechCleanupWarning != nil, true)

        fixture.binding.emitStatus(.failed, generation: generation + 1, target: target, cleanupUncertain: true)
        await waitUntil { clock.pendingRecoveryDelays == 1 }
        clock.advanceRecoveryDelay()
        await waitUntil { fixture.binding.discoveredTargets.count == 2 && clock.pendingStatusTimeouts == 1 }

        let recoveryTarget = try XCTUnwrap(fixture.binding.discoveredTargets.last)
        XCTAssertEqual(recoveryTarget.model, .mxMaster3S)
        XCTAssertEqual(recoveryTarget.association, association)

        fixture.binding.emitStatus(.ready, generation: generation + 2, target: target)
        await waitUntil {
            fixture.model.logitechCleanupWarning == nil &&
                fixture.model.selectedMouseStatus.phase == .ready &&
                !fixture.model.isReconnectPending
        }
        clock.releaseAll()
    }

    func testDifferentOrUnknownVerifiedIdentityIsNotPublishedOrActivated() async throws {
        let generation: UInt64 = 91
        let device = try makeDevice()
        let association = try XCTUnwrap(device.logitechAssociation)
        let target = LogitechConnectionTarget(model: .mxMaster3S, association: association)
        let candidates = [
            endpoint(identity: .init(unitID: "87654321", modelID: "123456789abc")),
            endpoint(identity: .init(unitID: "00000000", modelID: "000000000000"))
        ]

        for candidate in candidates {
            let pairing = ConnectionChangePairingSession(verifiedCandidate: candidate)
            let fixture = try await makeFixture(
                devices: [device],
                candidates: [],
                stopResult: .locallyStopped(generation: generation, remoteCleanup: .unverified(target: target)),
                pairing: pairing
            )
            defer { fixture.remove() }

            fixture.model.presentLogitechSetup(destination: .reassociate(device.id))
            await waitUntil { !fixture.model.isLogitechSetupLoading && fixture.model.logitechCleanupWarning != nil }
            await beginPairing(fixture)
            pairing.emitVerified(candidate)
            await waitUntil {
                !fixture.model.isBoltPairingInProgress &&
                    fixture.model.boltPairingMessage?.contains("not managed by Hidhogg") == true
            }

            XCTAssertEqual(fixture.model.registration(id: device.id)?.logitechAssociation, association)
            XCTAssertEqual(fixture.model.registeredDevices.map(\.id), [device.id])
            XCTAssertTrue(fixture.binding.discoveredTargets.isEmpty)
            XCTAssertNotNil(fixture.model.logitechCleanupWarning)
        }
    }

    func testCancellationAndSaveConflictPreserveOldAssociationAndRecoveryWarning() async throws {
        let generation: UInt64 = 101
        let device = try makeDevice()
        let association = try XCTUnwrap(device.logitechAssociation)
        let target = LogitechConnectionTarget(model: .mxMaster3S, association: association)

        do {
            let pairing = ConnectionChangePairingSession(verifiedCandidate: endpoint(identity: association.identity))
            let fixture = try await makeFixture(
                devices: [device],
                stopResult: .locallyStopped(generation: generation, remoteCleanup: .unverified(target: target)),
                pairing: pairing
            )
            defer { fixture.remove() }

            fixture.model.presentLogitechSetup(destination: .reassociate(device.id))
            await waitUntil { !fixture.model.isLogitechSetupLoading && fixture.model.logitechCleanupWarning != nil }
            fixture.model.pairLogitechSetup()
            await waitUntil { fixture.model.boltPairingStatus?.phase == .awaitingSelection }
            fixture.model.cancelLogitechSetupPairing()
            await waitUntil { !fixture.model.isBoltPairingInProgress && !fixture.model.isLogitechSetupLoading }

            XCTAssertEqual(fixture.model.registration(id: device.id)?.logitechAssociation, association)
            XCTAssertNotNil(fixture.model.logitechCleanupWarning)
            XCTAssertTrue(fixture.binding.discoveredTargets.isEmpty)
        }

        do {
            let candidate = endpoint(identity: association.identity)
            let pairing = ConnectionChangePairingSession(verifiedCandidate: candidate)
            let fixture = try await makeFixture(
                devices: [device],
                stopResult: .locallyStopped(generation: generation, remoteCleanup: .unverified(target: target)),
                pairing: pairing
            )
            defer { fixture.remove() }

            fixture.model.presentLogitechSetup(destination: .reassociate(device.id))
            await waitUntil { !fixture.model.isLogitechSetupLoading && fixture.model.logitechCleanupWarning != nil }
            await beginPairing(fixture)

            let disk = try await fixture.store.load()
            var concurrentWorkspace = disk.workspace
            concurrentWorkspace.connectOnLaunch.toggle()
            _ = try await fixture.store.save(concurrentWorkspace, expecting: disk.revision)
            pairing.emitVerified(candidate)
            await waitUntil {
                !fixture.model.isBoltPairingInProgress &&
                    fixture.model.configurationFailureKind == .conflict
            }

            XCTAssertEqual(fixture.model.registration(id: device.id)?.logitechAssociation, association)
            XCTAssertEqual(fixture.model.registeredDevices.map(\.id), [device.id])
            XCTAssertTrue(fixture.binding.discoveredTargets.isEmpty)
            XCTAssertNotNil(fixture.model.logitechCleanupWarning)
            XCTAssertTrue(fixture.model.boltPairingMessage?.contains("not managed by Hidhogg") == true)
            let persisted = try await fixture.store.load()
            XCTAssertEqual(persisted.workspace.devices.first?.logitechAssociation, association)
        }
    }

    private func beginPairing(_ fixture: Fixture) async {
        fixture.model.pairLogitechSetup()
        await waitUntil { fixture.model.boltPairingStatus?.phase == .awaitingSelection }
        fixture.model.selectBoltPairingCandidate(fixture.pairing.candidate.id)
        await waitUntil { fixture.pairing.candidateSelectionCount == 1 }
    }

    private func makeFixture(
        devices: [RegisteredDevice],
        candidates: [LogitechEndpointCandidate] = [],
        connectOnLaunch: Bool = false,
        preferredMouseID: UUID? = nil,
        stopResult: BoltConnectionChangeStopResult,
        pairing: ConnectionChangePairingSession,
        clock: ConnectionChangeTestClock = ConnectionChangeTestClock()
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("configuration.toml")
        let store = ConfigurationStore(url: url)
        let initialWorkspace = WorkspaceConfiguration(
            connectOnLaunch: connectOnLaunch,
            devices: devices,
            preferredMouseID: preferredMouseID
        )
        _ = try await store.save(initialWorkspace, expecting: .missing)
        let binding = ConnectionChangeBindingSession(candidates: candidates, stopResult: stopResult)
        let model = AppModel(
            configurationURL: url,
            store: store,
            bolt: binding,
            makeBoltPairingSession: { @Sendable in pairing },
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
            loadImmediately: true,
            observeSleep: false,
            wakeDelay: { duration in try await clock.recoveryDelay(duration) },
            wakeStatusTimeout: { duration in try await clock.statusTimeout(duration) },
            frontmostApplication: { nil }
        )
        await waitUntil { !model.isLoading }
        return Fixture(root: root, store: store, binding: binding, pairing: pairing, model: model)
    }

    private func makeDevice(
        identity: LogitechIdentity = .init(unitID: "12345678", modelID: "123456789abc"),
        model: LogitechMouseModel = .mxMaster3S
    ) throws -> RegisteredDevice {
        var device = try XCTUnwrap(RegisteredDevice.make(family: model.family))
        device.displayName = "Configured mouse"
        if case .mouse(var configuration) = device.configuration {
            configuration.wheelInverted = true
            configuration.defaults["back"] = .key(.init(keyCode: 12))
            device.configuration = .mouse(configuration)
        }
        device.logitechAssociation = LogitechAssociation(identity: identity, preferredConnection: .bolt)
        return device
    }

    private func endpoint(
        identity: LogitechIdentity,
        model: LogitechMouseModel = .mxMaster3S
    ) -> LogitechEndpointCandidate {
        .init(id: UUID(), connection: .bolt, model: model, identity: identity)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Connection change condition did not settle", file: file, line: line)
    }

    private struct Fixture {
        let root: URL
        let store: ConfigurationStore
        let binding: ConnectionChangeBindingSession
        let pairing: ConnectionChangePairingSession
        let model: AppModel

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class ConnectionChangeBindingSession: BindingSession, @unchecked Sendable {
    let requiresExplicitAssociation = true
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var inventoryCandidates: [LogitechEndpointCandidate]
    private var stopResult: BoltConnectionChangeStopResult
    private var inventoryReads = 0
    private var connectionChangeStops = 0
    private var buffersNextStopStatus = false
    private var bufferedStatuses: [(UInt64, BoltEvent)] = []
    private var recordedTargets: [LogitechConnectionTarget] = []

    init(candidates: [LogitechEndpointCandidate], stopResult: BoltConnectionChangeStopResult) {
        inventoryCandidates = candidates
        self.stopResult = stopResult
        let stream = AsyncStream<BoltEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    var inventoryReadCount: Int { lock.withLock { inventoryReads } }
    var connectionChangeStopCount: Int { lock.withLock { connectionChangeStops } }
    var candidates: [LogitechEndpointCandidate] { lock.withLock { inventoryCandidates } }
    var discoveredTargets: [LogitechConnectionTarget] { lock.withLock { recordedTargets } }

    func existingConnections() async throws -> [LogitechEndpointCandidate] {
        lock.withLock {
            inventoryReads += 1
            return inventoryCandidates
        }
    }

    func updateCandidates(_ candidates: [LogitechEndpointCandidate]) {
        lock.withLock { inventoryCandidates = candidates }
    }

    func updateStopResult(_ result: BoltConnectionChangeStopResult) {
        lock.withLock { stopResult = result }
    }

    func bufferNextConnectionChangeStatus() {
        lock.withLock { buffersNextStopStatus = true }
    }

    func bufferStatus(
        _ phase: BoltPhase,
        generation: UInt64,
        target: LogitechConnectionTarget,
        cleanupUncertain: Bool = false
    ) {
        let event = statusEvent(phase, generation: generation, target: target, cleanupUncertain: cleanupUncertain)
        lock.withLock { bufferedStatuses.append((generation, event)) }
    }

    func emitBufferedStatus(generation: UInt64) {
        let event = lock.withLock { () -> BoltEvent? in
            guard let index = bufferedStatuses.firstIndex(where: { $0.0 == generation }) else { return nil }
            return bufferedStatuses.remove(at: index).1
        }
        if let event { continuation.yield(event) }
    }

    func discover(target: LogitechConnectionTarget) async {
        lock.withLock { recordedTargets.append(target) }
    }

    func discover() async {}
    func enable() async {}
    func disable() async {}
    func stop() async {}
    func stopForRestart() async -> Bool { true }
    func stopForRestart(restorePreviousSettingsOnDisconnect: Bool) async -> Bool { true }
    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool { false }

    func stopForConnectionChange(
        restorePreviousSettingsOnDisconnect: Bool
    ) async -> BoltConnectionChangeStopResult {
        let result = lock.withLock { () -> BoltConnectionChangeStopResult in
            connectionChangeStops += 1
            return stopResult
        }
        if case let .locallyStopped(generation, remoteCleanup) = result {
            let target: LogitechConnectionTarget?
            let cleanupUncertain: Bool
            switch remoteCleanup {
            case .verified:
                target = nil
                cleanupUncertain = false
            case .unverified(let unresolvedTarget):
                target = unresolvedTarget
                cleanupUncertain = true
            }
            let event = statusEvent(.idle, generation: generation, target: target, cleanupUncertain: cleanupUncertain)
            let buffered = lock.withLock { () -> Bool in
                guard buffersNextStopStatus else { return false }
                buffersNextStopStatus = false
                bufferedStatuses.append((generation, event))
                return true
            }
            if !buffered { continuation.yield(event) }
        }
        return result
    }

    func emitStatus(
        _ phase: BoltPhase,
        generation: UInt64,
        target: LogitechConnectionTarget,
        cleanupUncertain: Bool = false
    ) {
        continuation.yield(statusEvent(phase, generation: generation, target: target, cleanupUncertain: cleanupUncertain))
    }

    private func statusEvent(
        _ phase: BoltPhase,
        generation: UInt64,
        target: LogitechConnectionTarget?,
        cleanupUncertain: Bool
    ) -> BoltEvent {
        .status(BoltStatus(
            phase: phase,
            message: "Synthetic connection change",
            availableControls: [],
            generation: generation,
            cleanupUncertain: cleanupUncertain,
            model: target?.model,
            connection: target?.association.preferredConnection,
            verifiedIdentity: target?.association.identity
        ))
    }
}

private final class ConnectionChangePairingSession: BoltPairingManaging, @unchecked Sendable {
    let candidate: BoltPairingCandidate
    let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
    let events: AsyncStream<BoltPairingStatus>
    private let continuation: AsyncStream<BoltPairingStatus>.Continuation
    private let lock = NSLock()
    private var status = BoltPairingStatus(phase: .idle, message: "Synthetic pairing")
    private var receiversRead = 0
    private var candidateSelections = 0
    private let initialVerifiedCandidate: LogitechEndpointCandidate?

    init(verifiedCandidate: LogitechEndpointCandidate? = nil) {
        initialVerifiedCandidate = verifiedCandidate
        candidate = BoltPairingCandidate(
            id: UUID(),
            name: "Synthetic mouse",
            model: verifiedCandidate?.model ?? .mxMaster3S
        )
        let stream = AsyncStream<BoltPairingStatus>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    var receiverReadCount: Int { lock.withLock { receiversRead } }
    var candidateSelectionCount: Int { lock.withLock { candidateSelections } }

    func currentStatus() async -> BoltPairingStatus { lock.withLock { status } }

    func receivers() async throws -> [BoltReceiverCandidate] {
        lock.withLock { receiversRead += 1 }
        return [receiver]
    }

    func start(receiverID: UUID) async {
        publish(.init(phase: .awaitingSelection, message: "Synthetic candidate", candidates: [candidate]))
    }

    func select(candidateID: UUID) async {
        lock.withLock { candidateSelections += 1 }
        publish(.init(phase: .authenticating, message: "Synthetic authentication"))
    }

    func cancel() async {
        publish(.init(phase: .cancelled, message: "Synthetic cancellation"))
    }

    func close() async {}

    func emitVerified(_ candidate: LogitechEndpointCandidate? = nil) {
        guard let candidate = candidate ?? initialVerifiedCandidate else { return }
        publish(.init(phase: .verified, message: "Synthetic identity verified",
                      verifiedCandidate: candidate, pairingMayHaveSucceeded: true))
    }

    private func publish(_ next: BoltPairingStatus) {
        lock.withLock { status = next }
        continuation.yield(next)
    }
}

@MainActor
private final class ConnectionChangeTestClock {
    private enum WaitKind: Equatable { case recovery, statusTimeout }

    private struct Waiter {
        let id: UUID
        let kind: WaitKind
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []
    private var cancelledWaiters: Set<UUID> = []

    var pendingRecoveryDelays: Int { waiters.filter { $0.kind == .recovery }.count }
    var pendingStatusTimeouts: Int { waiters.filter { $0.kind == .statusTimeout }.count }

    func recoveryDelay(_ duration: Duration) async throws { await wait(kind: .recovery) }
    func statusTimeout(_ duration: Duration) async throws { await wait(kind: .statusTimeout) }

    func advanceRecoveryDelay() {
        guard let index = waiters.firstIndex(where: { $0.kind == .recovery }) else { return }
        waiters.remove(at: index).continuation.resume()
    }

    func releaseAll() {
        while !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
    }

    private func wait(kind: WaitKind) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(Waiter(id: UUID(), kind: kind, continuation: continuation))
        }
    }
}
