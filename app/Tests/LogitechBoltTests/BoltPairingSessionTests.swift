import Foundation
import Testing
import HidhoggDomain
@testable import LogitechBolt

@Test func pairingAdvertisementsReassembleBoundedNamesByPartAndSessionKey() throws {
    let name = "0123456789ABCDEFGHIJKLMabcdefghijklmnopqr"
    let nameBytes = Array(name.utf8)
    #expect(nameBytes.count == 41)

    let firstKey = BoltPairingCandidateKey(first: 0x31, second: 0x32)
    let secondKey = BoltPairingCandidateKey(first: 0x41, second: 0x42)
    let firstParts = try [
        BoltPairingProtocolDecoder.advertisement(advertisementPart(key: firstKey, part: 3,
                                                                    totalNameLength: nil,
                                                                    bytes: Array(nameBytes[27..<41]))),
        BoltPairingProtocolDecoder.advertisement(advertisementPart(key: firstKey, part: 1,
                                                                    totalNameLength: nameBytes.count,
                                                                    bytes: Array(nameBytes[0..<13]))),
        BoltPairingProtocolDecoder.advertisement(advertisementPart(key: firstKey, part: 2,
                                                                    totalNameLength: nil,
                                                                    bytes: Array(nameBytes[13..<27])))
    ]
    let otherPart = try BoltPairingProtocolDecoder.advertisement(advertisementPart(
        key: secondKey, part: 1, totalNameLength: 3, bytes: Array("MX4".utf8)
    ))

    var firstAssembly = BoltPairingCandidateAssembly()
    var secondAssembly = BoltPairingCandidateAssembly()
    for fragment in firstParts {
        if let total = fragment.nameTotalLength { firstAssembly.nameTotalLength = total }
        if let bytes = fragment.nameBytes { firstAssembly.fragments[fragment.part] = bytes }
    }
    if let total = otherPart.nameTotalLength { secondAssembly.nameTotalLength = total }
    if let bytes = otherPart.nameBytes { secondAssembly.fragments[otherPart.part] = bytes }

    #expect(firstParts.allSatisfy { $0.key == firstKey })
    #expect(otherPart.key == secondKey)
    #expect(firstAssembly.displayName == name)
    #expect(secondAssembly.displayName == "MX4")

    let unsupportedPart = advertisementPart(key: firstKey, part: 4, totalNameLength: nil, bytes: [])
    #expect(throws: BoltFailure.malformed) {
        try BoltPairingProtocolDecoder.advertisement(unsupportedPart)
    }
}

@Test func mouseChallengeUsesCountAndSixDigitTextWithoutTrailingAddressAssumptions() throws {
    var report: [UInt8] = [0x11, 0xFF, 0x4D, 3, 0x30, 0x30, 0x37]
    report += Array(repeating: 0xA5, count: 13)

    let challenge = try BoltPairingProtocolDecoder.challenge(report)
    #expect(challenge.directions.count == 10)
    #expect(challenge.directions.filter { $0 == .right }.count == 3)

    var invalid = report
    invalid[3] = 3
    invalid[6] = 0x58
    #expect(throws: BoltFailure.malformed) {
        try BoltPairingProtocolDecoder.challenge(invalid)
    }

    var outOfRange = report
    outOfRange[3] = 4
    outOfRange.replaceSubrange(4..<8, with: Array("1024".utf8))
    #expect(throws: BoltFailure.malformed) {
        try BoltPairingProtocolDecoder.challenge(outOfRange)
    }
}

@Test func challengeCompletionComesFromReceiverWithoutInventingClicks() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    fixture.receiver.emitChallenge("0007")
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge != nil })
    let initial = try #require(await fixture.session.currentStatus().challenge)
    #expect(initial.completedClicks == 0)
    #expect(initial.requiredClicks == 10)
    #expect(initial.confirmationDirection == .both)
    #expect(!initial.entryComplete)

    for _ in 0..<10 { fixture.receiver.emitProgress(1) }
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge?.completedClicks == 10 })
    #expect(await fixture.session.currentStatus().challenge?.entryComplete == false)
    fixture.receiver.emitProgress(4)
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge?.entryComplete == true })
    #expect(await fixture.session.currentStatus().challenge?.completedClicks == 10)
    fixture.receiver.emitProgress(3)
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge?.completedClicks == 0 })
    #expect(await fixture.session.currentStatus().challenge?.entryComplete == false)
    fixture.receiver.emitProgress(4)
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge?.entryComplete == true })
    #expect(await fixture.session.currentStatus().challenge?.completedClicks == 0)
    fixture.receiver.emitChallenge("0007")
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge?.entryComplete == true })
    fixture.receiver.emitProgress(0)
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge?.entryComplete == false })
    #expect(await fixture.session.currentStatus().phase == .authenticating)
    #expect(await fixture.session.currentStatus().verifiedCandidate == nil)
    await fixture.session.close()
}

@Test func passkeyProgressAndTerminalPairingRetainVendorAddressAndSlotFields() throws {
    let address: [UInt8] = [0x21, 0x22, 0x23, 0x24, 0x25, 0x26]
    var progress: [UInt8] = [0x11, 0xFF, 0x4E, 1] + address
    progress += Array(repeating: UInt8(0), count: 10)
    #expect(try BoltPairingProtocolDecoder.authenticationProgress(code: 1, payload: progress).address == address)

    var pairing: [UInt8] = [0x11, 0xFF, 0x54, 2, 0] + address + [4]
    pairing += Array(repeating: UInt8(0), count: 8)
    let terminal = try BoltPairingProtocolDecoder.pairingStatus(state: 2, error: 0, payload: pairing)
    #expect(terminal.address == address)
    #expect(terminal.slot == 4)
}

@Test func pairingRequiresVerifiedEmptyInventoryBeforeDiscoveryAndNeverOverwrites() async throws {
    let fullRecords = Dictionary(uniqueKeysWithValues: (UInt8(1)...UInt8(6)).map { slot in
        var record = pairingRecord(productID: 0xB034)
        if slot > 1 { record[1] |= 0x40 }
        return (slot, record)
    })
    let scenarios: [(records: [UInt8: [UInt8]], unknownSlot: UInt8?)] = [
        (fullRecords, nil),
        ([:], 1)
    ]

    for scenario in scenarios {
        let catalog = SyntheticPairingCatalog(records: scenario.records, unknownSlot: scenario.unknownSlot)
        let session = BoltPairingSession(catalog: catalog, cancellationReconciliationTimeout: .milliseconds(40))
        let receivers = try await session.receivers()
        let receiverID = try #require(receivers.first?.id)
        await session.start(receiverID: receiverID)
        let status = await session.currentStatus()
        let receiver = try #require(catalog.createdReceivers().first)

        #expect(status.phase == .failed)
        if scenario.unknownSlot == nil {
            #expect(status.message == "All 6 receiver slots contain stored pairings, including offline devices. Use another receiver to pair a new mouse.")
        }
        #expect(receiver.discoveryStartCount == 0)
        #expect(receiver.pairStartCount == 0)
        #expect(receiver.notificationRequests.isEmpty)
        await session.close()
        #expect(receiver.closeCount == 1)
    }
}

@Test func acknowledgementAndTimeoutAloneNeverProduceVerifiedPairing() async throws {
    let acknowledged = try await pairingFixture(pairRequestFailure: nil)
    await acknowledged.session.start(receiverID: acknowledged.receiverID)
    let selected = try await discoverCandidate(in: acknowledged)
    await acknowledged.session.select(candidateID: selected.id)

    let afterACK = await acknowledged.session.currentStatus()
    #expect(afterACK.phase == .authenticating)
    #expect(afterACK.verifiedCandidate == nil)
    #expect(afterACK.pairingMayHaveSucceeded)
    await acknowledged.session.close()
    let afterClose = await acknowledged.session.currentStatus()
    #expect(afterClose.phase == .pairedButNotAdded)
    #expect(afterClose.verifiedCandidate == nil)

    let timedOut = try await pairingFixture(pairRequestFailure: .timeout)
    await timedOut.session.start(receiverID: timedOut.receiverID)
    let timeoutCandidate = try await discoverCandidate(in: timedOut)
    await timedOut.session.select(candidateID: timeoutCandidate.id)
    let timeoutStatus = await timedOut.session.currentStatus()
    #expect(timeoutStatus.phase == .pairedButNotAdded)
    #expect(timeoutStatus.verifiedCandidate == nil)
    #expect(timeoutStatus.pairingMayHaveSucceeded)
    await timedOut.session.close()
}

@Test func terminalPairingRecordAndDynamicIdentityVerifyWithoutProgressCompletion() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)

    fixture.receiver.emitChallenge("0007")
    fixture.receiver.emitProgress(1)
    #expect(await pairingEventually {
        await fixture.session.currentStatus().challenge?.completedClicks == 1
    })

    fixture.receiver.insertPairing(slot: 1, productID: 0xB034)
    fixture.receiver.emitPairingStatus(state: 2, error: 0, slot: 1)
    fixture.receiver.emitPairingStatus(state: 2, error: 0, slot: 1)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .verified })

    let verified = await fixture.session.currentStatus()
    #expect(verified.verifiedCandidate?.model == .mxMaster3S)
    #expect(verified.verifiedCandidate?.identity == LogitechIdentity(unitID: "01020304", modelID: "b03412345678"))
    #expect(fixture.receiver.identityFeatureRequests == [9])
    #expect(fixture.receiver.pairingInfoReadCount == 18)
    #expect(verified.discoveryDiagnostics.advertisementEvents == 2)
    #expect(verified.discoveryDiagnostics.decodedAdvertisements == 2)

    fixture.receiver.emitAdvertisement()
    fixture.receiver.emitProgress(2)
    try await Task.sleep(for: .milliseconds(40))
    let afterLateDiscovery = await fixture.session.currentStatus()
    #expect(afterLateDiscovery.phase == .verified)
    #expect(afterLateDiscovery.verifiedCandidate == verified.verifiedCandidate)
    #expect(afterLateDiscovery.discoveryDiagnostics.advertisementEvents == 4)

    fixture.receiver.disconnect()
    #expect(await pairingEventually {
        await fixture.session.currentStatus().discoveryDiagnostics.transportFailures == 1
    })
    let afterTransportFailure = await fixture.session.currentStatus()
    #expect(afterTransportFailure.phase == .verified)
    #expect(afterTransportFailure.verifiedCandidate == verified.verifiedCandidate)
    await fixture.session.close()
    #expect(await fixture.session.currentStatus().verifiedCandidate == verified.verifiedCandidate)
    #expect(await fixture.session.currentStatus().discoveryDiagnostics.transportFailures == 1)
}

@Test func discoveryDiagnosticsCountValidIncompleteDuplicateUnsupportedAndMalformedAdvertisements() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .discovering })
    #expect(await fixture.session.currentStatus().discoveryDiagnostics == .init())

    let incomplete = advertisementPart(key: BoltPairingCandidateKey(first: 0x51, second: 0x52),
                                       part: 2, totalNameLength: nil, bytes: [0xA1, 0xA2])
    fixture.receiver.emitAdvertisement(payload: incomplete)
    fixture.receiver.emitAdvertisement()
    fixture.receiver.emitAdvertisement()
    fixture.receiver.emitAdvertisement(productID: 0xB048, keyFirst: 0x41,
                                      address: [0x21, 0x22, 0x23, 0x24, 0x25, 0x26])
    fixture.receiver.emitAdvertisement(payload: [0x11, 0xFF])

    #expect(await pairingEventually {
        let status = await fixture.session.currentStatus()
        return status.phase == .failed && status.discoveryDiagnostics.advertisementEvents == 8
    })
    let failed = await fixture.session.currentStatus()
    #expect(failed.discoveryDiagnostics.decodedAdvertisements == 7)
    #expect(failed.discoveryDiagnostics.rejectedAdvertisements == 1)
    #expect(failed.discoveryDiagnostics.unsupportedModelAdvertisements == 1)
    #expect(failed.candidates.count == 1)

    await fixture.session.close()
    #expect(await fixture.session.currentStatus().discoveryDiagnostics == failed.discoveryDiagnostics)

    let receivers = try await fixture.session.receivers()
    #expect(!receivers.isEmpty)
    #expect(await fixture.session.currentStatus().discoveryDiagnostics == .init())
}

@Test func discoveryDiagnosticsCountDiscoveryStatusAndRecoveryReceiverEvents() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)

    fixture.receiver.emitDiscoveryStatus(state: 0, error: 0)
    #expect(await pairingEventually {
        await fixture.session.currentStatus().discoveryDiagnostics.discoveryStatusEvents == 1
    })

    fixture.receiver.emitRecoveryAdvertisement()
    #expect(await pairingEventually {
        let status = await fixture.session.currentStatus()
        return status.phase == .failed && status.discoveryDiagnostics.recoveryEvents == 1
    })
    let failed = await fixture.session.currentStatus()
    #expect(failed.discoveryDiagnostics.advertisementEvents == 0)
    #expect(failed.discoveryDiagnostics.decodedAdvertisements == 0)
    #expect(failed.discoveryDiagnostics.discoveryStatusEvents == 1)
    #expect(failed.discoveryDiagnostics.recoveryEvents == 1)

    await fixture.session.close()
    #expect(await fixture.session.currentStatus().discoveryDiagnostics == failed.discoveryDiagnostics)
}

@Test func repeatedDiscoveryCountersRetainOneSelectableCandidate() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let first = try await discoverCandidate(in: fixture)

    for counter in UInt8(0)...UInt8(47) {
        let key = BoltPairingCandidateKey(first: counter, second: 0x71)
        fixture.receiver.emitAdvertisement(payload: advertisementPart(
            key: key, part: 1, totalNameLength: 12, bytes: Array("MX Master 3S".utf8)))
        fixture.receiver.emitAdvertisement(payload: advertisementPart(
            key: key, part: 0, totalNameLength: nil, bytes: []))
        #expect(await pairingEventually {
            await fixture.session.currentStatus().discoveryDiagnostics.advertisementEvents == 4 + Int(counter) * 2
        })
        let observed = await fixture.session.currentStatus()
        #expect(observed.phase == .awaitingSelection)
        #expect(observed.candidates == [first])
        #expect(observed.discoveryDiagnostics.rejectedAdvertisements == 0)
    }

    await fixture.session.select(candidateID: first.id)
    #expect(fixture.receiver.pairStartCount == 1)
    await fixture.session.close()
}

@Test func discoveryIgnoresUninterpretedMetadataAndNamePaddingChanges() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    let key = BoltPairingCandidateKey(first: 0x31, second: 0x32)
    var metadata = advertisementPart(key: key, part: 0, totalNameLength: nil, bytes: [])
    for index in [6, 16, 17, 19] { metadata[index] = 0xA5 }
    var name = advertisementPart(key: key, part: 1, totalNameLength: 12,
                                  bytes: Array("MX Master 3S".utf8))
    name[19] = 0xA5
    fixture.receiver.emitAdvertisement(payload: metadata)
    fixture.receiver.emitAdvertisement(payload: name)
    #expect(await pairingEventually {
        await fixture.session.currentStatus().discoveryDiagnostics.advertisementEvents == 4
    })
    let status = await fixture.session.currentStatus()
    #expect(status.phase == .awaitingSelection)
    #expect(status.candidates == [candidate])
    #expect(status.discoveryDiagnostics.rejectedAdvertisements == 0)
    await fixture.session.close()
}

@Test func discoveryFailureSurvivesLateEventsAndCloseWithCleanupEvidence() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0))
    await fixture.session.start(receiverID: fixture.receiverID)
    fixture.receiver.emitAdvertisement(payload: [0x11, 0xFF])
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .failed })
    let failed = await fixture.session.currentStatus()
    fixture.receiver.emitAdvertisement()
    fixture.receiver.emitDiscoveryStatus(state: 0, error: 0)
    fixture.receiver.emitDiscoveryStatus(state: 2, error: 0)
    #expect(await pairingEventually {
        await fixture.session.currentStatus().discoveryDiagnostics.discoveryStatusEvents == 2
    })
    let afterLateEvents = await fixture.session.currentStatus()
    #expect(afterLateEvents.phase == .failed)
    #expect(afterLateEvents.message == failed.message)
    await fixture.session.select(candidateID: UUID())
    #expect(fixture.receiver.pairStartCount == 0)
    await fixture.session.close()
    let closed = await fixture.session.currentStatus()
    #expect(closed.phase == .failed)
    #expect(closed.message == failed.message)
    #expect(closed.discoveryDiagnostics == afterLateEvents.discoveryDiagnostics)
    #expect(closed.notificationCleanupMessage == "Temporary receiver notification changes were restored and verified.")
    #expect(!closed.notificationCleanupRequiresAttention)
}

@Test(arguments: ["model", "kind", "address", "authentication", "name", "name-length", "new-counter-model", "new-counter-kind", "new-counter-authentication"])
func discoveryRetainsMeaningfulConflictGuards(field: String) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    _ = try await discoverCandidate(in: fixture)
    let key = BoltPairingCandidateKey(first: field.hasPrefix("new-counter") ? 0x41 : 0x31, second: 0x32)
    var report = advertisementPart(key: key, part: field.hasPrefix("name") ? 1 : 0,
                                    totalNameLength: 12, bytes: Array("MX Master 3S".utf8))
    switch field {
    case "model", "new-counter-model": report[8] = 0x42
    case "kind", "new-counter-kind": report[7] = 1
    case "address": report[10] = 0x21
    case "authentication", "new-counter-authentication": report[18] = 3
    case "name": report[7] = 0x41
    case "name-length": report[6] = 11
    default: Issue.record("Unknown synthetic conflict field.")
    }
    fixture.receiver.emitAdvertisement(payload: report)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .failed })
    #expect(await fixture.session.currentStatus().discoveryDiagnostics.rejectedAdvertisements == 1)
    #expect(await fixture.session.currentStatus().candidates.isEmpty)
    #expect(fixture.receiver.pairStartCount == 0)
    await fixture.session.close()
}

@Test(arguments: [true, false])
func discoveryBoundsDistinctPeersAndUnjoinedFragments(peers: Bool) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let limit = peers ? 16 : 32
    for index in 0...limit {
        let key = BoltPairingCandidateKey(first: UInt8(index), second: 0x71)
        var report = advertisementPart(key: key, part: peers ? 0 : 2, totalNameLength: nil, bytes: [])
        if peers { report[10] = UInt8(index + 1) }
        fixture.receiver.emitAdvertisement(payload: report)
        #expect(await pairingEventually {
            await fixture.session.currentStatus().discoveryDiagnostics.advertisementEvents == index + 1
        })
        let status = await fixture.session.currentStatus()
        #expect(status.candidates.count == (peers ? min(index + 1, limit) : 0))
        #expect(status.phase == (index == limit ? .failed : .awaitingSelection))
    }
    #expect(await fixture.session.currentStatus().discoveryDiagnostics.rejectedAdvertisements == 1)
    await fixture.session.close()
}

@Test(arguments: [false, true])
func deferredNameConflictsCompareOnlyDeclaredBytes(meaningful: Bool) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let key = BoltPairingCandidateKey(first: 0x31, second: 0x32)
    var continuation = advertisementPart(key: key, part: 2, totalNameLength: nil,
                                        bytes: Array("abc".utf8))
    fixture.receiver.emitAdvertisement(payload: continuation)
    continuation[meaningful ? 6 : 19] = 0xA5
    fixture.receiver.emitAdvertisement(payload: continuation)
    fixture.receiver.emitAdvertisement(payload: advertisementPart(
        key: key, part: 1, totalNameLength: 16, bytes: Array("0123456789ABC".utf8)))
    fixture.receiver.emitAdvertisement(payload: advertisementPart(
        key: key, part: 0, totalNameLength: nil, bytes: []))
    #expect(await pairingEventually {
        await fixture.session.currentStatus().discoveryDiagnostics.advertisementEvents == 4
    })
    let status = await fixture.session.currentStatus()
    #expect(status.phase == (meaningful ? .failed : .awaitingSelection))
    #expect(status.discoveryDiagnostics.rejectedAdvertisements == (meaningful ? 1 : 0))
    if !meaningful { #expect(status.candidates.first?.name == "0123456789ABCabc") }
    await fixture.session.close()
}

@Test func unsupportedAuthenticationAndUnknownProductCannotBeSelectedByName() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)

    fixture.receiver.emitAdvertisement(authentication: 3)
    fixture.receiver.emitAdvertisement(productID: 0xB048, keyFirst: 0x41,
                                      address: [0x21, 0x22, 0x23, 0x24, 0x25, 0x26])
    try await Task.sleep(for: .milliseconds(40))

    #expect(await fixture.session.currentStatus().candidates.isEmpty)
    #expect(await fixture.session.currentStatus().phase == .awaitingSelection)
    await fixture.session.select(candidateID: UUID())
    #expect(fixture.receiver.pairStartCount == 0)
    await fixture.session.close()
}

@Test func mx4AdvertisementDeviceKindMasksFlagsFromMouseKind() throws {
    let plainKindReport: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x00, 0x01, 0x02, 0x42, 0xB0,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xA5, 0x5A, 0x02, 0x00
    ]
    let flaggedKindReport: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x00, 0x01, 0x82, 0x42, 0xB0,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xA5, 0x5A, 0x02, 0x00
    ]

    let plainKind = try #require(BoltPairingProtocolDecoder.advertisement(plainKindReport).metadata)
    let flaggedKind = try #require(BoltPairingProtocolDecoder.advertisement(flaggedKindReport).metadata)
    #expect(plainKind.productID == 0xB042)
    #expect(flaggedKind.productID == 0xB042)
    #expect(plainKind.deviceKind == 0x02)
    #expect(flaggedKind.deviceKind == 0x02)
    #expect(plainKind.authentication == 0x02)
    #expect(flaggedKind.authentication == 0x02)
}

@Test func mx4PlainMouseKindCanBeSelectedThroughReceiverSession() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)

    let metadata: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x00, 0x01, 0x02, 0x42, 0xB0,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xA5, 0x5A, 0x02, 0x00
    ]
    let name: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x01, 0x0B, 0x4D, 0x58, 0x20,
        0x4D, 0x61, 0x73, 0x74, 0x65, 0x72, 0x20, 0x34, 0x00, 0x00
    ]
    fixture.receiver.emitAdvertisement(payload: metadata)
    fixture.receiver.emitAdvertisement(payload: name)

    #expect(await pairingEventually {
        let status = await fixture.session.currentStatus()
        return status.candidates.count == 1 && status.discoveryDiagnostics.advertisementEvents == 2
    })
    let candidate = try #require(await fixture.session.currentStatus().candidates.first)
    #expect(candidate.name == "MX Master 4")
    #expect(candidate.model == .mxMaster4)

    await fixture.session.select(candidateID: candidate.id)
    #expect(await fixture.session.currentStatus().phase == .authenticating)
    #expect(fixture.receiver.pairStartCount == 1)
    await fixture.session.close()
}

@Test func mx4FlaggedMouseKindCanBeSelectedAndRepeatedFlagsKeepCandidateIdentity() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)

    let flaggedMetadata: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x00, 0x01, 0x82, 0x42, 0xB0,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xA5, 0x5A, 0x02, 0x00
    ]
    let plainMetadata: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x00, 0x01, 0x02, 0x42, 0xB0,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xA5, 0x5A, 0x02, 0x00
    ]
    let name: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x01, 0x0B, 0x4D, 0x58, 0x20,
        0x4D, 0x61, 0x73, 0x74, 0x65, 0x72, 0x20, 0x34, 0x00, 0x00
    ]
    fixture.receiver.emitAdvertisement(payload: flaggedMetadata)
    fixture.receiver.emitAdvertisement(payload: name)

    #expect(await pairingEventually {
        let status = await fixture.session.currentStatus()
        return status.candidates.count == 1 && status.discoveryDiagnostics.advertisementEvents == 2
    })
    let candidate = try #require(await fixture.session.currentStatus().candidates.first)
    #expect(candidate.name == "MX Master 4")
    #expect(candidate.model == .mxMaster4)
    fixture.receiver.emitAdvertisement(payload: plainMetadata)
    #expect(await pairingEventually {
        await fixture.session.currentStatus().discoveryDiagnostics.advertisementEvents == 3
    })
    #expect(await fixture.session.currentStatus().candidates == [candidate])

    await fixture.session.select(candidateID: candidate.id)
    #expect(await fixture.session.currentStatus().phase == .authenticating)
    #expect(fixture.receiver.pairStartCount == 1)
    await fixture.session.close()
}

@Test func mx4NonMouseKindAndUnsupportedAuthenticationRemainIneligible() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)

    let nonMouse: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x73, 0x74, 0x00, 0x01, 0x81, 0x42, 0xB0,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xA5, 0x5A, 0x02, 0x00
    ]
    let unsupportedAuthentication: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x75, 0x76, 0x00, 0x01, 0x02, 0x42, 0xB0,
        0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xA5, 0x5A, 0x03, 0x00
    ]
    fixture.receiver.emitAdvertisement(payload: nonMouse)
    fixture.receiver.emitAdvertisement(payload: unsupportedAuthentication)

    #expect(await pairingEventually {
        await fixture.session.currentStatus().discoveryDiagnostics.advertisementEvents == 2
    })
    #expect(await fixture.session.currentStatus().candidates.isEmpty)
    await fixture.session.select(candidateID: UUID())
    #expect(fixture.receiver.pairStartCount == 0)
    await fixture.session.close()
}

@Test func mx4SemanticDeviceKindConflictStillInvalidatesCandidate() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)

    let mouse: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x00, 0x01, 0x82, 0x42, 0xB0,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xA5, 0x5A, 0x02, 0x00
    ]
    let name: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x01, 0x0B, 0x4D, 0x58, 0x20,
        0x4D, 0x61, 0x73, 0x74, 0x65, 0x72, 0x20, 0x34, 0x00, 0x00
    ]
    let differentKind: [UInt8] = [
        0x11, 0xFF, 0x4F, 0x71, 0x72, 0x00, 0x01, 0x81, 0x42, 0xB0,
        0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xA5, 0x5A, 0x02, 0x00
    ]
    fixture.receiver.emitAdvertisement(payload: mouse)
    fixture.receiver.emitAdvertisement(payload: name)
    #expect(await pairingEventually { await fixture.session.currentStatus().candidates.count == 1 })
    let candidate = try #require(await fixture.session.currentStatus().candidates.first)

    fixture.receiver.emitAdvertisement(payload: differentKind)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .failed })
    #expect(await fixture.session.currentStatus().discoveryDiagnostics.rejectedAdvertisements == 1)
    #expect(await fixture.session.currentStatus().candidates.isEmpty)
    await fixture.session.select(candidateID: candidate.id)
    #expect(fixture.receiver.pairStartCount == 0)
    await fixture.session.close()
}

@Test func cancellationWaitsForPairRequestDrainInsteadOfUsingShortReconciliationTimeout() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    fixture.receiver.pauseNextPairRequest()

    let selection = Task { await fixture.session.select(candidateID: candidate.id) }
    #expect(await pairingEventually { fixture.receiver.pairRequestIsPaused })
    let cancelFinished = SyntheticFlag()
    let cancellation = Task {
        await fixture.session.cancel()
        cancelFinished.set()
    }
    try await Task.sleep(for: .milliseconds(120))
    #expect(!cancelFinished.value)
    #expect(fixture.receiver.pairCancelCount == 0)

    fixture.receiver.resumePairRequest()
    await selection.value
    await cancellation.value
    #expect(cancelFinished.value)
    #expect(fixture.receiver.pairCancelCount == 1)
    await fixture.session.close()
}

@Test func cancellationWaitsForDiscoveryStartDrainBeforeSendingStop() async throws {
    let catalog = SyntheticPairingCatalog(records: [:], pauseDiscoveryStart: true)
    let session = BoltPairingSession(catalog: catalog, cancellationReconciliationTimeout: .milliseconds(40))
    let receivers = try await session.receivers()
    let receiverID = try #require(receivers.first?.id)

    let startFinished = SyntheticFlag()
    let start = Task {
        await session.start(receiverID: receiverID)
        startFinished.set()
    }
    #expect(await pairingEventually { catalog.createdReceivers().first?.discoveryStartIsPaused == true })
    let receiver = try #require(catalog.createdReceivers().first)

    let cancelFinished = SyntheticFlag()
    let cancellation = Task {
        await session.cancel()
        cancelFinished.set()
    }
    try await Task.sleep(for: .milliseconds(120))
    #expect(!startFinished.value)
    #expect(!cancelFinished.value)
    #expect(receiver.discoveryCancelCount == 0)

    receiver.resumeDiscoveryStart()
    await start.value
    await cancellation.value
    #expect(startFinished.value)
    #expect(cancelFinished.value)
    #expect(receiver.discoveryCancelCount == 1)
    #expect(receiver.pairStartCount == 0)
    #expect(await session.currentStatus().phase == .cancelled)
    await session.close()
}

@Test func cancellationFollowedByLateSuccessStaysPairedButNotAdded() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    await fixture.session.cancel()

    fixture.receiver.insertPairing(slot: 1, productID: 0xB034)
    fixture.receiver.emitPairingStatus(state: 2, error: 0, slot: 1)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .pairedButNotAdded })

    await fixture.session.close()
    let status = await fixture.session.currentStatus()
    #expect(status.phase == .pairedButNotAdded)
    #expect(status.pairingMayHaveSucceeded)
    #expect(status.verifiedCandidate == nil)
    #expect(fixture.receiver.closeCount == 1)
}

@Test func receiverRemovalDuringPairingPreservesUncertainOutcome() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    fixture.receiver.disconnect()
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .pairedButNotAdded })

    await fixture.session.close()
    let status = await fixture.session.currentStatus()
    #expect(status.phase == .pairedButNotAdded)
    #expect(status.pairingMayHaveSucceeded)
    #expect(status.verifiedCandidate == nil)
}

@Test func terminalAuthenticationFailureRequiresUnchangedFullInventory() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    fixture.receiver.emitChallenge("0007")
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge != nil })
    fixture.receiver.emitPairingStatus(state: 2, error: 2, slot: 0)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .failed })
    let failed = await fixture.session.currentStatus()
    #expect(!failed.pairingMayHaveSucceeded)
    #expect(failed.message == "The receiver reported a pairing failure during authentication; no new pairing was found.")
    #expect(fixture.receiver.pairingInfoReadCount == 18)
    await fixture.session.cancel()
    await fixture.session.close()
    let closed = await fixture.session.currentStatus()
    #expect(closed.phase == .failed)
    #expect(closed.message == failed.message)
    #expect(!closed.pairingMayHaveSucceeded)
    #expect(fixture.receiver.pairCancelCount == 0)
}

@Test(arguments: ["no-challenge", "address-mismatch", "changed-inventory", "unreadable-inventory", "timeout", "unknown-error", "nonterminal"])
func authenticationFailureRemainsUncertainWithoutCompleteEvidence(scenario: String) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    if scenario != "no-challenge" {
        fixture.receiver.emitChallenge("0007")
        #expect(await pairingEventually { await fixture.session.currentStatus().challenge != nil })
    }
    if scenario == "changed-inventory" { fixture.receiver.insertPairing(slot: 1, productID: 0xB034) }
    if scenario == "unreadable-inventory" { fixture.receiver.makeInventoryUnreadable(slot: 1) }
    let address: [UInt8] = scenario == "address-mismatch"
        ? [0x21, 0x22, 0x23, 0x24, 0x25, 0x26] : [0x11, 0x12, 0x13, 0x14, 0x15, 0x16]
    let error: UInt8 = scenario == "timeout" ? 1 : (scenario == "unknown-error" ? 3 : 2)
    fixture.receiver.emitPairingStatus(state: scenario == "nonterminal" ? 1 : 2,
                                      error: error, slot: 0, address: address)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .pairedButNotAdded })
    #expect(await fixture.session.currentStatus().pairingMayHaveSucceeded)
    await fixture.session.close()
    #expect(await fixture.session.currentStatus().phase == .pairedButNotAdded)
    #expect(await fixture.session.currentStatus().pairingMayHaveSucceeded)
    #expect(await fixture.session.currentStatus().verifiedCandidate == nil)
}

@Test func lateSuccessAfterReportedFailureStillVerifiesNewBond() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    fixture.receiver.emitChallenge("0007")
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge != nil })
    fixture.receiver.emitPairingStatus(state: 2, error: 2, slot: 0)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .failed })
    fixture.receiver.insertPairing(slot: 1, productID: 0xB034)
    fixture.receiver.emitPairingStatus(state: 2, error: 0, slot: 1)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .verified })
    let verified = await fixture.session.currentStatus()
    #expect(verified.pairingMayHaveSucceeded)
    #expect(verified.verifiedCandidate?.model == .mxMaster3S)
    await fixture.session.close()
    #expect(await fixture.session.currentStatus().verifiedCandidate == verified.verifiedCandidate)
}

@Test func closeWaitsForAuthenticationFailureInventoryBeforeRetainingReason() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    fixture.receiver.emitChallenge("0007")
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge != nil })
    fixture.receiver.pauseNextVerificationRead(identity: false)
    fixture.receiver.emitPairingStatus(state: 2, error: 2, slot: 0)
    #expect(await pairingEventually { fixture.receiver.verificationRequestIsPaused })
    let finished = SyntheticFlag()
    let close = Task {
        await fixture.session.close()
        finished.set()
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!finished.value)
    fixture.receiver.resumeVerificationRequest()
    await close.value
    let closed = await fixture.session.currentStatus()
    #expect(closed.phase == .failed)
    #expect(closed.message == "The receiver reported a pairing failure during authentication; no new pairing was found.")
    #expect(!closed.pairingMayHaveSucceeded)
}

@Test(arguments: [false, true])
func failedPairingCloseRechecksForChangedOrUnreadableInventory(unreadable: Bool) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    fixture.receiver.emitChallenge("0007")
    #expect(await pairingEventually { await fixture.session.currentStatus().challenge != nil })
    fixture.receiver.emitPairingStatus(state: 2, error: 2, slot: 0)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .failed })
    if unreadable { fixture.receiver.makeInventoryUnreadable(slot: 1) }
    else { fixture.receiver.insertPairing(slot: 1, productID: 0xB034) }
    await fixture.session.close()
    #expect(await fixture.session.currentStatus().phase == .pairedButNotAdded)
    #expect(await fixture.session.currentStatus().pairingMayHaveSucceeded)
    #expect(await fixture.session.currentStatus().verifiedCandidate == nil)
}

@Test func oneSessionCanRunANewReceiverAttemptAfterClose() async throws {
    let catalog = SyntheticPairingCatalog(records: [:])
    let session = BoltPairingSession(catalog: catalog, cancellationReconciliationTimeout: .milliseconds(40))

    let firstReceivers = try await session.receivers()
    let firstReceiverID = try #require(firstReceivers.first?.id)
    await session.start(receiverID: firstReceiverID)
    let firstReceiver = try #require(catalog.createdReceivers().first)
    await session.close()
    #expect(firstReceiver.closeCount == 1)

    let secondReceivers = try await session.receivers()
    let secondReceiverID = try #require(secondReceivers.first?.id)
    await session.start(receiverID: secondReceiverID)
    let receivers = catalog.createdReceivers()
    #expect(receivers.count == 2)
    #expect(receivers[1].openCount == 1)
    await session.close()
}

@Test func nativeDiagnosticsReachTimeoutEventWithoutAnyTypedReceiverEvents() async throws {
    let catalog = SyntheticPairingCatalog(records: [:])
    let session = BoltPairingSession(catalog: catalog, discoveryTimeout: .milliseconds(100))
    let receivers = try await session.receivers()
    let receiverID = try #require(receivers.first?.id)
    let terminal = Task { () -> BoltPairingStatus? in
        for await status in session.events {
            if status.phase == .failed { return status }
        }
        return nil
    }
    await session.start(receiverID: receiverID)
    let receiver = try #require(catalog.createdReceivers().first)
    let snapshot = BoltNativeInputDiagnostics(available: true, callbacks: 8, metadataRejected: 5,
                                                reportIDMismatch: 3)
    receiver.setInputDiagnostics(snapshot)
    let timedOut = try #require(await terminal.value)
    #expect(timedOut.message == "Discovery timed out without finding a verified supported mouse.")
    #expect(timedOut.discoveryDiagnostics == .init())
    #expect(timedOut.nativeInputDiagnostics == snapshot)
    await session.close()
    #expect(await session.currentStatus().nativeInputDiagnostics == snapshot)
    _ = try await session.receivers()
    #expect(await session.currentStatus().nativeInputDiagnostics == .init())
}

@Test func nativeSnapshotRefreshPreservesVerifiedStatusAndTypedDiagnostics() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    fixture.receiver.insertPairing(slot: 1, productID: 0xB034)
    fixture.receiver.emitPairingStatus(state: 2, error: 0, slot: 1)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .verified })
    let before = await fixture.session.currentStatus()
    let snapshot = BoltNativeInputDiagnostics(available: true, callbacks: 4, registerReplies: 2,
                                                featureReplies: 1, receiverNotifications: 1)
    fixture.receiver.setInputDiagnostics(snapshot)
    let after = await fixture.session.currentStatus()
    #expect(after.nativeInputDiagnostics == snapshot)
    #expect(after.phase == before.phase)
    #expect(after.message == before.message)
    #expect(after.candidates == before.candidates)
    #expect(after.challenge == before.challenge)
    #expect(after.verifiedCandidate == before.verifiedCandidate)
    #expect(after.pairingMayHaveSucceeded == before.pairingMayHaveSucceeded)
    #expect(after.discoveryDiagnostics == before.discoveryDiagnostics)
    await fixture.session.close()
    #expect(await fixture.session.currentStatus().nativeInputDiagnostics == snapshot)
}

@Test func delayedNativeSnapshotCannotReplaceNewerCloseEvidenceWithinSameAttempt() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil)
    await fixture.session.start(receiverID: fixture.receiverID)
    let earlier = BoltNativeInputDiagnostics(available: true, callbacks: 7, callbackErrors: 1,
                                               metadataRejected: 1, reportIDMismatch: 1,
                                               registerReplies: 1, featureReplies: 1,
                                               receiverNotifications: 1, unmatchedReports: 1)
    let latest = BoltNativeInputDiagnostics(available: true, callbacks: 14, callbackErrors: 2,
                                              metadataRejected: 2, reportIDMismatch: 2,
                                              registerReplies: 2, featureReplies: 2,
                                              receiverNotifications: 2, unmatchedReports: 2)
    fixture.receiver.setInputDiagnostics(earlier)
    fixture.receiver.pauseNextInputDiagnostics()
    fixture.receiver.emitDiscoveryStatus(state: 0, error: 0)
    let paused = await pairingEventually { fixture.receiver.inputDiagnosticsIsPaused }
    guard paused else {
        Issue.record("The receiver event did not pause its captured native snapshot.")
        await fixture.session.close()
        return
    }
    fixture.receiver.setInputDiagnostics(latest)
    let newerCloseSnapshot = Task { () -> BoltPairingStatus? in
        for await status in fixture.session.events {
            if status.phase == .cancelled && status.nativeInputDiagnostics == latest { return status }
        }
        return nil
    }
    let closing = Task { await fixture.session.close() }
    let published = try #require(await newerCloseSnapshot.value)
    #expect(published.nativeInputDiagnostics == latest)
    fixture.receiver.resumeInputDiagnostics()
    await closing.value
    let closed = await fixture.session.currentStatus()
    #expect(closed.nativeInputDiagnostics == latest)
    #expect(closed.phase == published.phase)
    #expect(closed.discoveryDiagnostics.discoveryStatusEvents == 1)
    _ = try await fixture.session.receivers()
    #expect(await fixture.session.currentStatus().nativeInputDiagnostics == .init())
}

@Test(arguments: [UInt32(0), 0x100, 0x800, 0x900, 0xA00020, 0xA00920])
func notificationLeasePreservesBaselineAndVerifiesBeforeDiscovery(baseline: UInt32) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: baseline))
    await fixture.session.start(receiverID: fixture.receiverID)
    let receiver = fixture.receiver
    let setup = await fixture.session.currentStatus()
    #expect(setup.phase == .discovering)
    #expect(setup.notificationSetupMessage != nil)
    #expect(receiver.notificationMask == baseline | 0x900)
    let owned = 0x900 & ~baseline
    #expect(receiver.notificationRequests.count == (owned == 0 ? 1 : 3))
    if owned != 0 {
        #expect(receiver.notificationRequests[1].payload == BoltReceiverNotificationLease.bytes(baseline | 0x900))
        let trace = receiver.requestTrace
        let start = try #require(trace.firstIndex(of: "write:192"))
        #expect(trace[start - 1] == "read:0")
    }
    await fixture.session.close()
    #expect(receiver.notificationMask == baseline)
    #expect(receiver.notificationRequests.count == (owned == 0 ? 1 : 6))
    let closed = await fixture.session.currentStatus()
    #expect(closed.notificationSetupMessage == setup.notificationSetupMessage)
    #expect(!closed.notificationCleanupRequiresAttention)
    if owned != 0 {
        #expect(closed.notificationCleanupMessage == "Temporary receiver notification changes were restored and verified.")
        #expect(Array(receiver.requestTrace.suffix(4)) == ["read:0", "write:0", "read:0", "close"])
    } else {
        #expect(closed.notificationCleanupMessage == nil)
    }
}

@Test func notificationLeaseRejectsSetupWithoutStartingDiscovery() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, failures: [2: .registerRejected(code: 3)]))
    await fixture.session.start(receiverID: fixture.receiverID)
    #expect(await fixture.session.currentStatus().phase == .failed)
    #expect(fixture.receiver.discoveryStartCount == 0)
    await fixture.session.close()
    #expect(fixture.receiver.notificationRequests.count == 2)
    #expect(fixture.receiver.notificationMask == 0)
}

@Test func notificationLeaseReadbackMismatchBlocksDiscoveryAndGuardsCleanup() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, readMasks: [3: 0x901, 4: 0x901]))
    await fixture.session.start(receiverID: fixture.receiverID)
    let status = await fixture.session.currentStatus()
    #expect(status.phase == .failed)
    #expect(fixture.receiver.discoveryStartCount == 0)
    #expect(status.notificationCleanupMessage == "Receiver notification flags changed; restoration was skipped to preserve external changes.")
    #expect(status.notificationCleanupRequiresAttention)
    await fixture.session.close()
    #expect(fixture.receiver.notificationRequests.filter { $0.operation == .write }.count == 1)
}

@Test(arguments: [2, 3])
func notificationLeaseTimeoutNeverResendsOrRestoresOnPoisonedChannel(ordinal: Int) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, failures: [ordinal: .timeout]))
    await fixture.session.start(receiverID: fixture.receiverID)
    let failed = await fixture.session.currentStatus()
    #expect(failed.phase == .failed)
    #expect(fixture.receiver.discoveryStartCount == 0)
    #expect(failed.notificationCleanupMessage == "Receiver notification restoration is uncertain; the request channel was not safe to reuse.")
    #expect(failed.notificationCleanupRequiresAttention)
    await fixture.session.cancel()
    await fixture.session.close()
    #expect(fixture.receiver.notificationRequests.count == ordinal)
    #expect(fixture.receiver.notificationMask == 0x900)
    _ = try await fixture.session.receivers()
    #expect(await fixture.session.currentStatus().notificationCleanupRequiresAttention == false)
}

@Test(arguments: [1, 2, 3])
func notificationLeaseCloseDrainsSetupAndPreventsLateDiscovery(ordinal: Int) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, pauseAt: ordinal))
    let start = Task { await fixture.session.start(receiverID: fixture.receiverID) }
    #expect(await pairingEventually {
        fixture.catalog.createdReceivers().last?.notificationRequestIsPaused == true
    })
    let receiver = fixture.receiver
    let cancel = Task { await fixture.session.cancel() }
    let close = Task { await fixture.session.close() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(receiver.closeCount == 0)
    #expect(receiver.notificationRequests.count == ordinal)
    receiver.resumeNotificationRequest()
    await start.value
    await cancel.value
    await close.value
    #expect(receiver.discoveryStartCount == 0)
    #expect(receiver.notificationMask == 0)
    #expect(receiver.closeCount == 1)
    #expect(receiver.notificationRequests.filter { $0.operation == .write }.count == (ordinal == 1 ? 0 : 2))
}

@Test func notificationLeaseConcurrentCancelCloseSharesOneRestoration() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, pauseAt: 5))
    await fixture.session.start(receiverID: fixture.receiverID)
    let receiver = fixture.receiver
    let cancel = Task { await fixture.session.cancel() }
    #expect(await pairingEventually { receiver.notificationRequestIsPaused })
    let close = Task { await fixture.session.close() }
    let secondClose = Task { await fixture.session.close() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(receiver.closeCount == 0)
    #expect(receiver.notificationRequests.count == 5)
    receiver.resumeNotificationRequest()
    await cancel.value
    await close.value
    await secondClose.value
    #expect(receiver.notificationRequests.count == 6)
    #expect(receiver.notificationMask == 0)
    #expect(receiver.requestTrace.filter { $0 == "close" }.count == 1)
}

@Test func notificationLeaseDuplicateCancelWaitsForDiscoveryStopBeforeRestoration() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0))
    await fixture.session.start(receiverID: fixture.receiverID)
    let receiver = fixture.receiver
    receiver.pauseNextCancellation()
    let firstCancel = Task { await fixture.session.cancel() }
    #expect(await pairingEventually { receiver.cancellationIsPaused })
    let secondFinished = SyntheticFlag()
    let secondCancel = Task {
        await fixture.session.cancel()
        secondFinished.set()
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!secondFinished.value)
    #expect(receiver.notificationRequests.count == 3)
    #expect(receiver.notificationMask == 0x900)
    receiver.resumeCancellation()
    await firstCancel.value
    await secondCancel.value
    #expect(receiver.discoveryCancelCount == 1)
    #expect(receiver.notificationRequests.count == 6)
    #expect(receiver.notificationMask == 0)
    #expect(await fixture.session.currentStatus().phase == .cancelled)
    await fixture.session.close()
}

@Test(arguments: [1, 2, 3, 4, 5, 6])
func notificationLeaseFailureDuringReadPreventsFurtherNotificationRequests(ordinal: Int) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, pauseAt: ordinal))
    let operation = Task {
        await fixture.session.start(receiverID: fixture.receiverID)
        if ordinal >= 4 { await fixture.session.cancel() }
    }
    #expect(await pairingEventually {
        fixture.catalog.createdReceivers().last?.notificationRequestIsPaused == true
    })
    let receiver = fixture.receiver
    receiver.emitFailure(.eventOverflow)
    #expect(await pairingEventually {
        await fixture.session.currentStatus().discoveryDiagnostics.transportFailures == 1
    })
    receiver.resumeNotificationRequest()
    await operation.value
    await fixture.session.close()
    #expect(receiver.notificationRequests.count == ordinal)
    #expect(receiver.notificationRequests.filter { $0.operation == .write }.count == (ordinal == 1 ? 0 : ordinal >= 5 ? 2 : 1))
    if ordinal <= 3 { #expect(receiver.discoveryStartCount == 0) }
    if ordinal >= 4 {
        #expect(await fixture.session.currentStatus().notificationCleanupMessage == "Receiver notification restoration is uncertain; the request channel was not safe to reuse.")
    }
}

@Test(arguments: [false, true])
func notificationLeaseWaitsForAuthenticationTimeoutPairCancel(closeInsteadOfCancel: Bool) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0),
                                           authenticationTimeout: .milliseconds(50))
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    let receiver = fixture.receiver
    await fixture.session.select(candidateID: candidate.id)
    receiver.pauseNextCancellation()
    #expect(await pairingEventually { receiver.cancellationIsPaused })
    let finished = SyntheticFlag()
    let operation = Task {
        if closeInsteadOfCancel { await fixture.session.close() }
        else { await fixture.session.cancel() }
        finished.set()
    }
    try await Task.sleep(for: .milliseconds(80))
    #expect(!finished.value)
    #expect(receiver.notificationRequests.count == 3)
    #expect(receiver.notificationMask == 0x900)
    #expect(receiver.closeCount == 0)
    receiver.resumeCancellation()
    await operation.value
    #expect(receiver.pairCancelCount == 1)
    if closeInsteadOfCancel {
        #expect(receiver.notificationRequests.count == 6)
        #expect(receiver.notificationMask == 0)
    } else {
        #expect(receiver.notificationRequests.count == 3)
        #expect(receiver.notificationMask == 0x900)
        #expect(await fixture.session.currentStatus().notificationCleanupRequiresAttention == true)
    }
    await fixture.session.close()
    #expect(receiver.notificationRequests.count == 6)
    #expect(receiver.notificationMask == 0)
    #expect(await fixture.session.currentStatus().notificationCleanupRequiresAttention == false)
}

@Test(arguments: [false, true])
func notificationLeaseCancelWaitsForAdmittedPairingVerification(identityRead: Bool) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0))
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    let receiver = fixture.receiver
    receiver.insertPairing(slot: 1, productID: 0xB034)
    receiver.pauseNextVerificationRead(identity: identityRead)
    receiver.emitPairingStatus(state: 2, error: 0, slot: 1)
    #expect(await pairingEventually { receiver.verificationRequestIsPaused })
    let finished = SyntheticFlag()
    let cancel = Task {
        await fixture.session.cancel()
        finished.set()
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!finished.value)
    #expect(receiver.notificationRequests.count == 3)
    #expect(receiver.notificationMask == 0x900)
    receiver.resumeVerificationRequest()
    await cancel.value
    #expect(await fixture.session.currentStatus().phase == .pairedButNotAdded)
    #expect(await fixture.session.currentStatus().pairingMayHaveSucceeded == true)
    #expect(await fixture.session.currentStatus().verifiedCandidate == nil)
    #expect(receiver.notificationRequests.count == 6)
    #expect(receiver.notificationMask == 0)
    #expect(await fixture.session.currentStatus().notificationCleanupMessage == "Temporary receiver notification changes were restored and verified.")
    #expect(await fixture.session.currentStatus().notificationCleanupRequiresAttention == false)
    await fixture.session.close()
}

@Test func notificationLeaseLateVerificationWaitsForCleanupAndDrainsBeforeClose() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, pauseAt: 4))
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    let receiver = fixture.receiver
    let closeFinished = SyntheticFlag()
    let close = Task {
        await fixture.session.close()
        closeFinished.set()
    }
    #expect(await pairingEventually { receiver.notificationRequestIsPaused })
    let inventoryReads = receiver.pairingInfoReadCount
    receiver.insertPairing(slot: 1, productID: 0xB034)
    receiver.pauseNextVerificationRead(identity: false)
    receiver.emitPairingStatus(state: 2, error: 0, slot: 1)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .verifying })
    #expect(!receiver.verificationRequestIsPaused)
    #expect(receiver.pairingInfoReadCount == inventoryReads)
    #expect(receiver.identityFeatureRequests.isEmpty)
    receiver.resumeNotificationRequest()
    #expect(await pairingEventually { receiver.verificationRequestIsPaused })
    #expect(!closeFinished.value)
    #expect(receiver.closeCount == 0)
    receiver.resumeVerificationRequest()
    await close.value
    #expect(receiver.identityFeatureRequests == [9])
    #expect(receiver.notificationRequests.count == 6)
    #expect(receiver.notificationMask == 0)
    #expect(await fixture.session.currentStatus().phase == .pairedButNotAdded)
    #expect(await fixture.session.currentStatus().pairingMayHaveSucceeded == true)
    #expect(await fixture.session.currentStatus().verifiedCandidate == nil)
    #expect(await fixture.session.currentStatus().notificationCleanupMessage == "Temporary receiver notification changes were restored and verified.")
    #expect(await fixture.session.currentStatus().notificationCleanupRequiresAttention == false)
}

@Test func notificationLeaseCancelDrainsSetupAndRestoresWithoutClosing() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, pauseAt: 2))
    let start = Task { await fixture.session.start(receiverID: fixture.receiverID) }
    #expect(await pairingEventually {
        fixture.catalog.createdReceivers().last?.notificationRequestIsPaused == true
    })
    let cancel = Task { await fixture.session.cancel() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(fixture.receiver.notificationRequests.count == 2)
    fixture.receiver.resumeNotificationRequest()
    await start.value
    await cancel.value
    #expect(await fixture.session.currentStatus().phase == .cancelled)
    #expect(fixture.receiver.discoveryStartCount == 0)
    #expect(fixture.receiver.notificationMask == 0)
    #expect(fixture.receiver.closeCount == 0)
    await fixture.session.close()
    #expect(fixture.receiver.notificationRequests.count == 6)
}

@Test(arguments: [1, 3])
func notificationLeaseUnreadableFlagsPreventDiscovery(ordinal: Int) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, failures: [ordinal: .registerRejected(code: 3)]))
    await fixture.session.start(receiverID: fixture.receiverID)
    #expect(await fixture.session.currentStatus().phase == .failed)
    #expect(fixture.receiver.discoveryStartCount == 0)
    await fixture.session.close()
    #expect(fixture.receiver.notificationMask == 0)
    #expect(fixture.receiver.notificationRequests.count == (ordinal == 1 ? 1 : 6))
}

@Test(arguments: [4, 5, 6])
func notificationLeaseCleanupFailureIsUncertainAndNeverRetried(ordinal: Int) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, failures: [ordinal: .timeout]))
    await fixture.session.start(receiverID: fixture.receiverID)
    await fixture.session.cancel()
    #expect(await fixture.session.currentStatus().notificationCleanupMessage == "Receiver notification restoration is uncertain; the request channel was not safe to reuse.")
    #expect(await fixture.session.currentStatus().notificationCleanupRequiresAttention == true)
    #expect(fixture.receiver.notificationRequests.count == ordinal)
    await fixture.session.close()
    #expect(fixture.receiver.notificationRequests.count == ordinal)
}

@Test(arguments: [UInt32(0x1900), 0x800, 0x0])
func notificationLeasePreservesUnexpectedExternalMask(mask: UInt32) async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0))
    await fixture.session.start(receiverID: fixture.receiverID)
    fixture.receiver.setNotificationMask(mask)
    await fixture.session.close()
    #expect(fixture.receiver.notificationMask == mask)
    #expect(fixture.receiver.notificationRequests.filter { $0.operation == .write }.count == 1)
    #expect(await fixture.session.currentStatus().notificationCleanupMessage == "Receiver notification flags changed; restoration was skipped to preserve external changes.")
    #expect(await fixture.session.currentStatus().notificationCleanupRequiresAttention == true)
}

@Test func notificationLeaseRestorationACKRequiresReadbackAndPreservesVerifiedOutcome() async throws {
    let fixture = try await pairingFixture(pairRequestFailure: nil,
                                           notifications: .init(baseline: 0, readMasks: [6: 0x900]))
    await fixture.session.start(receiverID: fixture.receiverID)
    let candidate = try await discoverCandidate(in: fixture)
    await fixture.session.select(candidateID: candidate.id)
    fixture.receiver.insertPairing(slot: 1, productID: 0xB034)
    fixture.receiver.emitPairingStatus(state: 2, error: 0, slot: 1)
    #expect(await pairingEventually { await fixture.session.currentStatus().phase == .verified })
    fixture.receiver.setInputDiagnostics(.init(available: true, callbacks: 12))
    let verified = await fixture.session.currentStatus()
    await fixture.session.close()
    let closed = await fixture.session.currentStatus()
    #expect(closed.phase == .verified)
    #expect(closed.message == verified.message)
    #expect(closed.verifiedCandidate == verified.verifiedCandidate)
    #expect(closed.pairingMayHaveSucceeded == verified.pairingMayHaveSucceeded)
    #expect(closed.discoveryDiagnostics == verified.discoveryDiagnostics)
    #expect(closed.nativeInputDiagnostics == verified.nativeInputDiagnostics)
    #expect(closed.notificationSetupMessage == verified.notificationSetupMessage)
    #expect(closed.notificationCleanupMessage == "Receiver notification restoration did not match its verification readback.")
    #expect(closed.notificationCleanupRequiresAttention)
}

private struct PairingFixture: Sendable {
    let session: BoltPairingSession
    let catalog: SyntheticPairingCatalog
    let receiverID: UUID

    var receiver: SyntheticPairingReceiver { catalog.createdReceivers().last! }
}

private func pairingFixture(pairRequestFailure: BoltReceiverTransportFailure?,
                            notifications: SyntheticNotificationScenario = .init(),
                            authenticationTimeout: Duration = .seconds(60)) async throws -> PairingFixture {
    let catalog = SyntheticPairingCatalog(records: [:], pairRequestFailure: pairRequestFailure,
                                          notifications: notifications)
    let session = BoltPairingSession(catalog: catalog, authenticationTimeout: authenticationTimeout,
                                      cancellationReconciliationTimeout: .milliseconds(40))
    let receivers = try await session.receivers()
    let receiverID = try #require(receivers.first?.id)
    return PairingFixture(session: session, catalog: catalog, receiverID: receiverID)
}

private func discoverCandidate(in fixture: PairingFixture) async throws -> BoltPairingCandidate {
    fixture.receiver.emitAdvertisement()
    guard await pairingEventually({
        let status = await fixture.session.currentStatus()
        return status.candidates.count == 1 && status.discoveryDiagnostics.advertisementEvents == 2
    }) else {
        Issue.record("Synthetic candidate was not discovered.")
        throw BoltFailure.timeout
    }
    return try #require(await fixture.session.currentStatus().candidates.first)
}

private func pairingEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<300 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private func advertisementPart(key: BoltPairingCandidateKey, part: UInt8,
                               totalNameLength: Int?, bytes: [UInt8],
                               productID: UInt16 = 0xB034,
                               authentication: UInt8 = BoltPairingProtocolDecoder.twoButtonAuthentication) -> [UInt8] {
    var report = Array(repeating: UInt8(0), count: 20)
    report[0] = 0x11
    report[1] = 0xFF
    report[2] = 0x4F
    report[3] = key.first
    report[4] = key.second
    report[5] = part
    if part == 0 {
        report[7] = BoltPairingProtocolDecoder.mouseDeviceKind
        report[8] = UInt8(productID & 0xFF)
        report[9] = UInt8(productID >> 8)
        report.replaceSubrange(10..<16, with: [0x11, 0x12, 0x13, 0x14, 0x15, 0x16])
        report[18] = authentication
    } else if part == 1 {
        report[6] = UInt8(totalNameLength ?? bytes.count)
        report.replaceSubrange(7..<min(20, 7 + bytes.count), with: bytes.prefix(13))
    } else {
        report.replaceSubrange(6..<min(20, 6 + bytes.count), with: bytes.prefix(14))
    }
    return report
}

private func pairingRecord(productID: UInt16) -> [UInt8] {
    [0x51, 0x02, UInt8(productID & 0xFF), UInt8(productID >> 8), 1, 2, 3, 4]
}

private struct SyntheticNotificationScenario: Sendable {
    var baseline: UInt32 = 0x900
    var failures: [Int: BoltReceiverTransportFailure] = [:]
    var readMasks: [Int: UInt32] = [:]
    var pauseAt: Int?
}

private final class SyntheticPairingCatalog: LogitechEndpointCatalog, @unchecked Sendable {
    let locator = LogitechEndpointLocator(id: UUID(), key: 1, connection: .bolt, productID: 0xC548)
    private let lock = NSLock()
    private let records: [UInt8: [UInt8]]
    private let unknownSlot: UInt8?
    private let pairRequestFailure: BoltReceiverTransportFailure?
    private let pauseDiscoveryStart: Bool
    private let notifications: SyntheticNotificationScenario
    private var receivers: [SyntheticPairingReceiver] = []

    init(records: [UInt8: [UInt8]], unknownSlot: UInt8? = nil,
         pairRequestFailure: BoltReceiverTransportFailure? = nil,
         pauseDiscoveryStart: Bool = false,
         notifications: SyntheticNotificationScenario = .init()) {
        self.records = records
        self.unknownSlot = unknownSlot
        self.pairRequestFailure = pairRequestFailure
        self.pauseDiscoveryStart = pauseDiscoveryStart
        self.notifications = notifications
    }

    func enumerate() async throws -> [LogitechEndpointLocator] { [locator] }

    func makeTransport(for locator: LogitechEndpointLocator,
                       onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport {
        makeReceiverTransport(for: locator, onTerminal: onTerminal) ?? SyntheticPairingReceiver(records: records)
    }

    func makeReceiverTransport(for locator: LogitechEndpointLocator,
                               onTerminal: @escaping @Sendable () -> Void) -> (any BoltReceiverTransport)? {
        guard locator.id == self.locator.id else { return nil }
        let receiver = SyntheticPairingReceiver(records: records, unknownSlot: unknownSlot,
                                                pairRequestFailure: pairRequestFailure,
                                                pauseDiscoveryStart: pauseDiscoveryStart,
                                                notifications: notifications)
        lock.lock()
        receivers.append(receiver)
        lock.unlock()
        return receiver
    }

    func createdReceivers() -> [SyntheticPairingReceiver] {
        lock.lock()
        defer { lock.unlock() }
        return receivers
    }
}

private final class SyntheticFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool { lock.withLock { storedValue } }
    func set() { lock.withLock { storedValue = true } }
}

private final class SyntheticPairingReceiver: BoltReceiverTransport, @unchecked Sendable {
    let events: AsyncStream<BoltTransportEvent>
    let receiverEvents: AsyncStream<BoltReceiverEvent>
    private let transportContinuation: AsyncStream<BoltTransportEvent>.Continuation
    private let receiverContinuation: AsyncStream<BoltReceiverEvent>.Continuation
    private let lock = NSLock()
    private var records: [UInt8: [UInt8]]
    private var unknownSlot: UInt8?
    private let pairRequestFailure: BoltReceiverTransportFailure?
    private var requests: [BoltReceiverRegisterRequest] = []
    private var cancellationRequests: [BoltReceiverRegisterRequest] = []
    private var disconnected = false
    private var closed = false
    private var opens = 0
    private var pairRequestShouldPause = false
    private var pairRequestPausedFlag = false
    private var pairRequestContinuation: CheckedContinuation<Void, Never>?
    private var discoveryStartShouldPause: Bool
    private var discoveryStartPausedFlag = false
    private var discoveryStartContinuation: CheckedContinuation<Void, Never>?
    private var requestedIdentityFeatures: [UInt8] = []
    private var diagnosticsSnapshot = BoltNativeInputDiagnostics()
    private var inputDiagnosticsShouldPause = false
    private var inputDiagnosticsContinuation: CheckedContinuation<Void, Never>?
    private let notifications: SyntheticNotificationScenario
    private var storedNotificationMask: UInt32
    private var notificationRequestCount = 0
    private var notificationContinuation: CheckedContinuation<Void, Never>?
    private var trace: [String] = []
    private var cancellationShouldPause = false
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var verificationPauseIdentity: Bool?
    private var verificationContinuation: CheckedContinuation<Void, Never>?

    init(records: [UInt8: [UInt8]], unknownSlot: UInt8? = nil,
         pairRequestFailure: BoltReceiverTransportFailure? = nil,
         pauseDiscoveryStart: Bool = false,
         notifications: SyntheticNotificationScenario = .init()) {
        self.records = records
        self.unknownSlot = unknownSlot
        self.pairRequestFailure = pairRequestFailure
        discoveryStartShouldPause = pauseDiscoveryStart
        self.notifications = notifications
        storedNotificationMask = notifications.baseline
        let transportStream = AsyncStream<BoltTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        events = transportStream.stream
        transportContinuation = transportStream.continuation
        let receiverStream = AsyncStream<BoltReceiverEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        receiverEvents = receiverStream.stream
        receiverContinuation = receiverStream.continuation
    }

    func open() async throws {
        lock.withLock { opens += 1 }
    }

    func inputDiagnostics() async -> BoltNativeInputDiagnostics {
        let (snapshot, shouldPause) = lock.withLock {
            let shouldPause = inputDiagnosticsShouldPause
            inputDiagnosticsShouldPause = false
            return (diagnosticsSnapshot, shouldPause)
        }
        if shouldPause {
            await withCheckedContinuation { continuation in
                lock.withLock { inputDiagnosticsContinuation = continuation }
            }
        }
        return snapshot
    }

    func setInputDiagnostics(_ snapshot: BoltNativeInputDiagnostics) {
        lock.withLock { diagnosticsSnapshot = snapshot }
    }

    var inputDiagnosticsIsPaused: Bool {
        lock.withLock { inputDiagnosticsContinuation != nil }
    }

    func pauseNextInputDiagnostics() {
        lock.withLock { inputDiagnosticsShouldPause = true }
    }

    func resumeInputDiagnostics() {
        let continuation = lock.withLock {
            let continuation = inputDiagnosticsContinuation
            inputDiagnosticsContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int { 8 }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        guard feature == 0, function == 1, parameters.count >= 3 else { throw BoltFailure.unavailable }
        return [2, 0, parameters[2]]
    }

    func requestDeviceInformation(slot: UInt8, feature: UInt8, function: UInt8,
                                  parameters: [UInt8]) async throws -> [UInt8] {
        if feature == 0, parameters == BoltWire.bytes(0x0003) { return [9, 0, 1] }
        if feature == 9, function == 0, parameters.isEmpty {
            await pauseVerificationIfNeeded(identity: true)
            lock.withLock { requestedIdentityFeatures.append(feature) }
            return [0, 1, 2, 3, 4, 0, 0x02, 0xB0, 0x34, 0x12, 0x34, 0x56, 0x78]
        }
        throw BoltFailure.unavailable
    }

    func registerRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverRegisterReply {
        lock.withLock { trace.append("\(request.operation):\(request.register)") }
        if request.register == 0 {
            let ordinal = lock.withLock {
                requests.append(request)
                notificationRequestCount += 1
                return notificationRequestCount
            }
            if ordinal == notifications.pauseAt {
                await withCheckedContinuation { continuation in
                    lock.withLock { notificationContinuation = continuation }
                }
            }
            return try lock.withLock {
                guard !closed, !disconnected else { throw BoltReceiverTransportFailure.disconnected }
                guard verificationContinuation == nil else { throw BoltReceiverTransportFailure.busy }
                if request.operation == .write {
                    let rejected: Bool
                    if case .registerRejected = notifications.failures[ordinal] { rejected = true }
                    else { rejected = false }
                    if !rejected {
                        storedNotificationMask = UInt32(request.payload[0]) << 16
                            | UInt32(request.payload[1]) << 8 | UInt32(request.payload[2])
                    }
                }
                if let failure = notifications.failures[ordinal] { throw failure }
                let mask = notifications.readMasks[ordinal] ?? storedNotificationMask
                return BoltReceiverRegisterReply(register: 0, payload: BoltReceiverNotificationLease.bytes(mask))
            }
        }
        if request.operation == .write, request.register == 0x00C0, request.payload.first == 30 {
            let shouldPause = lock.withLock {
                requests.append(request)
                let shouldPause = discoveryStartShouldPause
                discoveryStartShouldPause = false
                return shouldPause
            }
            if shouldPause {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock {
                        discoveryStartPausedFlag = true
                        discoveryStartContinuation = continuation
                    }
                }
            }
            guard lock.withLock({ !disconnected && !closed }) else {
                throw BoltReceiverTransportFailure.disconnected
            }
            return BoltReceiverRegisterReply(register: request.register, payload: [])
        }

        if request.operation == .write, request.register == 0x02C1, request.payload.first == 1 {
            let shouldPause = lock.withLock {
                requests.append(request)
                let shouldPause = pairRequestShouldPause
                pairRequestShouldPause = false
                return shouldPause
            }
            if shouldPause {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock {
                        pairRequestPausedFlag = true
                        pairRequestContinuation = continuation
                    }
                }
            }
            guard lock.withLock({ !disconnected && !closed }) else {
                throw BoltReceiverTransportFailure.disconnected
            }
            if let pairRequestFailure { throw pairRequestFailure }
            return BoltReceiverRegisterReply(register: request.register, payload: [])
        }

        if request.operation == .read, request.register == 0x02B5 {
            await pauseVerificationIfNeeded(identity: false)
        }
        let availability = lock.withLock { () -> (Bool, [UInt8]?) in
            requests.append(request)
            if request.operation == .read, request.register == 0x02B5,
               let selector = request.payload.first, selector >= 0x51, selector <= 0x56 {
                let slot = selector - 0x50
                return (!disconnected && !closed && slot != unknownSlot, records[slot])
            }
            return (!disconnected && !closed, nil)
        }
        guard availability.0 else {
            if request.operation == .read, request.register == 0x02B5 { throw BoltReceiverTransportFailure.timeout }
            throw BoltReceiverTransportFailure.disconnected
        }

        if request.operation == .read, request.register == 0x02B5 {
            guard let selector = request.payload.first, selector >= 0x51, selector <= 0x56 else {
                throw BoltReceiverTransportFailure.malformed
            }
            guard let record = availability.1 else { throw BoltReceiverTransportFailure.registerRejected(code: 0x08) }
            return BoltReceiverRegisterReply(register: request.register, payload: [selector] + record.dropFirst())
        }
        if request.operation == .read, request.register == 0x0002 {
            return BoltReceiverRegisterReply(register: request.register, payload: [0, 0])
        }
        return BoltReceiverRegisterReply(register: request.register, payload: request.payload)
    }

    func cancelRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverCancellationResult {
        let shouldPause = lock.withLock {
            let shouldPause = cancellationShouldPause
            cancellationShouldPause = false
            return shouldPause
        }
        if shouldPause {
            await withCheckedContinuation { continuation in
                lock.withLock { cancellationContinuation = continuation }
            }
        }
        let available = lock.withLock {
            trace.append("cancel:\(request.register)")
            cancellationRequests.append(request)
            return !disconnected && !closed
        }
        guard available else { throw BoltReceiverTransportFailure.disconnected }
        return .acknowledged(BoltReceiverRegisterReply(register: request.register, payload: request.payload))
    }

    func close() async {
        let shouldFinish = lock.withLock {
            trace.append("close")
            let wasOpen = !closed
            closed = true
            return wasOpen
        }
        if shouldFinish {
            transportContinuation.finish()
            receiverContinuation.finish()
        }
    }

    func emitAdvertisement(authentication: UInt8 = 2, productID: UInt16 = 0xB034,
                            keyFirst: UInt8 = 0x31,
                            address: [UInt8] = [0x11, 0x12, 0x13, 0x14, 0x15, 0x16]) {
        var metadata = advertisementPart(key: BoltPairingCandidateKey(first: keyFirst, second: 0x32),
                                         part: 0, totalNameLength: nil, bytes: [],
                                         productID: productID, authentication: authentication)
        metadata.replaceSubrange(10..<16, with: address)
        receiverContinuation.yield(.notification(.discoveryAdvertisement(
            payload: metadata
        ), at: .now))
        receiverContinuation.yield(.notification(.discoveryAdvertisement(
            payload: advertisementPart(key: BoltPairingCandidateKey(first: keyFirst, second: 0x32),
                                       part: 1, totalNameLength: 12, bytes: Array("MX Master 3S".utf8))
        ), at: .now))
    }

    func emitAdvertisement(payload: [UInt8]) {
        receiverContinuation.yield(.notification(.discoveryAdvertisement(payload: payload), at: .now))
    }

    func emitDiscoveryStatus(state: UInt8, error: UInt8) {
        let payload: [UInt8] = [0x10, 0xFF, 0x53, state, error, 0, 0]
        receiverContinuation.yield(.notification(.discoveryStatus(state: state, error: error,
                                                                    payload: payload), at: .now))
    }

    func emitRecoveryAdvertisement() {
        receiverContinuation.yield(.notification(.recoveryAdvertisement(payload: []), at: .now))
    }

    func emitChallenge(_ text: String) {
        var payload: [UInt8] = [0x11, 0xFF, 0x4D, UInt8(text.utf8.count)] + Array(text.utf8)
        payload += Array(repeating: UInt8(0xA5), count: 20 - payload.count)
        receiverContinuation.yield(.notification(.passkeyDisplayed(payload: payload), at: .now))
    }

    func emitProgress(_ code: UInt8) {
        let address: [UInt8] = [0x11, 0x12, 0x13, 0x14, 0x15, 0x16]
        var payload: [UInt8] = [0x11, 0xFF, 0x4E, code] + address
        payload += Array(repeating: UInt8(0), count: 20 - payload.count)
        receiverContinuation.yield(.notification(.passkeyEntry(code: code, payload: payload), at: .now))
    }

    func emitPairingStatus(state: UInt8, error: UInt8, slot: UInt8,
                           address: [UInt8] = [0x11, 0x12, 0x13, 0x14, 0x15, 0x16]) {
        var payload: [UInt8] = [0x11, 0xFF, 0x54, state, error] + address + [slot]
        payload += Array(repeating: UInt8(0), count: 20 - payload.count)
        receiverContinuation.yield(.notification(.pairingStatus(state: state, error: error, payload: payload), at: .now))
    }

    func insertPairing(slot: UInt8, productID: UInt16) {
        lock.withLock { records[slot] = pairingRecord(productID: productID) }
    }

    func makeInventoryUnreadable(slot: UInt8) {
        lock.withLock { unknownSlot = slot }
    }

    func disconnect() {
        lock.withLock { disconnected = true }
        receiverContinuation.yield(.failure(.disconnected))
    }

    func emitFailure(_ failure: BoltReceiverTransportFailure) {
        receiverContinuation.yield(.failure(failure))
    }

    func pauseNextCancellation() {
        lock.withLock { cancellationShouldPause = true }
    }

    var cancellationIsPaused: Bool { lock.withLock { cancellationContinuation != nil } }

    func resumeCancellation() {
        let continuation = lock.withLock {
            let continuation = cancellationContinuation
            cancellationContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func pauseNextVerificationRead(identity: Bool) {
        lock.withLock { verificationPauseIdentity = identity }
    }

    var verificationRequestIsPaused: Bool { lock.withLock { verificationContinuation != nil } }

    private func pauseVerificationIfNeeded(identity: Bool) async {
        let shouldPause = lock.withLock {
            guard verificationPauseIdentity == identity else { return false }
            verificationPauseIdentity = nil
            return true
        }
        guard shouldPause else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { verificationContinuation = continuation }
        }
    }

    func resumeVerificationRequest() {
        let continuation = lock.withLock {
            let continuation = verificationContinuation
            verificationContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func pauseNextPairRequest() {
        lock.withLock { pairRequestShouldPause = true }
    }

    func pauseNextDiscoveryStart() {
        lock.withLock { discoveryStartShouldPause = true }
    }

    var pairRequestIsPaused: Bool { lock.withLock { pairRequestPausedFlag } }
    var discoveryStartIsPaused: Bool { lock.withLock { discoveryStartPausedFlag } }

    func resumePairRequest() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = pairRequestContinuation
            pairRequestContinuation = nil
            pairRequestPausedFlag = false
            return continuation
        }
        continuation?.resume()
    }

    func resumeDiscoveryStart() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let continuation = discoveryStartContinuation
            discoveryStartContinuation = nil
            discoveryStartPausedFlag = false
            return continuation
        }
        continuation?.resume()
    }

    var discoveryStartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.operation == .write && $0.register == 0x00C0 && $0.payload.first != 0 }.count
    }

    var pairStartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.operation == .write && $0.register == 0x02C1 && $0.payload.first == 1 }.count
    }

    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return opens
    }

    var closeCount: Int {
        lock.withLock { closed ? 1 : 0 }
    }

    var pairCancelCount: Int {
        lock.withLock { cancellationRequests.filter { $0.register == 0x02C1 }.count }
    }

    var discoveryCancelCount: Int {
        lock.withLock { cancellationRequests.filter { $0.register == 0x00C0 }.count }
    }

    var pairingInfoReadCount: Int {
        lock.withLock { requests.filter { $0.operation == .read && $0.register == 0x02B5 }.count }
    }

    var identityFeatureRequests: [UInt8] { lock.withLock { requestedIdentityFeatures } }

    var notificationRequests: [BoltReceiverRegisterRequest] {
        lock.withLock { requests.filter { $0.register == 0 } }
    }

    var notificationMask: UInt32 { lock.withLock { storedNotificationMask } }
    var requestTrace: [String] { lock.withLock { trace } }
    var notificationRequestIsPaused: Bool { lock.withLock { notificationContinuation != nil } }

    func setNotificationMask(_ mask: UInt32) {
        lock.withLock { storedNotificationMask = mask }
    }

    func resumeNotificationRequest() {
        let continuation = lock.withLock {
            let continuation = notificationContinuation
            notificationContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
