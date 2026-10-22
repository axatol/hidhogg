import Foundation
import Testing
import HidhoggDomain
@testable import LogitechBolt

@Test func deviceInformationDefaultsPreserveExistingStatusConstruction() {
    let status = BoltStatus(phase: .ready, message: "Connected", availableControls: [], generation: 1, cleanupUncertain: false)
    #expect(status.deviceInformation == .init())
}

@Test func unifiedBatteryUsesOnlyAdvertisedPercentageAndPreservesUnknownCharging() throws {
    let percent = try BoltDeviceInformationReader.BatteryCapabilities([0, 2])
    let levels = try BoltDeviceInformationReader.BatteryCapabilities([15, 0])
    let observed = Date(timeIntervalSince1970: 1234)
    let value = try BoltDeviceInformationReader.battery([73, 4, 7, 0xFF], capabilities: percent, observedAt: observed)
    #expect(value == .init(percentage: 73, charging: .unknown(7), observedAt: observed))
    #expect(try BoltDeviceInformationReader.battery([255, 4, 2, 1], capabilities: levels).percentage == nil)
    #expect(try BoltDeviceInformationReader.battery([0, 1, 0, 0], capabilities: percent).percentage == 0)
    #expect(try BoltDeviceInformationReader.battery([100, 8, 3, 1], capabilities: percent).charging == .complete)
    #expect(throws: BoltFailure.malformed) { try BoltDeviceInformationReader.battery([101, 0, 0, 0], capabilities: percent) }
    #expect(throws: BoltFailure.malformed) { try BoltDeviceInformationReader.battery([50, 0, 0], capabilities: percent) }
    #expect(throws: BoltFailure.malformed) { try BoltDeviceInformationReader.BatteryCapabilities([0]) }
}

@Test(arguments: [UInt8(0), 1, 2, 3, 4, 255])
func unifiedBatteryChargingValues(_ raw: UInt8) throws {
    let capabilities = try BoltDeviceInformationReader.BatteryCapabilities([0, 2])
    let expected: BoltDeviceInformation.Charging = switch raw {
    case 0: .discharging
    case 1: .charging
    case 2: .slowCharging
    case 3: .complete
    case 4: .error
    default: .unknown(raw)
    }
    #expect(try BoltDeviceInformationReader.battery([45, 0, raw, 0], capabilities: capabilities).charging == expected)
}

@Test func firmwareParserBoundsCountAndRetainsRawFields() throws {
    let raw: [UInt8] = [0xFE, 0x41, 0, 0x7F, 0xFA, 0xCE, 0xBE, 0xEF, 0xE7] + Array(repeating: 0xFF, count: 7)
    let entity = try BoltDeviceInformationReader.firmwareEntity(raw)
    #expect(entity == .init(type: 0xFE, prefix: "A  ", rawVersion: 0xFACE, rawBuild: 0xBEEF, flags: 0xE7))
    #expect(try BoltDeviceInformationReader.firmwareCount([8] + Array(repeating: 0, count: 14)) == 8)
    #expect(try BoltDeviceInformationReader.firmwareCount(Array(repeating: 0, count: 15)) == 0)
    #expect(throws: BoltFailure.malformed) { try BoltDeviceInformationReader.firmwareCount([9] + Array(repeating: 0, count: 14)) }
    #expect(throws: BoltFailure.malformed) { try BoltDeviceInformationReader.firmwareCount(Array(repeating: 0, count: 14)) }
    #expect(throws: BoltFailure.malformed) { try BoltDeviceInformationReader.firmwareEntity(Array(raw.prefix(15))) }
    #expect(throws: BoltFailure.malformed) { try BoltDeviceInformationReader.featureIndex([3, 0]) }
    #expect(throws: BoltFailure.unsupported) { try BoltDeviceInformationReader.featureIndex([0, 0, 0]) }
    #expect(try BoltDeviceInformationReader.featureIndex([12, 0, 255]) == 12)
}

@Test func firmwareHardwareRevisionUsesRawPayloadByte() throws {
    let hardware: [UInt8] = [0xF2, 0xFA, 0x20, 0x20, 0xFA, 0xCE, 0xBE, 0xEF, 0x01] + Array(repeating: 0, count: 7)
    let parsedHardware = try BoltDeviceInformationReader.firmwareEntity(hardware)
    #expect(parsedHardware.hardwareRevision == 0xFA)
    #expect(parsedHardware.rawVersion == 0xFACE)

    let application: [UInt8] = [0xF0, 0x41, 0x42, 0x43, 0x12, 0x34, 0x00, 0x06, 0x01] + Array(repeating: 0, count: 7)
    #expect(try BoltDeviceInformationReader.firmwareEntity(application).hardwareRevision == nil)
}

private actor InformationTransport: BoltTransport {
    nonisolated let events: AsyncStream<BoltTransportEvent>
    nonisolated let ledger = BoltRequestIDLedger()
    private let continuation: AsyncStream<BoltTransportEvent>.Continuation
    var informationCalls: [(UInt8, UInt8, [UInt8])] = []
    var batteryRoot: [UInt8] = [12, 0, 0]
    var firmwareRoot: [UInt8] = [13, 0, 255]
    var capabilities: [UInt8] = [15, 2]
    var batteryPayload: [UInt8] = [73, 4, 0, 0]
    var entityCount: UInt8 = 1
    var failure: BoltFailure?
    var protocolErrorFeature: UInt8?
    var failingFeature: UInt8?
    var pauseFeature: UInt8?
    var paused = false
    private var resume: CheckedContinuation<Void, Never>?
    private var reporting: [UInt16: UInt8] = [:]

    init() {
        let stream = AsyncStream<BoltTransportEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func open() {}
    func close() {}

    nonisolated func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int {
        ledger.available(slot: slot, feature: feature, function: function)
    }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) throws -> [UInt8] {
        if feature == 0, function == 1 {
            guard slot == 2 else { throw BoltFailure.unavailable }
            return [2, 0, parameters[2]]
        }
        if feature == 0 {
            return parameters == [0x1B, 0x04] ? [9, 0, 5] : [0, 0, 0]
        }
        if feature == 9, function == 0 { return [2] }
        if feature == 9, function == 1 {
            let first = parameters == [0]
            return BoltWire.bytes(first ? 0x53 : 0x56) + BoltWire.bytes(first ? 0x3C : 0x3E) + [0x20] + Array(repeating: 0, count: 11)
        }
        if feature == 9, function == 2 {
            let cid = BoltWire.word(parameters, 0)
            return BoltWire.bytes(cid) + [reporting[cid, default: 0]] + Array(repeating: 0, count: 13)
        }
        if feature == 9, function == 3 {
            let cid = BoltWire.word(parameters, 0)
            reporting[cid] = parameters[2] == 3 ? 1 : 0
            return BoltWire.bytes(cid) + Array(repeating: 0, count: 14)
        }
        throw BoltFailure.malformed
    }

    func requestDeviceInformation(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        informationCalls.append((feature, function, parameters))
        let transaction = try BoltRequestTransaction(ledger: ledger, slot: slot, feature: feature, function: function, parameters: parameters)
        defer { transaction.retire() }
        let payload: [UInt8]
        if feature == 0 { payload = parameters == [0x10, 4] ? batteryRoot : firmwareRoot }
        else if feature == 12 { payload = function == 0 ? capabilities : batteryPayload }
        else if function == 0 { payload = [entityCount] + Array(repeating: 0, count: 14) }
        else { payload = [0, 0x41, 0x42, 0x43, 0xFA, 0xCE, 0xBE, 0xEF, 0xE1] + Array(repeating: 0, count: 7) }
        if pauseFeature == feature, function == 1 {
            pauseFeature = nil
            paused = true
            await withCheckedContinuation { resume = $0 }
            paused = false
        }
        if protocolErrorFeature == feature {
            let report: [UInt8] = [0x11, slot, 0xFF, feature, transaction.lease.functionSoftware, 9] + Array(repeating: 0, count: 14)
            let matched = try #require(transaction.reply(report))
            #expect(BoltHIDWorker.matchedReplyFailure(matched, optionalInformation: true) == nil)
            do { return try transaction.complete(matchedReply: matched, sendSucceeded: true) }
            catch { throw BoltDeviceInformationRequestError.protocolRejected }
        }
        if failingFeature == feature, let failure { throw failure }
        return try transaction.complete(matchedReply: .success(payload), sendSucceeded: true)
    }

    func setFailure(_ failure: BoltFailure, feature: UInt8) { self.failure = failure; failingFeature = feature }
    func setProtocolError(feature: UInt8) { protocolErrorFeature = feature }
    func setUnsupported() { batteryRoot = [0, 0, 0]; firmwareRoot = [0, 0, 0] }
    func setCount(_ value: UInt8) { entityCount = value }
    func pauseBattery() { pauseFeature = 12 }
    func pauseFirmware() { pauseFeature = 13 }
    func resumeRequest() { resume?.resume(); resume = nil }
    func sendBattery(percentage: UInt8, charging: UInt8 = 1, at: ContinuousClock.Instant = .now, malformed: Bool = false, slot: UInt8 = 2) {
        let report: [UInt8] = [0x11, slot, 12, 0, percentage, 0, charging, 0] + Array(repeating: 0, count: malformed ? 11 : 12)
        continuation.yield(.report(report, at: at))
    }
    func disconnect() { continuation.yield(.failure(.disconnected)) }
}

private actor InformationRecorder {
    var statuses: [BoltStatus] = []
    var last: BoltStatus? { statuses.last }
    func append(_ event: BoltEvent) { if case .status(let status) = event { statuses.append(status) } }
}

private struct InformationHarness {
    let transport: InformationTransport
    let controller: BoltController
    let recorder: InformationRecorder
    let reader: Task<Void, Never>

    init() {
        let transport = InformationTransport()
        self.transport = transport
        let controller = BoltController(makeTransport: { transport })
        self.controller = controller
        let recorder = InformationRecorder()
        self.recorder = recorder
        reader = Task { for await event in controller.events { await recorder.append(event) } }
    }
}

private func informationEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func informationDiscoveryDoesNotReadMetadataAndExplicitRefreshPreservesSession() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    #expect(await h.transport.informationCalls.isEmpty)
    #expect(await informationEventually { await h.recorder.last?.phase == .ready })
    let before = await h.recorder.last
    await h.controller.refreshDeviceInformation()
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.firmwareState == .available })
    let after = await h.recorder.last
    #expect(after?.phase == before?.phase)
    #expect(after?.message == before?.message)
    #expect(after?.generation == before?.generation)
    #expect(after?.deviceInformation.battery?.percentage == 73)
    #expect(after?.deviceInformation.firmware.first?.rawVersion == 0xFACE)
    #expect(after?.deviceInformation.isRefreshing == false)
    #expect(await h.transport.informationCalls.map { $0.0 } == [0, 12, 12, 0, 13, 13])
    #expect(await h.transport.informationCalls.allSatisfy { $0.1 <= 1 })
    await h.controller.stop()
    #expect(await informationEventually { await h.recorder.last?.deviceInformation == .init() })
}

@Test(arguments: [UInt8(12), 13])
func informationProtocolErrorsAreIndependentAndDoNotStopBindings(_ failedFeature: UInt8) async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.controller.enable()
    await h.transport.setProtocolError(feature: failedFeature)
    await h.controller.refreshDeviceInformation()
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.isRefreshing == false })
    let status = await h.recorder.last
    #expect(status?.phase == .enabled)
    #expect(status?.failure == nil)
    #expect(status?.deviceInformation.batteryState == (failedFeature == 12 ? .unavailable : .available))
    #expect(status?.deviceInformation.firmwareState == (failedFeature == 13 ? .unavailable : .available))
    #expect(h.transport.ledger.available(slot: 2, feature: failedFeature, function: 0) == 14)
    await h.controller.stop()
}

@Test func informationMissingFeaturesAndOversizedCountAreBounded() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.transport.setCount(9)
    await h.controller.refreshDeviceInformation()
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.firmwareState == .unavailable })
    #expect(await h.transport.informationCalls.filter { $0.0 == 13 && $0.1 == 1 }.isEmpty)
    await h.transport.setUnsupported()
    await h.controller.refreshDeviceInformation()
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.firmwareState == .unsupported })
    #expect(await h.recorder.last?.deviceInformation.batteryState == .unsupported)
    await h.controller.stop()
}

@Test func informationRefreshCoalescesAndPreservesBatteryEventRacingRead() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.transport.pauseBattery()
    let refresh = Task { await h.controller.refreshDeviceInformation() }
    #expect(await informationEventually { await h.transport.paused })
    await h.controller.refreshDeviceInformation()
    await h.transport.sendBattery(percentage: 81, charging: 2)
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.battery?.percentage == 81 })
    await h.transport.resumeRequest()
    await refresh.value
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.isRefreshing == false })
    #expect(await h.recorder.last?.deviceInformation.battery?.percentage == 81)
    #expect(await h.recorder.last?.deviceInformation.battery?.charging == .slowCharging)
    #expect(await h.transport.informationCalls.filter { $0.0 == 0 && $0.2 == [0x10, 4] }.count == 1)
    await h.controller.stop()
}

@Test func informationMalformedAndStaleEventsStayLocalAndPreserveSessionMessage() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.controller.refreshDeviceInformation()
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.batteryState == .available })
    let before = await h.recorder.last
    await h.transport.sendBattery(percentage: 80, malformed: true)
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.batteryState == .unavailable })
    await h.transport.sendBattery(percentage: 82)
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.battery?.percentage == 82 })
    await h.transport.sendBattery(percentage: 84, at: .now.advanced(by: .seconds(-1)))
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.batteryState == .unavailable })
    #expect(await h.recorder.last?.phase == before?.phase)
    #expect(await h.recorder.last?.message == before?.message)
    #expect(await h.recorder.last?.deviceInformation.firmwareState == .available)
    await h.controller.stop()
}

@Test func informationEventsRequireValidatedCapabilities() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.transport.setFailure(.timeout, feature: 12)
    await h.controller.refreshDeviceInformation()
    await h.transport.sendBattery(percentage: 80)
    await h.transport.disconnect()
    #expect(await informationEventually { await h.recorder.last?.phase == .failed })
    #expect(await h.recorder.statuses.allSatisfy { $0.deviceInformation.battery == nil })
    await h.controller.stop()
}

@Test func informationEventsRequireSelectedSlot() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.controller.refreshDeviceInformation()
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.battery?.percentage == 73 })
    await h.transport.sendBattery(percentage: 82, slot: 3)
    await h.transport.sendBattery(percentage: 83)
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.battery?.percentage == 83 })
    #expect(await h.recorder.statuses.allSatisfy { $0.deviceInformation.battery?.percentage != 82 })
    await h.controller.stop()
}

@Test(arguments: [BoltFailure.timeout, .disconnected, .transport])
func informationTimeoutIsLocalButPhysicalFailuresAreTerminal(_ failure: BoltFailure) async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.transport.setFailure(failure, feature: 12)
    await h.controller.refreshDeviceInformation()
    if failure == .timeout {
        #expect(await informationEventually { await h.recorder.last?.deviceInformation.firmwareState == .available })
        #expect(await h.recorder.last?.deviceInformation.batteryState == .unavailable)
        #expect(await h.recorder.last?.phase == .ready)
    } else {
        #expect(await informationEventually { await h.recorder.last?.phase == .failed })
        #expect(await h.recorder.last?.deviceInformation == .init())
    }
    await h.controller.stop()
}

@Test func informationStopRejectsLateRefreshPublication() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.transport.pauseFirmware()
    let refresh = Task { await h.controller.refreshDeviceInformation() }
    #expect(await informationEventually { await h.transport.paused })
    let stop = Task { await h.controller.stop() }
    #expect(await informationEventually { await h.recorder.last?.phase == .stopping })
    await h.transport.resumeRequest()
    await refresh.value
    await stop.value
    #expect(await informationEventually { await h.recorder.last?.phase == .idle })
    let statuses = await h.recorder.statuses
    if let stopping = statuses.firstIndex(where: { $0.phase == .stopping }) {
        #expect(statuses[stopping...].allSatisfy { $0.phase == .stopping || $0.phase == .idle })
    }
    #expect(await h.recorder.last?.deviceInformation == .init())
}

@Test func informationRefreshReservesSharedRootRequestIDs() async throws {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    try h.transport.ledger.retireForFixture(feature: 0, function: 0, count: 13)
    await h.controller.refreshDeviceInformation()
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.firmwareState == .unavailable })
    #expect(await h.transport.informationCalls.isEmpty)
    #expect(h.transport.ledger.available(slot: 2, feature: 0, function: 0) == 2)
    await h.controller.stop()
}

@Test func informationTaskCancellationFinishesLoadingWithoutPublishingLateData() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.transport.pauseBattery()
    let refresh = Task { await h.controller.refreshDeviceInformation() }
    #expect(await informationEventually { await h.transport.paused })
    refresh.cancel()
    await h.transport.resumeRequest()
    await refresh.value
    #expect(await informationEventually { await h.recorder.last?.deviceInformation.isRefreshing == false })
    #expect(await h.recorder.last?.deviceInformation.batteryState == .unavailable)
    #expect(await h.recorder.last?.deviceInformation.battery == nil)
    #expect(await h.recorder.last?.phase == .ready)
    #expect(await h.transport.informationCalls.filter { $0.0 == 13 }.isEmpty)
    await h.controller.stop()
}

@Test func informationDisableRevisionInvalidatesInFlightRead() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.controller.enable()
    await h.transport.pauseBattery()
    let refresh = Task { await h.controller.refreshDeviceInformation() }
    #expect(await informationEventually { await h.transport.paused })
    let disable = Task { await h.controller.disable() }
    #expect(await informationEventually { await h.recorder.last?.message.contains("Stopping shortcut delivery") == true })
    await h.transport.resumeRequest()
    await refresh.value
    await disable.value
    #expect(await informationEventually { await h.recorder.last?.phase == .ready })
    #expect(await h.recorder.last?.deviceInformation.isRefreshing == false)
    #expect(await h.recorder.last?.deviceInformation.battery == nil)
    #expect(await h.transport.informationCalls.filter { $0.0 == 13 }.isEmpty)
    await h.controller.stop()
}

@Test func informationDisconnectEventDuringRefreshClosesAndClearsMetadata() async {
    let h = InformationHarness()
    defer { h.reader.cancel() }
    await h.controller.discover()
    await h.transport.pauseBattery()
    let refresh = Task { await h.controller.refreshDeviceInformation() }
    #expect(await informationEventually { await h.transport.paused })
    await h.transport.disconnect()
    await h.transport.sendBattery(percentage: 89)
    await h.transport.resumeRequest()
    await refresh.value
    #expect(await informationEventually { await h.recorder.last?.phase == .failed })
    #expect(await h.recorder.last?.failure?.code == .disconnected)
    #expect(await h.recorder.last?.deviceInformation == .init())
    await h.controller.stop()
}

@Test func optionalInformationErrorPolicyUsesExactMatchedProtocolRepliesAndRetiresIDs() throws {
    let ledger = BoltRequestIDLedger()
    let transaction = try BoltRequestTransaction(ledger: ledger, slot: 2, feature: 12, function: 1, parameters: [])
    let tail = Array(repeating: UInt8(0), count: 14)
    let report: [UInt8] = [0x11, 2, 0xFF, 12, transaction.lease.functionSoftware, 9] + tail
    let matched = try #require(transaction.reply(report))
    #expect(BoltHIDWorker.matchedReplyFailure(matched, optionalInformation: false) == .transport)
    #expect(BoltHIDWorker.matchedReplyFailure(matched, optionalInformation: true) == nil)
    #expect(transaction.reply([0x11, 3, 0xFF, 12, transaction.lease.functionSoftware, 9] + tail) == nil)
    #expect(transaction.reply([0x11, 2, 0xFF, 13, transaction.lease.functionSoftware, 9] + tail) == nil)
    #expect(throws: BoltFailure.transport) { try transaction.complete(matchedReply: matched, sendSucceeded: true) }
    #expect(ledger.available(slot: 2, feature: 12, function: 1) == 14)
}
