import Foundation
import IOKit.hid
import Testing
import HidhoggDomain
@testable import LogitechBolt

@Test func identityProbeClassifiesBLEModelWithoutConflatingTransportNamespaces() throws {
    let probe = try LogitechIdentityProbe.decode(
        [0, 1, 2, 3, 4, 0, 0x06, 0xB0, 0x34, 0x12, 0x34, 0x56, 0x78],
        connection: .bluetooth, endpointProductID: 0xB034, featureIndex: 9, featureVersion: 6
    )

    #expect(probe.model == .mxMaster3S)
    #expect(probe.identity == LogitechIdentity(unitID: "01020304", modelID: "b03412345678"))
    #expect(probe.transportIDs[.bluetoothLowEnergy] == "b034")
    #expect(probe.transportIDs[.wirelessProduct] == "1234")
}

@Test func identityProbeRejectsConflictingAndUnknownModelIdentifiers() {
    let conflicting: [UInt8] = [0, 1, 2, 3, 4, 0, 0x06, 0xB0, 0x34, 0xB0, 0x42, 0, 0]
    do {
        _ = try LogitechIdentityProbe.decode(conflicting, connection: .bolt, endpointProductID: nil,
                                             featureIndex: 9, featureVersion: 6)
        Issue.record("Conflicting known model identifiers were accepted.")
    } catch let failure as BoltFailure {
        #expect(failure == .unsupportedModel)
    } catch {
        Issue.record("Unexpected identity probe error: \(error)")
    }

    let unknown: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x48, 0, 0, 0, 0]
    do {
        _ = try LogitechIdentityProbe.decode(unknown, connection: .bolt, endpointProductID: nil,
                                             featureIndex: 9, featureVersion: 6)
        Issue.record("An unknown model identifier was accepted.")
    } catch let failure as BoltFailure {
        #expect(failure == .unsupportedModel)
    } catch {
        Issue.record("Unexpected identity probe error: \(error)")
    }
}

@Test func identityProbeRequiresValidatedUnitAndModelIdentity() {
    let invalidUnit: [UInt8] = [0, 0, 0, 0, 0, 0, 0x02, 0xB0, 0x42, 0, 0, 0, 0]
    do {
        _ = try LogitechIdentityProbe.decode(invalidUnit, connection: .bolt, endpointProductID: nil,
                                             featureIndex: 9, featureVersion: 6)
        Issue.record("A zero unit identity was accepted.")
    } catch let failure as BoltFailure {
        #expect(failure == .identityUnavailable)
    } catch {
        Issue.record("Unexpected identity probe error: \(error)")
    }

    let unknownTransportMask: [UInt8] = [0, 1, 2, 3, 4, 0, 0x10, 0xB0, 0x42, 0, 0, 0, 0]
    do {
        _ = try LogitechIdentityProbe.decode(unknownTransportMask, connection: .bolt, endpointProductID: nil,
                                             featureIndex: 9, featureVersion: 6)
        Issue.record("An unknown transport mask was accepted.")
    } catch let failure as BoltFailure {
        #expect(failure == .identityUnavailable)
    } catch {
        Issue.record("Unexpected identity probe error: \(error)")
    }
}

@Test func endpointEligibilityRequiresKnownHIDPPOutputShape() {
    let valid = LogitechBluetoothOutputDescriptor(reportID: 0x11, usagePage: 0xFF00,
                                                  isOutput: true, reportCount: 19, reportSize: 8)
    #expect(LogitechEndpointEligibility.bluetoothOutputIsEligible(
        vendorID: 0x046D, productID: 0xB042, transport: "BluetoothLowEnergy", output: valid
    ))
    #expect(!LogitechEndpointEligibility.bluetoothOutputIsEligible(
        vendorID: 0x046D, productID: 0xB048, transport: "BluetoothLowEnergy", output: valid
    ))
    #expect(!LogitechEndpointEligibility.bluetoothOutputIsEligible(
        vendorID: 0x046D, productID: 0xB042, transport: "BluetoothLowEnergy",
        output: LogitechBluetoothOutputDescriptor(reportID: 0x10, usagePage: 0xFF00,
                                                  isOutput: true, reportCount: 19, reportSize: 8)
    ))
    #expect(!LogitechEndpointEligibility.bluetoothOutputIsEligible(
        vendorID: 0x046D, productID: 0xB042, transport: "BluetoothLowEnergy",
        output: LogitechBluetoothOutputDescriptor(reportID: 0x11, usagePage: 0x0001,
                                                  isOutput: true, reportCount: 19, reportSize: 8)
    ))
    #expect(!LogitechEndpointEligibility.bluetoothOutputIsEligible(
        vendorID: 0x046D, productID: 0xB042, transport: "BluetoothLowEnergy",
        output: LogitechBluetoothOutputDescriptor(reportID: 0x11, usagePage: 0xFF00,
                                                  isOutput: true, reportCount: 20, reportSize: 8)
    ))

    let nativeReports: [(UInt32, UInt32)] = [(0x11, kIOHIDElementTypeInput_Misc.rawValue), (0x11, kIOHIDElementTypeOutput.rawValue)]
    let invalidReports: [(UInt32, UInt32)] = [(0x11, kIOHIDElementTypeInput_Misc.rawValue), (0x11, 6)]
    #expect(LogitechEndpointEligibility.isEligibleBolt(
        vendorID: 0x046D, productID: 0xC548, transport: "USB", maxInputReportSize: 20,
        reportIDs: nativeReports
    ))
    #expect(!LogitechEndpointEligibility.isEligibleBolt(
        vendorID: 0x046D, productID: 0xC548, transport: "USB", maxInputReportSize: 20,
        reportIDs: invalidReports
    ))
    #expect(!LogitechEndpointEligibility.isEligibleBolt(
        vendorID: 0x046D, productID: 0xC548, transport: "USB", maxInputReportSize: 20,
        reportIDs: [(0x11, 1)]
    ))
}

@Test func verifiedTargetWinsOverUnselectedUnknownVariantAndCandidateSurvivesCleanup() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x42, 0, 0, 0, 0]
    let unknownPayload: [UInt8] = [0, 5, 6, 7, 8, 0, 0x02, 0xB0, 0x48, 0, 0, 0, 0]
    let targetLocator = LogitechEndpointLocator(id: UUID(), key: 1, connection: .bolt, productID: 0xC548)
    let unknownLocator = LogitechEndpointLocator(id: UUID(), key: 2, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    let catalog = EndpointFixtureCatalog(
        endpoints: [targetLocator, unknownLocator],
        payloads: [targetLocator.key: identityPayload, unknownLocator.key: unknownPayload],
        audit: audit
    )
    let controller = BoltController(
        makeTransport: { EndpointFixtureTransport(locator: targetLocator, payload: identityPayload, audit: audit) },
        endpointCatalog: catalog,
        requiresExplicitAssociation: true
    )
    let statuses = EndpointStatusRecorder()
    let reader = Task {
        for await event in controller.events {
            await statuses.append(event)
        }
    }
    defer { reader.cancel() }

    let candidates = try? await controller.existingConnections()
    #expect(candidates?.count == 1)
    guard let candidate = candidates?.first else {
        Issue.record("The synthetic MX Master 4 was not inventoried.")
        return
    }
    #expect(candidate.model == .mxMaster4)
    #expect(candidate.information.featureVersions[0x0003] == 6)

    let target = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )
    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    let ready = await statuses.last
    #expect(ready?.model == .mxMaster4)
    #expect(ready?.connection == .bolt)
    #expect(ready?.verifiedIdentity == candidate.identity)
    #expect(ready?.supportsManagement == false)
    #expect(await audit.setterRequestCount == 0)

    #expect(await controller.stopForRestart())
    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    #expect(await audit.setterRequestCount == 0)
}

@Test func managedSetterReservationIncludesIdentityChecksAndRollbackCapacity() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 3, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    let limits = EndpointFixtureLimits(available: [0x0001: 3, 0x0000: 6, 0x0900: 4])
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [locator.key: identityPayload],
                                         audit: audit, limits: limits)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: identityPayload, audit: audit, limits: limits)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }
    let candidates = try? await controller.existingConnections()
    guard let candidate = candidates?.first else {
        Issue.record("The synthetic MX Master 3S was not inventoried.")
        return
    }
    let target = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )

    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    await controller.enable()

    #expect(await endpointEventually {
        let last = await statuses.last
        return last?.phase == .failed && last?.failure?.code == .requestIDsExhausted
    })
    #expect(await audit.setterRequestCount == 0)
}

@Test func managedSetterRunsWhenIdentityAndRollbackPoolsMeetReservedBudget() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 4, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    let limits = EndpointFixtureLimits(available: [0x0001: 4, 0x0000: 6, 0x0900: 4])
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [locator.key: identityPayload],
                                         audit: audit, limits: limits)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: identityPayload, audit: audit, limits: limits)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }
    let candidates = try? await controller.existingConnections()
    guard let candidate = candidates?.first else {
        Issue.record("The synthetic MX Master 3S was not inventoried.")
        return
    }
    let target = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )

    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    await controller.enable()

    #expect(await endpointEventually { await statuses.last?.phase == .enabled })
    #expect(await audit.setterRequestCount == 2)
}

@Test func resolverRejectsDuplicateExactIdentitiesBeforeOpeningAManagedHandle() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let first = LogitechEndpointLocator(id: UUID(), key: 5, connection: .bolt, productID: 0xC548)
    let second = LogitechEndpointLocator(id: UUID(), key: 6, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    let catalog = EndpointFixtureCatalog(endpoints: [first, second],
                                         payloads: [first.key: identityPayload, second.key: identityPayload],
                                         audit: audit)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: first, payload: identityPayload, audit: audit)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }

    let candidates = try? await controller.existingConnections()
    #expect(candidates?.count == 2)
    guard let candidate = candidates?.first else {
        Issue.record("No exact-identity candidate was inventoried for the duplicate-resolution fixture.")
        return
    }
    let target = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )

    await controller.discover(target: target)

    #expect(await endpointEventually { await statuses.last?.phase == .failed })
    #expect((await statuses.last)?.failure?.code == .endpointAmbiguous)
    #expect(await audit.setterRequestCount == 0)
}

@Test func resolverRejectsAbsentSavedIdentityAndStaleInventoryToken() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 7, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [locator.key: identityPayload], audit: audit)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: identityPayload, audit: audit)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }

    let candidates = try? await controller.existingConnections()
    guard let candidate = candidates?.first else {
        Issue.record("The synthetic MX Master 3S was not inventoried for the absent-identity fixture.")
        return
    }
    let absent = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(
            identity: LogitechIdentity(unitID: "05060708", modelID: candidate.identity.modelID),
            preferredConnection: candidate.connection
        )
    )
    await controller.discover(target: absent)
    #expect(await endpointEventually { await statuses.last?.phase == .failed })
    #expect((await statuses.last)?.failure?.code == .identityMismatch)
    #expect(await audit.setterRequestCount == 0)

    let stale = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )
    _ = try? await controller.existingConnections()
    await controller.discover(target: stale)
    #expect(await endpointEventually { await statuses.last?.failure?.code == .candidateStale })
    #expect(await audit.setterRequestCount == 0)
}

@Test func resolverRejectsDeviceWhoseIdentityChangesAfterInventory() async {
    let originalPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let changedPayload: [UInt8] = [0, 5, 6, 7, 8, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 8, connection: .bolt, productID: 0xC548)
    let payloadStore = EndpointFixturePayloadStore([locator.key: originalPayload])
    let audit = EndpointFixtureAudit()
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [:], audit: audit,
                                         payloadStore: payloadStore)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: originalPayload, audit: audit,
                                 payloadStore: payloadStore)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }

    let candidates = try? await controller.existingConnections()
    guard let candidate = candidates?.first else {
        Issue.record("The synthetic MX Master 3S was not inventoried for the identity-swap fixture.")
        return
    }
    let target = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )
    await payloadStore.set(changedPayload, for: locator.key)

    await controller.discover(target: target)

    #expect(await endpointEventually { await statuses.last?.phase == .failed })
    #expect((await statuses.last)?.failure?.code == .identityMismatch)
    #expect(await audit.setterRequestCount == 0)
}

@Test func lifecycleStopDuringIdentityPreflightPreventsSetterDispatch() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 9, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [locator.key: identityPayload], audit: audit)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: identityPayload, audit: audit)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }

    let candidates = try? await controller.existingConnections()
    guard let candidate = candidates?.first else {
        Issue.record("The synthetic MX Master 3S was not inventoried for the stop-cancellation fixture.")
        return
    }
    let target = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )
    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })

    await audit.pauseNextIdentityProbe()
    let enable = Task { await controller.enable() }
    #expect(await endpointEventually { await audit.identityProbePaused })
    let stop = Task { await controller.stopForRestart() }
    #expect(await endpointEventually { await statuses.last?.phase == .stopping })
    await audit.resumeIdentityProbe()

    await enable.value
    #expect(await stop.value)
    #expect(await audit.setterRequestCount == 0)
}

@Test func cancelledExplicitPreflightStillAllowsVerifiedButtonRollback() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 11, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [locator.key: identityPayload], audit: audit)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: identityPayload, audit: audit)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }

    let candidates = try? await controller.existingConnections()
    guard let candidate = candidates?.first else {
        Issue.record("The synthetic MX Master 3S was not inventoried for the cancelled-preflight fixture.")
        return
    }
    let target = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )
    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })

    await audit.pauseIdentityProbe(onRead: 5)
    let enable = Task { await controller.enable() }
    #expect(await endpointEventually { await audit.identityProbePaused })
    enable.cancel()
    await audit.resumeIdentityProbe()
    await enable.value

    #expect(await endpointEventually {
        let last = await statuses.last
        return last?.phase == .failed && last?.cleanupUncertain == false
    })
    #expect(await audit.setterRequestCount == 2)
    #expect(await audit.buttonState(0x53) == 0)
    #expect(await audit.buttonState(0x56) == 0)
}

@Test func catalogAndTargetedDiscoveryDoNotRestartDuringPendingStop() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x42, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 12, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [locator.key: identityPayload], audit: audit)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: identityPayload, audit: audit)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }

    await audit.pauseNextIdentityProbe()
    let inventory = Task { try await controller.existingConnections() }
    #expect(await endpointEventually { await audit.identityProbePaused })

    let stop = Task { await controller.stopForRestart() }
    #expect(await endpointEventually { await statuses.last?.phase == .stopping })
    let target = LogitechConnectionTarget(
        model: .mxMaster4,
        association: LogitechAssociation(
            identity: LogitechIdentity(unitID: "01020304", modelID: "b04200000000"),
            preferredConnection: .bolt
        )
    )
    let queuedDiscovery = Task { await controller.discover(target: target) }
    let queuedInventory = Task { try await controller.existingConnections() }

    await audit.resumeIdentityProbe()
    let firstInventory = try? await inventory.value
    let cancelledInventory = try? await queuedInventory.value
    await queuedDiscovery.value

    #expect(firstInventory?.count == 1)
    #expect(cancelledInventory == nil)
    #expect(await stop.value)
    #expect(await audit.openedEndpoints.count == 1)
    #expect(await audit.setterRequestCount == 0)
}

@Test func uncertainCleanupAllowsOnlyTheRecordedAssociationToRecover() async {
    let identityPayload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let changedPayload: [UInt8] = [0, 5, 6, 7, 8, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 10, connection: .bolt, productID: 0xC548)
    let payloadStore = EndpointFixturePayloadStore([locator.key: identityPayload])
    let audit = EndpointFixtureAudit()
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [:], audit: audit,
                                         payloadStore: payloadStore)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: identityPayload, audit: audit,
                                 payloadStore: payloadStore)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }
    await audit.setButtonState(0x53, 1)

    let candidates = try? await controller.existingConnections()
    guard let candidate = candidates?.first else {
        Issue.record("The synthetic MX Master 3S was not inventoried for the uncertain-cleanup fixture.")
        return
    }
    let savedTarget = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: candidate.connection),
        candidateID: candidate.id
    )
    await audit.pauseIdentityProbe(onRead: 4)
    let discovery = Task { await controller.discover(target: savedTarget) }
    #expect(await endpointEventually { await audit.identityProbePaused })
    await payloadStore.set(changedPayload, for: locator.key)
    await audit.resumeIdentityProbe()
    await discovery.value

    #expect(await endpointEventually { await statuses.last?.phase == .failed })
    #expect((await statuses.last)?.cleanupUncertain == true)
    #expect(await audit.setterRequestCount == 0)

    let differentTarget = LogitechConnectionTarget(
        model: candidate.model,
        association: LogitechAssociation(
            identity: LogitechIdentity(unitID: "05060708", modelID: candidate.identity.modelID),
            preferredConnection: candidate.connection
        )
    )
    let statusCountBeforeDifferentTarget = await statuses.count
    await controller.discover(target: differentTarget)
    #expect(await endpointEventually {
        let count = await statuses.count
        let last = await statuses.last
        return count > statusCountBeforeDifferentTarget && last?.failure?.code == .identityMismatch
    })
    #expect(await audit.setterRequestCount == 0)

    await payloadStore.set(identityPayload, for: locator.key)
    await controller.discover(target: savedTarget)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    #expect((await statuses.last)?.cleanupUncertain == false)
    #expect(await audit.setterRequestCount == 1)
}

@Test func replacementBoltReceiverRecoversTheSameMouseWithoutLosingRepeatedStopPolicy() async throws {
    let payload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let original = LogitechEndpointLocator(id: UUID(), key: 10, connection: .bolt, productID: 0xC548)
    let replacement = LogitechEndpointLocator(id: UUID(), key: 20, connection: .bolt, productID: 0xC548)
    let payloadStore = EndpointFixturePayloadStore([original.key: payload, replacement.key: payload])
    let audit = EndpointFixtureAudit()
    await audit.configureWheel(root: [15, 0, 1])
    let catalog = SwitchingEndpointFixtureCatalog(endpoints: [original], audit: audit, payloadStore: payloadStore)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: original, payload: payload, audit: audit, payloadStore: payloadStore)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }
    let candidates = try await controller.existingConnections()
    let candidate = try #require(candidates.first)
    let target = LogitechConnectionTarget(model: candidate.model,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: .bolt))
    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    await controller.applyWheelPreference(true, restorePreviousSettingsOnDisconnect: true)
    #expect(await audit.wheelModeReply.first == 4)
    await audit.setWheelReadsFailing(true)
    let stopped = await controller.stopForConnectionChange(restorePreviousSettingsOnDisconnect: true)
    guard case .locallyStopped(_, .unverified(let recordedTarget)) = stopped else {
        Issue.record("The closed original receiver must retain its unverified mouse restoration.")
        return
    }
    #expect(recordedTarget == target)
    let writesBeforeRepeat = await audit.wheelWrites
    #expect(await controller.stopForConnectionChange(restorePreviousSettingsOnDisconnect: false) == stopped)
    #expect(await audit.wheelWrites == writesBeforeRepeat)
    #expect(await controller.stopForRestart() == false)

    let different = LogitechConnectionTarget(model: candidate.model,
        association: LogitechAssociation(identity: LogitechIdentity(unitID: "05060708", modelID: candidate.identity.modelID),
                                          preferredConnection: .bolt))
    await controller.discover(target: different)
    #expect(await endpointEventually { await statuses.last?.failure?.code == .identityMismatch })
    #expect(await audit.wheelWrites == writesBeforeRepeat)

    await catalog.replaceEndpoints([replacement])
    await audit.setWheelReadsFailing(false)
    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    #expect(await statuses.last?.cleanupUncertain == false)
    #expect(await audit.wheelModeReply.first == 0)
    #expect(await audit.wheelWrites == [[4], [0]])
    #expect(await audit.openedEndpoints.contains(replacement.key))
    #expect(await controller.stopForRestart())
}

private actor SwitchingEndpointFixtureCatalog: LogitechEndpointCatalog {
    private var endpoints: [LogitechEndpointLocator]
    private let audit: EndpointFixtureAudit
    private let payloadStore: EndpointFixturePayloadStore

    init(endpoints: [LogitechEndpointLocator], audit: EndpointFixtureAudit, payloadStore: EndpointFixturePayloadStore) {
        self.endpoints = endpoints
        self.audit = audit
        self.payloadStore = payloadStore
    }

    func replaceEndpoints(_ endpoints: [LogitechEndpointLocator]) { self.endpoints = endpoints }
    func enumerate() async -> [LogitechEndpointLocator] { endpoints }
    nonisolated func makeTransport(for locator: LogitechEndpointLocator,
                                   onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport {
        EndpointFixtureTransport(locator: locator, payload: [], audit: audit, payloadStore: payloadStore)
    }
}

@Test func connectionChangeRequiresAcknowledgementFromTemporaryIdentityProbes() async throws {
    let payload: [UInt8] = [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 10, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    await audit.setCloseResult(.unverified)
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [locator.key: payload], audit: audit)
    let controller = BoltController(makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: payload, audit: audit)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    #expect(try await controller.existingConnections().count == 1)
    #expect(await controller.stopForConnectionChange(restorePreviousSettingsOnDisconnect: true) == .blocked)
    await audit.setCloseResult(.closed)
    #expect(try await controller.existingConnections().count == 1)
    #expect(await controller.stopForConnectionChange(restorePreviousSettingsOnDisconnect: true) == .blocked)
    #expect(await audit.setterRequestCount == 0)
}


private func endpointEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private actor EndpointStatusRecorder {
    var statuses: [BoltStatus] = []

    func append(_ event: BoltEvent) {
        if case .status(let status) = event { statuses.append(status) }
    }

    var last: BoltStatus? { statuses.last }
    var count: Int { statuses.count }
}

private actor EndpointFixtureAudit {
    private(set) var setterRequestCount = 0
    private(set) var openedEndpoints: [UInt64] = []
    private(set) var closedEndpoints: [UInt64] = []
    var wheelRoot: [UInt8] = [0, 0, 0]
    var wheelCapabilities: [UInt8] = [12, 8]
    var wheelModeReply: [UInt8] = [0, 0]
    var wheelWrites: [[UInt8]] = []
    var failWheelReads = false
    var closeResult: BoltTransportCloseResult = .closed
    var nonWheelReads = 0
    var nonWheelSetterRequests = 0

    func configureWheel(root: [UInt8], capabilities: [UInt8] = [12, 8], mode: [UInt8] = [0, 0]) {
        wheelRoot = root
        wheelCapabilities = capabilities
        wheelModeReply = mode
    }

    func setWheelMode(_ reply: [UInt8]) { wheelModeReply = reply }
    func setCloseResult(_ result: BoltTransportCloseResult) { closeResult = result }
    func setWheelReadsFailing(_ failing: Bool) { failWheelReads = failing }

    func wheelRequest(function: UInt8, parameters: [UInt8]) throws -> [UInt8] {
        switch function {
        case 0: return wheelCapabilities
        case 1:
            guard !failWheelReads else { throw BoltFailure.timeout }
            return wheelModeReply
        case 2:
            wheelWrites.append(parameters)
            wheelModeReply = parameters + [0]
            return [0, 0, 0]
        default: throw BoltFailure.unsupported
        }
    }

    private var buttonStates: [UInt16: UInt8] = [0x53: 0, 0x56: 0]
    private var identityProbeCount = 0
    private var identityProbeAwaitingData = false
    private var pauseIdentityProbeOnRead: Int?
    private var identityProbeContinuation: CheckedContinuation<Void, Never>?
    private(set) var identityProbePaused = false

    func opened(_ key: UInt64) { openedEndpoints.append(key) }
    func closed(_ key: UInt64) { closedEndpoints.append(key) }
    func request(feature: UInt8, function: UInt8) {
        if function == 3 { setterRequestCount += 1 }
        if feature == 0x1B { nonWheelReads += 1 }
        if function == 2, feature != 0x1B, feature != wheelRoot.first { nonWheelSetterRequests += 1 }
    }
    func noteIdentityProbeRoot() { identityProbeAwaitingData = true }
    func pauseNextIdentityProbe() { pauseIdentityProbeOnRead = identityProbeCount + 1 }
    func pauseIdentityProbe(onRead read: Int) { pauseIdentityProbeOnRead = read }
    func waitIfIdentityProbePaused() async {
        guard identityProbeAwaitingData else { return }
        identityProbeAwaitingData = false
        identityProbeCount += 1
        guard pauseIdentityProbeOnRead == identityProbeCount else { return }
        pauseIdentityProbeOnRead = nil
        identityProbePaused = true
        await withCheckedContinuation { identityProbeContinuation = $0 }
        identityProbePaused = false
    }
    func resumeIdentityProbe() {
        identityProbeContinuation?.resume()
        identityProbeContinuation = nil
    }
    func buttonState(_ control: UInt16) -> UInt8 { buttonStates[control] ?? 0 }
    func setButtonState(_ control: UInt16, _ state: UInt8) { buttonStates[control] = state }
}

private struct EndpointFixtureLimits: Sendable {
    let available: [UInt16: Int]

    init(available: [UInt16: Int] = [:]) { self.available = available }

    func count(feature: UInt8, function: UInt8) -> Int {
        available[UInt16(feature) << 8 | UInt16(function)] ?? 15
    }
}

private actor EndpointFixturePayloadStore {
    private var payloads: [UInt64: [UInt8]]

    init(_ payloads: [UInt64: [UInt8]]) { self.payloads = payloads }

    func payload(for key: UInt64) -> [UInt8] { payloads[key] ?? [] }
    func set(_ payload: [UInt8], for key: UInt64) { payloads[key] = payload }
}

private struct EndpointFixtureCatalog: LogitechEndpointCatalog {
    let endpoints: [LogitechEndpointLocator]
    let payloads: [UInt64: [UInt8]]
    let audit: EndpointFixtureAudit
    let limits: EndpointFixtureLimits
    let payloadStore: EndpointFixturePayloadStore?

    init(endpoints: [LogitechEndpointLocator], payloads: [UInt64: [UInt8]], audit: EndpointFixtureAudit,
         limits: EndpointFixtureLimits = .init(), payloadStore: EndpointFixturePayloadStore? = nil) {
        self.endpoints = endpoints
        self.payloads = payloads
        self.audit = audit
        self.limits = limits
        self.payloadStore = payloadStore
    }

    func enumerate() async throws -> [LogitechEndpointLocator] { endpoints }

    func makeTransport(for locator: LogitechEndpointLocator,
                       onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport {
        EndpointFixtureTransport(locator: locator, payload: payloads[locator.key] ?? [], audit: audit,
                                 limits: limits, payloadStore: payloadStore)
    }
}

private struct EndpointFixtureTransport: BoltTransport {
    let locator: LogitechEndpointLocator
    let payload: [UInt8]
    let audit: EndpointFixtureAudit
    let limits: EndpointFixtureLimits
    let payloadStore: EndpointFixturePayloadStore?
    let events = AsyncStream<BoltTransportEvent> { $0.finish() }

    init(locator: LogitechEndpointLocator, payload: [UInt8], audit: EndpointFixtureAudit,
         limits: EndpointFixtureLimits = .init(), payloadStore: EndpointFixturePayloadStore? = nil) {
        self.locator = locator
        self.payload = payload
        self.audit = audit
        self.limits = limits
        self.payloadStore = payloadStore
    }

    func open() async throws { await audit.opened(locator.key) }
    func close() async { await audit.closed(locator.key) }
    func closeAndWait() async -> BoltTransportCloseResult {
        await close()
        return await audit.closeResult
    }
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int {
        limits.count(feature: feature, function: function)
    }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        await audit.request(feature: feature, function: function)
        guard slot == 1 else { throw BoltFailure.unavailable }
        if feature == 0, function == 1, parameters.count == 3 {
            await audit.noteIdentityProbeRoot()
            return [2, 0, parameters[2]]
        }
        if feature == 0, function == 0 {
            switch parameters {
            case [0x1B, 0x04]: return [0x1B, 0, 5]
            case [0x21, 0x21]: return await audit.wheelRoot
            case [0x21, 0x50]: return [0, 0, 0]
            default: throw BoltFailure.unavailable
            }
        }
        let wheelIndex = await audit.wheelRoot.first
        if feature == wheelIndex, feature != 0 {
            return try await audit.wheelRequest(function: function, parameters: parameters)
        }
        guard feature == 0x1B else { throw BoltFailure.unavailable }
        switch function {
        case 0: return [2]
        case 1:
            guard let index = parameters.first else { throw BoltFailure.unavailable }
            let row = index == 0 ? BoltWire.bytes(0x0053) + BoltWire.bytes(0x003C) : BoltWire.bytes(0x0056) + BoltWire.bytes(0x003E)
            return row + [0x20] + Array(repeating: 0, count: 11)
        case 2:
            guard parameters.count >= 2 else { throw BoltFailure.unavailable }
            let control = BoltWire.word(parameters, 0)
            return BoltWire.bytes(control) + [await audit.buttonState(control)] + [0, 0] + Array(repeating: 0, count: 11)
        case 3:
            guard parameters.count >= 3 else { throw BoltFailure.unavailable }
            let control = BoltWire.word(parameters, 0)
            await audit.setButtonState(control, parameters[2] == 3 ? 1 : 0)
            return BoltWire.bytes(control) + Array(repeating: 0, count: 14)
        default:
            throw BoltFailure.unavailable
        }
    }

    func requestDeviceInformation(slot: UInt8, feature: UInt8, function: UInt8,
                                  parameters: [UInt8]) async throws -> [UInt8] {
        await audit.request(feature: feature, function: function)
        if feature == 0, function == 0, parameters == [0, 3] { return [9, 0, 6] }
        if feature == 9, function == 0 {
            await audit.waitIfIdentityProbePaused()
            if let payloadStore { return await payloadStore.payload(for: locator.key) }
            return payload
        }
        return [0, 0, 0]
    }
}


@Test(arguments: [UInt8(0x17), 0x2A])
func mx4WheelDiscoversIndependentlyAndRestoresOnlyPhysicalFields(index: UInt8) async {
    let payload: [UInt8] = [0, 1, 2, 3, 4, 0, 2, 0xB0, 0x42, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 71, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    await audit.configureWheel(root: [index, 0, 1])
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [71: payload], audit: audit)
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: payload, audit: audit)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    defer { reader.cancel() }
    guard let candidate = try? await controller.existingConnections().first else {
        Issue.record("Missing synthetic MX4 candidate.")
        return
    }
    let target = LogitechConnectionTarget(model: .mxMaster4,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: .bolt), candidateID: candidate.id)
    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    #expect(await statuses.last?.wheel.support == .supported)
    #expect(await statuses.last?.supportsManagement == false)
    #expect(await audit.wheelWrites.isEmpty)
    #expect(await audit.nonWheelReads == 0)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await audit.wheelWrites == [[6]])
    await controller.enable()
    await controller.applyThumbwheelPreferences(inverted: true, amount: 2, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    #expect(await audit.wheelWrites == [[6]])
    #expect(await audit.setterRequestCount == 0)
    #expect(await audit.nonWheelSetterRequests == 0)
    #expect(await statuses.last?.wheel.captureActive == false)
    #expect(await controller.stopForRestart())
    #expect(await audit.wheelWrites == [[6], [0]])
    await controller.discover(target: target)
    #expect(await endpointEventually { await statuses.last?.wheel.support == .supported })
    #expect(await audit.wheelWrites == [[6], [0]])
    #expect(await controller.stopForRestart())
}


private func mx4WheelSession(root: [UInt8] = [23, 0, 1], capabilities: [UInt8] = [12, 8], mode: [UInt8] = [0, 0],
                             limits: EndpointFixtureLimits = .init()) async throws
    -> (BoltController, EndpointFixtureAudit, EndpointStatusRecorder, Task<Void, Never>, LogitechConnectionTarget) {
    let payload: [UInt8] = [0, 1, 2, 3, 4, 0, 2, 0xB0, 0x42, 0, 0, 0, 0]
    let locator = LogitechEndpointLocator(id: UUID(), key: 72, connection: .bolt, productID: 0xC548)
    let audit = EndpointFixtureAudit()
    await audit.configureWheel(root: root, capabilities: capabilities, mode: mode)
    let catalog = EndpointFixtureCatalog(endpoints: [locator], payloads: [72: payload], audit: audit, limits: limits)
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: {
        EndpointFixtureTransport(locator: locator, payload: payload, audit: audit, limits: limits)
    }, endpointCatalog: catalog, requiresExplicitAssociation: true)
    let statuses = EndpointStatusRecorder()
    let reader = Task { for await event in controller.events { await statuses.append(event) } }
    guard let candidate = try await controller.existingConnections().first else {
        reader.cancel()
        throw BoltFailure.unavailable
    }
    let target = LogitechConnectionTarget(model: .mxMaster4,
        association: LogitechAssociation(identity: candidate.identity, preferredConnection: .bolt), candidateID: candidate.id)
    await controller.discover(target: target)
    return (controller, audit, statuses, reader, target)
}

@Test func mx4WheelResolutionOnlyPreservesUnsupportedDirectionAndRestoresOwnedBit() async throws {
    let (controller, audit, statuses, reader, _) = try await mx4WheelSession(capabilities: [12, 0], mode: [4, 0])
    defer { reader.cancel() }
    #expect(await endpointEventually { await statuses.last?.wheel.support == .supported })
    #expect(await statuses.last?.wheel.supportsInversion == false)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await audit.wheelWrites.isEmpty)
    #expect(await statuses.last?.phase == .ready)
    await controller.applyWheelPreferences(inverted: nil, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await audit.wheelWrites == [[6]])
    #expect(await statuses.last?.wheel.supportsInversion == false)
    #expect(await controller.stopForRestart())
    #expect(await audit.wheelWrites == [[6], [4]])
}

@Test(arguments: [0, 1, 2, 3, 4, 5, 6])
func mx4WheelInvalidDiscoveryRemainsConnectedWithoutWrites(kind: Int) async throws {
    let roots: [[UInt8]] = [[0, 0, 0], [23, 0, 2], [23, 0], [23, 0, 1], [23, 0, 1], [23, 0, 1], [23, 0, 1]]
    let caps: [UInt8] = kind == 3 ? [12] : [12, 8]
    let modes: [[UInt8]] = [[0, 0], [0, 0], [0, 0], [0, 0], [0], [1, 0], [0, 1]]
    let (controller, audit, statuses, reader, _) = try await mx4WheelSession(root: roots[kind], capabilities: caps, mode: modes[kind])
    defer { reader.cancel() }
    #expect(await endpointEventually { await statuses.last?.phase == .ready })
    #expect(await statuses.last?.wheel.support == .unsupported)
    #expect(await statuses.last?.wheel.supportsInversion == false)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await audit.wheelWrites.isEmpty)
    #expect(await audit.nonWheelReads == 0)
    #expect(await controller.stopForRestart())
}

@Test(arguments: [0, 1, 2])
func mx4WheelCleanupRefusesRemappedFeatureLostCapabilityOrForeignMode(kind: Int) async throws {
    let (controller, audit, statuses, reader, _) = try await mx4WheelSession()
    defer { reader.cancel() }
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await audit.wheelWrites == [[6]])
    if kind == 0 { await audit.configureWheel(root: [42, 0, 1], mode: [6, 0]) }
    if kind == 1 { await audit.configureWheel(root: [23, 0, 1], capabilities: [12, 0], mode: [6, 0]) }
    if kind == 2 { await audit.setWheelMode([2, 0]) }
    #expect(await controller.stopForRestart() == false)
    #expect(await audit.wheelWrites == [[6]])
    #expect(await endpointEventually { await statuses.last?.cleanupUncertain == true })
}

@Test func mx4WheelIdentityAwaitCannotAuthorizeChangedMode() async throws {
    let (controller, audit, statuses, reader, _) = try await mx4WheelSession()
    defer { reader.cancel() }
    await audit.pauseNextIdentityProbe()
    let apply = Task { await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true) }
    #expect(await endpointEventually { await audit.identityProbePaused })
    await audit.setWheelMode([2, 0])
    await audit.resumeIdentityProbe()
    await apply.value
    #expect(await audit.wheelWrites.isEmpty)
    #expect(await endpointEventually { await statuses.last?.cleanupUncertain == true })
}

@Test(arguments: [false, true])
func mx4WheelCaptureOverloadWithNilAmountOnlyChangesPhysicalPreferences(posting: Bool) async throws {
    let (controller, audit, statuses, reader, _) = try await mx4WheelSession()
    defer { reader.cancel() }
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true,
                                          amount: nil, scrollPostingAllowed: posting)
    #expect(await audit.wheelWrites == [[6]])
    #expect(await statuses.last?.wheel.captureActive == false)
    #expect(await statuses.last?.wheel.support == .supported)
    #expect(await controller.stopForRestart())
    #expect(await audit.wheelWrites == [[6], [0]])
}

@Test(arguments: [UInt16(0), 0x1700, 0x1701, 0x1702, 0x0001, 0x0900])
func mx4WheelReservesFreshContractIdentityAndRollbackPools(pool: UInt16) async throws {
    let (controller, audit, _, reader, _) = try await mx4WheelSession(limits: .init(available: [pool: 1]))
    defer { reader.cancel() }
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await audit.wheelWrites.isEmpty)
}
