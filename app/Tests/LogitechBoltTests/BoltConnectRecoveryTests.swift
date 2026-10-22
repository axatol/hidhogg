import Foundation
import Testing
import HidhoggDomain
@testable import LogitechBolt

private actor RecoveryFixture {
    nonisolated let requestIDs = BoltFixtureRequestIDs()
    var buttons: [UInt16: UInt8] = [0x53: 1, 0x56: 1]
    var remap: UInt16 = 0
    var wheel: UInt8 = 1
    var thumb: [UInt8] = [1, 0]
    var writes: [(UInt8, [UInt8])] = []
    var failWrite: UInt8?
    var ignoreWrite: UInt8?
    var pauseWrite: UInt8?
    var paused = false
    var failReads: UInt8?
    var rootChanged = false
    var capabilitiesChanged = false
    var buttonRoots = 0
    var wheelRoots = 0
    var malformed: Int?
    var pending: CheckedContinuation<Void, Never>?
    var continuation: AsyncStream<BoltTransportEvent>.Continuation?

    func configure(wheel: UInt8 = 1, thumb: [UInt8] = [1, 0], remap: UInt16 = 0, buttonFlags: UInt8 = 1) {
        self.wheel = wheel; self.thumb = thumb; self.remap = remap
        buttons = [0x53: buttonFlags, 0x56: 1]
    }
    func setFailure(_ feature: UInt8?, ignore: Bool = false) {
        if ignore { ignoreWrite = feature } else { failWrite = feature }
    }
    func pause(_ feature: UInt8) { pauseWrite = feature }
    func resume() { pauseWrite = nil; pending?.resume(); pending = nil }
    func setForeign() { wheel = 0x80 }
    func changeRoot() { rootChanged = true }
    func changeCapabilities() { capabilitiesChanged = true }
    func malformedReply(_ kind: Int) { malformed = kind }
    func setNativeButtons() { buttons = [0x53: 0, 0x56: 0] }
    func setButtonDiverted() { buttons[0x53] = 1 }
    func disconnect() { continuation?.yield(.failure(.disconnected)) }
    func open(_ continuation: AsyncStream<BoltTransportEvent>.Continuation) { self.continuation = continuation }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        if feature == 0, function == 1 {
            guard slot == 2 else { throw BoltFailure.unavailable }
            return [2, 0, parameters[2]]
        }
        if feature == 0 {
            if parameters == [0x21, 0x21] {
                if malformed == 0 { return [15, 0] }
                wheelRoots += 1
                return [rootChanged && wheelRoots > 1 ? 17 : 15, 0, 1]
            }
            if parameters == [0x21, 0x50] { return malformed == 1 ? [16, 0] : [16, 0, 0] }
            buttonRoots += 1
            return [9, 0, 5]
        }
        if feature == 9 {
            if function == 0 { return [2] }
            if function == 1 {
                if capabilitiesChanged && buttonRoots > 1 { return Array(repeating: 0, count: 16) }
                let control: MouseControl = parameters[0] == 0 ? .back : .forward
                return BoltWire.bytes(BoltWire.cid(control)) + BoltWire.bytes(control == .back ? 0x3C : 0x3E) + [0x20] + Array(repeating: 0, count: 11)
            }
            let cid = BoltWire.word(parameters, 0)
            if function == 2 { return BoltWire.bytes(cid) + [buttons[cid] ?? 0] + BoltWire.bytes(remap == 0xFFFF ? cid : remap) + Array(repeating: 0, count: 11) }
        } else if function == 0 {
            if feature == 15 && malformed == 2 { return [8] }
            if feature == 16 && malformed == 3 { return [0, 0] }
            return feature == 15 ? [8, 8] : Array(repeating: 0, count: 8)
        } else if function == 1 {
            if failReads == feature { throw BoltFailure.timeout }
            return (feature == 15 ? [wheel, 0] : thumb) + Array(repeating: 0, count: 14)
        }
        writes.append((feature, parameters))
        if ignoreWrite != feature {
            if feature == 9 { buttons[BoltWire.word(parameters, 0)] = parameters[2] == 3 ? 1 : 0 }
            if feature == 15 { wheel = parameters[0] }
            if feature == 16 { thumb = parameters }
        }
        if pauseWrite == feature {
            paused = true
            await withCheckedContinuation { pending = $0 }
        }
        if failWrite == feature { throw BoltFailure.timeout }
        return feature == 9 ? BoltWire.bytes(BoltWire.word(parameters, 0)) + Array(repeating: 0, count: 14) : Array(repeating: 0, count: 16)
    }

    func failModeReads(_ feature: UInt8) { failReads = feature }
}

private final class RecoveryChannel: BoltTransport, Sendable {
    let events: AsyncStream<BoltTransportEvent>
    let continuation: AsyncStream<BoltTransportEvent>.Continuation
    let fixture: RecoveryFixture
    let ledger: BoltRequestIDLedger
    init(_ fixture: RecoveryFixture) {
        self.fixture = fixture
        ledger = fixture.requestIDs.makeTransportLedger()
        let stream = AsyncStream<BoltTransportEvent>.makeStream()
        events = stream.stream; continuation = stream.continuation
    }
    func open() async { await fixture.open(continuation) }
    func close() async { continuation.finish() }
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int { ledger.available(slot: slot, feature: feature, function: function) }
    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        let transaction = try BoltRequestTransaction(ledger: ledger, slot: slot, feature: feature, function: function, parameters: parameters)
        defer { transaction.retire() }
        let payload = try await fixture.request(slot: slot, feature: feature, function: function, parameters: parameters)
        let size = payload.count <= 3 ? 3 : 16
        let report: [UInt8] = [size == 3 ? 0x10 : 0x11, slot, feature, transaction.lease.functionSoftware] + payload + Array(repeating: 0, count: size - payload.count)
        let decoded = try transaction.complete(matchedReply: transaction.reply(report), sendSucceeded: true)
        return await fixture.malformed == nil ? decoded : payload
    }
}

private actor RecoveryRecorder {
    var statuses: [BoltStatus] = []
    var inputs = 0
    var last: BoltStatus? { statuses.last }
    func record(_ event: BoltEvent) {
        if case .status(let status) = event { statuses.append(status) } else { inputs += 1 }
    }
}

private func recoveryEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func connectReclaimsFourDivertedControlsBeforeReadyAndUsesNormalPreferencePath() async {
    let fixture = RecoveryFixture()
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .ready })
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
    #expect(await fixture.wheel == 0)
    #expect(await fixture.thumb == [0, 0])
    #expect(await fixture.writes.count == 4)
    #expect(await recorder.last?.wheel.support == .supported)
    #expect(await recorder.last?.thumbwheel.support == .supported)
    #expect(await recorder.inputs == 0)
    await controller.applyWheelPreference(true, restorePreviousSettingsOnDisconnect: true)
    await controller.applyThumbwheelPreferences(inverted: true, amount: nil, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: false)
    await controller.enable()
    #expect(await recoveryEventually { await recorder.last?.phase == .enabled })
    await controller.stop()
    #expect(await fixture.wheel == 0)
    #expect(await fixture.thumb == [0, 0])
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
}

@Test(arguments: [UInt8(0), 2, 4, 6]) func connectRecoveryPreservesOtherModeBits(bits: UInt8) async {
    let fixture = RecoveryFixture()
    await fixture.configure(wheel: bits | 1, thumb: [1, bits | 1])
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    await controller.discover()
    #expect(await fixture.wheel == bits)
    #expect(await fixture.thumb == [0, bits | 1])
    await controller.stop()
}

@Test(arguments: [0, 1, 2, 3]) func connectPreflightRejectsUnknownStateBeforeAnyWrite(kind: Int) async {
    let fixture = RecoveryFixture()
    await fixture.configure(wheel: kind == 0 ? 0x80 : 1, thumb: kind == 1 ? [1, 8] : [1, 0], remap: kind == 2 ? 0x77 : 0, buttonFlags: kind == 3 ? 3 : 1)
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.writes.isEmpty)
    #expect(await recorder.statuses.allSatisfy { $0.phase != .ready })
}

@Test(arguments: [UInt8(9), 15, 16]) func connectSetterFailureNeverPublishesReadyAndDoesNotRestoreDiversion(feature: UInt8) async {
    let fixture = RecoveryFixture()
    await fixture.setFailure(feature)
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.failure?.stage == .connectRecoveryWrite)
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.statuses.allSatisfy { $0.phase != .ready })
    #expect(await fixture.writes.allSatisfy { feature, parameters in feature == 9 ? parameters[2] == 2 : parameters[0] & 1 == 0 })
}

@Test func connectReadbackFailureRetainsUncertaintyAndBlocksRediscovery() async {
    let fixture = RecoveryFixture()
    await fixture.setFailure(15, ignore: true)
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.failure?.stage == .connectRecoveryReadback)
    #expect(await recorder.last?.cleanupUncertain == true)
    #expect(await fixture.writes.count == 4)
    await controller.discover()
    #expect(await fixture.writes.count == 4)
    #expect(await fixture.thumb == [1, 0])
}

@Test(arguments: [0, 1, 2, 3, 4]) func connectPartialCancellationAndTerminalFailuresRemainSafe(kind: Int) async {
    let fixture = RecoveryFixture()
    await fixture.pause(15)
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    let discovery = Task { await controller.discover() }
    #expect(await recoveryEventually { await fixture.paused })
    var transition: Task<Void, Never>?
    if kind == 0 { discovery.cancel() }
    if kind == 1 { transition = Task { await controller.stop() } }
    if kind == 2 { await fixture.disconnect(); await fixture.failModeReads(15) }
    if kind == 3 { await fixture.setForeign(); discovery.cancel() }
    if kind == 4 { transition = Task { await controller.disable() }; try? await Task.sleep(for: .milliseconds(20)) }
    if kind == 1 { #expect(await recoveryEventually { await recorder.last?.phase == .stopping }) }
    if kind == 2 { try? await Task.sleep(for: .milliseconds(20)) }
    await fixture.resume()
    await discovery.value
    await transition?.value
    #expect(await recoveryEventually { await recorder.last?.phase == (kind == 1 ? .idle : .failed) })
    #expect(await recorder.statuses.allSatisfy { $0.phase != .ready })
    #expect(await recorder.last?.cleanupUncertain == (kind == 2 || kind == 3))
    #expect(await fixture.thumb == [1, 0])
    #expect(await fixture.writes.count == 3)
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
}

@Test func connectRevalidatesCapabilityTableBeforeFirstRecoveryWrite() async {
    let fixture = RecoveryFixture()
    await fixture.changeCapabilities()
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    await controller.discover()
    #expect(await fixture.writes.isEmpty)
}

@Test func connectRevalidatesFeatureAssociationBeforeRecoveryWrite() async {
    let fixture = RecoveryFixture()
    await fixture.configure(buttonFlags: 0)
    await fixture.setNativeButtons()
    await fixture.changeRoot()
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    await controller.discover()
    #expect(await fixture.writes.isEmpty)
}

@Test func connectRecoveryDoesNotWeakenLaterEnableForeignStateGuard() async {
    let fixture = RecoveryFixture()
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    await controller.discover()
    await fixture.setButtonDiverted()
    await controller.enable()
    #expect(await fixture.writes.count == 4)
    #expect(await fixture.buttons[0x53] == 1)
}

@Test(arguments: [0, 1, 2, 3]) func connectMalformedPreflightBlocksAllRecoveryWrites(kind: Int) async {
    let fixture = RecoveryFixture()
    await fixture.malformedReply(kind)
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.failure?.code == .replyMalformed)
    #expect(await fixture.writes.isEmpty)
}

@Test func connectRecoveryRecognisesExistingSelfCIDRemapSemantics() async {
    let fixture = RecoveryFixture()
    await fixture.configure(remap: 0xFFFF)
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .ready })
    #expect(await fixture.writes.count == 4)
    await controller.stop()
}

@Test func connectRecoveryReservesReadbackAndCleanupCapacityBeforeWriting() async throws {
    let fixture = RecoveryFixture()
    let channel = RecoveryChannel(fixture)
    try fixture.requestIDs.retireForFixture(feature: 9, function: 2, count: 6)
    let controller = BoltController(makeTransport: { channel })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.failure?.code == .requestIDsExhausted)
    #expect(await fixture.writes.isEmpty)
}
