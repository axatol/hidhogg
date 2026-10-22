import Foundation
import Testing
import HidhoggDomain
@testable import LogitechBolt

private actor WheelFixture {
    nonisolated let requestIDs = BoltFixtureRequestIDs()
    static func row(cid: UInt16, task: UInt16, flags: UInt8 = 0x20) -> [UInt8] {
        BoltWire.bytes(cid) + BoltWire.bytes(task) + [flags] + Array(repeating: 0, count: 11)
    }

    var root: [UInt8] = [15, 0, 1]
    var capabilities: [UInt8] = [0, 0x08]
    var capabilityRows: [[UInt8]] = [
        WheelFixture.row(cid: 0x53, task: 0x3C),
        WheelFixture.row(cid: 0x56, task: 0x3E)
    ]
    var mode: UInt8 = 0
    var modeHost: UInt8 = 0
    var modeReads = 0
    var modeOverrides: [Int: UInt8] = [:]
    var failedReads = Set<Int>()
    var failingAllReads = false
    var failingCapabilities = false
    var throwBeforeSet = false
    var throwAfterSet = false
    var ignoreRestore = false
    var pauseSet = false
    var setPaused = false
    var pendingSet: CheckedContinuation<Void, Never>?
    var pauseReadNumber: Int?
    var readPaused = false
    var pendingRead: CheckedContinuation<Void, Never>?
    var pauseButtonSet = false
    var buttonSetPaused = false
    var pendingButtonSet: CheckedContinuation<Void, Never>?
    var failButtonRestore = false
    var writes: [[UInt8]] = []
    var wheelRoots = 0
    var opens: [UInt8] = []
    var closes = 0
    var buttons: [UInt16: UInt8] = [0x53: 0, 0x56: 0]
    var continuation: AsyncStream<BoltTransportEvent>.Continuation?
    var tokens: [UInt32: Int] = [:]

    func configure(root: [UInt8] = [15, 0, 1], capabilities: [UInt8] = [0, 0x08], mode: UInt8 = 0, host: UInt8 = 0) {
        self.root = root
        self.capabilities = capabilities
        self.mode = mode
        modeHost = host
    }

    func configureWrites(before: Bool = false, after: Bool = false, ignoreRestore: Bool = false, pause: Bool = false) {
        throwBeforeSet = before
        throwAfterSet = after
        self.ignoreRestore = ignoreRestore
        pauseSet = pause
    }

    func overrideRead(_ number: Int, mode: UInt8) { modeOverrides[number] = mode }
    func pauseRead(_ number: Int) { pauseReadNumber = number }
    func resumeRead() { pendingRead?.resume(); pendingRead = nil }
    func pauseButtonWrite() { pauseButtonSet = true }
    func resumeButtonWrite() { pauseButtonSet = false; pendingButtonSet?.resume(); pendingButtonSet = nil }
    func failButtonRestoration() { failButtonRestore = true }
    func failRead(_ number: Int) { failedReads.insert(number) }
    func setMode(_ mode: UInt8) { self.mode = mode }
    func setRoot(_ root: [UInt8]) { self.root = root }
    func setCapabilities(_ capabilities: [UInt8]) { self.capabilities = capabilities }
    func setCapabilityRows(_ rows: [[UInt8]]) { capabilityRows = rows }
    func tokenCount(feature: UInt8, function: UInt8) -> Int {
        tokens[UInt32(2) << 16 | UInt32(feature) << 8 | UInt32(function), default: 0]
    }
    func failCapabilities() { failingCapabilities = true }
    func resumeSet() { pauseSet = false; pendingSet?.resume(); pendingSet = nil }
    func failTransport(unreadable: Bool = false) {
        failingAllReads = unreadable
        continuation?.yield(.failure(.disconnected))
    }
    func sendReport(_ bytes: [UInt8], at: ContinuousClock.Instant = .now) {
        continuation?.yield(.report(bytes, at: at))
    }
    func sendWheel(vertical: Int16, horizontal: Int16 = 0, highResolution: Bool = false) {
        let payload = [UInt8(highResolution ? 0x10 : 0)] + BoltWire.bytes(UInt16(bitPattern: vertical)) + BoltWire.bytes(UInt16(bitPattern: horizontal))
        sendReport([0x11, 2, 15, 0] + payload + Array(repeating: 0, count: 11))
    }
    func send(_ controls: [UInt16]) {
        let payload = controls.flatMap(BoltWire.bytes) + Array(repeating: UInt8(0), count: 16 - controls.count * 2)
        continuation?.yield(.report([0x11, 2, 9, 0] + payload, at: .now))
    }

    func open(_ continuation: AsyncStream<BoltTransportEvent>.Continuation) {
        self.continuation = continuation
        tokens.removeAll()
        opens.append(mode)
    }

    func close() { closes += 1 }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        let signature = UInt32(slot) << 16 | UInt32(feature) << 8 | UInt32(function)
        let token = (tokens[signature] ?? 0) + 1
        tokens[signature] = token
        if feature == 0, function == 1 {
            guard slot == 2 else { throw BoltFailure.unavailable }
            return [2, 0, parameters[2]]
        }
        if feature == 0 {
            if parameters == [0x21, 0x21] {
                wheelRoots += 1
                return root
            }
            return [9, 0, 5]
        }
        if feature == 15 {
            if function == 0 {
                if failingCapabilities { throw BoltFailure.timeout }
                return capabilities
            }
            if function == 1 {
                modeReads += 1
                if modeReads == pauseReadNumber {
                    readPaused = true
                    await withCheckedContinuation { pendingRead = $0 }
                }
                if failingAllReads || failedReads.contains(modeReads) { throw BoltFailure.timeout }
                if let override = modeOverrides[modeReads] { mode = override }
                return [mode, modeHost] + Array(repeating: 0, count: 14)
            }
            writes.append(parameters)
            if throwBeforeSet {
                throwBeforeSet = false
                throw BoltFailure.timeout
            }
            if !ignoreRestore || parameters[0] != 0 { mode = parameters[0] }
            if pauseSet {
                setPaused = true
                await withCheckedContinuation { pendingSet = $0 }
            }
            if throwAfterSet { throw BoltFailure.timeout }
            return Array(repeating: 0, count: 16)
        }
        if function == 0 { return [UInt8(capabilityRows.count)] }
        if function == 1 { return capabilityRows[Int(parameters[0])] }
        let cid = BoltWire.word(parameters, 0)
        if function == 2 {
            return BoltWire.bytes(cid) + [buttons[cid] ?? 0] + Array(repeating: 0, count: 13)
        }
        if parameters[2] == 2, failButtonRestore { throw BoltFailure.transport }
        buttons[cid] = parameters[2] == 3 ? 1 : 0
        if parameters[2] == 3, pauseButtonSet {
            buttonSetPaused = true
            await withCheckedContinuation { pendingButtonSet = $0 }
        }
        return BoltWire.bytes(cid) + Array(repeating: 0, count: 14)
    }
}

private final class WheelChannel: BoltTransport, Sendable {
    let events: AsyncStream<BoltTransportEvent>
    let continuation: AsyncStream<BoltTransportEvent>.Continuation
    private let requestIDs: BoltRequestIDLedger
    let fixture: WheelFixture

    init(_ fixture: WheelFixture) {
        self.fixture = fixture
        requestIDs = fixture.requestIDs.makeTransportLedger()
        let stream = AsyncStream<BoltTransportEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
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

private actor WheelRecorder {
    var statuses: [BoltStatus] = []
    var presses: [(MouseControl, UInt64, ContinuousClock.Instant)] = []
    var last: BoltStatus? { statuses.last }
    var scrolls: [(Double, Double, UInt64, ContinuousClock.Instant)] = []
    func scroll(_ index: Int) -> (Double, Double, UInt64, ContinuousClock.Instant) { scrolls[index] }
    var scrollCount: Int { scrolls.count }
    var pressCount: Int { presses.count }
    func firstPressGeneration() -> UInt64? { presses.first?.1 }
    func record(_ event: BoltEvent) {
        switch event {
        case .thumbwheel: break
        case .scroll(let vertical, let horizontal, let generation, let observedAt): scrolls.append((vertical, horizontal, generation, observedAt))
        case .status(let status): statuses.append(status)
        case .press(let control, let generation, let observedAt): presses.append((control, generation, observedAt))
        }
    }
}

private func watchWheel(_ controller: BoltController, _ recorder: WheelRecorder) -> Task<Void, Never> {
    Task { for await event in controller.events { await recorder.record(event) } }
}

private func wheelEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func wheelPublicStatusDefaultsPreserveExistingCallers() {
    let status = BoltStatus(phase: .idle, message: "", availableControls: [], generation: 0, cleanupUncertain: false)
    #expect(status.wheel == BoltWheelStatus())
    #expect(status.wheel.support == .unknown)
    #expect(status.wheel.observedInverted == nil)
    #expect(status.wheel.observedHighResolution == nil)
    #expect(!status.wheel.isOwned && !status.wheel.isApplying)
}

@Test func enableFailureIdentifiesVerticalWheelStage() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(true, restorePreviousSettingsOnDisconnect: true)
    await fixture.failRead(await fixture.modeReads + 1)

    await controller.enable()

    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.failure?.stage == .verticalWheel)
}

@Test func successfulAlternatingWheelPreferencesAndButtonCyclesContinuePastFifteenRequests() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    for edit in 0..<24 {
        await controller.applyWheelPreferences(inverted: edit.isMultiple(of: 2), highResolution: nil,
                                               restorePreviousSettingsOnDisconnect: true)
        await controller.enable()
        await controller.disable()
    }
    #expect(await wheelEventually { await recorder.last?.phase == .ready })
    #expect(await fixture.writes.count == 24)
    #expect(await fixture.tokenCount(feature: 15, function: 1) > 15)
    #expect(await fixture.tokenCount(feature: 9, function: 3) > 15)
    #expect(await fixture.closes == 0)
    await controller.applyWheelPreferences(inverted: true, highResolution: nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.mode == 4)
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 0)
}

@Test func fixtureReplacementTransportHasFreshIDsWithoutResettingOldLedger() async throws {
    let fixture = WheelFixture()
    let first = WheelChannel(fixture)
    try fixture.requestIDs.retireForFixture(feature: 15, function: 1, count: 13)
    #expect(first.availableRequestIDs(slot: 2, feature: 15, function: 1) == 2)
    let replacement = WheelChannel(fixture)
    #expect(replacement.availableRequestIDs(slot: 2, feature: 15, function: 1) == 15)
    #expect(first.availableRequestIDs(slot: 2, feature: 15, function: 1) == 2)
    for _ in 0..<20 { _ = try await replacement.request(slot: 2, feature: 15, function: 1, parameters: []) }
    #expect(replacement.availableRequestIDs(slot: 2, feature: 15, function: 1) == 15)
    #expect(first.availableRequestIDs(slot: 2, feature: 15, function: 1) == 2)
}

@Test(arguments: [false, true])
func wheelResolutionComposesOneFullModeAndTracksOwnMixedChanges(restore: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: restore)
    #expect(await fixture.writes == [[6]])
    #expect(await wheelEventually { await recorder.last?.wheel.observedHighResolution == true })
    await controller.applyWheelPreferences(inverted: false, highResolution: true, restorePreviousSettingsOnDisconnect: restore)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: restore)
    await controller.applyWheelPreferences(inverted: true, highResolution: false, restorePreviousSettingsOnDisconnect: restore)
    #expect(await fixture.writes == [[6], [2], [6], [4]])
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == (restore ? 0 : 4))
    #expect(await fixture.requestIDs.available(slot: 2, feature: 15, function: 1) == 15)
}

@Test(arguments: [false, true], [false, true])
func wheelPartialNilReleaseRestoresOnlyReleasedAttributableField(restore: Bool, releaseResolution: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: restore)
    await controller.applyWheelPreferences(
        inverted: releaseResolution ? true : nil,
        highResolution: releaseResolution ? nil : true,
        restorePreviousSettingsOnDisconnect: restore
    )
    let managedBit: UInt8 = releaseResolution ? 4 : 2
    #expect(await fixture.mode == (restore ? managedBit : 6))
    #expect(await fixture.writes == (restore ? [[6], [managedBit]] : [[6]]))
    await controller.applyWheelPreferences(
        inverted: releaseResolution ? false : nil,
        highResolution: releaseResolution ? nil : false,
        restorePreviousSettingsOnDisconnect: restore
    )
    #expect(await fixture.mode == (restore ? 0 : (6 ^ managedBit)))
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == (restore ? 0 : (6 ^ managedBit)))
}

@Test func wheelResolutionOnlyPreservesUnmanagedDirectionAndReportsBothValues() async {
    let fixture = WheelFixture()
    await fixture.configure(mode: 4)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.writes == [[6]])
    #expect(await wheelEventually {
        guard let status = await recorder.last else { return false }
        return status.wheel.observedInverted == true && status.wheel.observedHighResolution == true && !status.wheel.isApplying
    })
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.mode == 4)
    #expect(await fixture.writes == [[6], [4]])
    #expect(await controller.stopForRestart())
}

@Test(arguments: [false, true])
func wheelResolutionPendingWriteRollsBackFullVerifiedModeOrBaseline(restore: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: restore)
    await fixture.failRead(8)
    await controller.applyWheelPreferences(inverted: false, highResolution: false, restorePreviousSettingsOnDisconnect: restore)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.mode == (restore ? 0 : 6))
    #expect(await fixture.writes == (restore ? [[6], [0]] : [[6], [0], [6]]))
}

@Test(arguments: [false, true])
func wheelResolutionStopDuringSetterUsesLatestPolicy(restore: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: !restore)
    await fixture.configureWrites(pause: true)
    let apply = Task { await controller.applyWheelPreferences(inverted: false, highResolution: false, restorePreviousSettingsOnDisconnect: !restore) }
    #expect(await wheelEventually { await fixture.setPaused })
    let stop = Task { await controller.stop(restorePreviousSettingsOnDisconnect: restore) }
    #expect(await wheelEventually { await recorder.last?.phase == .stopping })
    await fixture.resumeSet()
    await apply.value
    await stop.value
    #expect(await fixture.mode == (restore ? 0 : 6))
    #expect(await wheelEventually { await recorder.last?.phase == .idle })
    #expect(await recorder.last?.cleanupUncertain == false)
}

@Test func wheelResolutionForeignDriftRejectsNextDirectionEdit() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    await fixture.setMode(4)
    await controller.applyWheelPreferences(inverted: false, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await wheelEventually { await recorder.last?.cleanupUncertain == true })
    #expect(await recorder.last?.wheel.observedInverted == nil)
    #expect(await recorder.last?.wheel.observedHighResolution == nil)
    #expect(await fixture.writes == [[6]])
    #expect(await fixture.mode == 4)
}

@Test func wheelResolutionCancelledSetterRestoresLastVerifiedFullMode() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: false)
    await fixture.configureWrites(pause: true)
    let apply = Task { await controller.applyWheelPreferences(inverted: false, highResolution: false, restorePreviousSettingsOnDisconnect: false) }
    #expect(await wheelEventually { await fixture.setPaused })
    apply.cancel()
    await fixture.resumeSet()
    await apply.value
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.mode == 6)
    #expect(await fixture.writes == [[6], [0], [6]])
}

@Test func wheelResolutionRestoresOnlyItsOwnBitAfterUnmanagedDirectionChanges() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await fixture.setMode(4)
    await controller.applyWheelPreferences(inverted: nil, highResolution: true, restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.mode == 6)
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 4)
    #expect(await fixture.writes == [[6], [4]])
}

@Test func wheelDiscoveryObservesNativeModeWithoutMutation() async {
    let fixture = WheelFixture()
    await fixture.configure(mode: 6)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await wheelEventually { await recorder.last?.wheel.observedInverted == true })
    #expect(await recorder.last?.wheel.support == .supported)
    #expect(await recorder.last?.wheel.isOwned == false)
    #expect(await fixture.writes.isEmpty)
    await controller.stop()
    #expect(await fixture.mode == 6)
    #expect(await fixture.writes.isEmpty)
}

@Test(arguments: [[0, 0, 0], [15, 0, 2], [15, 0x20, 1], [15, 0x80, 1], [15, 0]])
func wheelAbsentOrUnsupportedFeatureKeepsKeyboardDiscovery(root: [UInt8]) async {
    let fixture = WheelFixture()
    await fixture.configure(root: root)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await wheelEventually { await recorder.last?.phase == .ready })
    #expect(await recorder.last?.wheel.support == .unsupported)
    #expect(await recorder.last?.availableControls == Set(MouseControl.allCases))
    await controller.enable()
    #expect(await wheelEventually { await recorder.last?.phase == .enabled })
    #expect(await fixture.writes.isEmpty)
    await controller.stop()
}

@Test(arguments: [UInt8(0), 1, 0xF7])
func wheelRequiresInvertCapability(flags: UInt8) async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [0, flags])
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await wheelEventually { await recorder.last?.wheel.support == .unsupported })
    #expect(await fixture.modeReads == 0)
    #expect(await fixture.writes.isEmpty)
    await controller.stop()
}

@Test(arguments: [UInt8(8), 0x80])
func wheelRejectsReservedModeBeforeConnection(mode: UInt8) async {
    let fixture = WheelFixture()
    await fixture.configure(mode: mode)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.writes.isEmpty)
    await controller.stop()
}

@Test func wheelRejectsNonzeroModeHost() async {
    let fixture = WheelFixture()
    await fixture.configure(host: 1)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.writes.isEmpty)
    await controller.stop()
}

@Test func wheelApplyWorksWhileReadyOrEnabledAndDoesNotAcquireNoopOwnership() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.applyWheelPreference(true)
    #expect(await fixture.opens.isEmpty)
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(false)
    #expect(await wheelEventually { await recorder.last?.wheel.observedInverted == false })
    #expect(await recorder.last?.wheel.isOwned == false)
    #expect(await fixture.wheelRoots == 4)
    #expect(await fixture.writes.isEmpty)
    await controller.enable()
    #expect(await wheelEventually { await recorder.last?.phase == .enabled })
    await fixture.send([])
    await fixture.send([0x53])
    #expect(await wheelEventually { await recorder.pressCount == 1 })
    let generation = await recorder.firstPressGeneration()!
    #expect(controller.withPressAdmission(generation: generation, observedAt: .now) {})
    await controller.applyWheelPreference(true)
    #expect(await wheelEventually {
        guard let status = await recorder.last else { return false }
        return status.phase == .enabled && status.wheel.isOwned
    })
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.buttons.values.allSatisfy { $0 == 1 })
    #expect(controller.withPressAdmission(generation: generation, observedAt: .now) {})
    #expect(await fixture.opens.count == 1)
    await controller.disable()
    #expect(await wheelEventually { await recorder.last?.phase == .ready })
    #expect(await recorder.last?.wheel.isOwned == true)
    #expect(await fixture.mode == 4)
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
    #expect(await fixture.closes == 0)
    await controller.applyWheelPreference(nil)
    #expect(await wheelEventually { await recorder.last?.wheel.isOwned == false })
    #expect(await fixture.mode == 0)
    await controller.stop()
}

@Test func wheelApplyPreservesResolutionAndOriginalAcrossRepeatedApplies() async {
    let fixture = WheelFixture()
    await fixture.configure(mode: 2)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    #expect(await wheelEventually { await recorder.last?.wheel.isOwned == true })
    #expect(await fixture.mode == 6)
    #expect(await fixture.writes == [[6]])
    #expect(await fixture.modeReads == 5)
    await controller.applyWheelPreference(true)
    #expect(await fixture.writes == [[6]])
    await controller.applyWheelPreference(false)
    #expect(await wheelEventually { await recorder.last?.wheel.isOwned == false })
    #expect(await fixture.writes == [[6], [2]])
    await controller.applyWheelPreference(true)
    await controller.applyWheelPreference(nil)
    #expect(await wheelEventually { await recorder.last?.wheel.isOwned == false })
    #expect(await fixture.writes == [[6], [2], [6], [2]])
    #expect(await fixture.mode == 2)
    #expect(await recorder.last?.phase == .ready)
    await controller.stop()
    #expect(await fixture.writes == [[6], [2], [6], [2]])
}

@Test func wheelOriginalInvertedModeIsRestoredOnStop() async {
    let fixture = WheelFixture()
    await fixture.configure(mode: 6)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(false)
    #expect(await fixture.mode == 2)
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 6)
    #expect(await fixture.writes == [[2], [6]])
}

@Test func wheelReadbackIsAuthoritativeAfterFailedAcknowledgement() async {
    let fixture = WheelFixture()
    await fixture.configureWrites(after: true)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    #expect(await wheelEventually { await recorder.last?.wheel.isOwned == true })
    #expect(await recorder.last?.phase == .ready)
    #expect(await fixture.mode == 4)
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 0)
    #expect(await fixture.writes == [[4], [0]])
}

@Test func wheelFailedWriteAtOriginalBaselineNeedsNoRestoreWrite() async {
    let fixture = WheelFixture()
    await fixture.configureWrites(before: true)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.last?.wheel.isOwned == false)
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.mode == 0)
}

@Test func wheelFailedReadbackRestoresPossibleWrite() async {
    let fixture = WheelFixture()
    await fixture.failRead(5)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.mode == 0)
    #expect(await fixture.writes == [[4], [0]])
    #expect(await fixture.modeReads == 7)
}

@Test func wheelRetiredRequestIDsPreserveOwnedCleanupCapacity() async throws {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    for _ in 0..<20 { await controller.applyWheelPreference(true) }
    #expect(await fixture.modeReads > 15)
    #expect(await fixture.closes == 0)
    try fixture.requestIDs.retireForFixture(feature: 15, function: 1, count: 12)
    await controller.applyWheelPreference(true)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.last?.wheel.isOwned == false)
    #expect(await fixture.writes == [[4], [0]])
    #expect(await fixture.mode == 0)
    #expect(await fixture.closes == 1)
    #expect(fixture.requestIDs.available(slot: 2, feature: 15, function: 1) == 3)
}

@Test func wheelPrewriteRereadRejectsChangedFullModeWithoutWriting() async {
    let fixture = WheelFixture()
    await fixture.overrideRead(4, mode: 2)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.writes.isEmpty)
    #expect(await fixture.mode == 2)
    #expect(await recorder.last?.cleanupUncertain == false)
}

@Test func wheelForeignFullModeBlocksCleanupAndFurtherMutation() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    await fixture.setMode(6)
    await controller.applyWheelPreference(false)
    #expect(await wheelEventually { await recorder.last?.cleanupUncertain == true })
    #expect(await recorder.last?.wheel.isOwned == true)
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.mode == 6)
    #expect(await fixture.closes == 1)
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.enable()
    await controller.applyWheelPreference(true)
    #expect(await fixture.opens.count == 1)
    #expect(await fixture.writes == [[4]])
    #expect(await controller.stopForRestart() == false)
}

@Test(arguments: [[16, 0, 1], [0, 0, 0], [15, 0x20, 1], [15, 0, 2], []])
func wheelChangedFeatureAssociationNeverReadsOrWritesStaleIndex(root: [UInt8]) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    #expect(await fixture.mode == 4)
    let reads = await fixture.modeReads
    await fixture.setRoot(root)
    await controller.applyWheelPreference(false)
    #expect(await wheelEventually { await recorder.last?.cleanupUncertain == true })
    #expect(await recorder.last?.wheel.isOwned == true)
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.modeReads == reads)
    #expect(await fixture.closes == 1)
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.enable()
    #expect(await fixture.opens == [0])
    #expect(await controller.stopForRestart() == false)
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.modeReads == reads)
}

@Test(arguments: [[0, 0], [0, 0xF7], [0], []])
func wheelChangedCapabilityAssociationNeverReadsOrWritesStaleIndex(capabilities: [UInt8]) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    #expect(await fixture.mode == 4)
    let reads = await fixture.modeReads
    await fixture.setCapabilities(capabilities)
    await controller.applyWheelPreference(false)
    #expect(await wheelEventually { await recorder.last?.cleanupUncertain == true })
    #expect(await recorder.last?.wheel.isOwned == true)
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.modeReads == reads)
    #expect(await fixture.closes == 1)
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.enable()
    #expect(await fixture.opens == [0])
    #expect(await controller.stopForRestart() == false)
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.modeReads == reads)
}

@Test func wheelCapabilityTimeoutStillAttemptsOwnedCleanup() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    await fixture.failCapabilities()
    await controller.applyWheelPreference(false)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.last?.wheel.isOwned == false)
    #expect(await fixture.writes == [[4], [0]])
    #expect(await fixture.mode == 0)
    #expect(await fixture.closes == 1)
}

@Test func wheelCleanupAcceptsAlreadyRestoredOriginalWithoutWriting() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    await fixture.setMode(0)
    #expect(await controller.stopForRestart())
    #expect(await fixture.writes == [[4]])
}

@Test func wheelCleanupRequiresIndependentBaselineVerification() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    await fixture.configureWrites(ignoreRestore: true)
    #expect(await controller.stopForRestart() == false)
    #expect(await wheelEventually { await recorder.last?.cleanupUncertain == true })
    #expect(await recorder.last?.wheel.isOwned == true)
    #expect(await fixture.mode == 4)
    #expect(await fixture.writes == [[4], [0]])
    #expect(await fixture.modeReads == 7)
    #expect(await fixture.closes == 1)
}

@Test(arguments: [false, true])
func enableReusesOwnedWheelHandleWhileDiscoverySettlesBeforeReplacement(enable: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    if enable { await controller.enable() } else { await controller.discover() }
    #expect(await fixture.opens == (enable ? [0] : [0, 0]))
    #expect(await fixture.writes == (enable ? [[4]] : [[4], [0]]))
    #expect(await fixture.mode == (enable ? 4 : 0))
    #expect(await wheelEventually { await recorder.last?.wheel.isOwned == enable })
    #expect(await recorder.last?.phase == (enable ? .enabled : .ready))
    await controller.stop()
}

@Test(arguments: [8, 9, 10, 11, 12])
func enableReusesValidatedCapabilityTableAndRetiredBudgetStillProtectsCleanup(capabilityRowCount: Int) async throws {
    let fixture = WheelFixture()
    var rows = [
        WheelFixture.row(cid: 0x53, task: 0x3C),
        WheelFixture.row(cid: 0x56, task: 0x3E)
    ]
    rows += (2..<capabilityRowCount).map { index in
        WheelFixture.row(cid: UInt16(0x0100 + index), task: UInt16(0x0200 + index))
    }
    await fixture.setCapabilityRows(rows)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }

    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await wheelEventually { await recorder.last?.phase == .ready })
    #expect(await fixture.tokenCount(feature: 9, function: 1) == capabilityRowCount + 2)

    await controller.enable()
    #expect(await wheelEventually { await recorder.last?.phase == .enabled })
    #expect(await fixture.tokenCount(feature: 9, function: 1) == capabilityRowCount + 4)
    #expect(await fixture.tokenCount(feature: 9, function: 2) == 8)
    #expect(await fixture.tokenCount(feature: 9, function: 3) == 2)

    await controller.disable()
    #expect(await wheelEventually { await recorder.last?.phase == .ready })
    #expect(await fixture.tokenCount(feature: 9, function: 2) == 12)
    #expect(await fixture.tokenCount(feature: 9, function: 3) == 4)
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })

    await controller.enable()
    #expect(await wheelEventually { await recorder.last?.phase == .enabled })
    await controller.disable()
    #expect(await fixture.tokenCount(feature: 9, function: 2) == 20)
    #expect(await fixture.tokenCount(feature: 9, function: 3) == 8)
    try fixture.requestIDs.retireForFixture(feature: 9, function: 2, count: 8)
    await controller.enable()
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.tokenCount(feature: 9, function: 2) == 20)
    #expect(await fixture.tokenCount(feature: 9, function: 3) == 8)
    #expect(await fixture.opens.count == 1)
    #expect(await fixture.closes == 1)
}

@Test(arguments: [false, true])
func wheelForeignModePreventsHandleReplacement(enable: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    await fixture.setMode(2)
    if enable { await controller.enable() } else { await controller.discover() }
    #expect(await wheelEventually { await recorder.last?.cleanupUncertain == true })
    #expect(await fixture.opens == [0])
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.mode == 2)
    #expect(await controller.stopForRestart() == false)
}

@Test func wheelStopWaitsForPossibleWriteAndSerializesOtherOperations() async {
    let fixture = WheelFixture()
    await fixture.configureWrites(pause: true)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    let apply = Task { await controller.applyWheelPreference(true) }
    #expect(await wheelEventually { await fixture.setPaused })
    #expect(await wheelEventually { await recorder.last?.wheel.isApplying == true })
    let stop = Task { await controller.stop() }
    #expect(await wheelEventually { await recorder.last?.phase == .stopping })
    await fixture.resumeSet()
    await apply.value
    await stop.value
    #expect(await fixture.writes == [[4], [0]])
    #expect(await fixture.mode == 0)
    #expect(await wheelEventually { await recorder.last?.phase == .idle })
    #expect(await recorder.last?.wheel.isOwned == false)
    #expect(await recorder.last?.wheel.isApplying == false)
}

@Test func overlappingWheelAppliesRunInSubmissionOrder() async {
    let fixture = WheelFixture()
    await fixture.configureWrites(pause: true)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    let first = Task { await controller.applyWheelPreference(true) }
    #expect(await wheelEventually { await fixture.setPaused })
    let second = Task { await controller.applyWheelPreference(false) }
    await Task.yield()
    #expect(await fixture.writes == [[4]])
    await fixture.resumeSet()
    await first.value
    await second.value
    #expect(await fixture.writes == [[4], [0]])
    #expect(await fixture.mode == 0)
    #expect(await wheelEventually {
        guard let status = await recorder.last else { return false }
        return status.phase == .ready && !status.wheel.isOwned
    })
    #expect(await fixture.closes == 0)
    await controller.stop()
}

@Test(arguments: [false, true])
func wheelTerminalFailureRestoresOrRetainsUncertainty(unreadable: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(true)
    await fixture.failTransport(unreadable: unreadable)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == unreadable)
    #expect(await recorder.last?.wheel.isOwned == unreadable)
    #expect(await fixture.mode == (unreadable ? 4 : 0))
    #expect(await fixture.closes == 1)
    if unreadable {
        await controller.discover()
        await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
        #expect(await fixture.opens.count == 1)
        #expect(await controller.stopForRestart() == false)
    }
}

@Test func wheelDefaultKeepsVerifiedDirectionAndReleasesButtonsOnStop() async {
    let fixture = WheelFixture()
    await fixture.configure(mode: 2)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreference(true)
    await controller.enable()
    #expect(await fixture.buttons.values.allSatisfy { $0 == 1 })

    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 6)
    #expect(await fixture.writes == [[6]])
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
    #expect(await fixture.closes == 1)
}

@Test func wheelDefaultUnmanagedRetainsDirectionAndLaterOptInRestoresConnectionBaseline() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreference(true)
    let reads = await fixture.modeReads
    await controller.applyWheelPreference(nil)
    #expect(await fixture.mode == 4)
    #expect(await fixture.modeReads == reads)

    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    #expect(await fixture.mode == 0)
    #expect(await fixture.writes == [[4], [0]])
    #expect(await controller.stopForRestart())
}

@Test(arguments: [false, true])
func wheelLiveRestorationPolicyUsesLatestValueAtStop(restore: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreference(true, restorePreviousSettingsOnDisconnect: !restore)
    await controller.applyWheelPreference(true, restorePreviousSettingsOnDisconnect: restore)
    #expect(await fixture.writes == [[4]])

    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == (restore ? 0 : 4))
    #expect(await fixture.writes == (restore ? [[4], [0]] : [[4]]))
}

@Test func wheelPolicyOnlyUpdatesWithUnmanagedDirectionDoNotWrite() async {
    let fixture = WheelFixture()
    await fixture.configure(mode: 6)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: true)
    await controller.applyWheelPreference(nil, restorePreviousSettingsOnDisconnect: false)
    #expect(await fixture.modeReads == 2)
    #expect(await fixture.writes.isEmpty)
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 6)
}

@Test func wheelDefaultFailedSecondWriteRollsBackToLastVerifiedDirection() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(true)
    await fixture.failRead(8)
    await controller.applyWheelPreference(false)

    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.last?.wheel.observedInverted == true)
    #expect(await fixture.mode == 4)
    #expect(await fixture.writes == [[4], [0], [4]])
}

@Test func wheelOptInFailedSecondSetterRestoresOriginalBaseline() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(true, restorePreviousSettingsOnDisconnect: true)
    await fixture.configureWrites(before: true)
    await controller.applyWheelPreference(false)

    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.last?.wheel.isOwned == false)
    #expect(await fixture.mode == 0)
    #expect(await fixture.writes == [[4], [0], [0]])
}

@Test func wheelDefaultStopDuringSecondSetterRollsBackOnlyUnverifiedChange() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(true)
    await fixture.configureWrites(pause: true)
    let apply = Task { await controller.applyWheelPreference(false) }
    #expect(await wheelEventually { await fixture.setPaused })
    let stop = Task { await controller.stop() }
    #expect(await wheelEventually { await recorder.last?.phase == .stopping })
    await fixture.resumeSet()
    await apply.value
    await stop.value

    #expect(await fixture.mode == 4)
    #expect(await fixture.writes == [[4], [0], [4]])
    #expect(await wheelEventually { await recorder.last?.phase == .idle })
    #expect(await recorder.last?.cleanupUncertain == false)
}

@Test func wheelDefaultKeepsVerifiedDirectionOnUnrelatedSessionFailure() async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreference(true)
    await controller.enable()
    await fixture.failTransport(unreadable: true)

    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.mode == 4)
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
}

@Test func wheelDefaultUnverifiedForeignModeBlocksRollbackWithoutWriting() async {
    let fixture = WheelFixture()
    await fixture.overrideRead(5, mode: 6)
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    await controller.applyWheelPreference(true)

    #expect(await wheelEventually { await recorder.last?.cleanupUncertain == true })
    #expect(await fixture.mode == 6)
    #expect(await fixture.writes == [[4]])
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
    #expect(await controller.stopForRestart() == false)
}

@Test(arguments: [false, true])
func wheelRejectsResolutionChangeSinceDiscoveryBeforeFirstWrite(restore: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await fixture.setMode(2)
    await controller.applyWheelPreference(true, restorePreviousSettingsOnDisconnect: restore)

    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.writes.isEmpty)
    #expect(await fixture.mode == 2)
    #expect(await recorder.last?.cleanupUncertain == false)
}

@Test(arguments: [false, true])
func wheelExplicitStopPolicyOverridesConnectedPolicyWithoutApplyingDirection(restore: Bool) async {
    let fixture = WheelFixture()
    let controller = BoltController(makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreference(true, restorePreviousSettingsOnDisconnect: !restore)
    #expect(await controller.stopForRestart(restorePreviousSettingsOnDisconnect: restore))
    #expect(await fixture.mode == (restore ? 0 : 4))
    #expect(await fixture.writes == (restore ? [[4], [0]] : [[4]]))
}


@Test(arguments: [false, true])
func wheelCaptureNormalizesAndNeutralizesDirectionThenRestoresRouting(restore: Bool) async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: restore,
                                           amount: 1, scrollPostingAllowed: true)
    #expect(await fixture.mode == 3)
    #expect(await fixture.writes == [[6], [3]])
    #expect(await wheelEventually { await recorder.last?.wheel.captureActive == true })
    #expect(await recorder.last?.wheel.observedInverted == false)
    #expect(await recorder.last?.wheel.effectiveInverted == true)
    await fixture.sendWheel(vertical: 8, horizontal: -16, highResolution: true)
    #expect(await wheelEventually { await recorder.scrollCount == 1 })
    let scroll = await recorder.scroll(0)
    #expect(scroll.0 == -1 && scroll.1 == -2)
    #expect(controller.withScrollAdmission(generation: scroll.2, observedAt: scroll.3) {})
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == (restore ? 0 : 6))
    #expect(!controller.withScrollAdmission(generation: scroll.2, observedAt: scroll.3) {})
}

@Test func wheelCaptureAmountOnlyChangesDoNotUseHIDTokensAndPermissionLossKeepsPreferences() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: false, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    let tokens = await fixture.tokens
    let reads = await fixture.modeReads
    let writes = await fixture.writes
    await controller.applyWheelPreferences(inverted: true, highResolution: false, restorePreviousSettingsOnDisconnect: false,
                                           amount: 4, scrollPostingAllowed: true)
    #expect(await fixture.tokens == tokens)
    #expect(await fixture.modeReads == reads)
    #expect(await fixture.writes == writes)
    await controller.applyWheelPreferences(inverted: true, highResolution: false, restorePreviousSettingsOnDisconnect: false,
                                           amount: 4, scrollPostingAllowed: false)
    #expect(await fixture.mode == 4)
    #expect(await fixture.writes == [[4], [1], [4]])
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 4)
}

@Test(arguments: [false, true])
func wheelCaptureDenialOrZeroMultiplierUsesNativeRouting(zeroMultiplier: Bool) async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [zeroMultiplier ? 0 : 8, 0x08], mode: 4)
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: zeroMultiplier)
    #expect(await fixture.writes.isEmpty)
    #expect(await fixture.mode == 4)
    #expect(await wheelEventually { await recorder.last?.wheel.captureBlocker != nil })
    #expect(await recorder.last?.wheel.captureActive == false)
    #expect(await controller.stopForRestart())
}

@Test func wheelCaptureCoexistsWithButtonsAndTheirSeparateGeneration() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    await fixture.sendWheel(vertical: 1)
    #expect(await wheelEventually { await recorder.scrollCount == 1 })
    let epoch = await recorder.scroll(0).2
    await controller.enable()
    await fixture.send([])
    await fixture.send([0x53])
    await fixture.sendWheel(vertical: 8, highResolution: true)
    #expect(await wheelEventually {
        let presses = await recorder.pressCount
        let scrolls = await recorder.scrollCount
        return presses == 1 && scrolls == 2
    })
    let scrolls = await recorder.scrolls
    #expect(scrolls[0].0 == scrolls[1].0)
    #expect(scrolls[1].2 == epoch)
    await controller.disable()
    await fixture.sendWheel(vertical: 1)
    #expect(await wheelEventually { await recorder.scrollCount == 3 })
    #expect(await fixture.mode == 1)
    #expect(await fixture.buttons.values.allSatisfy { $0 == 0 })
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 0)
}

@Test(arguments: [7, 9, 19, 21])
func wheelCaptureMalformedSelectedReportFailsAndReleases(length: Int) async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    await fixture.sendReport([length == 7 ? 0x10 : 0x11, 2, 15, 0] + Array(repeating: 0, count: length - 4))
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == 0)
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.scrollCount == 0)
}

@Test func wheelCaptureIgnoresUnrelatedReportsButStaleSelectedReportReleases() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    for header: [UInt8] in [[0x11, 3, 15, 0], [0x11, 2, 14, 0], [0x11, 2, 15, 0x10]] {
        await fixture.sendReport(header)
    }
    await fixture.sendWheel(vertical: 1)
    #expect(await wheelEventually { await recorder.scrollCount == 1 })
    let scroll = await recorder.scroll(0)
    #expect(!controller.withScrollAdmission(generation: scroll.2, observedAt: .now.advanced(by: .milliseconds(-500))) {})
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == 0)
    #expect(!controller.withScrollAdmission(generation: scroll.2, observedAt: .now) {})
}

@Test(arguments: [false, true])
func wheelCapturePartialSetterOrCancellationRestoresNativeMode(cancel: Bool) async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08], mode: 6)
    await fixture.configureWrites(before: !cancel, pause: cancel)
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    let apply = Task {
        await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                               amount: 1, scrollPostingAllowed: true)
    }
    if cancel {
        #expect(await wheelEventually { await fixture.setPaused })
        let stop = Task { await controller.stop() }
        #expect(await wheelEventually { await recorder.last?.phase == .stopping })
        await fixture.resumeSet()
        await apply.value
        await stop.value
    } else { await apply.value }
    #expect(await fixture.mode == 6)
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.writes == (cancel ? [[3], [6]] : [[3]]))
}

@Test func wheelCaptureDirectionEditSettlesNativeModeThenRecapturesWithoutDoubleInversion() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    await controller.applyWheelPreferences(inverted: true, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    #expect(await fixture.writes == [[1], [0], [4], [1]])
    await fixture.sendWheel(vertical: 1)
    #expect(await wheelEventually { await recorder.scrollCount == 1 })
    #expect(await recorder.scroll(0).0 == -1)
    #expect(await controller.stopForRestart())
    #expect(await fixture.mode == 4)
}


private final class WheelPermissionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = true
    private var remainingChecks: Int?
    private let onDenial: @Sendable () -> Void
    init(onDenial: @escaping @Sendable () -> Void = {}) { self.onDenial = onDenial }
    func read() -> Bool {
        lock.withLock {
            guard granted else { return false }
            guard let remainingChecks else { return true }
            self.remainingChecks = remainingChecks - 1
            if remainingChecks <= 0 { onDenial() }
            return remainingChecks > 0
        }
    }
    func deny() { lock.withLock { granted = false } }
    func denyAfterChecks(_ count: Int) { lock.withLock { remainingChecks = count } }
}

@Test func wheelCaptureFreshPermissionCheckPrecedesPossibleRoutingWrite() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let permission = WheelPermissionFlag()
    let controller = BoltController(scrollPostingPreflight: { permission.read() }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await fixture.pauseRead(3)
    let apply = Task {
        await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                               amount: 1, scrollPostingAllowed: true)
    }
    #expect(await wheelEventually { await fixture.readPaused })
    permission.deny()
    await fixture.resumeRead()
    await apply.value
    #expect(await fixture.writes.isEmpty)
    #expect(await fixture.mode == 0)
    #expect(await wheelEventually { await recorder.last?.wheel.captureBlocker != nil })
    #expect(await controller.stopForRestart())
}

@Test(arguments: [false, true])
func wheelCapturePendingVerificationReportsCannotBeReplayed(pauseSetter: Bool) async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    await fixture.configureWrites(pause: pauseSetter)
    if !pauseSetter { await fixture.pauseRead(4) }
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    let apply = Task {
        await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                               amount: 1, scrollPostingAllowed: true)
    }
    if pauseSetter { #expect(await wheelEventually { await fixture.setPaused }) }
    else { #expect(await wheelEventually { await fixture.readPaused }) }
    await fixture.sendWheel(vertical: 1)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await recorder.scrollCount == 0)
    if pauseSetter { await fixture.resumeSet() }
    else { await fixture.resumeRead() }
    await apply.value
    try? await Task.sleep(for: .milliseconds(10))
    #expect(await recorder.scrollCount == 0)
    await fixture.sendWheel(vertical: 1)
    #expect(await wheelEventually { await recorder.scrollCount == 1 })
    #expect(await controller.stopForRestart())
}

@Test func wheelCaptureDeliversDuringButtonActivationAndReleasesWhenButtonCleanupFails() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    await fixture.pauseButtonWrite()
    let enable = Task { await controller.enable() }
    #expect(await wheelEventually { await fixture.buttonSetPaused })
    await fixture.sendWheel(vertical: 1)
    #expect(await wheelEventually { await recorder.scrollCount == 1 })
    let scroll = await recorder.scroll(0)
    #expect(controller.withScrollAdmission(generation: scroll.2, observedAt: scroll.3) {})
    await fixture.resumeButtonWrite()
    await enable.value
    await fixture.failButtonRestoration()
    await controller.disable()
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == 0)
    #expect(await fixture.closes == 1)
    #expect(!controller.withScrollAdmission(generation: scroll.2, observedAt: .now) {})
}

@Test func wheelCaptureOverflowStopsAndRestoresRoutingWithoutConsumer() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(bufferSize: 2, scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    for _ in 0..<8 { await fixture.sendWheel(vertical: 1) }
    #expect(await wheelEventually { await fixture.closes == 1 })
    #expect(await fixture.mode == 0)
    #expect(await fixture.writes == [[1], [0]])
}

@Test func wheelCaptureBenignSuspensionRenewsEpochButTerminalGateNeverRenews() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    await fixture.sendWheel(vertical: 1)
    #expect(await wheelEventually { await recorder.scrollCount == 1 })
    let old = await recorder.scroll(0)
    controller.suspendScrollAdmission()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    #expect(!controller.withScrollAdmission(generation: old.2, observedAt: .now) {})
    await fixture.sendWheel(vertical: 1)
    #expect(await wheelEventually { await recorder.scrollCount == 2 })
    let fresh = await recorder.scroll(1)
    #expect(controller.withScrollAdmission(generation: fresh.2, observedAt: fresh.3) {})
    controller.invalidateScrollAdmission()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 2, scrollPostingAllowed: true)
    #expect(await fixture.mode == 0)
    #expect(await fixture.closes == 1)
    #expect(!controller.withScrollAdmission(generation: fresh.2, observedAt: .now) {})
}


@Test(arguments: [false, true])
func wheelCaptureStaleOrFutureSelectedReportFailsAndCleansUp(future: Bool) async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: nil, highResolution: nil, restorePreviousSettingsOnDisconnect: false,
                                           amount: 1, scrollPostingAllowed: true)
    await fixture.sendReport([0x11, 2, 15, 0, 0, 0, 1] + Array(repeating: 0, count: 13),
                             at: .now.advanced(by: .milliseconds(future ? 500 : -500)))
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == 0)
    #expect(await recorder.scrollCount == 0)
}

@Test(arguments: [false, true])
func wheelCaptureEditToNativePreflightsFinalPhysicalRestorationBeforeReleasingCapture(postingDenied: Bool) async throws {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: nil, restorePreviousSettingsOnDisconnect: true,
                                           amount: 1, scrollPostingAllowed: true)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true,
                                           amount: 1, scrollPostingAllowed: true)
    #expect(await fixture.mode == 3)
    #expect(await fixture.modeReads == 14)
    try fixture.requestIDs.retireForFixture(feature: 15, function: 1, count: 13)
    await controller.applyWheelPreferences(inverted: false, highResolution: true, restorePreviousSettingsOnDisconnect: true,
                                           amount: postingDenied ? 1 : nil, scrollPostingAllowed: !postingDenied)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == 0)
    #expect(await fixture.modeReads <= 16)
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.writes.last == [0])
}

@Test(arguments: [false, true])
func wheelCaptureAmountOffPreflightsFinalPhysicalRestorationBeforeReleasingCapture(postingDenied: Bool) async throws {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let controller = BoltController(scrollPostingPreflight: { true }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: nil, restorePreviousSettingsOnDisconnect: true,
                                           amount: 1, scrollPostingAllowed: true)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true,
                                           amount: 1, scrollPostingAllowed: true)
    #expect(await fixture.mode == 3)
    #expect(await fixture.modeReads == 14)
    try fixture.requestIDs.retireForFixture(feature: 15, function: 1, count: 13)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true,
                                           amount: postingDenied ? 1 : nil, scrollPostingAllowed: !postingDenied)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == 0)
    #expect(await fixture.modeReads <= 16)
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await fixture.writes.last == [0])
}


@Test func wheelCapturePermissionLossAfterSetterUsesCombinedFinalCleanupWhenOnlyTwoReadsRemain() async {
    let fixture = WheelFixture()
    await fixture.configure(capabilities: [8, 0x08])
    let permission = WheelPermissionFlag(onDenial: {
        try? fixture.requestIDs.retireForFixture(feature: 15, function: 1, count: 13)
    })
    permission.denyAfterChecks(3)
    let controller = BoltController(scrollPostingPreflight: { permission.read() }, makeTransport: { WheelChannel(fixture) })
    let recorder = WheelRecorder()
    let reader = watchWheel(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.applyWheelPreferences(inverted: true, highResolution: nil, restorePreviousSettingsOnDisconnect: true,
                                           amount: 1, scrollPostingAllowed: true)
    await controller.applyWheelPreferences(inverted: true, highResolution: true, restorePreviousSettingsOnDisconnect: true,
                                           amount: 1, scrollPostingAllowed: true)
    #expect(await wheelEventually { await recorder.last?.phase == .failed })
    #expect(await fixture.mode == 0)
    #expect(await fixture.modeReads == 16)
    #expect(await fixture.writes == [[4], [1], [4], [6], [3], [0]])
    #expect(fixture.requestIDs.available(slot: 2, feature: 15, function: 1) == 2)
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await recorder.last?.wheel.captureActive == false)
}
