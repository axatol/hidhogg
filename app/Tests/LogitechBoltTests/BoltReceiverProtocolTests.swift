import Foundation
import Testing
@testable import LogitechBolt

@Test func receiverRegisterFramesUseShortAndLongReportsWithReceiverAddress() throws {
    let discoveryPayload: [UInt8] = [30, 1]
    let discovery = try BoltReceiverRegisterRequest(operation: .write, register: 0x00C0,
                                                     payload: discoveryPayload)
    #expect(discovery.frame() == [0x10, 0xFF, 0x80, 0xC0, 30, 1, 0])

    let pairPayload: [UInt8] = [1, 0, 0xA5, 0xA4, 0xA3, 0xA2, 0xA1, 0xA0, 0, 20]
    let pair = try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1,
                                                payload: pairPayload)
    let expectedPair: [UInt8] = [0x11, 0xFF, 0x82, 0xC1, 1, 0, 0xA5, 0xA4, 0xA3,
                                 0xA2, 0xA1, 0xA0, 0, 20, 0, 0, 0, 0, 0, 0]
    #expect(pair.frame() == expectedPair)
    #expect(pair.frame().count == 20)

    let cancelPayload: [UInt8] = [2]
    let cancelPairing = try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1,
                                                         payload: cancelPayload)
    let expectedCancel: [UInt8] = [0x11, 0xFF, 0x82, 0xC1, 2, 0, 0, 0, 0, 0,
                                   0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    #expect(cancelPairing.frame() == expectedCancel)

    let infoPayload: [UInt8] = [0x51]
    let pairingInfo = try BoltReceiverRegisterRequest(operation: .read, register: 0x02B5,
                                                       payload: infoPayload)
    #expect(pairingInfo.frame() == [0x10, 0xFF, 0x83, 0xB5, 0x51, 0, 0])
}

@Test func receiverRegisterFramesRejectPayloadsThatDoNotFitWireReports() throws {
    let shortPayload: [UInt8] = [1, 2, 3]
    let short = try BoltReceiverRegisterRequest(operation: .read, register: 0x00C0,
                                                 payload: shortPayload)
    #expect(short.frame().count == 7)

    let longPayload: [UInt8] = Array(repeating: UInt8(1), count: 16)
    let long = try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1,
                                                payload: longPayload)
    #expect(long.frame().count == 20)

    let oversizedPayload: [UInt8] = Array(repeating: UInt8(1), count: 17)
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1,
                                        payload: oversizedPayload)
    }
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverRegisterRequest(operation: .read, register: 0x0400, payload: shortPayload)
    }
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverRegisterRequest(operation: .read, register: 0x0100, payload: shortPayload)
    }
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverRegisterRequest(operation: .write, register: 0x0100, payload: shortPayload)
    }
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverRegisterRequest(operation: .read, register: 0x0300, payload: shortPayload)
    }
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverRegisterRequest(operation: .write, register: 0x0300, payload: shortPayload)
    }
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverRegisterRequest(operation: .read, register: 0x02B5, payload: [])
    }
}

@Test func receiverRegisterRepliesMatchAddressAndFullRequestIdentifier() throws {
    let payload: [UInt8] = [30, 1]
    let request = try BoltReceiverRegisterRequest(operation: .write, register: 0x00C0,
                                                   payload: payload)
    let replyPayload: [UInt8] = [2, 0, 0]
    let replyFrame: [UInt8] = [0x10, 0xFF, 0x80, 0xC0] + replyPayload
    #expect(BoltReceiverProtocol.response(replyFrame, for: request)
            == .reply(BoltReceiverRegisterReply(register: 0x00C0, payload: replyPayload)))

    let wrongAddress: [UInt8] = [0x10, 0x01, 0x80, 0xC0, 2, 0, 0]
    let wrongOperation: [UInt8] = [0x10, 0xFF, 0x81, 0xC0, 2, 0, 0]
    let wrongRegister: [UInt8] = [0x10, 0xFF, 0x80, 0xC1, 2, 0, 0]
    let wrongReportLength: [UInt8] = [0x10, 0xFF, 0x80, 0xC0, 2, 0]
    let wrongReportID: [UInt8] = [0x11, 0xFF, 0x80, 0xC0, 2, 0, 0]
    #expect(BoltReceiverProtocol.response(wrongAddress, for: request) == nil)
    #expect(BoltReceiverProtocol.response(wrongOperation, for: request) == nil)
    #expect(BoltReceiverProtocol.response(wrongRegister, for: request) == nil)
    #expect(BoltReceiverProtocol.response(wrongReportLength, for: request) == nil)
    #expect(BoltReceiverProtocol.response(wrongReportID, for: request) == nil)
    #expect(BoltReceiverProtocol.responseMatch(wrongReportLength, for: request) == .malformed)
    #expect(BoltReceiverProtocol.responseMatch(wrongReportID, for: request) == .malformed)

    let pairingInfoPayload: [UInt8] = [0x51]
    let pairingInfo = try BoltReceiverRegisterRequest(operation: .read, register: 0x02B5,
                                                       payload: pairingInfoPayload)
    let wrongBank: [UInt8] = [0x10, 0xFF, 0x82, 0xB5, 0x51, 0, 0]
    let staleSelectorReply: [UInt8] = [0x10, 0xFF, 0x83, 0xB5, 0x50, 2, 3]
    let pairingInfoReply: [UInt8] = [0x10, 0xFF, 0x83, 0xB5, 0x51, 2, 3]
    let pairingInfoReplyPayload: [UInt8] = [0x51, 2, 3]
    #expect(BoltReceiverProtocol.response(wrongBank, for: pairingInfo) == nil)
    #expect(BoltReceiverProtocol.response(staleSelectorReply, for: pairingInfo) == nil)
    #expect(BoltReceiverProtocol.response(pairingInfoReply, for: pairingInfo)
            == .reply(BoltReceiverRegisterReply(register: 0x02B5, payload: pairingInfoReplyPayload)))
}

@Test func receiverShortErrorsMatchLongRegisterRequestsWithoutMatchingUnrelatedErrors() throws {
    let payload: [UInt8] = [1, 0, 1, 2, 3, 4, 5, 6, 0, 20]
    let request = try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1,
                                                   payload: payload)
    let errorFrame: [UInt8] = [0x10, 0xFF, 0x8F, 0x82, 0xC1, 0x05, 0]
    let unrelatedError: [UInt8] = [0x10, 0xFF, 0x8F, 0x81, 0xC1, 0x05, 0]
    let truncatedError: [UInt8] = [0x10, 0xFF, 0x8F, 0x82, 0xC1, 0x05]
    #expect(BoltReceiverProtocol.response(errorFrame, for: request)
            == .error(BoltReceiverRegisterError(register: 0x02C1, code: 0x05)))
    #expect(BoltReceiverProtocol.response(unrelatedError, for: request) == nil)
    #expect(BoltReceiverProtocol.responseMatch(truncatedError, for: request) == .malformed)
}

@Test func receiverCancellationRequestsAreLimitedToDiscoveryAndPairingStopActions() throws {
    let stopDiscoveryPayload: [UInt8] = [0, 2]
    let stopDiscovery = try BoltReceiverRegisterRequest(operation: .write, register: 0x00C0,
                                                         payload: stopDiscoveryPayload)
    #expect(stopDiscovery.frame() == [0x10, 0xFF, 0x80, 0xC0, 0, 2, 0])
    let startDiscoveryPayload: [UInt8] = [30, 1]
    let startDiscovery = try BoltReceiverRegisterRequest(operation: .write, register: 0x00C0,
                                                          payload: startDiscoveryPayload)
    let cancelPairingPayload: [UInt8] = [2]
    let cancelPairing = try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1,
                                                         payload: cancelPairingPayload)
    let startPairingPayload: [UInt8] = [1, 0]
    let startPairing = try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1,
                                                        payload: startPairingPayload)
    let readRequest = try BoltReceiverRegisterRequest(operation: .read, register: 0x00C0, payload: [])

    #expect(BoltReceiverProtocol.isCancellation(stopDiscovery))
    #expect(!BoltReceiverProtocol.isCancellation(startDiscovery))
    #expect(BoltReceiverProtocol.isCancellation(cancelPairing))
    #expect(!BoltReceiverProtocol.isCancellation(startPairing))
    #expect(!BoltReceiverProtocol.isCancellation(readRequest))

    var ledger = BoltReceiverCancellationLedger()
    let firstStopClaim = ledger.claim(stopDiscovery)
    let repeatedStopClaim = ledger.claim(stopDiscovery)
    let firstPairCancelClaim = ledger.claim(cancelPairing)
    let repeatedPairCancelClaim = ledger.claim(cancelPairing)
    let startClaim = ledger.claim(startDiscovery)
    #expect(firstStopClaim)
    #expect(!repeatedStopClaim)
    #expect(firstPairCancelClaim)
    #expect(!repeatedPairCancelClaim)
    #expect(!startClaim)
}

@Test func receiverRegisterRepliesOutsideTheirDeadlineAreIgnored() throws {
    let requestPayload: [UInt8] = [30, 1]
    let request = try BoltReceiverRegisterRequest(operation: .write, register: 0x00C0,
                                                   payload: requestPayload)
    let replyPayload: [UInt8] = [2, 0, 0]
    let replyFrame: [UInt8] = [0x10, 0xFF, 0x80, 0xC0] + replyPayload

    #expect(BoltReceiverProtocol.response(replyFrame, for: request, now: 4, deadline: 5)
            == .reply(BoltReceiverRegisterReply(register: 0x00C0, payload: replyPayload)))
    #expect(BoltReceiverProtocol.response(replyFrame, for: request, now: 6, deadline: 5) == nil)
}

@Test func receiverNotificationsAreTypedAndKeepOnlyValidatedFullFrames() throws {
    let discoveryAdvertisement: [UInt8] = [0x11, 0xFF, 0x4F, 0, 0, 0, 0, 1, 2, 3,
                                           4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
    #expect(try BoltReceiverProtocol.notification(discoveryAdvertisement)
            == .discoveryAdvertisement(payload: discoveryAdvertisement))

    let recoveryAdvertisement: [UInt8] = [0x11, 0xFF, 0x52, 1, 2, 3, 4, 5, 6, 7,
                                          8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
    #expect(try BoltReceiverProtocol.notification(recoveryAdvertisement)
            == .recoveryAdvertisement(payload: recoveryAdvertisement))

    let pairingStatus: [UInt8] = [0x11, 0xFF, 0x54, 2, 0, 0, 0, 7, 0, 0, 0, 0,
                                  0, 0, 0, 0, 0, 0, 0, 0]
    #expect(try BoltReceiverProtocol.notification(pairingStatus)
            == .pairingStatus(state: 2, error: 0, payload: pairingStatus))

    let discoveryStatus: [UInt8] = [0x10, 0xFF, 0x53, 1, 0, 0, 0]
    #expect(try BoltReceiverProtocol.notification(discoveryStatus)
            == .discoveryStatus(state: 1, error: 0, payload: discoveryStatus))

    let passkeyDisplayed: [UInt8] = [0x11, 0xFF, 0x4D, 0, 0, 0, 0]
        + Array(repeating: UInt8(0), count: 13)
    #expect(try BoltReceiverProtocol.notification(passkeyDisplayed)
            == .passkeyDisplayed(payload: passkeyDisplayed))

    let passkeyEntry: [UInt8] = [0x11, 0xFF, 0x4E, 1, 0, 0, 0, 0, 0, 0,
                                 0, 0, 0, 0, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60]
    #expect(try BoltReceiverProtocol.notification(passkeyEntry)
            == .passkeyEntry(code: 1, payload: passkeyEntry))

    let featureNotification: [UInt8] = [0x11, 2, 0x4F, 0] + Array(repeating: UInt8(0), count: 16)
    #expect(try BoltReceiverProtocol.notification(featureNotification) == nil)
}

@Test func malformedReceiverNotificationsFailWithoutReturningTheirBytes() throws {
    let malformed: [UInt8] = [0x10, 0xFF, 0x54, 2]
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverProtocol.notification(malformed)
    }

    let shortAdvertisement: [UInt8] = [0x10, 0xFF, 0x4F, 1]
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverProtocol.notification(shortAdvertisement)
    }

    let shortPasskey: [UInt8] = [0x10, 0xFF, 0x4E, 1, 0, 0, 0]
    #expect(throws: BoltReceiverTransportFailure.malformed) {
        try BoltReceiverProtocol.notification(shortPasskey)
    }
}
