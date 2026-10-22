import Foundation
import Testing
import HidhoggDomain
@testable import LogitechBolt

private struct SensitiveLocalizedError: LocalizedError, Sendable {
    var errorDescription: String? { "Sensitive transport failure at /private/secret/config.toml after Command-Option-X." }
}

private actor FixtureTransport {
    nonisolated let requestIDs = BoltFixtureRequestIDs()
    var continuation: AsyncStream<BoltTransportEvent>.Continuation?
    var states: [UInt16: UInt8] = [0x53: 0, 0x56: 0]
    var remaps: [UInt16: UInt16] = [:]
    var mutations: [(UInt16, UInt8)] = []
    var opens = 0
    var closes = 0
    var rows: [[UInt8]] = [FixtureTransport.row(cid: 0x53, task: 0x3C), FixtureTransport.row(cid: 0x56, task: 0x3E)]
    var slots: Set<UInt8> = [2]
    var failForward = false
    var failForwardReadback = false
    var failReporting = false
    var failAfterMutation = false
    var ignoreOff = false
    var beforeForward: CheckedContinuation<Void, Never>?
    var pauseForward = false
    var forwardPaused = false
    var version: UInt8 = 5
    var pauseOpen = false
    var openPaused = false
    var beforeOpen: CheckedContinuation<Void, Never>?
    var pauseCapabilities = false
    var capabilitiesPaused = false
    var beforeCapabilities: CheckedContinuation<Void, Never>?
    var failNextRequestWithSensitiveError = false
    var requests = 0


    static func row(cid: UInt16, task: UInt16, flags: UInt8 = 0x20) -> [UInt8] {
        BoltWire.bytes(cid) + BoltWire.bytes(task) + [flags] + Array(repeating: 0, count: 11)
    }

    func open(_ continuation: AsyncStream<BoltTransportEvent>.Continuation) async {
        self.continuation = continuation
        opens += 1
        if pauseOpen {
            openPaused = true
            await withCheckedContinuation { beforeOpen = $0 }
        }
    }
    func close() { closes += 1 }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        requests += 1
        if failNextRequestWithSensitiveError {
            failNextRequestWithSensitiveError = false
            throw SensitiveLocalizedError()
        }
        if feature == 0, function == 1 {
            guard slots.contains(slot) else { throw BoltFailure.unavailable }
            return [2, 0, parameters[2]]
        }
        if feature == 0 {
            if parameters == [0x21, 0x21] { return [0, 0, 0] }
            if parameters == [0x1B, 0x04], pauseCapabilities {
                capabilitiesPaused = true
                await withCheckedContinuation { beforeCapabilities = $0 }
            }
            return [9, 0, version]
        }
        if function == 0 { return [UInt8(rows.count)] }
        if function == 1 { return rows[Int(parameters[0])] }
        let cid = BoltWire.word(parameters, 0)
        if function == 2 {
            if failReporting { throw BoltFailure.timeout }
            if cid == 0x56, failForwardReadback, states[cid] == 1 {
                failForwardReadback = false
                throw BoltFailure.timeout
            }
            return BoltWire.bytes(cid) + [states[cid] ?? 0] + BoltWire.bytes(remaps[cid] ?? 0) + Array(repeating: 0, count: 11)
        }
        if cid == 0x56, parameters[2] == 3, pauseForward {
            forwardPaused = true
            await withCheckedContinuation { beforeForward = $0 }
        }
        mutations.append((cid, parameters[2]))
        if cid == 0x56, parameters[2] == 3, failForward { throw BoltFailure.timeout }
        if parameters[2] == 3 || !ignoreOff { states[cid] = parameters[2] == 3 ? 1 : 0 }
        if failAfterMutation, parameters[2] == 3 { throw BoltFailure.timeout }
        return BoltWire.bytes(cid) + Array(repeating: 0, count: 14)
    }

    func configure(failForward: Bool = false, failForwardReadback: Bool = false, failReporting: Bool = false, failAfterMutation: Bool = false, ignoreOff: Bool = false, pauseForward: Bool = false) {
        self.failForward = failForward
        self.failForwardReadback = failForwardReadback
        self.failReporting = failReporting
        self.failAfterMutation = failAfterMutation
        self.ignoreOff = ignoreOff
        self.pauseForward = pauseForward
    }

    func setRemap(_ cid: UInt16, _ remap: UInt16) { remaps[cid] = remap }
    func setState(_ cid: UInt16, _ state: UInt8) { states[cid] = state }
    func setRows(_ rows: [[UInt8]]) { self.rows = rows }
    func setSlots(_ slots: Set<UInt8>) { self.slots = slots }
    func setVersion(_ version: UInt8) { self.version = version }
    func resumeForward() { beforeForward?.resume(); beforeForward = nil }
    func pauseNextOpen() { pauseOpen = true }
    func resumeOpen() { pauseOpen = false; beforeOpen?.resume(); beforeOpen = nil }
    func pauseNextCapabilities() { pauseCapabilities = true }
    func resumeCapabilities() { pauseCapabilities = false; beforeCapabilities?.resume(); beforeCapabilities = nil }
    func injectSensitiveRequestError() { failNextRequestWithSensitiveError = true }
    func send(_ controls: [UInt16], at: ContinuousClock.Instant? = nil) {
        let payload = controls.flatMap(BoltWire.bytes) + Array(repeating: UInt8(0), count: 16 - controls.count * 2)
        continuation?.yield(.report([0x11, 2, 9, 0] + payload, at: at ?? .now))
    }
    func disconnect() { continuation?.yield(.failure(.disconnected)) }
    func stale() { continuation?.yield(.failure(.stale)) }
}

private final class FixtureChannel: BoltTransport, Sendable {
    let events: AsyncStream<BoltTransportEvent>
    let continuation: AsyncStream<BoltTransportEvent>.Continuation
    private let requestIDs: BoltRequestIDLedger
    let state: FixtureTransport

    init(_ state: FixtureTransport) {
        self.state = state
        requestIDs = state.requestIDs.makeTransportLedger()
        let stream = AsyncStream<BoltTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        events = stream.stream
        continuation = stream.continuation
    }

    func open() async { await state.open(continuation) }
    func close() async { await state.close(); continuation.finish() }
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int {
        requestIDs.available(slot: slot, feature: feature, function: function)
    }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        let transaction = try BoltRequestTransaction(ledger: requestIDs, slot: slot, feature: feature, function: function, parameters: parameters)
        defer { transaction.retire() }
        let payload = try await state.request(slot: slot, feature: feature, function: function, parameters: parameters)
        let size = payload.count <= 3 ? 3 : 16
        let report: [UInt8] = [size == 3 ? 0x10 : 0x11, slot, feature, transaction.lease.functionSoftware]
            + payload + Array(repeating: 0, count: size - payload.count)
        return try transaction.complete(matchedReply: transaction.reply(report), sendSucceeded: true)
    }
}

private actor Recorder {
    var statuses: [BoltStatus] = []
    var presses: [(MouseControl, UInt64, ContinuousClock.Instant)] = []

    func append(_ event: BoltEvent) {
        switch event {
        case .thumbwheel: break
        case .scroll: break
        case .status(let status): statuses.append(status)
        case .press(let control, let generation, let observedAt): presses.append((control, generation, observedAt))
        }
    }
    var last: BoltStatus? { statuses.last }
}

private func recording(_ controller: BoltController, _ recorder: Recorder) -> Task<Void, Never> {
    Task { for await event in controller.events { await recorder.append(event) } }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func discoveryAndEnableAreExplicitAndFresh() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    #expect(await transport.opens == 0)
    await controller.enable()
    #expect(await transport.mutations.isEmpty)
    await controller.discover()
    #expect(await eventually { await recorder.last?.phase == .ready })
    #expect(await transport.mutations.isEmpty)
    await controller.enable()
    #expect(await eventually { await recorder.last?.phase == .enabled })
    #expect(await transport.opens == 1)
    #expect(await transport.mutations.map(\.1) == [3, 3])
    await controller.disable()
    #expect(await transport.states.values.allSatisfy { $0 == 0 })
    #expect(await eventually { await recorder.last?.phase == .ready })
    #expect(await transport.opens == 1)
    #expect(await transport.closes == 0)
    #expect(await transport.mutations.map(\.1) == [3, 3, 2, 2])
    await controller.stop()
    #expect(await eventually { await recorder.last?.phase == .idle })
    #expect(await transport.closes == 1)
}

@Test func unknownLocalizedTransportErrorsAreRedactedFromFailureStatus() async {
    let transport = FixtureTransport()
    await transport.injectSensitiveRequestError()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }

    await controller.discover()

    #expect(await eventually { await recorder.last?.phase == .failed })
    let failure = await recorder.last
    #expect(failure?.failure?.code == .transportFailed)
    #expect(failure?.message.contains("Sensitive transport failure") == false)
    #expect(failure?.message.contains("/private/secret") == false)
    #expect(failure?.message.contains("Command-Option-X") == false)
    #expect(failure?.message.contains("The Bolt transport failed.") == true)
}

@Test func restartCleanupReturnsVerifiedRestorationDirectly() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    await controller.discover()
    await controller.enable()
    #expect(await controller.stopForRestart())
    #expect(await transport.states.values.allSatisfy { $0 == 0 })
}

@Test func restartCleanupRejectsForeignStateDirectly() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    await controller.discover()
    await controller.enable()
    await transport.setState(0x53, 2)
    #expect(await controller.stopForRestart() == false)
    #expect(await transport.states[0x53] == 2)
}

@Test func heldStartReleaseArmingAndDuplicateFiltering() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    await transport.send([0x53, 0x56], at: .now.advanced(by: .seconds(-1)))
    await transport.send([0x53, 0x56])
    await transport.send([0x53, 0x56])
    await transport.send([])
    await transport.send([0x53])
    await transport.send([0x53])
    await transport.send([])
    await transport.send([0x56])
    #expect(await eventually { await recorder.presses.count == 2 })
    #expect(await recorder.presses.map(\.0) == [.back, .forward])
    let generations = await recorder.presses.map(\.1)
    #expect(Set(generations).count == 1)
    await controller.stop()
    await transport.send([])
    await transport.send([0x53])
    #expect(await recorder.presses.count == 2)
}

@Test func partialEnableRollsBackEachPossiblyChangedControl() async {
    let transport = FixtureTransport()
    await transport.configure(failForward: true)
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    #expect(await eventually { await recorder.last?.phase == .failed })
    let failure = await recorder.last?.failure
    #expect(failure?.code == .requestTimeout)
    #expect(failure?.stage == .buttonWriteForward)
    #expect(failure?.sourceFileID.hasPrefix("/") == false)
    #expect((failure?.sourceLine ?? 0) > 0)
    #expect(await transport.states.values.allSatisfy { $0 == 0 })
    #expect(await transport.mutations.map(\.1) == [3, 3, 2])
    #expect(await recorder.last?.cleanupUncertain == false)
}

@Test func timeoutAfterAppliedWriteStillRestores() async {
    let transport = FixtureTransport()
    await transport.configure(failAfterMutation: true)
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.failure?.stage == .buttonWriteBack)
    #expect(await transport.mutations.map(\.1) == [3, 2])
    #expect(await transport.states[0x53] == 0)
}

@Test func failedButtonReadbackReportsItsStageAndRestores() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await transport.configure(failForwardReadback: true)

    await controller.enable()

    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.failure?.stage == .buttonReadbackForward)
    #expect(await transport.states.values.allSatisfy { $0 == 0 })
}

@Test func foreignBaselinePreventsAllWrites() async {
    let transport = FixtureTransport()
    await transport.setRemap(0x56, 0x77)
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    await controller.discover()
    await controller.enable()
    #expect(await transport.mutations.isEmpty)
}

@Test func enableRechecksBaselineOnTheDiscoveredHandle() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await transport.setState(0x53, 1)
    await controller.enable()
    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await transport.mutations.isEmpty)
    #expect(await transport.opens == 1)
    #expect(await transport.closes == 1)
    #expect(await recorder.last?.failure?.stage == .buttonBaselineBack)
    #expect(await recorder.last?.message.contains("The device state did not match the expected state.") == true)
}

@Test func enableRejectsChangedEligibleCapabilityRowOnTheDiscoveredHandle() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await transport.setRows([
        FixtureTransport.row(cid: 0x53, task: 0x3C, flags: 0),
        FixtureTransport.row(cid: 0x56, task: 0x3E)
    ])

    await controller.enable()

    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await transport.mutations.isEmpty)
    #expect(await transport.opens == 1)
    #expect(await transport.closes == 1)
    #expect(await recorder.last?.failure?.stage == .capabilities)
}

@Test func disableDuringPartialEnableRestoresButtonsAndKeepsTheHandle() async {
    let transport = FixtureTransport()
    await transport.configure(pauseForward: true)
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    let enable = Task { await controller.enable() }
    #expect(await eventually { await transport.forwardPaused })
    let disable = Task { await controller.disable() }
    await transport.resumeForward()
    await enable.value
    await disable.value
    #expect(await transport.states.values.allSatisfy { $0 == 0 })
    #expect(await eventually { await recorder.last?.phase == .ready })
    #expect(await recorder.last?.cleanupUncertain == false)
    #expect(await transport.opens == 1)
    #expect(await transport.closes == 0)
    #expect(await transport.mutations.map(\.1) == [3, 3, 2, 2])
    await controller.stop()
}

@Test func externalMutationIsNotOverwrittenAndBlocksRearm() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    await transport.setState(0x53, 2)
    await controller.disable()
    #expect(await eventually { await recorder.last?.cleanupUncertain == true })
    #expect(await transport.states[0x53] == 2)
    #expect(await transport.mutations.map(\.0) == [0x53, 0x56, 0x56])
    let opens = await transport.opens
    await controller.discover()
    await controller.enable()
    #expect(await transport.opens == opens)
}

@Test func offAcknowledgementRequiresSeparateBaselineVerification() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    await transport.configure(ignoreOff: true)
    await controller.stop()
    #expect(await eventually { await recorder.last?.cleanupUncertain == true })
}

@Test func stopDuringPartialEnableWaitsForRequestThenRestores() async {
    let transport = FixtureTransport()
    await transport.configure(pauseForward: true)
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    let enable = Task { await controller.enable() }
    #expect(await eventually { await transport.forwardPaused })
    let stop = Task { await controller.stop() }
    #expect(await eventually { await recorder.last?.phase == .stopping })
    #expect(await transport.mutations.count == 1)
    await transport.resumeForward()
    await enable.value
    await stop.value
    #expect(await transport.states.values.allSatisfy { $0 == 0 })
    #expect(await eventually { await recorder.last?.phase == .idle })
    #expect(await recorder.presses.isEmpty)
}

@Test func disconnectDoesNotRearmAndReportsUncertainCleanup() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    await transport.configure(failReporting: true)
    await transport.disconnect()
    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.cleanupUncertain == true)
    await transport.send([])
    await transport.send([0x53])
    #expect(await recorder.presses.isEmpty)
}

@Test func staleEventFailsClosedAndRestores() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    await transport.stale()
    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await transport.states.values.allSatisfy { $0 == 0 })
}

@Test func droppedPressStopsAndCleansUpWithoutReplay() async {
    let transport = FixtureTransport()
    let controller = BoltController(bufferSize: 1, makeTransport: { FixtureChannel(transport) })
    await controller.discover()
    await controller.enable()
    await transport.send([])
    await transport.send([0x53])
    await transport.send([])
    await transport.send([0x56])
    #expect(await eventually { await transport.mutations.count == 4 })
    var iterator = controller.events.makeAsyncIterator()
    guard case .status(let status) = await iterator.next() else { Issue.record("Expected terminal status, not buffered press"); return }
    #expect(status.phase == .failed)
    #expect(status.cleanupUncertain == false)
}

@Test func ambiguousSlotsAndChangedCapabilitiesPreventEnable() async {
    let transport = FixtureTransport()
    await transport.setSlots([1, 2])
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await recorder.last?.failure?.code == .endpointAmbiguous)
    #expect(await transport.mutations.isEmpty)
    await transport.setSlots([2])
    await controller.discover()
    await transport.setVersion(4)
    await controller.enable()
    #expect(await transport.mutations.isEmpty)
    #expect(await transport.opens == 2)
}

@Test func boltFailureCodesKeepAmbiguousAndExhaustedRequestIDsDistinct() {
    #expect(BoltFailure.ambiguous.diagnosticCode == .endpointAmbiguous)
    #expect(BoltFailure.tokenExhausted.diagnosticCode == .requestIDsExhausted)
    #expect(BoltFailure.ambiguous.diagnosticCode != BoltFailure.tokenExhausted.diagnosticCode)
}

@Test func wireRejectsDuplicatesVirtualWrongTaskAndMalformedSnapshots() throws {
    let back = FixtureTransport.row(cid: 0x53, task: 0x3C)
    let forward = FixtureTransport.row(cid: 0x56, task: 0x3E)
    #expect(try BoltWire.eligible([back, forward]) == Set(MouseControl.allCases))
    #expect(throws: BoltFailure.ambiguous) { try BoltWire.eligible([back, back, forward]) }
    #expect(try BoltWire.eligible([back, FixtureTransport.row(cid: 0x56, task: 0x3E, flags: 0xA0)]) == [.back])
    #expect(try BoltWire.eligible([back, FixtureTransport.row(cid: 0x56, task: 0x3C)]) == [.back])
    let duplicate: [UInt8] = [0x11, 2, 9, 0, 0, 0x53, 0, 0x53] + Array(repeating: 0, count: 12)
    #expect(throws: BoltFailure.malformed) { try BoltWire.snapshot(duplicate, slot: 2, feature: 9) }
    let gap: [UInt8] = [0x11, 2, 9, 0, 0, 0, 0, 0x56] + Array(repeating: 0, count: 12)
    #expect(throws: BoltFailure.malformed) { try BoltWire.snapshot(gap, slot: 2, feature: 9) }
}

@Test func wireCorrelatesLongShortErrorsAndRejectsStaleTokens() throws {
    let shortError: [UInt8] = [0x10, 2, 0x8F, 0, 0x11, 4, 0]
    let longError: [UInt8] = [0x11, 2, 0xFF, 0, 0x11, 9] + Array(repeating: 0, count: 14)
    for report in [shortError, longError] {
        #expect(throws: BoltFailure.unavailable) { try BoltWire.reply(report, slot: 2, feature: 0, functionSoftware: 0x11)?.get() }
        #expect(BoltWire.reply(report, slot: 3, feature: 0, functionSoftware: 0x11) == nil)
        #expect(BoltWire.reply(report, slot: 2, feature: 0, functionSoftware: 0x12) == nil)
    }
    let success: [UInt8] = [0x11, 2, 9, 0x21, 0, 0x53] + Array(repeating: 0, count: 14)
    #expect(try BoltWire.reply(success, slot: 2, feature: 9, functionSoftware: 0x21)?.get().count == 16)
    #expect(BoltWire.reply(success, slot: 2, feature: 9, functionSoftware: 0x22) == nil)
    #expect(BoltWire.reply(success, slot: 2, feature: 8, functionSoftware: 0x21) == nil)
    #expect(BoltWire.reply(success, slot: 2, feature: 9, functionSoftware: 0x31) == nil)
    let notification: [UInt8] = [0x11, 2, 9, 0] + Array(repeating: 0, count: 16)
    #expect(BoltWire.reply(notification, slot: 2, feature: 9, functionSoftware: 1) == nil)
}

@Test func admissionRequiresEnabledCurrentFreshGenerationAndTerminalInvalidation() async {
    let transport = FixtureTransport()
    let admission = BoltPressAdmission()
    let controller = BoltController(admission: admission, makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    var posted = 0
    #expect(!controller.withPressAdmission(generation: 0, observedAt: .now) { posted += 1 })
    await controller.discover()
    await controller.enable()
    await transport.send([])
    await transport.send([0x53])
    #expect(await eventually { await recorder.presses.count == 1 })
    guard let event = await recorder.presses.first else { Issue.record("Missing press"); return }
    #expect(controller.withPressAdmission(generation: event.1, observedAt: event.2) { posted += 1 })
    #expect(!controller.withPressAdmission(generation: event.1 + 1, observedAt: event.2) { posted += 1 })
    #expect(!controller.withPressAdmission(generation: event.1, observedAt: .now.advanced(by: .milliseconds(-251))) { posted += 1 })
    #expect(!controller.withPressAdmission(generation: event.1, observedAt: .now.advanced(by: .seconds(1))) { posted += 1 })
    admission.invalidate()
    #expect(!controller.withPressAdmission(generation: event.1, observedAt: event.2) { posted += 1 })
    await controller.stop()
    #expect(!controller.withPressAdmission(generation: event.1, observedAt: .now) { posted += 1 })
    #expect(posted == 1)
}

@Test func malformedNotificationStopsSessionAndRestoresBothControls() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await controller.enable()
    await transport.send([0x53, 0x53])
    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await transport.states.values.allSatisfy { $0 == 0 })
    #expect(await recorder.presses.isEmpty)
}

private final class WeakWorker: @unchecked Sendable {
    weak var value: BoltHIDWorker?
    init(_ worker: BoltHIDWorker) { value = worker }
}

private func finishOfflineWorker() async throws -> WeakWorker {
    let worker = BoltHIDWorker()
    let weakWorker = WeakWorker(worker)
    #expect(try await worker.submit { _ in 42 } == 42)
    worker.finish()
    return weakWorker
}

@Test func finishedRunLoopWorkerReleasesThreadOwnershipWithoutOpeningHID() async throws {
    let weakWorker = try await finishOfflineWorker()
    #expect(await eventually { weakWorker.value == nil })
}

@Test func finishedRunLoopRejectsSubmissionInsteadOfRestartingWithoutOpeningHID() async throws {
    let worker = BoltHIDWorker()
    #expect(try await worker.submit { _ in 42 } == 42)
    worker.finish()
    do {
        _ = try await worker.submit { _ in 43 }
        Issue.record("Finished worker accepted another submission")
    } catch {
        #expect(error as? BoltFailure == .disconnected)
    }
    worker.finish()
}

@Test func stopDuringDiscoveryCannotPublishReadyOrResumeRequests() async {
    let transport = FixtureTransport()
    await transport.pauseNextOpen()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    let discovery = Task { await controller.discover() }
    #expect(await eventually { await transport.openPaused })
    let stop = Task { await controller.stop() }
    #expect(await eventually { await recorder.last?.phase == .stopping })
    await controller.enable()
    await controller.discover()
    await transport.resumeOpen()
    await discovery.value
    await stop.value
    #expect(await eventually { await recorder.last?.phase == .idle })
    #expect(await transport.requests == 0)
    #expect(await transport.opens == 1)
    #expect(await transport.mutations.isEmpty)
    #expect(await recorder.statuses.allSatisfy { $0.phase != .ready && $0.phase != .enabled })
}

@Test func stopDuringFreshEnableChecksCannotResurrectDiversion() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    let requests = await transport.requests
    await transport.pauseNextCapabilities()
    let enabling = Task { await controller.enable() }
    #expect(await eventually { await transport.capabilitiesPaused })
    let stop = Task { await controller.stop() }
    #expect(await eventually { await recorder.last?.phase == .stopping })
    await transport.resumeCapabilities()
    await enabling.value
    await stop.value
    #expect(await eventually { await recorder.last?.phase == .idle })
    #expect(await transport.requests == requests + 1)
    #expect(await transport.opens == 1)
    #expect(await transport.mutations.isEmpty)
    #expect(await recorder.statuses.allSatisfy { $0.phase != .enabled })
}

@Test func terminalFailureRequiresExplicitFreshDiscoveryButDoesNotPermanentlyPoisonIt() async {
    let transport = FixtureTransport()
    let controller = BoltController(makeTransport: { FixtureChannel(transport) })
    let recorder = Recorder()
    let reader = recording(controller, recorder)
    defer { reader.cancel() }
    await controller.discover()
    await transport.stale()
    #expect(await eventually { await recorder.last?.phase == .failed })
    #expect(await transport.opens == 1)
    await controller.discover()
    #expect(await eventually { await recorder.last?.phase == .ready })
    #expect(await transport.opens == 2)
    #expect(await transport.mutations.isEmpty)
    await controller.stop()
}
