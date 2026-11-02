import Foundation
@testable import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class BoltReceiverManagementIntegrationTests: XCTestCase {
    func testSetupWaitsForExistingConnectionsThenCachesAllInventoriesSerially() async throws {
        let first = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver 1")
        let second = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver 2")
        let firstInventory = inventory(receiverID: first.id, rowCount: 1)
        let secondInventory = inventory(receiverID: second.id, rowCount: 2)
        let management = SyntheticBoltReceiverManagementSession(
            receivers: [first, second], inventories: [first.id: firstInventory, second.id: secondInventory]
        )
        let fixture = try await makeFixture(managementSessions: [management])
        defer { fixture.remove() }
        fixture.binding.pauseCatalog()
        fixture.model.presentLogitechSetup()

        await waitUntil { fixture.binding.catalogIsPending }
        XCTAssertEqual(management.receiverReadCount, 0)
        fixture.binding.resumeCatalog()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltStoredInventories.count == 2
        }

        XCTAssertEqual(management.inventoryReceiverIDs, [first.id, second.id])
        XCTAssertEqual(management.maximumConcurrentInventoryReads, 1)
        XCTAssertEqual(fixture.model.boltStoredInventories, [firstInventory, secondInventory])
        XCTAssertEqual(fixture.model.boltStoredReceiverLabels, [first.id: first.label, second.id: second.label])
        XCTAssertEqual(fixture.model.boltManagedInventory, secondInventory)
        XCTAssertFalse(fixture.model.isBoltManagedInventoryStale)
        XCTAssertFalse(fixture.model.canUnpairStoredRecord(inventoryID: firstInventory.id,
                                                           recordID: try XCTUnwrap(firstInventory.rows.first).id))
        XCTAssertTrue(fixture.model.canUnpairStoredRecord(inventoryID: secondInventory.id,
                                                          recordID: try XCTUnwrap(secondInventory.rows.first).id))

        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
    }

    func testPairingRetainsLastReadInventoriesStaleUntilRefresh() async throws {
        let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
        let refreshedReceiver = BoltReceiverCandidate(id: UUID(), label: "Replacement receiver")
        let lastRead = inventory(receiverID: receiver.id)
        let refreshed = inventory(receiverID: refreshedReceiver.id, rowCount: 2)
        let management = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: lastRead]
        )
        let refreshedManagement = SyntheticBoltReceiverManagementSession(
            receivers: [refreshedReceiver], inventories: [refreshedReceiver.id: refreshed]
        )
        let pairing = SyntheticReceiverManagementFailurePairing()
        let fixture = try await makeFixture(managementSessions: [management, refreshedManagement], pairing: pairing)
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltStoredInventories == [lastRead]
        }
        let originalWorkspace = fixture.model.workspace
        let savedBefore = try await fixture.store.load()
        let lastReadRow = try XCTUnwrap(lastRead.rows.first)
        XCTAssertTrue(fixture.model.canUnpairStoredRecord(inventoryID: lastRead.id, recordID: lastReadRow.id))

        management.pauseNextClose()
        fixture.model.pairLogitechSetup()
        await waitUntil { management.closeIsPending }
        XCTAssertEqual(pairing.receiverReadCount, 0)
        XCTAssertEqual(fixture.model.boltStoredInventories, [lastRead])
        XCTAssertEqual(fixture.model.boltStoredReceiverLabels, [receiver.id: receiver.label])
        XCTAssertTrue(fixture.model.isBoltManagedInventoryStale)
        XCTAssertNil(fixture.model.boltManagedInventory)
        XCTAssertFalse(fixture.model.canUnpairStoredRecord(inventoryID: lastRead.id, recordID: lastReadRow.id))
        fixture.model.unpairBoltManagedRecord(recordID: lastReadRow.id, inventoryID: lastRead.id)
        XCTAssertEqual(management.unpairCallCount, 0)
        XCTAssertEqual(management.writeCount, 0)

        management.resumeClose()
        await waitUntil { !fixture.model.isBoltPairingInProgress && pairing.startCount == 1 }
        XCTAssertEqual(pairing.receiverReadCount, 1)
        XCTAssertEqual(fixture.model.boltPairingStatus?.phase, .failed)
        XCTAssertEqual(management.closeCount, 1)
        XCTAssertEqual(fixture.model.boltStoredInventories, [lastRead])
        XCTAssertTrue(fixture.model.isBoltManagedInventoryStale)
        XCTAssertEqual(fixture.model.workspace, originalWorkspace)
        let savedAfterPairing = try await fixture.store.load()
        XCTAssertEqual(savedAfterPairing.workspace, savedBefore.workspace)

        fixture.model.inspectBoltReceivers()
        await waitUntil {
            !fixture.model.isBoltReceiverManagementBusy && fixture.model.boltManagedInventory == refreshed &&
                !fixture.model.isBoltManagedInventoryStale
        }
        let refreshedRow = try XCTUnwrap(refreshed.rows.first)
        XCTAssertEqual(fixture.model.boltStoredInventories, [refreshed])
        XCTAssertEqual(fixture.model.boltStoredReceiverLabels, [refreshedReceiver.id: refreshedReceiver.label])
        XCTAssertTrue(fixture.model.canUnpairStoredRecord(inventoryID: refreshed.id, recordID: refreshedRow.id))
        XCTAssertFalse(fixture.model.canUnpairStoredRecord(inventoryID: lastRead.id, recordID: lastReadRow.id))
        fixture.model.unpairBoltManagedRecord(recordID: lastReadRow.id, inventoryID: lastRead.id)
        XCTAssertEqual(refreshedManagement.unpairCallCount, 0)
        XCTAssertEqual(refreshedManagement.writeCount, 0)
        XCTAssertEqual(fixture.model.workspace, originalWorkspace)
        let savedAfterRefresh = try await fixture.store.load()
        XCTAssertEqual(savedAfterRefresh.workspace, savedBefore.workspace)

        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
    }

    func testPairingCancellationKeepsInventoryStaleUntilExplicitRefresh() async throws {
        let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
        let lastRead = inventory(receiverID: receiver.id)
        let refreshed = inventory(receiverID: receiver.id, rowCount: 2)
        let management = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: lastRead]
        )
        let refreshedManagement = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: refreshed]
        )
        let pairing = SyntheticReceiverManagementFailurePairing()
        let fixture = try await makeFixture(managementSessions: [management, refreshedManagement], pairing: pairing)
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltStoredInventories == [lastRead]
        }

        let row = try XCTUnwrap(lastRead.rows.first)
        pairing.pauseNextStart()
        fixture.model.pairLogitechSetup()
        await waitUntil { pairing.startIsPending }
        fixture.model.cancelLogitechSetupPairing()
        await waitUntil {
            !fixture.model.isBoltPairingInProgress && !fixture.model.isLogitechSetupLoading
        }

        XCTAssertEqual(management.closeCount, 1)
        XCTAssertEqual(fixture.model.boltStoredInventories, [lastRead])
        XCTAssertTrue(fixture.model.isBoltManagedInventoryStale)
        XCTAssertNil(fixture.model.boltManagedInventory)
        fixture.model.unpairBoltManagedRecord(recordID: row.id, inventoryID: lastRead.id)
        XCTAssertEqual(management.unpairCallCount, 0)
        XCTAssertEqual(management.writeCount, 0)

        fixture.model.inspectBoltReceivers()
        await waitUntil {
            !fixture.model.isBoltReceiverManagementBusy && fixture.model.boltManagedInventory == refreshed &&
                !fixture.model.isBoltManagedInventoryStale
        }
        XCTAssertEqual(fixture.model.boltStoredInventories, [refreshed])
        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
    }

    func testVerifiedUnpairRequiresExactSnapshotRetainsSettingsAndAllowsPairingAgain() async throws {
        let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
        let selectedRow = BoltReceiverInventoryRow(id: UUID(), slot: 2, label: "Offline MX Master 3S", isReachable: false)
        let remainingRow = BoltReceiverInventoryRow(id: UUID(), slot: 4, label: "MX Anywhere 3", isReachable: true)
        let inventory = BoltReceiverInventory(id: UUID(), receiverID: receiver.id, capacity: 6, rows: [selectedRow, remainingRow])
        let updatedInventory = BoltReceiverInventory(id: UUID(), receiverID: receiver.id, capacity: 6, rows: [remainingRow])
        let management = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory], outcome: .verifiedRemoved(updatedInventory)
        )
        let refreshedManagement = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory], outcome: .verifiedRemoved(updatedInventory)
        )
        let recoveryManagement = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: updatedInventory]
        )
        let candidate = endpointCandidate()
        var device = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        device.displayName = "Saved mouse"
        if case .mouse(var configuration) = device.configuration {
            configuration.wheelInverted = true
            configuration.defaults["back"] = .key(.init(keyCode: 12))
            device.configuration = .mouse(configuration)
        }
        let pairing = SyntheticReceiverManagementFailurePairing()
        let retryPairing = SyntheticReceiverManagementFailurePairing()
        let fixture = try await makeFixture(candidates: [candidate], devices: [device],
                                            managementSessions: [management, refreshedManagement, recoveryManagement],
                                            pairing: pairing, pairingSessions: [pairing, retryPairing])
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltManagedInventory == inventory
        }
        let before = fixture.model.workspace
        let savedBefore = try await fixture.store.load()

        fixture.model.pairLogitechSetup()
        await waitUntil { !fixture.model.isBoltPairingInProgress && pairing.startCount == 1 }
        XCTAssertEqual(fixture.model.boltPairingStatus?.phase, .failed)

        fixture.model.inspectBoltReceivers()
        await waitUntil { !fixture.model.isBoltReceiverManagementBusy && fixture.model.boltManagedInventory == inventory }
        let currentInventory = try XCTUnwrap(fixture.model.boltManagedInventory)
        XCTAssertTrue(fixture.model.canUnpairStoredRecord(inventoryID: currentInventory.id, recordID: selectedRow.id))
        fixture.model.unpairBoltManagedRecord(recordID: selectedRow.id, inventoryID: UUID())
        fixture.model.unpairBoltManagedRecord(recordID: UUID(), inventoryID: currentInventory.id)
        XCTAssertEqual(refreshedManagement.unpairCallCount, 0)

        fixture.model.unpairBoltManagedRecord(recordID: selectedRow.id, inventoryID: currentInventory.id)
        await waitUntil { !fixture.model.isBoltReceiverManagementBusy }
        XCTAssertEqual(refreshedManagement.unpairCallCount, 1)
        XCTAssertEqual(refreshedManagement.writeCount, 1)
        XCTAssertEqual(refreshedManagement.lastUnpairRecordID, selectedRow.id)
        XCTAssertEqual(refreshedManagement.lastUnpairInventoryID, currentInventory.id)
        XCTAssertEqual(fixture.model.boltManagedInventory, updatedInventory)
        XCTAssertTrue(fixture.model.logitechSetupCandidates.isEmpty)
        XCTAssertEqual(fixture.model.logitechSetupMessage, "Refresh Devices before adding a mouse.")
        XCTAssertNil(fixture.model.boltPairingStatus)
        XCTAssertNil(fixture.model.boltPairingMessage)
        XCTAssertTrue(fixture.model.isLogitechSetupSelectionBlocked)
        XCTAssertEqual(fixture.model.workspace, before)
        let savedAfter = try await fixture.store.load()
        XCTAssertEqual(savedAfter.workspace, savedBefore.workspace)

        fixture.model.refreshLogitechSetup()
        await waitUntil {
            fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading &&
                !fixture.model.isBoltReceiverManagementBusy && recoveryManagement.receiverReadCount == 1 &&
                fixture.model.boltManagedInventory == updatedInventory &&
                !fixture.model.requiresLogitechSetupRefreshBeforePairing
        }
        XCTAssertFalse(fixture.model.isLogitechSetupSelectionBlocked)

        fixture.model.pairLogitechSetup()
        await waitUntil { retryPairing.startCount == 1 && !fixture.model.isBoltPairingInProgress }
        XCTAssertEqual(fixture.model.boltPairingStatus?.phase, .failed)
        fixture.model.dismissBoltPairing()
        await waitUntil { !fixture.model.isBoltPairingInProgress }
        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
    }

    func testReceiverSelectionSwitchesWithinTheInspectedSession() async throws {
        let first = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver 1")
        let second = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver 2")
        let firstInventory = inventory(receiverID: first.id, rowCount: 1)
        let secondInventory = inventory(receiverID: second.id, rowCount: 2)
        let management = SyntheticBoltReceiverManagementSession(
            receivers: [first, second], inventories: [first.id: firstInventory, second.id: secondInventory]
        )
        let fixture = try await makeFixture(managementSessions: [management])
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltStoredInventories.count == 2
        }
        XCTAssertEqual(fixture.model.boltManagedInventory, secondInventory)
        fixture.model.selectBoltManagedReceiver(first.id)
        await waitUntil { !fixture.model.isBoltReceiverManagementBusy && fixture.model.boltManagedInventory?.receiverID == first.id }
        fixture.model.selectBoltManagedReceiver(second.id)
        await waitUntil { !fixture.model.isBoltReceiverManagementBusy && fixture.model.boltManagedInventory?.receiverID == second.id }

        XCTAssertEqual(management.inventoryReceiverIDs, [first.id, second.id, first.id, second.id])
        XCTAssertEqual(management.closeCount, 0)
        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
        XCTAssertEqual(management.closeCount, 1)
    }

    func testInventoryWaitsForRuntimeCleanupAndRejectsAnOverlappingSetupScan() async throws {
        let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
        let management = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory(receiverID: receiver.id)]
        )
        let refreshedManagement = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory(receiverID: receiver.id)]
        )
        let fixture = try await makeFixture(managementSessions: [management, refreshedManagement])
        defer { fixture.remove() }
        fixture.binding.pauseStop()
        fixture.model.presentLogitechSetup()
        await waitUntil { fixture.binding.stopIsPending }
        XCTAssertEqual(management.receiverReadCount, 0)
        fixture.binding.resumeStop()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltManagedInventory != nil
        }
        XCTAssertEqual(management.receiverReadCount, 1)

        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
        fixture.binding.pauseCatalog()
        fixture.model.refreshLogitechSetup()
        await waitUntil { fixture.binding.catalogIsPending }
        fixture.model.inspectBoltReceivers()
        XCTAssertEqual(management.receiverReadCount, 1)
        XCTAssertEqual(refreshedManagement.receiverReadCount, 0)
        fixture.binding.resumeCatalog()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                refreshedManagement.receiverReadCount == 1
        }
        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
    }

    func testPairingExclusionEndsAfterFailedSessionCloses() async throws {
        let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
        let management = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory(receiverID: receiver.id)]
        )
        let refreshedManagement = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory(receiverID: receiver.id)]
        )
        let pairing = SyntheticReceiverManagementFailurePairing()
        let fixture = try await makeFixture(managementSessions: [management, refreshedManagement], pairing: pairing)
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltManagedInventory != nil
        }

        pairing.pauseNextClose()
        fixture.model.pairLogitechSetup()
        await waitUntil { pairing.closeIsPending }
        fixture.model.inspectBoltReceivers()
        XCTAssertEqual(management.receiverReadCount, 1)
        XCTAssertEqual(refreshedManagement.receiverReadCount, 0)

        pairing.resumeClose()
        await waitUntil { !fixture.model.isBoltPairingInProgress }
        XCTAssertEqual(fixture.model.boltPairingStatus?.phase, .failed)
        fixture.model.inspectBoltReceivers()
        await waitUntil {
            !fixture.model.isBoltReceiverManagementBusy && refreshedManagement.receiverReadCount == 1 &&
                fixture.model.boltManagedInventory != nil
        }
        XCTAssertEqual(management.receiverReadCount, 1)
        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
    }

    func testUncertainUnpairRequiresARefreshedManagementSession() async throws {
        let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
        let first = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory(receiverID: receiver.id)],
            outcome: .uncertain("Synthetic uncertain outcome")
        )
        let refreshed = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory(receiverID: receiver.id, rowCount: 2)]
        )
        let fixture = try await makeFixture(managementSessions: [first, refreshed])
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltManagedInventory != nil
        }
        let snapshot = try XCTUnwrap(fixture.model.boltManagedInventory)
        let record = try XCTUnwrap(snapshot.rows.first)
        fixture.model.unpairBoltManagedRecord(recordID: record.id, inventoryID: snapshot.id)
        await waitUntil { !fixture.model.isBoltReceiverManagementActive && !fixture.model.isBoltReceiverManagementBusy }
        XCTAssertEqual(first.unpairCallCount, 1)
        XCTAssertEqual(first.writeCount, 1)
        XCTAssertEqual(first.closeCount, 1)

        fixture.model.inspectBoltReceivers()
        await waitUntil { !fixture.model.isBoltReceiverManagementBusy && fixture.model.boltManagedInventory?.rows.count == 2 }
        XCTAssertEqual(first.unpairCallCount, 1)
        XCTAssertEqual(refreshed.unpairCallCount, 0)
        XCTAssertEqual(refreshed.receiverReadCount, 1)
        XCTAssertEqual(fixture.managerFactory.creationCount, 2)
        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
    }

    func testNavigationAndSleepRevokeQueuedUnpairBeforeDispatch() async throws {
        for sleep in [false, true] {
            let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
            let storedInventory = inventory(receiverID: receiver.id)
            let management = SyntheticBoltReceiverManagementSession(
                receivers: [receiver], inventories: [receiver.id: storedInventory], outcome: .verifiedRemoved(storedInventory)
            )
            let fixture = try await makeFixture(managementSessions: [management])
            defer { fixture.remove() }
            fixture.model.presentLogitechSetup()
            await waitUntil {
                !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                    fixture.model.boltManagedInventory != nil
            }
            let snapshot = try XCTUnwrap(fixture.model.boltManagedInventory)
            let record = try XCTUnwrap(snapshot.rows.first)

            management.pauseNextUnpairBeforeDispatch()
            fixture.model.unpairBoltManagedRecord(recordID: record.id, inventoryID: snapshot.id)
            await waitUntil { management.unpairIsPending }
            if sleep { fixture.model.systemWillSleep() }
            else { fixture.model.navigate(to: .settings) }
            await waitUntil { management.closeCount == 1 }
            XCTAssertEqual(management.unpairCallCount, 1)
            XCTAssertEqual(management.writeCount, 0)
            XCTAssertFalse(fixture.model.isBoltReceiverManagementActive)
            management.resumeUnpair()
            if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
            await waitUntil { !management.unpairIsPending }
            XCTAssertEqual(management.writeCount, 0)
        }
    }

    func testLateUnpairOutcomeDoesNotOverwriteRefreshedSetupState() async throws {
        let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
        let management = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory(receiverID: receiver.id)],
            outcome: .verifiedRemoved(inventory(receiverID: receiver.id)), pauseUnpairBeforeResult: true
        )
        let refreshedManagement = SyntheticBoltReceiverManagementSession(
            receivers: [receiver], inventories: [receiver.id: inventory(receiverID: receiver.id)]
        )
        let candidate = endpointCandidate()
        let fixture = try await makeFixture(candidates: [candidate], managementSessions: [management, refreshedManagement])
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                fixture.model.boltManagedInventory != nil
        }
        let snapshot = try XCTUnwrap(fixture.model.boltManagedInventory)
        let record = try XCTUnwrap(snapshot.rows.first)
        management.pauseNextUnpairBeforeResult()
        fixture.model.unpairBoltManagedRecord(recordID: record.id, inventoryID: snapshot.id)
        await waitUntil { management.unpairIsPending }
        XCTAssertEqual(management.writeCount, 1)

        fixture.binding.pauseCatalog()
        fixture.model.refreshLogitechSetup()
        management.resumeUnpair()
        await waitUntil { fixture.binding.catalogIsPending }
        XCTAssertNil(fixture.model.logitechSetupMessage)
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [candidate.id])
        fixture.model.addLogitechSetupCandidate(candidate.id)
        XCTAssertTrue(fixture.binding.targets.isEmpty)
        fixture.binding.resumeCatalog()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                refreshedManagement.receiverReadCount == 1
        }
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [candidate.id])
        if let close = fixture.model.closeBoltReceiverManagement() { await close.value }
    }

    private func makeFixture(
        candidates: [LogitechEndpointCandidate] = [],
        devices: [RegisteredDevice] = [],
        managementSessions: [SyntheticBoltReceiverManagementSession],
        pairing: SyntheticReceiverManagementFailurePairing? = nil,
        pairingSessions: [SyntheticReceiverManagementFailurePairing]? = nil
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        _ = try await store.save(WorkspaceConfiguration(connectOnLaunch: false, devices: devices), expecting: .missing)
        let binding = PairingBindingSession(candidates: candidates)
        let managerFactory = SyntheticBoltReceiverManagementFactory(sessions: managementSessions)
        let pairingFactory: (@Sendable () -> any BoltPairingManaging)?
        if let pairingSessions {
            let factory = SyntheticReceiverManagementPairingFactory(sessions: pairingSessions)
            pairingFactory = { @Sendable in factory.make() }
        } else {
            pairingFactory = pairing.map { session in { @Sendable in session } }
        }
        let model = AppModel(
            configurationURL: url,
            store: store,
            bolt: binding,
            makeBoltPairingSession: pairingFactory,
            makeBoltReceiverManagementSession: { @Sendable in managerFactory.make() },
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
            loadImmediately: true,
            observeSleep: false,
            wakeDelay: { _ in try await Task.sleep(for: .seconds(30)) },
            frontmostApplication: { nil }
        )
        await waitUntil { !model.isLoading }
        return Fixture(root: root, store: store, binding: binding, managerFactory: managerFactory, model: model)
    }

    private func endpointCandidate() -> LogitechEndpointCandidate {
        .init(id: UUID(), connection: .bolt, model: .mxMaster3S,
              identity: .init(unitID: "12345678", modelID: "123456789abc"), information: .init())
    }

    private func inventory(receiverID: UUID, rowCount: Int = 1) -> BoltReceiverInventory {
        let rows = (0..<rowCount).map { index in
            BoltReceiverInventoryRow(id: UUID(), slot: UInt8(index + 1), label: "Synthetic device \(index + 1)", isReachable: index == 0)
        }
        return BoltReceiverInventory(id: UUID(), receiverID: receiverID, capacity: 6, rows: rows)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic receiver management condition did not settle", file: file, line: line)
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let store: ConfigurationStore
    let binding: PairingBindingSession
    let managerFactory: SyntheticBoltReceiverManagementFactory
    let model: AppModel

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SyntheticBoltReceiverManagementFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let sessions: [SyntheticBoltReceiverManagementSession]
    private var creations = 0

    init(sessions: [SyntheticBoltReceiverManagementSession]) {
        self.sessions = sessions
    }

    var creationCount: Int { lock.withLock { creations } }

    func make() -> any BoltReceiverManaging {
        lock.withLock {
            let session = sessions[min(creations, sessions.count - 1)]
            creations += 1
            return session
        }
    }
}

private final class SyntheticBoltReceiverManagementSession: BoltReceiverManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let availableReceivers: [BoltReceiverCandidate]
    private let inventories: [UUID: BoltReceiverInventory]
    private let outcome: BoltUnpairOutcome
    private var receiverReads = 0
    private var inventoryReads: [UUID] = []
    private var activeInventoryReads = 0
    private var maximumInventoryReads = 0
    private var unpairCalls = 0
    private var lastUnpairRecord: UUID?
    private var lastUnpairInventory: UUID?
    private var writes = 0
    private var closes = 0
    private var closed = false
    private var pauseNextUnpairPreflight = false
    private var unpairPreflightWait: CheckedContinuation<Void, Never>?
    private var unpairResultWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseNextUnpairResult: Bool
    private var shouldPauseNextClose = false
    private var closePauseWait: CheckedContinuation<Void, Never>?
    private var inFlightUnpairs = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        receivers: [BoltReceiverCandidate],
        inventories: [UUID: BoltReceiverInventory],
        outcome: BoltUnpairOutcome = .notRemoved("The synthetic receiver rejected the command."),
        pauseUnpairBeforeResult: Bool = false
    ) {
        availableReceivers = receivers
        self.inventories = inventories
        self.outcome = outcome
        pauseNextUnpairResult = pauseUnpairBeforeResult
    }

    var receiverReadCount: Int { lock.withLock { receiverReads } }
    var inventoryReceiverIDs: [UUID] { lock.withLock { inventoryReads } }
    var maximumConcurrentInventoryReads: Int { lock.withLock { maximumInventoryReads } }
    var unpairCallCount: Int { lock.withLock { unpairCalls } }
    var lastUnpairRecordID: UUID? { lock.withLock { lastUnpairRecord } }
    var lastUnpairInventoryID: UUID? { lock.withLock { lastUnpairInventory } }
    var writeCount: Int { lock.withLock { writes } }
    var closeCount: Int { lock.withLock { closes } }
    var closeIsPending: Bool { lock.withLock { closePauseWait != nil } }
    var unpairIsPending: Bool { lock.withLock { unpairPreflightWait != nil || !unpairResultWaiters.isEmpty } }

    func pauseNextUnpairBeforeDispatch() {
        lock.withLock { pauseNextUnpairPreflight = true }
    }

    func pauseNextUnpairBeforeResult() {
        lock.withLock { pauseNextUnpairResult = true }
    }

    func pauseNextClose() {
        lock.withLock { shouldPauseNextClose = true }
    }

    func resumeClose() {
        let continuation = lock.withLock {
            let continuation = closePauseWait
            closePauseWait = nil
            return continuation
        }
        continuation?.resume()
    }

    func resumeUnpair() {
        let waiters = lock.withLock {
            if let waiter = unpairPreflightWait {
                unpairPreflightWait = nil
                return [waiter]
            }
            let waiters = unpairResultWaiters
            unpairResultWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func receivers() async throws -> [BoltReceiverCandidate] {
        guard !lock.withLock({ closed }) else { throw SyntheticReceiverManagementError.closed }
        lock.withLock { receiverReads += 1 }
        return availableReceivers
    }

    func inventory(receiverID: UUID) async throws -> BoltReceiverInventory {
        guard !lock.withLock({ closed }), let inventory = inventories[receiverID] else {
            throw SyntheticReceiverManagementError.closed
        }
        lock.withLock {
            inventoryReads.append(receiverID)
            activeInventoryReads += 1
            maximumInventoryReads = max(maximumInventoryReads, activeInventoryReads)
        }
        try await Task.sleep(for: .milliseconds(10))
        lock.withLock { activeInventoryReads -= 1 }
        return inventory
    }

    func unpair(recordID: UUID, inventoryID: UUID) async -> BoltUnpairOutcome {
        let isOpen = lock.withLock { () -> Bool in
            unpairCalls += 1
            lastUnpairRecord = recordID
            lastUnpairInventory = inventoryID
            inFlightUnpairs += 1
            return !closed
        }
        guard isOpen else {
            finishUnpair()
            return .notRemoved("The session closed before dispatch.")
        }
        let pausePreflight = lock.withLock { () -> Bool in
            let pause = pauseNextUnpairPreflight
            pauseNextUnpairPreflight = false
            return pause
        }
        if pausePreflight {
            await withCheckedContinuation { continuation in
                lock.withLock { unpairPreflightWait = continuation }
            }
        }
        let canDispatch = lock.withLock { () -> Bool in
            guard !closed else { return false }
            if case .notRemoved = outcome { return false }
            writes += 1
            return true
        }
        guard canDispatch else {
            finishUnpair()
            return .notRemoved("The session closed before dispatch.")
        }
        let shouldPauseResult = lock.withLock { () -> Bool in
            let pause = pauseNextUnpairResult
            pauseNextUnpairResult = false
            return pause
        }
        if shouldPauseResult {
            await withCheckedContinuation { continuation in
                lock.withLock { unpairResultWaiters.append(continuation) }
            }
        }
        finishUnpair()
        return outcome
    }

    func close() async {
        await withCheckedContinuation { continuation in
            let paused = lock.withLock { () -> Bool in
                guard shouldPauseNextClose else { return false }
                shouldPauseNextClose = false
                closePauseWait = continuation
                return true
            }
            if !paused { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            let wait = lock.withLock { () -> Bool in
                if !closed {
                    closed = true
                    closes += 1
                }
                guard inFlightUnpairs > 0 else { return false }
                closeWaiters.append(continuation)
                return true
            }
            if !wait { continuation.resume() }
        }
    }

    private func finishUnpair() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            inFlightUnpairs -= 1
            guard inFlightUnpairs == 0 else { return [] }
            let waiters = closeWaiters
            closeWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private enum SyntheticReceiverManagementError: Error {
    case closed
}

private final class SyntheticReceiverManagementFailurePairing: BoltPairingManaging, @unchecked Sendable {
    private let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver")
    private let stream: AsyncStream<BoltPairingStatus>.Continuation
    let events: AsyncStream<BoltPairingStatus>
    private let lock = NSLock()
    private var status = BoltPairingStatus(phase: .idle, message: "Synthetic pairing")
    private var starts = 0
    private var receiverReads = 0
    private var shouldPauseNextStart = false
    private var startWait: CheckedContinuation<Void, Never>?
    private var pauseClose = false
    private var closeWait: CheckedContinuation<Void, Never>?

    init() {
        let stream = AsyncStream<BoltPairingStatus>.makeStream()
        events = stream.stream
        self.stream = stream.continuation
    }

    var startCount: Int { lock.withLock { starts } }
    var receiverReadCount: Int { lock.withLock { receiverReads } }
    var startIsPending: Bool { lock.withLock { startWait != nil } }
    var closeIsPending: Bool { lock.withLock { closeWait != nil } }

    func receivers() async throws -> [BoltReceiverCandidate] {
        lock.withLock { receiverReads += 1 }
        return [receiver]
    }

    func start(receiverID: UUID) async {
        await withCheckedContinuation { continuation in
            let paused = lock.withLock { () -> Bool in
                starts += 1
                guard shouldPauseNextStart else { return false }
                shouldPauseNextStart = false
                startWait = continuation
                return true
            }
            if !paused { continuation.resume() }
        }
        let failure = BoltPairingStatus(phase: .failed, message: "Synthetic pairing failure")
        let shouldPublish = lock.withLock { () -> Bool in
            guard status.phase != .cancelled else { return false }
            status = failure
            return true
        }
        if shouldPublish { stream.yield(failure) }
    }

    func select(candidateID: UUID) async {}
    func cancel() async {
        let (waiter, cancelled) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, BoltPairingStatus) in
            let waiter = startWait
            startWait = nil
            let cancelled = BoltPairingStatus(phase: .cancelled, message: "Synthetic pairing cancelled")
            status = cancelled
            return (waiter, cancelled)
        }
        waiter?.resume()
        stream.yield(cancelled)
    }

    func close() async {
        await withCheckedContinuation { continuation in
            let paused = lock.withLock {
                if pauseClose {
                    pauseClose = false
                    closeWait = continuation
                    return true
                }
                return false
            }
            if !paused { continuation.resume() }
        }
    }

    func currentStatus() async -> BoltPairingStatus { lock.withLock { status } }

    func pauseNextStart() { lock.withLock { shouldPauseNextStart = true } }

    func resumeStart() {
        let continuation = lock.withLock {
            let continuation = startWait
            startWait = nil
            return continuation
        }
        continuation?.resume()
    }

    func pauseNextClose() { lock.withLock { pauseClose = true } }

    func resumeClose() {
        let continuation = lock.withLock {
            let continuation = closeWait
            closeWait = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class SyntheticReceiverManagementPairingFactory: @unchecked Sendable {
    private let sessions: [SyntheticReceiverManagementFailurePairing]
    private let lock = NSLock()
    private var creations = 0

    init(sessions: [SyntheticReceiverManagementFailurePairing]) {
        self.sessions = sessions
    }

    func make() -> any BoltPairingManaging {
        lock.withLock {
            let session = sessions[min(creations, sessions.count - 1)]
            creations += 1
            return session
        }
    }
}
