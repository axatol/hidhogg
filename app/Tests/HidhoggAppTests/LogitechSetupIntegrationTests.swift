import Foundation
@testable import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class LogitechSetupIntegrationTests: XCTestCase {
    func testSetupHasNoMouseSelectionOrPreregistrationAndSerializesInventory() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let prior = fixture.model.workspace
        fixture.binding.pauseStop()
        fixture.model.presentLogitechSetup()
        XCTAssertEqual(fixture.model.navigation.current.route, .logitechSetup)
        XCTAssertNil(fixture.model.selectedMouseID)
        XCTAssertEqual(fixture.model.workspace, prior)
        await waitUntil { fixture.binding.stopIsPending }
        XCTAssertEqual(fixture.binding.catalogReads, 0)
        fixture.model.pairLogitechSetup()
        XCTAssertEqual(fixture.pairing.receiverReads, 0)
        fixture.binding.resumeStop()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        XCTAssertEqual(fixture.binding.catalogReads, 1)
        XCTAssertFalse(fixture.binding.catalogProbedManagedEndpoint)
        XCTAssertEqual(fixture.model.workspace, prior)
        fixture.model.cancelLogitechSetup()
    }

    func testExistingVerifiedModelsAndTransportsPublishOnlyAfterSaveThenOpen() async throws {
        for mouseModel in LogitechMouseModel.allCases {
            for connection in LogitechConnection.allCases {
                let candidate = candidate(model: mouseModel, connection: connection)
                let gate = PairingPublicationGate()
                let fixture = try await makeFixture(candidates: [candidate], gate: gate)
                defer { fixture.remove() }
                fixture.model.presentLogitechSetup()
                await waitUntil { !fixture.model.isLogitechSetupLoading }
                let prior = fixture.model.workspace
                gate.pauseNextPublication()
                fixture.model.addLogitechSetupCandidate(candidate.id)
                await waitUntil { gate.hasEntered }
                XCTAssertEqual(fixture.model.workspace, prior)
                XCTAssertTrue(fixture.binding.targets.isEmpty)
                gate.release()
                await waitUntil { fixture.binding.targets.count == 1 }
                let id = try XCTUnwrap(fixture.model.selectedMouseID)
                let device = try XCTUnwrap(fixture.model.registration(id: id))
                XCTAssertEqual(device.mouseModel, mouseModel)
                XCTAssertEqual(device.logitechAssociation, .init(identity: candidate.identity, preferredConnection: connection))
                XCTAssertEqual(fixture.model.navigation.current.route, .mouse(id))
                let saved = try await fixture.store.load()
                XCTAssertEqual(saved.workspace.devices.first { $0.id == id }, device)
                XCTAssertEqual(saved.workspace.preferredMouseID, id)
                if mouseModel == .mxMaster4 {
                    XCTAssertFalse(fixture.model.selectedMouseSupportsManagement)
                    XCTAssertEqual(fixture.binding.writeCount, 0)
                }
                fixture.model.disconnect()
            }
        }
    }

    func testDuplicateIdentityIncludingDisabledRegistrationRequiresExplicitOpen() async throws {
        let candidate = candidate()
        for enabled in [true, false] {
            var existing = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
            existing.isEnabled = enabled
            existing.logitechAssociation = .init(identity: candidate.identity, preferredConnection: .bluetooth)
            let fixture = try await makeFixture(devices: [existing], candidates: [candidate])
            defer { fixture.remove() }
            fixture.model.presentLogitechSetup()
            await waitUntil { !fixture.model.isLogitechSetupLoading }
            XCTAssertEqual(fixture.model.existingLogitechRegistrationID(for: candidate), existing.id)
            fixture.model.addLogitechSetupCandidate(candidate.id)
            XCTAssertEqual(fixture.model.workspace.devices, [existing])
            XCTAssertEqual(fixture.model.navigation.current.route, .logitechSetup)
            XCTAssertTrue(fixture.binding.targets.isEmpty)
            fixture.model.openExistingLogitechSetupDevice(existing.id)
            await waitUntil { fixture.model.navigation.current.route == .mouse(existing.id) }
            XCTAssertEqual(fixture.model.selectedMouseID, existing.id)
        }
    }

    func testReassociationRetainsUUIDNameAndSettingsAndFiltersRequiredModel() async throws {
        let candidate = candidate(connection: .bluetooth)
        var existing = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        existing.displayName = "Configured mouse"
        if case .mouse(var configuration) = existing.configuration {
            configuration.wheelInverted = true
            configuration.defaults["back"] = .key(.init(keyCode: 12))
            existing.configuration = .mouse(configuration)
        }
        let fixture = try await makeFixture(devices: [existing], candidates: [candidate, self.candidate(model: .mxMaster4)])
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup(destination: .reassociate(existing.id))
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [candidate.id])
        fixture.model.addLogitechSetupCandidate(candidate.id)
        await waitUntil { fixture.binding.targets.count == 1 }
        let saved = try await fixture.store.load()
        let updated = try XCTUnwrap(saved.workspace.devices.first)
        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.displayName, existing.displayName)
        XCTAssertEqual(updated.configuration, existing.configuration)
        XCTAssertEqual(updated.mouseModel, existing.mouseModel)
        XCTAssertEqual(updated.logitechAssociation?.identity, candidate.identity)
        XCTAssertEqual(updated.logitechAssociation?.preferredConnection, .bluetooth)
        fixture.model.disconnect()
    }

    func testReassociationReportsVerifiedWrongModelInsteadOfNoMouse() async throws {
        let device = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        let fixture = try await makeFixture(devices: [device], candidates: [candidate(model: .mxMaster4)])
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup(destination: .reassociate(device.id))
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        XCTAssertTrue(fixture.model.logitechSetupCandidates.isEmpty)
        XCTAssertTrue(fixture.model.logitechSetupMessage?.contains("none matches the registered model") == true)
        XCTAssertTrue(fixture.binding.targets.isEmpty)
        fixture.model.cancelLogitechSetup()
    }

    func testOpenExistingRetainsPriorRuntimeOwnerEvenWhenOpeningAnotherDisabledRegistration() async throws {
        for enabled in [true, false] {
            let ownerCandidate = candidate()
            let otherCandidate = LogitechEndpointCandidate(id: UUID(), connection: .bluetooth, model: .mxMaster4,
                                                          identity: .init(unitID: "11223344", modelID: "5566778899aa"), information: .init())
            var owner = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
            owner.logitechAssociation = .init(identity: ownerCandidate.identity, preferredConnection: .bolt)
            var other = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster4))
            other.isEnabled = enabled
            other.logitechAssociation = .init(identity: otherCandidate.identity, preferredConnection: .bluetooth)
            let fixture = try await makeFixture(devices: [owner, other], candidates: [otherCandidate], preferredMouseID: owner.id)
            defer { fixture.remove() }
            await waitUntil { fixture.binding.targets.count == 1 && fixture.model.presentedMouseOwnerID == owner.id }
            fixture.model.presentLogitechSetup()
            await waitUntil { !fixture.model.isLogitechSetupLoading }
            XCTAssertNil(fixture.model.presentedMouseOwnerID)
            fixture.model.openExistingLogitechSetupDevice(other.id)
            await waitUntil { fixture.model.navigation.current.route == .mouse(other.id) && fixture.binding.targets.count == 2 }
            XCTAssertEqual(fixture.model.selectedMouseID, other.id)
            XCTAssertEqual(fixture.model.workspace.preferredMouseID, owner.id)
            XCTAssertEqual(fixture.model.registeredDevices, [owner, other])
            XCTAssertTrue(fixture.binding.targets.allSatisfy { $0.association.identity == ownerCandidate.identity })
            fixture.model.disconnect()
        }
    }

    func testSingleReceiverStartsOnlyOnExplicitPairAndNewModelComesFromVerification() async throws {
        let pairing = SyntheticBoltPairingSession(model: .mxMaster4)
        let fixture = try await makeFixture(pairing: pairing)
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        XCTAssertEqual(pairing.receiverReads, 0)
        XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        fixture.model.pairLogitechSetup()
        await waitUntil { fixture.model.boltPairingStatus?.phase == .awaitingSelection }
        XCTAssertEqual(pairing.receiverReads, 1)
        XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        XCTAssertFalse(fixture.model.isBoltPairingPresented)
        fixture.model.selectBoltPairingCandidate(pairing.candidate.id)
        await waitUntil { pairing.selectionCount == 1 }
        pairing.pauseClose()
        pairing.emitVerified()
        await waitUntil { pairing.closeIsPending }
        XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        XCTAssertTrue(fixture.binding.targets.isEmpty)
        pairing.resumeClose()
        await waitUntil {
            guard let id = fixture.model.selectedMouseID else { return false }
            return fixture.binding.targets.count == 1 && fixture.model.presentedMouseOwnerID == id &&
                fixture.model.selectedMouseStatus.phase == .ready
        }
        XCTAssertEqual(fixture.model.registration(id: try XCTUnwrap(fixture.model.selectedMouseID))?.mouseModel, .mxMaster4)
        XCTAssertFalse(fixture.model.selectedMouseSupportsManagement)
        XCTAssertEqual(fixture.binding.writeCount, 0)
        fixture.model.disconnect()
    }

    func testFailedPairingRetainsInventoryAndBlocksActionsWhileReceiverIsOwned() async throws {
        let candidate = candidate()
        let refreshedCandidate = self.candidate()
        let pairing = SyntheticTerminalBoltPairingSession()
        let receiverFactory = SyntheticLogitechSetupReceiverManagementFactory()
        let fixture = try await makeFixture(
            candidates: [candidate], pairingSession: pairing, receiverManagementFactory: receiverFactory
        )
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                receiverFactory.receiverReadCount == 1 &&
                receiverFactory.inventoryReadCount == receiverFactory.receivers.count
        }
        let visibleCandidates = fixture.model.logitechSetupCandidates
        XCTAssertEqual(visibleCandidates.map(\.id), [candidate.id])

        fixture.model.pairLogitechSetup()
        await waitUntil { pairing.closeIsPending }
        XCTAssertTrue(fixture.model.isBoltPairingInProgress)
        XCTAssertEqual(fixture.model.logitechSetupCandidates, visibleCandidates)

        fixture.model.refreshLogitechSetup()
        fixture.model.addLogitechSetupCandidate(candidate.id)
        XCTAssertEqual(fixture.binding.catalogReads, 1)
        XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        XCTAssertEqual(fixture.model.logitechSetupCandidates, visibleCandidates)

        pairing.resumeClose()
        await waitUntil { !fixture.model.isBoltPairingInProgress }
        XCTAssertEqual(fixture.model.boltPairingStatus?.phase, .failed)
        XCTAssertTrue(fixture.model.isLogitechSetupSelectionBlocked)
        XCTAssertEqual(fixture.model.logitechSetupCandidates, visibleCandidates)

        fixture.binding.updateCandidates([refreshedCandidate])
        fixture.model.refreshLogitechSetup()
        await waitUntil {
            fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading &&
                !fixture.model.isBoltReceiverManagementBusy &&
                receiverFactory.receiverReadCount == 2 &&
                receiverFactory.inventoryReadCount == receiverFactory.receivers.count * 2 &&
                !fixture.model.requiresLogitechSetupRefreshBeforePairing
        }
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [refreshedCandidate.id])

        fixture.model.addLogitechSetupCandidate(refreshedCandidate.id)
        await waitUntil { fixture.binding.targets.count == 1 }
        let registration = try XCTUnwrap(fixture.model.registration(id: try XCTUnwrap(fixture.model.selectedMouseID)))
        XCTAssertEqual(registration.logitechAssociation?.identity, refreshedCandidate.identity)
        fixture.model.disconnect()
    }

    func testPairingPreservesExistingInventoryMessage() async throws {
        let pairing = SyntheticTerminalBoltPairingSession()
        let fixture = try await makeFixture(pairingSession: pairing)
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        let inventoryMessage = try XCTUnwrap(fixture.model.logitechSetupMessage)

        fixture.model.pairLogitechSetup()
        await waitUntil { pairing.closeIsPending }
        XCTAssertEqual(fixture.model.logitechSetupMessage, inventoryMessage)
        pairing.resumeClose()
        await waitUntil { !fixture.model.isBoltPairingInProgress }
        XCTAssertEqual(fixture.model.logitechSetupMessage, inventoryMessage)
    }

    func testUncertainPairingBlocksCachedSelectionUntilRefresh() async throws {
        for (phase, failsSave) in [
            (BoltPairingPhase.pairedButNotAdded, false),
            (.verified, true)
        ] {
            let candidate = candidate()
            let refreshedCandidate = self.candidate()
            let gate = PairingPublicationGate()
            let pairing = SyntheticTerminalBoltPairingSession(
                phase: phase,
                pairingMayHaveSucceeded: true,
                verifiedCandidate: failsSave ? candidate : nil
            )
            let receiverFactory = SyntheticLogitechSetupReceiverManagementFactory()
            let fixture = try await makeFixture(
                candidates: [candidate], gate: gate, pairingSession: pairing,
                receiverManagementFactory: receiverFactory
            )
            defer { fixture.remove() }
            fixture.model.presentLogitechSetup()
            await waitUntil {
                !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                    receiverFactory.receiverReadCount == 1 &&
                    receiverFactory.inventoryReadCount == receiverFactory.receivers.count
            }
            if failsSave { gate.failNextPublication() }

            fixture.model.pairLogitechSetup()
            await waitUntil { pairing.closeIsPending }
            pairing.resumeClose()
            await waitUntil { !fixture.model.isBoltPairingInProgress }
            XCTAssertEqual(fixture.model.boltPairingStatus?.phase, phase)
            XCTAssertTrue(fixture.model.isLogitechSetupSelectionBlocked)
            XCTAssertTrue(fixture.model.shouldShowLogitechSetupRecoveryButton)

            fixture.model.pairLogitechSetup()
            let retryStarted = fixture.model.isBoltPairingInProgress
            XCTAssertFalse(retryStarted)
            XCTAssertTrue(fixture.model.isLogitechSetupSelectionBlocked)
            XCTAssertEqual(pairing.startCount, 1)
            if retryStarted {
                fixture.model.cancelLogitechSetupPairing()
                await waitUntil { pairing.closeIsPending }
                pairing.resumeClose()
                await waitUntil { fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading }
                continue
            }

            fixture.model.addLogitechSetupCandidate(candidate.id)
            await waitUntil { !fixture.model.isLogitechSetupLoading }
            XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
            XCTAssertEqual(fixture.model.navigation.current.route, .logitechSetup)
            XCTAssertEqual(fixture.binding.targets, [])
            let cachedInventories = fixture.model.boltStoredInventories
            XCTAssertEqual(cachedInventories.count, receiverFactory.receivers.count)

            fixture.binding.updateCandidates([refreshedCandidate])
            fixture.binding.pauseCatalog()
            fixture.model.refreshLogitechSetup()
            await waitUntil { fixture.binding.catalogIsPending }
            XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [candidate.id])
            XCTAssertTrue(fixture.model.requiresLogitechSetupRefreshBeforePairing)
            XCTAssertEqual(pairing.startCount, 1)
            XCTAssertEqual(fixture.model.boltStoredInventories, cachedInventories)
            XCTAssertTrue(fixture.model.isBoltManagedInventoryStale)
            XCTAssertEqual(receiverFactory.inventoryReadCount, receiverFactory.receivers.count)

            fixture.binding.resumeCatalog()
            await waitUntil {
                fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading &&
                    !fixture.model.isBoltReceiverManagementBusy &&
                    receiverFactory.receiverReadCount == 2 &&
                    receiverFactory.inventoryReadCount == receiverFactory.receivers.count * 2 &&
                    !fixture.model.requiresLogitechSetupRefreshBeforePairing
            }
            XCTAssertFalse(fixture.model.isLogitechSetupSelectionBlocked)
            XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [refreshedCandidate.id])
            XCTAssertEqual(pairing.startCount, 1)

            fixture.model.addLogitechSetupCandidate(candidate.id)
            XCTAssertTrue(fixture.binding.targets.isEmpty)
            fixture.model.addLogitechSetupCandidate(refreshedCandidate.id)
            await waitUntil { fixture.binding.targets.count == 1 }
            let registration = try XCTUnwrap(fixture.model.registration(id: try XCTUnwrap(fixture.model.selectedMouseID)))
            XCTAssertEqual(registration.logitechAssociation?.identity, refreshedCandidate.identity)
            fixture.model.disconnect()
        }
    }

    func testDefinitePairingFailureRequiresFreshDevicesBeforeExplicitRetry() async throws {
        let candidate = candidate()
        let refreshedCandidate = self.candidate()
        let pairing = SyntheticTerminalBoltPairingSession(emitsTransientPossibleSuccess: true)
        let retryPairing = SyntheticTerminalBoltPairingSession()
        let pairingFactory = SyntheticTerminalBoltPairingSessionFactory(sessions: [pairing, retryPairing])
        let receiverFactory = SyntheticLogitechSetupReceiverManagementFactory()
        let fixture = try await makeFixture(
            candidates: [candidate], pairingSessionFactory: { pairingFactory.make() },
            receiverManagementFactory: receiverFactory
        )
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                receiverFactory.receiverReadCount == 1 &&
                receiverFactory.inventoryReadCount == receiverFactory.receivers.count
        }

        fixture.model.pairLogitechSetup()
        await waitUntil { pairing.closeIsPending }
        pairing.resumeClose()
        await waitUntil { !fixture.model.isBoltPairingInProgress }
        XCTAssertEqual(fixture.model.boltPairingStatus?.phase, .failed)
        XCTAssertEqual(fixture.model.boltPairingStatus?.message, "Synthetic pairing failed")
        XCTAssertFalse(fixture.model.boltPairingStatus?.pairingMayHaveSucceeded ?? true)
        XCTAssertNil(fixture.model.boltPairingStatus?.verifiedCandidate)
        XCTAssertNil(fixture.model.boltPairingMessage)
        XCTAssertTrue(fixture.model.requiresLogitechSetupRefreshBeforePairing)
        XCTAssertTrue(fixture.model.isLogitechSetupSelectionBlocked)
        XCTAssertEqual(pairing.startCount, 1)

        fixture.model.pairLogitechSetup()
        XCTAssertEqual(pairing.startCount, 1)
        XCTAssertTrue(fixture.model.isLogitechSetupSelectionBlocked)

        fixture.binding.updateCandidates([refreshedCandidate])
        fixture.binding.pauseCatalog()
        fixture.model.refreshLogitechSetup()
        await waitUntil { fixture.binding.catalogIsPending }
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [candidate.id])
        XCTAssertEqual(pairing.startCount, 1)
        fixture.binding.resumeCatalog()
        await waitUntil {
            fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading &&
                !fixture.model.isBoltReceiverManagementBusy &&
                receiverFactory.receiverReadCount == 2 &&
                receiverFactory.inventoryReadCount == receiverFactory.receivers.count * 2 &&
                !fixture.model.requiresLogitechSetupRefreshBeforePairing
        }
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [refreshedCandidate.id])
        XCTAssertFalse(fixture.model.isLogitechSetupSelectionBlocked)
        XCTAssertEqual(pairing.startCount, 1)

        fixture.model.pairLogitechSetup()
        await waitUntil { retryPairing.startCount == 1 && retryPairing.closeIsPending }
        XCTAssertEqual(fixture.binding.catalogReads, 2)
        retryPairing.resumeClose()
        await waitUntil { !fixture.model.isBoltPairingInProgress }
        XCTAssertEqual(fixture.model.boltPairingStatus?.phase, .failed)
        XCTAssertEqual(fixture.model.boltPairingStatus?.message, "Synthetic pairing failed")
        XCTAssertNil(fixture.model.boltPairingMessage)
        XCTAssertTrue(fixture.model.requiresLogitechSetupRefreshBeforePairing)
    }

    func testOrdinaryRefreshKeepsVerifiedEndpointActionsAvailableWithoutReceiverInventory() async throws {
        let candidate = candidate()
        let refreshedCandidate = self.candidate()
        let fixture = try await makeFixture(candidates: [candidate])
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }

        fixture.binding.updateCandidates([refreshedCandidate])
        fixture.model.refreshLogitechSetup()
        await waitUntil { fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading }

        XCTAssertFalse(fixture.model.requiresLogitechSetupRefreshBeforePairing)
        XCTAssertFalse(fixture.model.isLogitechSetupSelectionBlocked)
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [refreshedCandidate.id])
        fixture.model.addLogitechSetupCandidate(refreshedCandidate.id)
        await waitUntil { fixture.binding.targets.count == 1 }
        fixture.model.disconnect()
    }

    func testEmptyReceiverRefreshRetainsStaleStoredRowsAndAllowsFreshBluetoothAdd() async throws {
        let staleCandidate = candidate()
        let refreshedBluetoothCandidate = candidate(connection: .bluetooth)
        let pairing = SyntheticTerminalBoltPairingSession(
            phase: .pairedButNotAdded,
            pairingMayHaveSucceeded: true
        )
        let receiverFactory = SyntheticLogitechSetupReceiverManagementFactory()
        let fixture = try await makeFixture(
            candidates: [staleCandidate], pairingSession: pairing, receiverManagementFactory: receiverFactory
        )
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil {
            !fixture.model.isLogitechSetupLoading && !fixture.model.isBoltReceiverManagementBusy &&
                receiverFactory.receiverReadCount == 1 &&
                receiverFactory.inventoryReadCount == receiverFactory.receivers.count
        }
        let cachedInventories = fixture.model.boltStoredInventories
        XCTAssertEqual(cachedInventories.count, receiverFactory.receivers.count)

        fixture.model.pairLogitechSetup()
        await waitUntil { pairing.closeIsPending }
        pairing.resumeClose()
        await waitUntil { !fixture.model.isBoltPairingInProgress }
        XCTAssertTrue(fixture.model.requiresLogitechSetupRefreshBeforePairing)

        receiverFactory.removeAllReceivers()
        fixture.binding.updateCandidates([refreshedBluetoothCandidate])
        fixture.model.refreshLogitechSetup()
        await waitUntil {
            fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading &&
                !fixture.model.isBoltReceiverManagementBusy && receiverFactory.receiverReadCount == 2 &&
                !fixture.model.requiresLogitechSetupRefreshBeforePairing
        }

        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [refreshedBluetoothCandidate.id])
        XCTAssertEqual(fixture.model.boltStoredInventories, cachedInventories)
        XCTAssertTrue(fixture.model.isBoltManagedInventoryStale)
        XCTAssertEqual(receiverFactory.inventoryReadCount, cachedInventories.count)
        XCTAssertFalse(fixture.model.isLogitechSetupSelectionBlocked)
        XCTAssertEqual(pairing.startCount, 1)

        fixture.model.addLogitechSetupCandidate(refreshedBluetoothCandidate.id)
        await waitUntil { fixture.binding.targets.count == 1 }
        let registration = try XCTUnwrap(fixture.model.registration(id: try XCTUnwrap(fixture.model.selectedMouseID)))
        XCTAssertEqual(registration.logitechAssociation?.preferredConnection, .bluetooth)
        fixture.model.disconnect()
    }

    func testOrdinaryRefreshFailureClearsCachedEndpointSelection() async throws {
        let candidate = candidate()
        let fixture = try await makeFixture(candidates: [candidate])
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }

        fixture.binding.pauseCatalog()
        fixture.binding.failNextCatalogRead()
        fixture.model.refreshLogitechSetup()
        await waitUntil { fixture.binding.catalogIsPending }
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [candidate.id])
        fixture.binding.resumeCatalog()
        await waitUntil { fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading }

        XCTAssertTrue(fixture.model.logitechSetupCandidates.isEmpty)
        XCTAssertFalse(fixture.model.requiresLogitechSetupRefreshBeforePairing)
        fixture.model.addLogitechSetupCandidate(candidate.id)
        XCTAssertTrue(fixture.binding.targets.isEmpty)
        XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
    }

    func testMultipleReceiversRequireExplicitSelectionAndPairingStopAwaitsCloseBeforeInventory() async throws {
        let pairing = SyntheticBoltPairingSession(receiverCount: 2)
        let fixture = try await makeFixture(pairing: pairing)
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        fixture.model.pairLogitechSetup()
        await waitUntil { fixture.model.boltPairingReceivers.count == 2 && !fixture.model.isBoltPairingLoading }
        XCTAssertNil(fixture.model.boltPairingStatus)
        fixture.model.selectBoltPairingReceiver(pairing.receiver.id)
        await waitUntil { fixture.model.boltPairingStatus?.phase == .awaitingSelection }
        pairing.pauseClose()
        fixture.model.cancelLogitechSetupPairing()
        await waitUntil { pairing.closeIsPending }
        XCTAssertEqual(fixture.binding.catalogReads, 1)
        pairing.resumeClose()
        await waitUntil { fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading }
        XCTAssertEqual(fixture.model.navigation.current.route, .logitechSetup)
        XCTAssertEqual(fixture.model.logitechSetupDestination, .newRegistration)
        XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        fixture.model.cancelLogitechSetup()
    }

    func testInlineCancelDuringAdmittedPairSaveRefreshesWithoutRestoringNewRuntime() async throws {
        let pairing = SyntheticBoltPairingSession()
        var owner = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        owner.logitechAssociation = .init(identity: .init(unitID: "11223344", modelID: "5566778899aa"), preferredConnection: .bolt)
        let gate = PairingPublicationGate()
        let fixture = try await makeFixture(devices: [owner], candidates: [pairing.verified], gate: gate,
                                            pairing: pairing, preferredMouseID: owner.id)
        defer { fixture.remove() }
        await waitUntil { fixture.binding.targets.count == 1 && fixture.model.presentedMouseOwnerID == owner.id }
        let priorRoute = fixture.model.navigation.current.route
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        fixture.model.pairLogitechSetup()
        await waitUntil { fixture.model.boltPairingStatus?.phase == .awaitingSelection }
        gate.pauseNextPublication()
        pairing.emitVerified()
        await waitUntil { gate.hasEntered }
        fixture.model.cancelLogitechSetupPairing()
        gate.release()
        await waitUntil { fixture.binding.catalogReads == 2 && !fixture.model.isLogitechSetupLoading }
        XCTAssertEqual(fixture.model.navigation.current.route, .logitechSetup)
        XCTAssertEqual(fixture.model.registeredDevices.count, 2)
        XCTAssertEqual(fixture.binding.targets.count, 1)
        XCTAssertTrue(fixture.model.logitechSetupMessage?.contains("saved") == true)
        XCTAssertEqual(fixture.model.logitechSetupCandidates.map(\.id), [pairing.verified.id])
        fixture.model.cancelLogitechSetup()
        await waitUntil { fixture.model.navigation.current.route == priorRoute }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.binding.targets.count, 1)
    }

    func testFailedStagedSavePublishesNothing() async throws {
        let candidate = candidate()
        let gate = PairingPublicationGate()
        let fixture = try await makeFixture(candidates: [candidate], gate: gate)
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        gate.failNextPublication()
        fixture.model.addLogitechSetupCandidate(candidate.id)
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        XCTAssertTrue(fixture.binding.targets.isEmpty)
        XCTAssertNotNil(fixture.model.configurationSaveError)
        let saved = try await fixture.store.load()
        XCTAssertTrue(saved.workspace.devices.isEmpty)
    }

    func testCancelDuringAdmittedNewRegistrationSaveRetainsSavedOutcomeWithoutOpening() async throws {
        let candidate = candidate()
        let gate = PairingPublicationGate()
        let fixture = try await makeFixture(candidates: [candidate], gate: gate)
        defer { fixture.remove() }
        let priorRoute = fixture.model.navigation.current.route
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        gate.pauseNextPublication()
        fixture.model.addLogitechSetupCandidate(candidate.id)
        await waitUntil { gate.hasEntered }
        fixture.model.cancelLogitechSetup()
        gate.release()
        await waitUntil { !fixture.model.isSaving && fixture.model.navigation.current.route == priorRoute }
        XCTAssertEqual(fixture.model.navigation.current.route, priorRoute)
        XCTAssertEqual(fixture.model.registeredDevices.count, 1)
        XCTAssertTrue(fixture.model.logitechSetupMessage?.contains("saved") == true)
        XCTAssertTrue(fixture.binding.targets.isEmpty)
        let saved = try await fixture.store.load()
        XCTAssertEqual(saved.workspace.devices, fixture.model.workspace.devices)
    }

    func testSleepCleanupWaitsForInlinePairingCloseBeforeControllerStop() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        fixture.model.pairLogitechSetup()
        await waitUntil { fixture.model.boltPairingStatus?.phase == .awaitingSelection }
        let stops = fixture.binding.stopCount
        fixture.pairing.pauseClose()
        fixture.model.systemWillSleep()
        await waitUntil { fixture.pairing.closeIsPending }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.binding.stopCount, stops)
        fixture.pairing.resumeClose()
        await waitUntil { fixture.binding.stopCount == stops + 1 }
        XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        XCTAssertTrue(fixture.binding.targets.isEmpty)
    }

    func testStagedPublicationPreservesConcurrentCanonicalAndChildD200XEditsInSerializedLane() async throws {
        let candidate = candidate()
        let gate = PairingPublicationGate()
        let deck = RegisteredDevice(configuration: .d200x(.empty))
        let fixture = try await makeFixture(devices: [deck], candidates: [candidate], gate: gate)
        defer { fixture.remove() }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        gate.pauseNextPublication()
        fixture.model.addLogitechSetupCandidate(candidate.id)
        await waitUntil { gate.hasEntered }
        var draft = fixture.model.document.draft
        draft.connectOnLaunch = true
        fixture.model.updateDraft(draft)
        fixture.model.d200x.setClockFormat(.twelveHour)
        let editedDeck = fixture.model.document.draft.d200x
        let flush = Task { await fixture.model.flushPendingSave() }
        gate.release()
        let flushed = await flush.value
        XCTAssertTrue(flushed)
        XCTAssertTrue(fixture.model.workspace.connectOnLaunch)
        XCTAssertEqual(fixture.model.workspace.devices.first { $0.id == deck.id }?.configuration, .d200x(editedDeck))
        XCTAssertEqual(fixture.model.registeredDevices.filter { $0.family.isLogitechMouse }.count, 1)
        XCTAssertTrue(fixture.binding.targets.isEmpty)
        let saved = try await fixture.store.load()
        XCTAssertEqual(saved.workspace, fixture.model.workspace)
        XCTAssertTrue(fixture.model.logitechSetupMessage?.contains("saved") == true)
    }

    func testNavigationAndSleepRevokeLateInventoryAndBlockPairingUntilReleased() async throws {
        for sleep in [false, true] {
            let fixture = try await makeFixture(candidates: [candidate()])
            defer { fixture.remove() }
            fixture.binding.pauseCatalog()
            fixture.model.presentLogitechSetup()
            await waitUntil { fixture.binding.catalogIsPending }
            if sleep { fixture.model.systemWillSleep() }
            else { fixture.model.navigate(to: .settings) }
            fixture.model.pairLogitechSetup()
            XCTAssertEqual(fixture.pairing.receiverReads, 0)
            fixture.binding.resumeCatalog()
            await waitUntil { !fixture.binding.catalogIsPending }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertTrue(fixture.model.logitechSetupCandidates.isEmpty)
            XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
            XCTAssertTrue(fixture.binding.targets.isEmpty)
        }
    }

    func testCancelRestoresPriorRouteOnlyWhenContextIsUnchanged() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        fixture.model.navigate(to: .notifications)
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        fixture.model.cancelLogitechSetup()
        await waitUntil { fixture.model.navigation.current.route == .notifications }
        fixture.model.presentLogitechSetup()
        await waitUntil { !fixture.model.isLogitechSetupLoading }
        fixture.model.navigate(to: .settings)
        fixture.model.cancelLogitechSetup()
        XCTAssertEqual(fixture.model.navigation.current.route, .settings)
    }

    private func candidate(model: LogitechMouseModel = .mxMaster3S, connection: LogitechConnection = .bolt) -> LogitechEndpointCandidate {
        .init(id: UUID(), connection: connection, model: model,
              identity: .init(unitID: "12345678", modelID: "123456789abc"), information: .init())
    }

    private struct Fixture {
        let root: URL
        let store: ConfigurationStore
        let binding: PairingBindingSession
        let pairing: SyntheticBoltPairingSession
        let model: AppModel
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture(
        devices: [RegisteredDevice] = [], candidates: [LogitechEndpointCandidate] = [],
        gate: PairingPublicationGate? = nil, pairing: SyntheticBoltPairingSession = SyntheticBoltPairingSession(),
        pairingSession: (any BoltPairingManaging)? = nil,
        pairingSessionFactory: (@Sendable () -> any BoltPairingManaging)? = nil,
        receiverManagementFactory: SyntheticLogitechSetupReceiverManagementFactory? = nil,
        preferredMouseID: UUID? = nil
    ) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url, beforeRegistryPublication: { try gate?.enter() })
        _ = try await store.save(WorkspaceConfiguration(connectOnLaunch: preferredMouseID != nil, devices: devices,
                                                       preferredMouseID: preferredMouseID), expecting: .missing)
        let binding = PairingBindingSession(candidates: candidates)
        let makeReceiverManagementSession: (@Sendable () -> any BoltReceiverManaging)?
        if let receiverManagementFactory {
            makeReceiverManagementSession = { @Sendable in receiverManagementFactory.make() }
        } else {
            makeReceiverManagementSession = nil
        }
        let makePairingSession: @Sendable () -> any BoltPairingManaging
        if let pairingSessionFactory {
            makePairingSession = pairingSessionFactory
        } else {
            makePairingSession = {
                if let pairingSession { return pairingSession }
                return pairing
            }
        }
        let model = AppModel(configurationURL: url, store: store, bolt: binding, makeBoltPairingSession: makePairingSession,
                             makeBoltReceiverManagementSession: makeReceiverManagementSession,
                             sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
                             loadImmediately: true, observeSleep: false,
                             wakeDelay: { _ in try await Task.sleep(for: .seconds(30)) }, frontmostApplication: { nil })
        await waitUntil { !model.isLoading }
        return Fixture(root: root, store: store, binding: binding, pairing: pairing, model: model)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic setup condition did not settle", file: file, line: line)
    }
}

private final class SyntheticTerminalBoltPairingSession: BoltPairingManaging, @unchecked Sendable {
    private let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic Logi Bolt receiver")
    private let continuation: AsyncStream<BoltPairingStatus>.Continuation
    let events: AsyncStream<BoltPairingStatus>
    private let lock = NSLock()
    private var status = BoltPairingStatus(phase: .idle, message: "Synthetic pairing")
    private var closeWait: CheckedContinuation<Void, Never>?
    private var starts = 0
    private let transientStatus: BoltPairingStatus?
    private let terminalStatus: BoltPairingStatus

    init(
        phase: BoltPairingPhase = .failed,
        pairingMayHaveSucceeded: Bool = false,
        verifiedCandidate: LogitechEndpointCandidate? = nil,
        emitsTransientPossibleSuccess: Bool = false
    ) {
        let stream = AsyncStream<BoltPairingStatus>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        terminalStatus = .init(phase: phase, message: "Synthetic pairing \(phase.rawValue)",
                               verifiedCandidate: verifiedCandidate, pairingMayHaveSucceeded: pairingMayHaveSucceeded)
        transientStatus = emitsTransientPossibleSuccess
            ? .init(phase: .authenticating, message: "Synthetic authentication", pairingMayHaveSucceeded: true)
            : nil
    }

    var closeIsPending: Bool { lock.withLock { closeWait != nil } }
    var startCount: Int { lock.withLock { starts } }

    func currentStatus() async -> BoltPairingStatus { lock.withLock { status } }

    func receivers() async throws -> [BoltReceiverCandidate] { [receiver] }

    func start(receiverID: UUID) async {
        lock.withLock { starts += 1 }
        if let transientStatus { emit(transientStatus) }
        emit(terminalStatus)
    }

    func select(candidateID: UUID) async {}

    func cancel() async {}

    func close() async {
        await withCheckedContinuation { continuation in
            lock.withLock { closeWait = continuation }
        }
    }

    func resumeClose() {
        let wait = lock.withLock {
            let value = closeWait
            closeWait = nil
            return value
        }
        wait?.resume()
    }

    private func emit(_ status: BoltPairingStatus) {
        lock.withLock { self.status = status }
        continuation.yield(status)
    }
}

private final class SyntheticTerminalBoltPairingSessionFactory: @unchecked Sendable {
    private let sessions: [SyntheticTerminalBoltPairingSession]
    private let lock = NSLock()
    private var creations = 0

    init(sessions: [SyntheticTerminalBoltPairingSession]) {
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

private final class SyntheticLogitechSetupReceiverManagementFactory: @unchecked Sendable {
    private let inventories: [UUID: BoltReceiverInventory]
    private let lock = NSLock()
    private var accessibleReceivers: [BoltReceiverCandidate]
    private var receiverReads = 0
    private var inventoryReads: [UUID] = []

    init(receiverCount: Int = 2) {
        let availableReceivers = (0..<receiverCount).map { index in
            BoltReceiverCandidate(id: UUID(), label: "Synthetic receiver \(index + 1)")
        }
        accessibleReceivers = availableReceivers
        inventories = Dictionary(uniqueKeysWithValues: availableReceivers.map { receiver in
            let row = BoltReceiverInventoryRow(id: UUID(), slot: 1, label: "Cached synthetic device", isReachable: true)
            return (receiver.id, BoltReceiverInventory(id: UUID(), receiverID: receiver.id, capacity: 6, rows: [row]))
        })
    }

    var receivers: [BoltReceiverCandidate] { lock.withLock { accessibleReceivers } }
    var receiverReadCount: Int { lock.withLock { receiverReads } }
    var inventoryReadCount: Int { lock.withLock { inventoryReads.count } }

    func make() -> any BoltReceiverManaging {
        SyntheticLogitechSetupReceiverManagementSession(factory: self, receivers: receivers, inventories: inventories)
    }

    func removeAllReceivers() { lock.withLock { accessibleReceivers = [] } }
    fileprivate func recordReceiverRead() { lock.withLock { receiverReads += 1 } }
    fileprivate func recordInventoryRead(_ receiverID: UUID) { lock.withLock { inventoryReads.append(receiverID) } }
}

private final class SyntheticLogitechSetupReceiverManagementSession: BoltReceiverManaging, @unchecked Sendable {
    private let factory: SyntheticLogitechSetupReceiverManagementFactory
    private let availableReceivers: [BoltReceiverCandidate]
    private let inventories: [UUID: BoltReceiverInventory]

    init(
        factory: SyntheticLogitechSetupReceiverManagementFactory,
        receivers: [BoltReceiverCandidate],
        inventories: [UUID: BoltReceiverInventory]
    ) {
        self.factory = factory
        availableReceivers = receivers
        self.inventories = inventories
    }

    func receivers() async throws -> [BoltReceiverCandidate] {
        factory.recordReceiverRead()
        return availableReceivers
    }

    func inventory(receiverID: UUID) async throws -> BoltReceiverInventory {
        guard let inventory = inventories[receiverID] else { throw SyntheticReceiverInventoryError.missing }
        factory.recordInventoryRead(receiverID)
        return inventory
    }

    func unpair(recordID: UUID, inventoryID: UUID) async -> BoltUnpairOutcome {
        .notRemoved("Synthetic receiver management does not unpair devices.")
    }

    func close() async {}
}

private enum SyntheticReceiverInventoryError: Error {
    case missing
}
