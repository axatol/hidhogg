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
    var wheelRootAbsent = false
    var wheelRootUnsupported = false
    var thumbwheelRootAbsent = false
    var thumbwheelRootUnsupported = false
    var buttonRoots = 0
    var wheelRoots = 0
    var malformed: Int?
    var pending: CheckedContinuation<Void, Never>?
    var continuations: [AsyncStream<BoltTransportEvent>.Continuation] = []
    var lifecycle: [String] = []
    var activeTransport = 0
    var shiftsFeatureIndexesOnReconnect = false
    var closedTransports = Set<Int>()
    var writesByTransport: [(transport: Int, feature: UInt8)] = []
    var writesAfterClose = 0
    var modeReadsByTransport: [(transport: Int, feature: UInt8)] = []

    private var buttonFeature: UInt8 { shiftsFeatureIndexesOnReconnect && activeTransport > 1 ? 10 : 9 }
    private var wheelFeature: UInt8 { shiftsFeatureIndexesOnReconnect && activeTransport > 1 ? 17 : 15 }
    private var thumbwheelFeature: UInt8 { shiftsFeatureIndexesOnReconnect && activeTransport > 1 ? 18 : 16 }

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
    func shiftFeatureIndexesOnReconnect() { shiftsFeatureIndexesOnReconnect = true }
    func changeRoot() { rootChanged = true }
    func changeCapabilities() { capabilitiesChanged = true }
    func setWheelRootAbsent() { wheelRootAbsent = true; wheelRootUnsupported = false }
    func setWheelRootUnsupported() { wheelRootAbsent = false; wheelRootUnsupported = true }
    func setThumbwheelRootAbsent() { thumbwheelRootAbsent = true; thumbwheelRootUnsupported = false }
    func setThumbwheelRootUnsupported() { thumbwheelRootAbsent = false; thumbwheelRootUnsupported = true }
    func setSupportedRoots() {
        wheelRootAbsent = false
        wheelRootUnsupported = false
        thumbwheelRootAbsent = false
        thumbwheelRootUnsupported = false
    }
    func malformedReply(_ kind: Int) { malformed = kind }
    func clearMalformedReply() { malformed = nil }
    func setNativeButtons() { buttons = [0x53: 0, 0x56: 0] }
    func setButtonDiverted() { buttons[0x53] = 1 }
    func disconnect() { continuations.last?.yield(.failure(.disconnected)) }
    func open(_ continuation: AsyncStream<BoltTransportEvent>.Continuation) {
        continuations.append(continuation)
        activeTransport = continuations.count
        lifecycle.append("open")
    }
    func close() {
        closedTransports.insert(activeTransport)
        lifecycle.append("close")
    }
    func finishEvents() { continuations.forEach { $0.finish() } }
    func sendSnapshot(transport: Int, controls: Set<MouseControl>) {
        guard continuations.indices.contains(transport) else { return }
        let pressed = MouseControl.allCases.filter(controls.contains).flatMap { BoltWire.bytes(BoltWire.cid($0)) }
        let payload = pressed + Array(repeating: UInt8(0), count: 16 - pressed.count)
        let feature: UInt8 = shiftsFeatureIndexesOnReconnect && transport > 0 ? 10 : 9
        continuations[transport].yield(.report([0x11, 2, feature, 0] + payload, at: .now))
    }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        if feature == 0, function == 1 {
            guard slot == 2 else { throw BoltFailure.unavailable }
            return [2, 0, parameters[2]]
        }
        if feature == 0 {
            if parameters == [0x21, 0x21] {
                if malformed == 0 { return [15, 0] }
                wheelRoots += 1
                if wheelRootAbsent { return [0, 0, 0] }
                if wheelRootUnsupported { return [wheelFeature, 0, 2] }
                return [rootChanged && wheelRoots > 1 ? 17 : wheelFeature, 0, 1]
            }
            if parameters == [0x21, 0x50] {
                if malformed == 1 { return [thumbwheelFeature, 0] }
                if thumbwheelRootAbsent { return [0, 0, 0] }
                if thumbwheelRootUnsupported { return [thumbwheelFeature, 0, 1] }
                return [thumbwheelFeature, 0, 0]
            }
            buttonRoots += 1
            return [buttonFeature, 0, 5]
        }
        guard feature == buttonFeature || feature == wheelFeature || feature == thumbwheelFeature else {
            throw BoltFailure.unsupported
        }
        if feature == buttonFeature {
            if function == 0 { return [2] }
            if function == 1 {
                if capabilitiesChanged && buttonRoots > 1 { return Array(repeating: 0, count: 16) }
                let control: MouseControl = parameters[0] == 0 ? .back : .forward
                return BoltWire.bytes(BoltWire.cid(control)) + BoltWire.bytes(control == .back ? 0x3C : 0x3E) + [0x20] + Array(repeating: 0, count: 11)
            }
            let cid = BoltWire.word(parameters, 0)
            if function == 2 { return BoltWire.bytes(cid) + [buttons[cid] ?? 0] + BoltWire.bytes(remap == 0xFFFF ? cid : remap) + Array(repeating: 0, count: 11) }
        } else if function == 0 {
            if feature == wheelFeature && malformed == 2 { return [8] }
            if feature == thumbwheelFeature && malformed == 3 { return [0, 0] }
            return feature == wheelFeature ? [8, 8] : Array(repeating: 0, count: 8)
        } else if function == 1 {
            modeReadsByTransport.append((activeTransport, feature))
            if failReads == feature { throw BoltFailure.timeout }
            return (feature == wheelFeature ? [wheel, 0] : thumb) + Array(repeating: 0, count: 14)
        }
        writes.append((feature, parameters))
        writesByTransport.append((activeTransport, feature))
        if closedTransports.contains(activeTransport) { writesAfterClose += 1 }
        if ignoreWrite != feature {
            if feature == buttonFeature { buttons[BoltWire.word(parameters, 0)] = parameters[2] == 3 ? 1 : 0 }
            if feature == wheelFeature { wheel = parameters[0] }
            if feature == thumbwheelFeature { thumb = parameters }
        }
        if pauseWrite == feature {
            paused = true
            await withCheckedContinuation { pending = $0 }
        }
        if failWrite == feature { throw BoltFailure.timeout }
        return feature == buttonFeature ? BoltWire.bytes(BoltWire.word(parameters, 0)) + Array(repeating: 0, count: 14) : Array(repeating: 0, count: 16)
    }

    func failModeReads(_ feature: UInt8?) { failReads = feature }
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
    func close() async { await fixture.close() }
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
    func isFailedUncertain() -> Bool { last?.phase == .failed && last?.cleanupUncertain == true }
    func failedRecoveryWasPublished(after count: Int) -> Bool {
        statuses.count > count && statuses.dropFirst(count).allSatisfy { $0.phase != .ready } &&
            statuses.last?.phase == .failed && statuses.last?.cleanupUncertain == true
    }
    func readyRecoveryWasPublished(after count: Int) -> Bool {
        statuses.count > count && statuses.last?.phase == .ready && statuses.last?.cleanupUncertain == false
    }
    func unverifiedStopWasPublished(after count: Int) -> Bool {
        statuses.count >= count + 2 && statuses.last?.phase == .failed &&
            statuses.last?.cleanupUncertain == true &&
            statuses.last?.message.contains("fresh discovery must verify") == true
    }
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

@Test func connectReadbackFailureRetainsUncertaintyUntilFreshVerifiedRediscovery() async {
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
    let writesAfterFirstFailure = await fixture.writes.count

    await fixture.setWheelRootAbsent()
    let statusesBeforeAbsentWheel = await recorder.statuses.count
    await controller.discover()
    #expect(await recoveryEventually { await recorder.failedRecoveryWasPublished(after: statusesBeforeAbsentWheel) })
    #expect(await fixture.lifecycle.filter { $0 == "open" }.count == 2)
    #expect(await fixture.writes.count == writesAfterFirstFailure)
    #expect(await fixture.writesAfterClose == 0)

    await fixture.setSupportedRoots()
    await fixture.malformedReply(2)
    await controller.discover()
    #expect(await recoveryEventually { await fixture.lifecycle.filter { $0 == "open" }.count == 3 })
    #expect(await recoveryEventually { await recorder.last?.failure?.code == .replyMalformed })
    #expect(await recorder.last?.cleanupUncertain == true)
    #expect(await fixture.writes.count == writesAfterFirstFailure)
    let statusesBeforeStop = await recorder.statuses.count
    #expect(await controller.stopForRestart() == false)
    #expect(await recoveryEventually { await recorder.unverifiedStopWasPublished(after: statusesBeforeStop) })
    #expect(await recorder.last?.phase == .failed)
    #expect(await recorder.last?.cleanupUncertain == true)
    #expect(await recorder.last?.message.contains("fresh discovery must verify") == true)
    await fixture.clearMalformedReply()
    await fixture.setFailure(nil, ignore: true)
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .ready })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.lifecycle == ["open", "close", "open", "close", "open", "close", "open"])
    #expect(await fixture.thumb == [0, 0])
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
    await controller.enable()
    #expect(await recoveryEventually { await recorder.last?.phase == .enabled })
    await fixture.sendSnapshot(transport: 3, controls: [])
    try? await Task.sleep(for: .milliseconds(20))
    await fixture.sendSnapshot(transport: 0, controls: [.back])
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await recorder.inputs == 0)
    await fixture.sendSnapshot(transport: 3, controls: [.back])
    #expect(await recoveryEventually { await recorder.inputs == 1 })
    await controller.stop()
    await fixture.finishEvents()
}

@Test func freshRecoveryUsesRequeriedFeatureIndexesAfterUncertainCleanup() async {
    let fixture = RecoveryFixture()
    await fixture.shiftFeatureIndexesOnReconnect()
    await fixture.setFailure(15, ignore: true)
    let controller = BoltController(makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }

    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == true)
    #expect(await fixture.lifecycle == ["open", "close"])

    await fixture.setFailure(nil, ignore: true)
    await fixture.setButtonDiverted()
    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .ready })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.lifecycle == ["open", "close", "open"])
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
    #expect(await fixture.wheel == 0)
    #expect(await fixture.thumb == [0, 0])

    await controller.enable()
    #expect(await recoveryEventually { await recorder.last?.phase == .enabled })
    #expect(await fixture.writesByTransport.filter { $0.transport == 2 }.map { $0.feature } == [10, 17, 18, 10, 10])
    #expect(await fixture.writesAfterClose == 0)
    await controller.stop()
    await fixture.finishEvents()
}

@Test func uncertainWheelCaptureRequiresFreshSupportedRoutingBeforeReady() async {
    let fixture = RecoveryFixture()
    await fixture.shiftFeatureIndexesOnReconnect()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }

    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .ready })
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    #expect(await recoveryEventually { await recorder.last?.wheel.captureActive == true })
    #expect(await fixture.wheel == 1)

    await fixture.failModeReads(15)
    await fixture.disconnect()
    #expect(await recoveryEventually { await recorder.isFailedUncertain() })
    #expect(await fixture.wheel == 1)

    await fixture.failModeReads(nil)
    await fixture.setWheelRootAbsent()
    let statusCountBeforeAbsentRoot = await recorder.statuses.count
    await controller.discover()
    let absentRootRejected = await recoveryEventually { await recorder.failedRecoveryWasPublished(after: statusCountBeforeAbsentRoot) }
    #expect(absentRootRejected)
    guard absentRootRejected else { return }
    await controller.enable()
    #expect(await recorder.last?.phase == .failed)
    #expect(await fixture.writesByTransport.filter { $0.transport == 2 }.isEmpty)

    await fixture.setWheelRootUnsupported()
    let statusCountBeforeUnsupportedRoot = await recorder.statuses.count
    await controller.discover()
    let unsupportedRootRejected = await recoveryEventually { await recorder.failedRecoveryWasPublished(after: statusCountBeforeUnsupportedRoot) }
    #expect(unsupportedRootRejected)
    guard unsupportedRootRejected else { return }
    await controller.enable()
    #expect(await recorder.last?.phase == .failed)
    #expect(await fixture.writesByTransport.filter { $0.transport == 3 }.isEmpty)

    await fixture.setSupportedRoots()
    let statusCountBeforeSupportedRoot = await recorder.statuses.count
    await controller.discover()
    #expect(await recoveryEventually { await recorder.readyRecoveryWasPublished(after: statusCountBeforeSupportedRoot) })
    #expect(await fixture.wheel == 0)
    #expect(await fixture.writesByTransport.filter { $0.transport == 4 }.map { $0.feature } == [17])
    let freshModeReadFeatures = await fixture.modeReadsByTransport.filter { $0.transport > 1 }.map { $0.feature }
    #expect(freshModeReadFeatures == [17, 18, 17, 17, 17, 18])
    #expect(await fixture.writesAfterClose == 0)
    await controller.enable()
    #expect(await recoveryEventually { await recorder.last?.phase == .enabled })
    await controller.stop()
    await fixture.finishEvents()
}

@Test func uncertainThumbwheelCaptureRequiresFreshSupportedRoutingBeforeReady() async {
    let fixture = RecoveryFixture()
    await fixture.shiftFeatureIndexesOnReconnect()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { RecoveryChannel(fixture) })
    let recorder = RecoveryRecorder()
    let reader = Task { for await event in controller.events { await recorder.record(event) } }
    defer { reader.cancel() }

    await controller.discover()
    #expect(await recoveryEventually { await recorder.last?.phase == .ready })
    await controller.applyThumbwheelPreferences(inverted: nil, amount: 1, restorePreviousSettingsOnDisconnect: false,
                                               scrollPostingAllowed: true)
    #expect(await recoveryEventually { await recorder.last?.thumbwheel.captureActive == true })
    #expect(await fixture.thumb == [1, 0])

    await fixture.failModeReads(16)
    await fixture.disconnect()
    #expect(await recoveryEventually { await recorder.isFailedUncertain() })
    #expect(await fixture.thumb == [1, 0])

    await fixture.failModeReads(nil)
    await fixture.setThumbwheelRootAbsent()
    let statusCountBeforeAbsentRoot = await recorder.statuses.count
    await controller.discover()
    let absentRootRejected = await recoveryEventually { await recorder.failedRecoveryWasPublished(after: statusCountBeforeAbsentRoot) }
    #expect(absentRootRejected)
    guard absentRootRejected else { return }
    await controller.enable()
    #expect(await recorder.last?.phase == .failed)
    #expect(await fixture.writesByTransport.filter { $0.transport == 2 }.isEmpty)

    await fixture.setThumbwheelRootUnsupported()
    let statusCountBeforeUnsupportedRoot = await recorder.statuses.count
    await controller.discover()
    let unsupportedRootRejected = await recoveryEventually { await recorder.failedRecoveryWasPublished(after: statusCountBeforeUnsupportedRoot) }
    #expect(unsupportedRootRejected)
    guard unsupportedRootRejected else { return }
    await controller.enable()
    #expect(await recorder.last?.phase == .failed)
    #expect(await fixture.writesByTransport.filter { $0.transport == 3 }.isEmpty)

    await fixture.setSupportedRoots()
    let statusCountBeforeSupportedRoot = await recorder.statuses.count
    await controller.discover()
    #expect(await recoveryEventually { await recorder.readyRecoveryWasPublished(after: statusCountBeforeSupportedRoot) })
    #expect(await fixture.thumb == [0, 0])
    #expect(await fixture.writesByTransport.filter { $0.transport == 4 }.map { $0.feature } == [18])
    let freshModeReadFeatures = await fixture.modeReadsByTransport.filter { $0.transport > 1 }.map { $0.feature }
    #expect(freshModeReadFeatures == [17, 17, 17, 18, 18, 18, 17, 18])
    #expect(await fixture.writesAfterClose == 0)
    await controller.enable()
    #expect(await recoveryEventually { await recorder.last?.phase == .enabled })
    await controller.stop()
    await fixture.finishEvents()
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
