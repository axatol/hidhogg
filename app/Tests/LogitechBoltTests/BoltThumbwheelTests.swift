import Foundation
import Testing
@testable import LogitechBolt

private actor ThumbFixture {
    nonisolated let requestIDs = BoltFixtureRequestIDs()
    var root: [UInt8] = [16, 0, 0]
    var wheelRoot: [UInt8] = [15, 0, 1]
    var mode: [UInt8] = [0, 0]
    var info = Array(repeating: UInt8(0), count: 8)
    var wheelMode: UInt8 = 0
    var writes: [[UInt8]] = []
    var wheelWrites: [[UInt8]] = []
    var buttons: [UInt16: UInt8] = [0x53: 0, 0x56: 0]
    var tokens: [UInt32: Int] = [:]
    var continuation: AsyncStream<BoltTransportEvent>.Continuation?
    var closes = 0
    var failBeforeSet = false
    var failAfterSet = false
    var failRestore = false
    var failButtonRestore = false
    var pauseSet = false
    var setPaused = false
    var pendingSet: CheckedContinuation<Void, Never>?
    var pauseReadNumber: Int?
    var readPaused = false
    var pendingRead: CheckedContinuation<Void, Never>?
    var reads = 0

    func configure(root: [UInt8] = [16, 0, 0], mode: [UInt8] = [0, 0], wheelRoot: [UInt8] = [15, 0, 1]) {
        self.root = root; self.mode = mode; self.wheelRoot = wheelRoot
    }
    func configureFailures(before: Bool = false, after: Bool = false, restore: Bool = false, buttons: Bool = false) {
        failBeforeSet = before; failAfterSet = after; failRestore = restore; failButtonRestore = buttons
    }
    func setMode(_ mode: [UInt8]) { self.mode = mode }
    func setRoot(_ root: [UInt8]) { self.root = root }
    func setInfo(_ info: [UInt8]) { self.info = info }
    func pauseSetter() { pauseSet = true }
    func resumeSetter() { pauseSet = false; pendingSet?.resume(); pendingSet = nil }
    func pauseRead(_ number: Int) { pauseReadNumber = number }
    func resumeRead() { pendingRead?.resume(); pendingRead = nil }
    func count(feature: UInt8, function: UInt8) -> Int {
        tokens[UInt32(2) << 16 | UInt32(feature) << 8 | UInt32(function), default: 0]
    }
    func open(_ continuation: AsyncStream<BoltTransportEvent>.Continuation) { self.continuation = continuation }
    func close() { closes += 1 }
    func send(_ bytes: [UInt8], at: ContinuousClock.Instant = .now) { continuation?.yield(.report(bytes, at: at)) }
    func movement(_ rotation: Int16, state: UInt8 = 2, flags: UInt8 = 0, at: ContinuousClock.Instant = .now) {
        send([0x11, 2, 16, 0] + BoltWire.bytes(UInt16(bitPattern: rotation)) + [0x12, 0x34, state, flags] + Array(repeating: 0, count: 10), at: at)
    }
    func wheel(_ rotation: Int16) {
        send([0x11, 2, 15, 0, 0] + BoltWire.bytes(UInt16(bitPattern: rotation)) + Array(repeating: 0, count: 13))
    }
    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        let key = UInt32(slot) << 16 | UInt32(feature) << 8 | UInt32(function)
        tokens[key, default: 0] += 1
        if feature == 0, function == 1 {
            guard slot == 2 else { throw BoltFailure.unavailable }
            return [2, 0, parameters[2]]
        }
        if feature == 0 {
            if parameters == [0x21, 0x50] { return root }
            if parameters == [0x21, 0x21] { return wheelRoot }
            return [9, 0, 5]
        }
        if feature == 16 {
            if function == 0 { return info }
            if function == 1 {
                reads += 1
                if reads == pauseReadNumber {
                    readPaused = true
                    await withCheckedContinuation { pendingRead = $0 }
                }
                return mode + Array(repeating: 0, count: 14)
            }
            writes.append(parameters)
            if failBeforeSet { failBeforeSet = false; throw BoltFailure.timeout }
            if failRestore, parameters[0] == 0 { throw BoltFailure.timeout }
            mode = parameters
            if pauseSet {
                setPaused = true
                await withCheckedContinuation { pendingSet = $0 }
            }
            if failAfterSet { throw BoltFailure.timeout }
            return Array(repeating: 0, count: 16)
        }
        if feature == 15 {
            if function == 0 { return [8, 8] }
            if function == 1 { return [wheelMode, 0] + Array(repeating: 0, count: 14) }
            wheelWrites.append(parameters); wheelMode = parameters[0]
            return Array(repeating: 0, count: 16)
        }
        if function == 0 { return [2] }
        if function == 1 {
            let cid: UInt16 = parameters[0] == 0 ? 0x53 : 0x56
            let task: UInt16 = parameters[0] == 0 ? 0x3C : 0x3E
            return BoltWire.bytes(cid) + BoltWire.bytes(task) + [0x20] + Array(repeating: 0, count: 11)
        }
        let cid = BoltWire.word(parameters, 0)
        if function == 2 { return BoltWire.bytes(cid) + [buttons[cid] ?? 0] + Array(repeating: 0, count: 13) }
        if parameters[2] == 2, failButtonRestore { throw BoltFailure.transport }
        buttons[cid] = parameters[2] == 3 ? 1 : 0
        return BoltWire.bytes(cid) + Array(repeating: 0, count: 14)
    }
}

private final class ThumbChannel: BoltTransport, Sendable {
    private let requestIDs: BoltRequestIDLedger
    let fixture: ThumbFixture
    let events: AsyncStream<BoltTransportEvent>
    let continuation: AsyncStream<BoltTransportEvent>.Continuation
    init(_ fixture: ThumbFixture) {
        self.fixture = fixture
        requestIDs = fixture.requestIDs.makeTransportLedger()
        let stream = AsyncStream<BoltTransportEvent>.makeStream()
        events = stream.stream; continuation = stream.continuation
    }
    func open() async { await fixture.open(continuation) }
    func close() async { await fixture.close(); continuation.finish() }
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int {
        requestIDs.available(slot: slot, feature: feature, function: function)
    }

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

private actor ThumbRecorder {
    var last: BoltStatus?
    var movements: [(Double, UInt8, UInt64, ContinuousClock.Instant)] = []
    var scrolls = 0
    var count: Int { movements.count }
    func movement(_ index: Int) -> (Double, UInt8, UInt64, ContinuousClock.Instant) { movements[index] }
    func record(_ event: BoltEvent) {
        switch event {
        case .status(let status): last = status
        case .thumbwheel(let rotation, let state, let generation, let time): movements.append((rotation, state, generation, time))
        case .scroll: scrolls += 1
        case .press: break
        }
    }
}

private func watchThumb(_ controller: BoltController, _ recorder: ThumbRecorder) -> Task<Void, Never> {
    Task { for await event in controller.events { await recorder.record(event) } }
}

private func thumbEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func thumbwheelWireDecodesExactSelectedLongReportAndRawCounts() throws {
    let report: [UInt8] = [0x11, 2, 16, 0, 0xFF, 0xFE, 0x12, 0x34, 3, 0x0E] + Array(repeating: 0, count: 10)
    let movement = try #require(try BoltWire.thumbwheelMovement(report, slot: 2, feature: 16))
    #expect(movement.rotation == -2 && movement.elapsed == 0x1234 && movement.state == 3 && movement.flags == 0x0E)
    #expect(try BoltWire.thumbwheelMovement(report, slot: 3, feature: 16) == nil)
    #expect(throws: BoltFailure.malformed) { try BoltWire.thumbwheelMovement(Array(report.prefix(19)), slot: 2, feature: 16) }
    #expect(try ThumbwheelState.Mode.decode([0, 6]) == .init(diverted: false, inverted: false))
    #expect(throws: BoltFailure.foreignState) { try ThumbwheelState.Mode.decode([2, 0]) }
}

@Test(arguments: [false, true])
func thumbwheelDirectionCaptureNeutralizesOnceAndRestoresPolicy(restore: Bool) async {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    #expect(await fixture.count(feature: 16, function: 0) == 0)
    await controller.applyThumbwheelPreferences(inverted: true, amount: 1, restorePreviousSettingsOnDisconnect: restore, scrollPostingAllowed: true)
    #expect(await fixture.writes == [[0, 1], [1, 0]])
    await fixture.movement(9, state: 1)
    await fixture.movement(-4, state: 2)
    await fixture.movement(0, state: 3)
    await fixture.movement(10, state: 0)
    #expect(await thumbEventually { await recorder.count == 3 })
    #expect(await recorder.movement(0).0 == -9)
    #expect(await recorder.movement(1).0 == 4)
    #expect(await recorder.movement(2).1 == 3)
    let event = await recorder.movement(0)
    #expect(controller.withThumbwheelAdmission(generation: event.2, observedAt: event.3) {})
    #expect(await recorder.last?.thumbwheel.effectiveInverted == true)
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == [0, restore ? 0 : 1])
    #expect(!controller.withThumbwheelAdmission(generation: event.2, observedAt: .now) {})
}

@Test(arguments: [[0, 0, 0], [16, 0, 1], [16, 0x80, 0]])
func thumbwheelUnsupportedIsLocalAndDoesNotAffectVerticalCapture(root: [UInt8]) async {
    let fixture = ThumbFixture(); await fixture.configure(root: root)
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false, amount: 1, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: true, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    #expect(await thumbEventually { await recorder.last?.thumbwheel.support == .unsupported })
    #expect(await recorder.last?.phase == .ready)
    #expect(await fixture.wheelMode == 1)
    #expect(await fixture.writes.isEmpty)
    #expect(await controller.stopForRestart())
}

@Test func thumbwheelWorksWithout2121AndAmountOnlyConsumesNoRequests() async {
    let fixture = ThumbFixture(); await fixture.configure(wheelRoot: [0, 0, 0])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyThumbwheelPreferences(inverted: nil, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    let counts = await fixture.tokens
    await fixture.movement(3)
    #expect(await thumbEventually { await recorder.count == 1 })
    let old = await recorder.movement(0)
    controller.suspendThumbwheelAdmission()
    await controller.applyThumbwheelPreferences(inverted: nil, amount: 2, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    #expect(await fixture.tokens == counts)
    #expect(!controller.withThumbwheelAdmission(generation: old.2, observedAt: .now) {})
    await fixture.movement(3)
    #expect(await thumbEventually { await recorder.count == 2 })
    #expect(await recorder.movement(1).0 == 3)
    #expect(await controller.stopForRestart())
}

@Test func thumbwheelPermissionReleasePreservesVerticalCaptureAndPhysicalDirection() async {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false, amount: 1, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: true, amount: 1, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: true, amount: 1, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: false)
    #expect(await fixture.mode == [0, 1])
    #expect(await fixture.wheelMode == 1)
    await fixture.wheel(1)
    #expect(await thumbEventually { await recorder.scrolls == 1 })
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == [0, 0])
}

@Test(arguments: [0, 1, 2, 3])
func thumbwheelMalformedStaleOrInvalidReportsReleaseBothCaptures(kind: Int) async {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false, amount: 1, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: nil, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    if kind == 0 { await fixture.send([0x10, 2, 16, 0, 0, 0, 0]) }
    else if kind == 1 { await fixture.movement(1, state: 4) }
    else { await fixture.movement(1, at: .now.advanced(by: .milliseconds(kind == 2 ? -500 : 500))) }
    #expect(await thumbEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == [0, 0])
    #expect(await fixture.wheelMode == 0)
    #expect(await recorder.count == 0)
    #expect(await recorder.last?.cleanupUncertain == false)
}

@Test(arguments: [false, true])
func thumbwheelFailedSetterAndCancellationRestoreAttributableState(cancel: Bool) async {
    let fixture = ThumbFixture(); await fixture.configure(mode: [0, 1])
    if cancel { await fixture.pauseSetter() } else { await fixture.configureFailures(before: true) }
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    let apply = Task { await controller.applyThumbwheelPreferences(inverted: nil, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true) }
    if cancel {
        #expect(await thumbEventually { await fixture.setPaused })
        let stop = Task { await controller.stop() }
        #expect(await thumbEventually { await recorder.last?.phase == .stopping })
        await fixture.resumeSetter(); await apply.value; await stop.value
    } else { await apply.value }
    #expect(await fixture.mode == [0, 1])
    #expect(await recorder.last?.cleanupUncertain == false)
}

@Test func thumbwheelButtonCleanupFailureStillReleasesBothCaptures() async {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false, amount: 1, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: nil, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    await controller.enable()
    await fixture.configureFailures(buttons: true)
    await controller.disable()
    #expect(await thumbEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == [0, 0])
    #expect(await fixture.wheelMode == 0)
    #expect(await recorder.last?.phase == .failed)
}

@Test(arguments: [[0, 0, 0, 0, 2, 0, 0, 0], [0, 0, 0, 0, 0, 0x10, 0, 0], [0, 0]])
func thumbwheelMalformedInfoIsLocalUnsupported(info: [UInt8]) async {
    let fixture = ThumbFixture(); await fixture.setInfo(info)
    let controller = BoltController(makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyThumbwheelPreferences(inverted: true, amount: nil, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: false)
    #expect(await thumbEventually { await recorder.last?.thumbwheel.support == .unsupported })
    #expect(await fixture.writes.isEmpty)
    #expect(await recorder.last?.phase == .ready)
    #expect(await controller.stopForRestart())
}

@Test func thumbwheelRetiredRequestIDsKeepFinalCleanupReserve() async throws {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyThumbwheelPreferences(inverted: true, amount: 1, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: false, amount: 1, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    #expect(await fixture.reads == 13)
    try fixture.requestIDs.retireForFixture(feature: 16, function: 1, count: 13)
    await controller.applyThumbwheelPreferences(inverted: false, amount: nil, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    #expect(await thumbEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.reads == 15)
    #expect(await fixture.mode == [0, 0])
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.last?.phase == .failed)
}

private final class ThumbPermission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var checks: Int?
    private let onDenial: @Sendable () -> Void
    init(onDenial: @escaping @Sendable () -> Void = {}) { self.onDenial = onDenial }
    func read() -> Bool {
        lock.withLock {
            guard allowed else { return false }
            guard let checks else { return true }
            self.checks = checks - 1
            if checks <= 0 { onDenial() }
            return checks > 0
        }
    }
    func deny() { lock.withLock { allowed = false } }
    func denyAfterChecks(_ checks: Int) { lock.withLock { self.checks = checks } }
}

@Test(arguments: [false, true])
func thumbwheelPendingCaptureEventsAreNotReplayedAndPermissionIsFresh(deny: Bool) async {
    let fixture = ThumbFixture(); await fixture.pauseRead(2)
    let permission = ThumbPermission()
    let controller = BoltController(scrollPostingPreflight: { permission.read() }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    let apply = Task { await controller.applyThumbwheelPreferences(inverted: nil, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true) }
    #expect(await thumbEventually { await fixture.readPaused })
    await fixture.movement(7, state: 1)
    if deny { permission.deny() }
    await fixture.resumeRead(); await apply.value
    #expect(await recorder.count == 0)
    if deny {
        #expect(await fixture.writes.isEmpty)
        #expect(await recorder.last?.thumbwheel.captureBlocker != nil)
    } else {
        await fixture.movement(.min, state: 1)
        #expect(await thumbEventually { await recorder.count == 1 })
        #expect(await recorder.movement(0).0 == -32768)
    }
    #expect(await controller.stopForRestart())
}

@Test func thumbwheelStopUsesLatestRestorePolicyBeforeWaitingForApply() async {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyThumbwheelPreferences(inverted: true, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    await fixture.pauseRead(7)
    let apply = Task { await controller.applyThumbwheelPreferences(inverted: false, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true) }
    #expect(await thumbEventually { await fixture.readPaused })
    let stop = Task { await controller.stop(restorePreviousSettingsOnDisconnect: true) }
    #expect(await thumbEventually { await recorder.last?.phase == .stopping })
    await fixture.resumeRead(); await apply.value; await stop.value
    #expect(await fixture.mode == [0, 0])
    #expect(await recorder.last?.cleanupUncertain == false)
}

@Test func thumbwheelPermissionLossAfterSetterRetainsFinalTwoReadReleaseCapacity() async {
    let fixture = ThumbFixture()
    let permission = ThumbPermission(onDenial: {
        try? fixture.requestIDs.retireForFixture(feature: 16, function: 1, count: 13)
    })
    permission.denyAfterChecks(3)
    let controller = BoltController(scrollPostingPreflight: { permission.read() }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyThumbwheelPreferences(inverted: true, amount: 1, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: false, amount: 1, restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    #expect(await thumbEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.reads == 15)
    #expect(await fixture.mode == [0, 0])
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(fixture.requestIDs.available(slot: 2, feature: 16, function: 1) == 2)
}

@Test func thumbwheelAndVerticalCaptureEditsContinueBeyondIDWrapAndRestoreBothOwnedSettings() async {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    for edit in 0..<25 {
        let inverted = edit.isMultiple(of: 2)
        await controller.applyWheelPreferences(inverted: inverted, highResolution: nil,
                                               restorePreviousSettingsOnDisconnect: true, amount: 1, scrollPostingAllowed: true)
        await controller.applyThumbwheelPreferences(inverted: inverted, amount: 1,
                                                   restorePreviousSettingsOnDisconnect: true, scrollPostingAllowed: true)
    }
    #expect(await thumbEventually { await recorder.last?.thumbwheel.captureActive == true })
    #expect(await recorder.last?.wheel.captureActive == true)
    #expect(await recorder.last?.phase == .ready)
    #expect(await fixture.count(feature: 16, function: 1) > 100)
    #expect(await fixture.count(feature: 15, function: 1) > 100)
    #expect(await fixture.closes == 0)
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == [0, 0])
    #expect(await fixture.wheelMode == 0)
    #expect(fixture.requestIDs.available(slot: 2, feature: 16, function: 1) == 15)
    #expect(fixture.requestIDs.available(slot: 2, feature: 15, function: 1) == 15)
}

@Test func thumbwheelForeignCaptureIsUntouchedAndOtherCaptureStillReleases() async {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false, amount: 1, scrollPostingAllowed: true)
    await controller.applyThumbwheelPreferences(inverted: nil, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    await fixture.setMode([1, 1])
    #expect(!(await controller.stopForRestart()))
    #expect(await thumbEventually { await recorder.last?.cleanupUncertain == true })
    #expect(await fixture.mode == [1, 1])
    #expect(await fixture.wheelMode == 0)
    #expect(await fixture.writes == [[1, 0]])
}

@Test func thumbwheelTerminalAdmissionCannotBeRenewedByAmountEdit() async {
    let fixture = ThumbFixture()
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { ThumbChannel(fixture) })
    let recorder = ThumbRecorder(); let reader = watchThumb(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyThumbwheelPreferences(inverted: nil, amount: 1, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    await fixture.movement(1)
    #expect(await thumbEventually { await recorder.count == 1 })
    let old = await recorder.movement(0)
    controller.invalidateThumbwheelAdmission()
    await controller.applyThumbwheelPreferences(inverted: nil, amount: 2, restorePreviousSettingsOnDisconnect: false, scrollPostingAllowed: true)
    #expect(await thumbEventually { await recorder.last?.phase == .failed })
    #expect(!controller.withThumbwheelAdmission(generation: old.2, observedAt: .now) {})
    #expect(await fixture.mode == [0, 0])
}
