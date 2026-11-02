import Foundation
import Testing
import HidhoggDomain
@testable import LogitechBolt

private actor HardwareFixture {
    nonisolated let requestIDs = BoltFixtureRequestIDs()
    var model4 = true
    var roots: [UInt16: [UInt8]] = [0x2111: [23, 0, 0], 0x2201: [31, 0, 1], 0x2205: [35, 0, 0], 0x19B0: [42, 0, 0], 0x19C0: [48, 0, 0]]
    var smart: [UInt8] = [2, 10, 50]
    var smartCaps: [UInt8] = [1, 10, 50, 100]
    var legacy: [UInt8] = [2, 12, 15]
    var dpi: [UInt8] = [0, 3, 232, 3, 232]
    var dpiList: [UInt8] = [0, 0, 200, 0xE0, 50, 0x1F, 0x40, 0, 0]
    var sensors: UInt8 = 1
    var pointer: [UInt8] = [1, 0]
    var hapticCaps: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x13]
    var haptic: [UInt8] = [0xA3, 50, 0xAA]
    var engine: UInt8 = 0
    var forceCount: UInt8 = 1
    var forceInfo: [UInt8] = [0, 1, 0, 100, 0, 200, 0, 10]
    var force: [UInt8] = [0, 100]
    var identityChanged = false
    var setters: [(UInt8, UInt8, [UInt8])] = []
    var timeoutAfterSet = false
    var wheelMode: UInt8 = 0
    var thumbMode: [UInt8] = [0, 0]
    var controlsVersion: UInt8 = 6
    var extraControls = false
    var buttonStates: [UInt16: UInt8] = [:]
    var sink: AsyncStream<BoltTransportEvent>.Continuation?
    var pauseSetter = false
    var pauseReadback = false
    var paused = false
    var pauseContinuation: CheckedContinuation<Void, Never>?
    var awaitingReadback = false
    var failingReads = false
    var roundedIntensity: UInt8?

    func suspendNextSetter(readback: Bool) { pauseSetter = !readback; pauseReadback = readback }
    func resume() { pauseSetter = false; pauseReadback = false; pauseContinuation?.resume(); pauseContinuation = nil; paused = false }
    func failAllReads(_ failing: Bool) { failingReads = failing }
    func roundHapticIntensity(to value: UInt8) { roundedIntensity = value }

    func configureRouting(controls: Bool = true, thumbFlags: UInt8 = 0, extraControls: Bool = false) {
        roots[0x2121] = [15, 0, 1]
        roots[0x2150] = [16, 0, 0]
        controlsVersion = controls ? 6 : 99
        self.extraControls = extraControls
        thumbMode = [0, thumbFlags]
    }
    func connectEvents(_ sink: AsyncStream<BoltTransportEvent>.Continuation) { self.sink = sink }
    func sendButtons(_ cids: [UInt16]) {
        let payload = cids.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
        sink?.yield(.report([0x11, 2, 9, 0] + payload + Array(repeating: 0, count: 16 - payload.count), at: .now))
    }
    func routing() -> (UInt8, [UInt8], [UInt16: UInt8]) { (wheelMode, thumbMode, buttonStates) }
    func rows() -> [[UInt8]] {
        let definitions: [(UInt16, UInt16)] = extraControls
            ? [(0x50, 0x38), (0x51, 0x39), (0x52, 0x3A), (0x53, 0x3C), (0x56, 0x3E), (0xC3, model4 ? 0x9C : 0xA9), (0xC4, 0x9D), (0x1A0, 0x109), (0xD7, 0xB4)]
            : [(0x53, 0x3C), (0x56, 0x3E)]
        return definitions.map { cid, task in
            let flags: UInt8 = cid == 0x50 || cid == 0x51 ? 1 : cid == 0xD7 ? 0xA0 : 0x31
            return [UInt8(cid >> 8), UInt8(cid & 255), UInt8(task >> 8), UInt8(task & 255), flags, 0, 2, 3, 5] + Array(repeating: 0, count: 7)
        }
    }

    func configure(model4: Bool = true, root: UInt16? = nil, value: [UInt8]? = nil,
                   shortCaps: Bool = false, torque: Bool = true, forceCount: UInt8 = 1, sensors: UInt8 = 1) {
        self.model4 = model4
        if let root { roots[root] = value }
        if shortCaps { smartCaps = [1, 10, 50]; hapticCaps = [0, 0, 0] }
        if !torque { smartCaps[0] = 0 }
        self.forceCount = forceCount
        self.sensors = sensors
    }
    func changeHapticFlags(_ flags: UInt8) { haptic[0] = flags }
    func changeSmartThreshold(_ threshold: UInt8) { smart[1] = threshold }
    func changeIdentity() { identityChanged = true }
    func setTimeoutAfterWrite() { timeoutAfterSet = true }
    func configureDPI(version: UInt8, state: [UInt8], list: [UInt8]? = nil) {
        roots[0x2201] = [31, 0, version]
        dpi = state
        if let list { dpiList = list }
    }
    func snapshot() -> ([UInt8], [UInt8], [UInt8], [UInt8], [UInt8]) { (smart, dpi, pointer, haptic, force) }
    func writes() -> [(UInt8, UInt8, [UInt8])] { setters }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        guard slot == 2 else { throw BoltFailure.unavailable }
        if failingReads { throw BoltFailure.timeout }
        if awaitingReadback, pauseReadback, feature == 35, function == 0 {
            paused = true
            await withCheckedContinuation { pauseContinuation = $0 }
        }
        if feature == 0, function == 1 { return [2, 0, parameters[2]] }
        if feature == 0 {
            let identifier = UInt16(parameters[0]) << 8 | UInt16(parameters[1])
            if identifier == 3 { return [7, 0, 6] }
            if identifier == 0x1B04 { return [9, 0, model4 ? controlsVersion : 5] }
            return roots[identifier] ?? [0, 0, 0]
        }
        if feature == 7 {
            if function == 0 { return [0, identityChanged ? 5 : 1, 2, 3, 4, 0, 2, 0xB0, model4 ? 0x42 : 0x34, 0, 0, 0, 0] }
            throw BoltFailure.unavailable
        }
        if feature == 9 {
            if function == 0 { return [UInt8(rows().count)] }
            if function == 1 { return rows()[Int(parameters[0])] }
            let cid = UInt16(parameters[0]) << 8 | UInt16(parameters[1])
            if function == 2 { return parameters + [buttonStates[cid] ?? 0] + Array(repeating: 0, count: 13) }
            if parameters[2] & 2 != 0 { buttonStates[cid] = parameters[2] & 1 }
            setters.append((feature, function, parameters))
            return Array(parameters.prefix(2)) + Array(repeating: 0, count: 14)
        }
        if feature == 15 {
            if function == 0 { return [8, 8] }
            if function == 1 { return [wheelMode, 0] }
            wheelMode = parameters[0]
        } else if feature == 16 {
            if function == 0 { return [0, 120, 0, 120, 0, 15, 0, 1] }
            if function == 1 { return thumbMode }
            thumbMode = parameters
        } else if feature == 23 {
            if function == 0 { return smartCaps }
            if function == 1 { return smart }
            for index in 0..<3 where parameters[index] != 0 { smart[index] = parameters[index] }
        } else if feature == 24 {
            if function == 0 { return legacy }
            for index in 0..<3 where parameters[index] != 0 { legacy[index] = parameters[index] }
        } else if feature == 31 {
            if function == 0 { return [sensors] }
            if function == 1 { return dpiList }
            if function == 2 { return dpi }
            dpi[1] = parameters[1]; dpi[2] = parameters[2]
        } else if feature == 35 {
            if function == 0 { return pointer }
            pointer = parameters
        } else if feature == 42 {
            if function == 0 { return hapticCaps }
            if function == 1 { return haptic }
            if function == 3 { return [engine] }
            if function == 2 { haptic[0] = parameters[0]; haptic[1] = roundedIntensity ?? parameters[1] }
        } else if feature == 48 {
            if function == 0 { return [forceCount] }
            if function == 1 { return forceInfo }
            if function == 2 { return force }
            force = Array(parameters.dropFirst())
        } else { throw BoltFailure.unavailable }
        setters.append((feature, function, parameters))
        awaitingReadback = true
        if pauseSetter {
            paused = true
            await withCheckedContinuation { pauseContinuation = $0 }
        }
        if timeoutAfterSet { timeoutAfterSet = false; throw BoltFailure.timeout }
        return [0, 0, 0]
    }
}

private final class HardwareTransport: BoltTransport, Sendable {
    let fixture: HardwareFixture
    let events: AsyncStream<BoltTransportEvent>
    let continuation: AsyncStream<BoltTransportEvent>.Continuation
    let requestIDs: BoltRequestIDLedger
    init(_ fixture: HardwareFixture) {
        self.fixture = fixture
        requestIDs = fixture.requestIDs.makeTransportLedger()
        (events, continuation) = AsyncStream.makeStream()
    }
    func open() async throws { await fixture.connectEvents(continuation) }
    func close() async { continuation.finish() }
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int { requestIDs.available(slot: slot, feature: feature, function: function) }
    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        let transaction = try BoltRequestTransaction(ledger: requestIDs, slot: slot, feature: feature, function: function, parameters: parameters)
        defer { transaction.retire() }
        let payload = try await fixture.request(slot: slot, feature: feature, function: function, parameters: parameters)
        let size = payload.count <= 3 ? 3 : 16
        let report: [UInt8] = [size == 3 ? 0x10 : 0x11, slot, feature, transaction.lease.functionSoftware]
            + payload + Array(repeating: 0, count: size - payload.count)
        return try transaction.complete(matchedReply: transaction.reply(report), sendSucceeded: true)
    }
}

private struct HardwareCatalog: LogitechEndpointCatalog {
    let fixture: HardwareFixture
    let locator = LogitechEndpointLocator(id: UUID(), key: 99, connection: .bolt, productID: 0xC548)
    func enumerate() async throws -> [LogitechEndpointLocator] { [locator] }
    func makeTransport(for locator: LogitechEndpointLocator, onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport { HardwareTransport(fixture) }
}

private func hardwareController(_ fixture: HardwareFixture, posting: Bool = false) async throws -> BoltController {
    let controller = BoltController(scrollPostingPreflight: { posting }, makeTransport: { HardwareTransport(fixture) }, endpointCatalog: HardwareCatalog(fixture: fixture), requiresExplicitAssociation: true)
    let candidate = try #require(try await controller.existingConnections().first)
    await controller.discover(target: .init(model: candidate.model, association: .init(identity: candidate.identity, preferredConnection: candidate.connection), candidateID: candidate.id))
    await controller.refreshHardwareSettings()
    return controller
}

@Test(arguments: [false, true]) func hardwareSettingsReadWriteRestoreAcrossModels(model4: Bool) async throws {
    let fixture = HardwareFixture()
    await fixture.configure(model4: model4)
    let controller = try await hardwareController(fixture)
    let baseline = await fixture.snapshot()
    await controller.applyHardwareSettings(.init(smartShiftThreshold: 20, smartShiftTorque: 75, dpi: 1600, pointerSpeed: 1.5,
                                                  hapticsEnabled: false, hapticIntensity: 80, hapticPowerSaving: false, forceThreshold: 150), restorePreviousSettingsOnDisconnect: true)
    let changed = await fixture.snapshot()
    #expect(changed.0 == [2, 20, 75])
    #expect(changed.1 == [0, 6, 64, 3, 232])
    #expect(changed.2 == [1, 128])
    #expect(changed.3 == [0xA0, 80, 0xAA])
    #expect(changed.4 == [0, 150])
    #expect(await controller.stopForRestart())
    let restored = await fixture.snapshot()
    #expect(restored.0 == baseline.0)
    #expect(restored.1 == baseline.1)
    #expect(restored.2 == baseline.2)
    #expect(restored.3 == baseline.3)
    #expect(restored.4 == baseline.4)
}

@Test func hardwareLegacySmartShiftPreservesDefaultThreshold() async throws {
    let fixture = HardwareFixture()
    await fixture.configure(root: 0x2111, value: [0, 0, 0])
    await fixture.configure(root: 0x2110, value: [24, 0, 0])
    let controller = try await hardwareController(fixture)
    await controller.applyHardwareSettings(.init(smartShiftMode: .ratchet), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.writes().contains { $0.0 == 24 && $0.2 == [2, 255, 0] })
    #expect(await controller.stopForRestart())
    #expect(await fixture.writes().contains { $0.0 == 24 && $0.2 == [2, 12, 0] })
}

@Test(arguments: [0x2111, 0x2201, 0x2205, 0x19B0, 0x19C0]) func hardwareUnknownFeatureVersionsNeverAuthorizeWrites(identifier: Int) async throws {
    let fixture = HardwareFixture()
    await fixture.configure(root: UInt16(identifier), value: [55, 0, 99])
    let controller = try await hardwareController(fixture)
    await controller.applyHardwareSettings(.init(smartShiftThreshold: 20, dpi: 1600, pointerSpeed: 1.5, hapticIntensity: 80, forceThreshold: 150), restorePreviousSettingsOnDisconnect: false)
    #expect(await fixture.writes().allSatisfy { $0.0 != 55 })
    await controller.stop()
}

@Test func hardwareShortCapabilityAndAmbiguousSensorForceRepliesNeverAuthorizeTheirWrites() async throws {
    let fixture = HardwareFixture()
    await fixture.configure(shortCaps: true, forceCount: 2, sensors: 2)
    let controller = try await hardwareController(fixture)
    await controller.applyHardwareSettings(.init(smartShiftThreshold: 20, dpi: 1600, hapticIntensity: 80, forceThreshold: 150), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.writes().isEmpty)
    await controller.stop()
}

@Test func hardwareUnadvertisedTorqueAndUnsupportedDPIHaveNoWrites() async throws {
    let fixture = HardwareFixture()
    await fixture.configure(torque: false)
    let controller = try await hardwareController(fixture)
    await controller.applyHardwareSettings(.init(smartShiftTorque: 70, dpi: 1625), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.writes().isEmpty)
    await controller.stop()
}

@Test func hardwareRestorePreservesUnownedHapticFlagChanges() async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    await controller.applyHardwareSettings(.init(hapticIntensity: 80), restorePreviousSettingsOnDisconnect: true)
    await fixture.changeHapticFlags(0xE3)
    #expect(await controller.stopForRestart())
    #expect(await fixture.snapshot().3 == [0xE3, 50, 0xAA])
}

@Test func hardwareForeignOwnedStateRefusesRestoration() async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    await controller.applyHardwareSettings(.init(smartShiftThreshold: 20), restorePreviousSettingsOnDisconnect: true)
    await fixture.changeSmartThreshold(30)
    #expect(await controller.stopForRestart() == false)
    #expect(await fixture.snapshot().0 == [2, 30, 50])
    #expect(await fixture.writes().count == 1)
}

@Test func hardwareSetterTimeoutRetainsOwnedRollback() async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    await fixture.setTimeoutAfterWrite()
    await controller.applyHardwareSettings(.init(pointerSpeed: 1.5), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.snapshot().2 == [1, 128])
    #expect(await controller.stopForRestart())
    #expect(await fixture.snapshot().2 == [1, 0])
}

@Test func hardwareHapticTestHonorsMuteAndAdvertisedWaveform() async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    await controller.playHapticTest(waveform: 3)
    #expect(await fixture.writes().isEmpty)
    await controller.applyHardwareSettings(.init(hapticsEnabled: false), restorePreviousSettingsOnDisconnect: false)
    await controller.playHapticTest(waveform: 1)
    #expect(await fixture.writes().allSatisfy { $0.1 != 4 })
    await controller.applyHardwareSettings(.init(hapticsEnabled: true), restorePreviousSettingsOnDisconnect: false)
    await controller.playHapticTest(waveform: 1)
    #expect(await fixture.writes().contains { $0.0 == 42 && $0.1 == 4 && $0.2 == [1, 0, 0] })
    await controller.stop()
}

@Test func hardwareIdentityChangeBlocksAllSettingsWrites() async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    await fixture.changeIdentity()
    await controller.applyHardwareSettings(.init(pointerSpeed: 1.5), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.writes().isEmpty)
    await controller.stop()
}

@Test func hardwareDPIListRejectsUnterminatedOrMalformedRanges() {
    #expect(throws: BoltFailure.self) { try HIDPPHardwareCodec.dpiValues([0, 200, 0xE0, 0, 0x1F, 0x40, 0, 0]) }
    #expect(throws: BoltFailure.self) { try HIDPPHardwareCodec.dpiValues([0, 200]) }
    #expect(throws: BoltFailure.self) { try HIDPPHardwareCodec.dpiValues([0xE0, 50, 0x1F, 0x40, 0, 0]) }
}

@Test func hardwareMX4WheelAndThumbCaptureDoNotRequireButtonSupport() async throws {
    let fixture = HardwareFixture()
    await fixture.configureRouting(controls: false)
    let controller = try await hardwareController(fixture, posting: true)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true, amount: 2, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: true, amount: 2, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    let routing = await fixture.routing()
    #expect(routing.0 == 3)
    #expect(routing.1 == [1, 0])
    #expect(await fixture.writes().allSatisfy { $0.0 != 9 })
    #expect(await controller.stopForRestart())
    #expect(await fixture.routing().0 == 0)
    #expect(await fixture.routing().1 == [0, 0])
}

@Test func hardwareMX4ThumbUnknownStatusBitsRefuseAllThumbWrites() async throws {
    let fixture = HardwareFixture()
    await fixture.configureRouting(thumbFlags: 6)
    let controller = try await hardwareController(fixture, posting: true)
    await controller.applyThumbwheelPreferences(inverted: true, amount: 2, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    #expect(await fixture.writes().allSatisfy { $0.0 != 16 })
    #expect(await fixture.routing().1 == [0, 6])
    await controller.stop()
}

@Test(arguments: [false, true]) func hardwareControlTableAdmitsOnlySelectedPlainControls(model4: Bool) async throws {
    let fixture = HardwareFixture()
    await fixture.configure(model4: model4)
    await fixture.configureRouting(extraControls: true)
    let controller = try await hardwareController(fixture)
    await controller.enable(controls: [.middle, .wheelMode, .thumbRest])
    let routing = await fixture.routing()
    #expect(routing.2[0x52] == 1)
    #expect(routing.2[0xC3] == 1)
    #expect(routing.2[0xC4] == 1)
    #expect(routing.2[0x53] == nil)
    #expect(routing.2[0x56] == nil)
    #expect(routing.2[0x50] == nil)
    #expect(routing.2[0x51] == nil)
    #expect(routing.2[0x1A0] == nil)
    #expect(routing.2[0xD7] == nil)
    #expect(await controller.stopForRestart())
    #expect(await fixture.routing().2.values.allSatisfy { $0 == 0 })
}

@Test func hardwareControlMetadataRequiresModelSpecificTask() throws {
    let mx4Thumb: [UInt8] = [0, 0xC3, 0, 0x9C, 0x31, 0, 2, 3, 5] + Array(repeating: 0, count: 7)
    #expect(try BoltWire.eligible([mx4Thumb], model: .mxMaster4) == [.thumbRest])
    #expect(try BoltWire.eligible([mx4Thumb], model: .mxMaster3S).isEmpty)
    let virtual: [UInt8] = [0, 0xC3, 0, 0x9C, 0xB1, 0, 2, 3, 5] + Array(repeating: 0, count: 7)
    #expect(try BoltWire.eligible([virtual], model: .mxMaster4).isEmpty)
}

private actor HardwareEventRecorder {
    var status: BoltStatus?
    func record(_ event: BoltEvent) { if case .status(let status) = event { self.status = status } }
}

private func hardwareEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

@Test(arguments: [UInt16(0x0000), 0x0001, 0x0700, 0x2300, 0x2301])
func hardwareRetiredNativeRequestPoolsRefuseWriteBeforeMutation(pool: UInt16) async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    try fixture.requestIDs.retireForFixture(feature: UInt8(pool >> 8), function: UInt8(pool & 255), count: 14)
    await controller.applyHardwareSettings(.init(pointerSpeed: 1.5), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.writes().isEmpty)
    #expect(await fixture.snapshot().2 == [1, 0])
    await controller.stop()
}

@Test(arguments: [false, true]) func hardwareShutdownDuringSetterOrReadbackRestoresOnlyOwnedWrite(readback: Bool) async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    let recorder = HardwareEventRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await fixture.suspendNextSetter(readback: readback)
    let apply = Task { await controller.applyHardwareSettings(.init(pointerSpeed: 1.5, hapticsEnabled: false), restorePreviousSettingsOnDisconnect: true) }
    #expect(await hardwareEventually { await fixture.paused })
    let stop = Task { await controller.stopForRestart() }
    #expect(await hardwareEventually { await recorder.status?.phase == .stopping })
    await fixture.resume()
    await apply.value
    #expect(await stop.value)
    #expect(await fixture.snapshot().2 == [1, 0])
    #expect(await fixture.writes().count == 2)
    #expect(await fixture.writes().allSatisfy { $0.0 == 35 })
}

@Test func hardwareDisableDuringSetterPreventsLaterFeatureWrites() async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    let recorder = HardwareEventRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.enable()
    await fixture.suspendNextSetter(readback: false)
    let apply = Task { await controller.applyHardwareSettings(.init(pointerSpeed: 1.5, hapticsEnabled: false), restorePreviousSettingsOnDisconnect: true) }
    #expect(await hardwareEventually { await fixture.paused })
    let disable = Task { await controller.disable() }
    #expect(await hardwareEventually { await recorder.status?.message.contains("Stopping shortcut delivery") == true })
    await fixture.resume()
    await apply.value
    await disable.value
    #expect(await fixture.writes().allSatisfy { $0.0 != 42 })
    #expect(await controller.stopForRestart())
    #expect(await fixture.snapshot().2 == [1, 0])
}

@Test func hardwareFailedCleanupRecoversOnlySameAssociationBeforeReady() async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    await controller.applyHardwareSettings(.init(pointerSpeed: 1.5), restorePreviousSettingsOnDisconnect: true)
    await fixture.failAllReads(true)
    #expect(await controller.stopForRestart() == false)
    #expect(await fixture.snapshot().2 == [1, 128])
    await fixture.failAllReads(false)
    let wrongTarget = LogitechConnectionTarget(model: .mxMaster4, association: .init(identity: .init(unitID: "05060708", modelID: "b04200000000"), preferredConnection: .bolt))
    await controller.discover(target: wrongTarget)
    #expect(await fixture.writes().count == 1)
    let target = LogitechConnectionTarget(model: .mxMaster4, association: .init(identity: .init(unitID: "01020304", modelID: "b04200000000"), preferredConnection: .bolt))
    await controller.discover(target: target)
    #expect(await fixture.snapshot().2 == [1, 0])
    #expect(await fixture.writes().count == 2)
    #expect(await controller.stopForRestart())
}

@Test func hardwareCaptureAndSelectedButtonsRecoverAfterUnreadableCleanup() async throws {
    let fixture = HardwareFixture()
    await fixture.configureRouting(extraControls: true)
    let controller = try await hardwareController(fixture, posting: true)
    await controller.enable(controls: [.middle])
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true, amount: 2, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: true, amount: 2, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    await fixture.failAllReads(true)
    #expect(await controller.stopForRestart() == false)
    await fixture.failAllReads(false)
    let target = LogitechConnectionTarget(model: .mxMaster4, association: .init(identity: .init(unitID: "01020304", modelID: "b04200000000"), preferredConnection: .bolt))
    await controller.discover(target: target)
    #expect(await fixture.routing().0 == 0)
    #expect(await fixture.routing().1 == [0, 0])
    #expect(await fixture.routing().2[0x52] == 0)
    #expect(await controller.stopForRestart())
}

@Test(arguments: [false, true]) func hardwareDPIV2ShowsExactReadbackButCannotGuessLevel(model4: Bool) async throws {
    let fixture = HardwareFixture()
    await fixture.configure(model4: model4)
    await fixture.configureDPI(version: 2, state: [0, 3, 232, 3, 232])
    let controller = try await hardwareController(fixture)
    let recorder = HardwareEventRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.refreshHardwareSettings()
    #expect(await hardwareEventually { await recorder.status?.hardwareSettings.dpi.current == 1000 })
    #expect(await recorder.status?.hardwareSettings.dpi.support == .supported)
    #expect(await recorder.status?.hardwareSettings.dpi.canWrite == false)
    #expect(await recorder.status?.hardwareSettings.dpi.values.contains(1600) == true)
    await controller.applyHardwareSettings(.init(dpi: 1600), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.writes().allSatisfy { $0.0 != 31 })
    #expect(await fixture.snapshot().1 == [0, 3, 232, 3, 232])
    #expect(await controller.stopForRestart())
}

@Test(arguments: [UInt8(0), 1]) func hardwareDPIDefaultAbsenceDoesNotBlockKnownCurrent(version: UInt8) async throws {
    let fixture = HardwareFixture()
    await fixture.configureDPI(version: version, state: version == 0 ? [0, 3, 232] : [0, 3, 232, 0, 0])
    let controller = try await hardwareController(fixture)
    let recorder = HardwareEventRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.refreshHardwareSettings()
    #expect(await hardwareEventually { await recorder.status?.hardwareSettings.dpi.current == 1000 })
    #expect(await recorder.status?.hardwareSettings.dpi.defaultDPI == nil)
    #expect(await recorder.status?.hardwareSettings.dpi.canWrite == true)
    await controller.applyHardwareSettings(.init(dpi: 1600), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.snapshot().1[1...2] == [6, 64])
    #expect(await controller.stopForRestart())
    #expect(await fixture.snapshot().1[1...2] == [3, 232])
}

@Test func hardwareDPIImplicitDefaultCannotAuthorizeUnprovenZeroRestoration() async throws {
    let fixture = HardwareFixture()
    await fixture.configureDPI(version: 1, state: [0, 0, 0, 3, 232])
    let controller = try await hardwareController(fixture)
    await controller.applyHardwareSettings(.init(dpi: 1600), restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.writes().allSatisfy { $0.0 != 31 })
    #expect(await controller.stopForRestart())
}

@Test func hardwareDPIListPreservesFullPayloadAndOffGridUpperEndpoint() throws {
    let full: [UInt8] = [0, 100, 0, 200, 0, 250, 1, 44, 1, 144, 1, 244, 3, 232, 0]
    #expect(try HIDPPHardwareCodec.dpiValues(full) == [100, 200, 250, 300, 400, 500, 1000])
    #expect(try HIDPPHardwareCodec.dpiValues([1, 144, 0xE1, 144, 5, 220, 0, 0]) == [400, 800, 1200, 1500])
    #expect(try HIDPPHardwareCodec.dpiValues([6, 64, 3, 32, 3, 32, 0, 0]) == [800, 1600])
}

@Test func hardwareHapticRefusalKeepsFreshSupportedObservationWithoutClaimingOwnershipOfRounding() async throws {
    let fixture = HardwareFixture()
    let controller = try await hardwareController(fixture)
    let recorder = HardwareEventRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await fixture.roundHapticIntensity(to: 60)
    await controller.applyHardwareSettings(.init(hapticIntensity: 63), restorePreviousSettingsOnDisconnect: true)
    #expect(await hardwareEventually { await recorder.status?.hardwareSettings.haptics.intensity == 60 })
    #expect(await recorder.status?.hardwareSettings.haptics.support == .supported)
    #expect(await recorder.status?.hardwareSettings.haptics.message?.contains("60") == true)
    #expect(await fixture.writes().count == 1)
    #expect(await controller.stopForRestart() == false)
    #expect(await fixture.snapshot().3[1] == 60)
    #expect(await fixture.writes().count == 1)
}
