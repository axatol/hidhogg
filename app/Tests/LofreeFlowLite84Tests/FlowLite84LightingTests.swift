import Foundation
import Testing
@testable import LofreeFlowLite84

struct FlowLite84LightingTests {
    @Test func readableValuesKeepUnknownsAndUseOneBasedLevels() {
        #expect(FlowLite84LightingEffect.allCases.map(\.rawValue) == [4, 5, 6, 7, 8, 9, 10])
        #expect(FlowLite84LightingIdleOff.allCases.map(\.rawValue) == [1, 3, 6, 12, 30, 60, 90])
        let value = FlowLite84Lighting(mode: 255, enabled: false, idleOffUnits: 0)
        #expect(value.effect == nil)
        #expect(value.idleOff == nil)
        #expect(value.mode == 255)
        #expect(value.idleOffUnits == 0)
        #expect(FlowLite84Lighting.displayedLevel(0) == 1)
        #expect(FlowLite84Lighting.displayedLevel(4) == 5)
        #expect(FlowLite84Lighting.displayedLevel(5) == nil)
        #expect(FlowLite84Lighting.levelTitle(nil) == "Unknown")
    }

    @Test func lightingOutputAllowsOnlyExactScalarAndKnownEffectRegions() throws {
        for address: UInt16 in [8496, 8498, 8500] {
            try FlowLite84Codec.validateOutput(FlowLite84Codec.encode(.lightingWrite(address: address, bytes: [255, 0x56])))
        }
        for mode in FlowLite84LightingEffect.allCases {
            try FlowLite84Codec.validateOutput(FlowLite84Codec.encode(.lightingWrite(address: 8544 + UInt16(mode.rawValue) * 32, bytes: [0, 3, 3, 0x4f])))
        }
        for address: UInt16 in [0, 8495, 8497, 8502, 8544, 8640, 8673, 8676, 8896, 9024, 9408, 9416, 10064] {
            for bytes: [UInt8] in [[1, 0x54], [0, 3, 3, 0x4f]] {
                #expect(throws: FlowLite84Failure.invalidRequest) {
                    try FlowLite84Codec.encode(.lightingWrite(address: address, bytes: bytes))
                }
            }
        }
        for bytes: [UInt8] in [[], [1], [1, 0], [1, 2, 3], [1, 2, 3, 4], Array(repeating: 0, count: 256)] {
            #expect(throws: FlowLite84Failure.invalidRequest) {
                try FlowLite84Codec.encode(.lightingWrite(address: 8496, bytes: bytes))
            }
        }
        let hidden = fixturePacket(command: 7, address: 8496, count: 0x82, fields: [1, 0x54, 1])
        #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.validateOutput(hidden) }
    }

    @Test func acknowledgementRequiresAddressCountStatusAndPacketChecksum() throws {
        let request = FlowLite84Request.lightingWrite(address: 8496, bytes: [4, 0x51])
        for count: UInt8 in [2, 0x82] {
            try FlowLite84Codec.decode(fixturePacket(command: 7, address: 8496, count: count)).validate(for: request)
        }
        #expect(throws: FlowLite84Failure.rejected(command: 7, status: 1)) {
            try FlowLite84Codec.decode(fixturePacket(command: 7, status: 1, address: 8496, count: 2)).validate(for: request)
        }
        for address: UInt16 in [8498, 8500] {
            #expect(throws: FlowLite84Failure.invalidResponse(.writeHeader)) {
                try FlowLite84Codec.decode(fixturePacket(command: 7, address: address, count: 2)).validate(for: request)
            }
        }
        #expect(throws: FlowLite84Failure.invalidResponse(.writeHeader)) {
            try FlowLite84Codec.decode(fixturePacket(command: 7, address: 8496, count: 4)).validate(for: request)
        }
        var corrupt = fixturePacket(command: 7, address: 8496, count: 2)
        corrupt[16] &+= 1
        #expect(throws: FlowLite84Failure.invalidResponse(.packetChecksum)) { try FlowLite84Codec.decode(corrupt) }
        let safe = try Array(fixturePacket(command: 7, address: 8496, count: 2, fields: [99, 98])).withUnsafeBufferPointer {
            try FlowLite84Codec.sanitizedInput(reportID: 8, bytes: $0)
        }
        #expect(try FlowLite84Codec.decode(#require(safe)).fields.isEmpty)
    }

    @Test func partialEditPreservesColorUnknownSpeedAndUntouchedRegionsAndRestoresExactly() async throws {
        let transport = LightingFixtureTransport()
        let original = [UInt8(6), 201, 255, 0x55 &- 6 &- 201 &- 255]
        await transport.set(8864, original)
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        var initial: FlowLite84Snapshot?
        for await event in session.events {
            guard case .snapshot(let snapshot, _) = event else { continue }
            initial = snapshot
            break
        }
        let initialSnapshot = try #require(initial)
        #expect(initialSnapshot.lighting?.speedLevel == 201)
        #expect(initialSnapshot.lighting?.brightnessLevel == 255)
        #expect(FlowLite84Lighting.levelTitle(initialSnapshot.lighting?.speedLevel) == "Unknown")
        #expect(FlowLite84Lighting.levelTitle(initialSnapshot.lighting?.brightnessLevel) == "Unknown")
        #expect(!initialSnapshot.unavailableFields.contains("lighting.speedLevel"))
        #expect(!initialSnapshot.unavailableFields.contains("lighting.brightnessLevel"))
        let applied = try await session.applyLighting(FlowLite84LightingEdit(brightnessLevel: 0))
        #expect(applied.lighting?.brightnessLevel == 0)
        #expect(applied.lighting?.speedLevel == 201)
        #expect(FlowLite84Lighting.levelTitle(applied.lighting?.speedLevel) == "Unknown")
        #expect(!applied.unavailableFields.contains("lighting.speedLevel"))
        #expect(applied.canRestoreOriginalLighting)
        #expect(await transport.value(8864) == [6, 201, 0, 0x55 &- 6 &- 201])
        #expect(await transport.writeAddresses == [8864])
        let restored = try await session.restoreOriginalLighting()
        #expect(restored.lighting?.speedLevel == 201)
        #expect(restored.lighting?.brightnessLevel == 255)
        #expect(FlowLite84Lighting.levelTitle(restored.lighting?.brightnessLevel) == "Unknown")
        #expect(!restored.unavailableFields.contains("lighting.speedLevel"))
        #expect(!restored.unavailableFields.contains("lighting.brightnessLevel"))
        #expect(await transport.value(8864) == original)
        #expect(await transport.writeAddresses == [8864, 8864])
        #expect(!restored.canRestoreOriginalLighting)
        await session.disconnect()
    }

    @Test func originalScalarsRemainOriginalAcrossMultipleApplies() async throws {
        let transport = LightingFixtureTransport()
        await transport.set(8500, [0, 0x55])
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        _ = try await session.applyLighting(FlowLite84LightingEdit(idleOff: .oneMinute))
        _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false, idleOff: .fiveMinutes))
        let restored = try await session.restoreOriginalLighting()
        #expect(restored.lighting?.idleOffUnits == 0)
        #expect(restored.lighting?.idleOff == nil)
        #expect(restored.lighting?.enabled == true)
        #expect(!restored.canRestoreOriginalLighting)
        #expect(await transport.value(8500) == [0, 0x55])
        await session.disconnect()
    }

    @Test func effectEditReadsDestinationHeaderAndPreservesItsOtherFields() async throws {
        let transport = LightingFixtureTransport()
        await transport.set(8672, [5, 4, 2, 0x4a])
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        let result = try await session.applyLighting(FlowLite84LightingEdit(effect: .trailing, brightnessLevel: 1))
        #expect(result.lighting?.effect == .trailing)
        #expect(result.lighting?.speedLevel == 4)
        #expect(result.lighting?.brightnessLevel == 1)
        #expect(await transport.value(8672) == [5, 4, 1, 0x4b])
        #expect(await transport.writeAddresses == [8672, 8496])
        _ = try await session.restoreOriginalLighting()
        #expect(await transport.value(8672) == [5, 4, 2, 0x4a])
        #expect(await transport.value(8496) == [10, 0x4b])
        await session.disconnect()
    }

    @Test func unknownModeAllowsScalarEditAndRestoresUnknownWithoutWritingUnknownEffect() async throws {
        let transport = LightingFixtureTransport()
        await transport.set(8496, [250, 0x5b])
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false))
        await lightingFailure(.lightingUnavailable) {
            _ = try await session.applyLighting(FlowLite84LightingEdit(brightnessLevel: 2))
        }
        _ = try await session.applyLighting(FlowLite84LightingEdit(effect: .steady))
        let restored = try await session.restoreOriginalLighting()
        #expect(restored.lighting?.mode == 250)
        #expect(await transport.writeAddresses == [8498, 8496, 8496, 8498])
        await session.disconnect()
    }

    @Test func ambiguousOfflineFlagDoesNotPreventScopedFreshLightingEdit() async throws {
        let transport = LightingFixtureTransport()
        await transport.setOnline(false)
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        let snapshot = try await session.applyLighting(FlowLite84LightingEdit(enabled: false))
        #expect(!snapshot.online)
        #expect(snapshot.lighting?.enabled == false)
        #expect(await transport.writeAddresses == [8498])
        await session.disconnect()
    }

    @Test func invalidOrEmptyEditAndMissingOriginalDoNotSendWrites() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        for edit in [FlowLite84LightingEdit(), FlowLite84LightingEdit(brightnessLevel: 5), FlowLite84LightingEdit(speedLevel: 255)] {
            await lightingFailure(.invalidRequest) { _ = try await session.applyLighting(edit) }
        }
        await lightingFailure(.noOriginalLighting) { _ = try await session.restoreOriginalLighting() }
        #expect(await transport.writeAddresses.isEmpty)
        await session.disconnect()
    }

    @Test func identicalEditDoesNotWriteOrCreateRestorationSnapshot() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        let result = try await session.applyLighting(FlowLite84LightingEdit(enabled: true))
        #expect(await transport.writeAddresses.isEmpty)
        #expect(!result.canRestoreOriginalLighting)
        await session.disconnect()
    }

    @Test(arguments: [LightingFixtureTransport.Ack.silent, .wrongAddress, .sendFailure])
    func unknownWriteOutcomeReconcilesButNeverReportsSuccessOrResends(_ ack: LightingFixtureTransport.Ack) async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(timing: FlowLite84Timing(responseTimeout: .milliseconds(250)), makeTransport: { transport })
        try await session.connect()
        await transport.setAck(ack)
        await lightingFailure(.lightingOutcomeUnknown) {
            _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false, idleOff: .fiveMinutes))
        }
        #expect(await transport.value(8498) == [0, 0x55])
        #expect(await transport.writeAddresses == [8498])
        #expect(await transport.readsAfterWrite > 0)
        #expect(await session.status == .connected(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)))
        await session.disconnect()
    }

    @Test(arguments: [LightingFixtureTransport.Ack.badChecksum, .wrongIdentity, .outOfScope, .wrongCount, .outOfScopeAck])
    func globallyInvalidFramesDuringWriteCloseSessionAndReportUnknown(_ ack: LightingFixtureTransport.Ack) async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(ack)
        await lightingFailure(.lightingOutcomeUnknown) {
            _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false))
        }
        #expect(await eventually { await session.status == .failed(.lightingOutcomeUnknown) })
        #expect(await transport.closes == 1)
        #expect(await transport.writeAddresses == [8498])
        #expect(await transport.readsAfterWrite == 0)
        await lightingFailure(.disconnected) { try await session.refresh() }
        await lightingFailure(.disconnected) {
            _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: true))
        }
        #expect(await transport.writeAddresses == [8498])
    }

    @Test func rejectionAndReadbackMismatchAreFailuresWithoutBlindRetry() async throws {
        for ack in [LightingFixtureTransport.Ack.rejected, .doesNotPersist] {
            let transport = LightingFixtureTransport()
            let session = FlowLite84Session(makeTransport: { transport })
            try await session.connect()
            await transport.setAck(ack)
            let expected: FlowLite84Failure = ack == .rejected ? .rejected(command: 7, status: 1) : .lightingReadbackMismatch
            await lightingFailure(expected) { _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false)) }
            #expect(await transport.writeAddresses == [8498])
            #expect(await transport.value(8498) == [1, 0x54])
            await session.disconnect()
        }
    }

    @Test func concurrentOperationsAndVendorRefreshWaitForWriteCompletion() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        let applying = Task { try await session.applyLighting(FlowLite84LightingEdit(enabled: false)) }
        #expect(await eventually { await transport.writeAddresses == [8498] })
        let requestCount = await transport.requests.count
        await transport.notify()
        let refresh = Task { try await session.refresh() }
        let battery = Task { try await session.refreshBattery() }
        await lightingFailure(.busy) { _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: true)) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await transport.requests.count == requestCount)
        await transport.release()
        _ = try await applying.value
        try await refresh.value
        try await battery.value
        #expect(await eventually { await transport.requests.contains { $0[1] == 3 } })
        #expect(await transport.maximumConcurrentWrites == 1)
        await session.disconnect()
    }

    @Test func disconnectDuringWriteReportsUnknownAndNeverRestoresOrReapplies() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        let applying = Task { try await session.applyLighting(FlowLite84LightingEdit(enabled: false)) }
        #expect(await eventually { await transport.writeAddresses == [8498] })
        await session.disconnect()
        await lightingFailure(.lightingOutcomeUnknown) { _ = try await applying.value }
        #expect(await transport.writeAddresses == [8498])
        await lightingFailure(.noOriginalLighting) { _ = try await session.restoreOriginalLighting() }
    }

    @Test func sendCompletionTimeoutClosesBeforeAnyReconciliationRead() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(timing: FlowLite84Timing(responseTimeout: .milliseconds(250)), makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        await lightingFailure(.lightingOutcomeUnknown) {
            _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false))
        }
        #expect(await eventually { await session.status == .failed(.lightingOutcomeUnknown) })
        #expect(await transport.writeAddresses == [8498])
        #expect(await transport.readsAfterWrite == 0)
        #expect(await transport.maximumConcurrentWrites == 1)
    }

    @Test func cancellationDuringWriteReportsUnknownAndClosesWithoutRetry() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        let applying = Task { try await session.applyLighting(FlowLite84LightingEdit(enabled: false)) }
        #expect(await eventually { await transport.writeAddresses == [8498] })
        applying.cancel()
        await lightingFailure(.lightingOutcomeUnknown) { _ = try await applying.value }
        #expect(await eventually { await session.status == .failed(.lightingOutcomeUnknown) })
        #expect(await transport.writeAddresses == [8498])
    }

    @Test func unsolicitedBatteryDuringLightingIsPreservedInConfirmedResult() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        let applying = Task { try await session.applyLighting(FlowLite84LightingEdit(enabled: false)) }
        #expect(await eventually { await transport.writeAddresses == [8498] })
        await transport.emitBattery()
        await transport.release()
        let result = try await applying.value
        #expect(result.battery?.reportedLevel == 42)
        #expect(result.battery?.charging == false)
        #expect(result.batteryReadAt != nil)
        #expect(!result.unavailableFields.contains("battery"))
        #expect(result.lighting?.enabled == false)
        await session.disconnect()
    }
}

private func lightingFailure(_ expected: FlowLite84Failure, operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected bounded lighting failure") }
    catch { #expect(error as? FlowLite84Failure == expected) }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

actor LightingFixtureTransport: FlowLite84Transport {
    enum Ack: Sendable { case normal, silent, wrongAddress, wrongCount, badChecksum, wrongIdentity, outOfScope, outOfScopeAck, sendFailure, rejected, doesNotPersist, held }
    nonisolated let reports: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var storage: [UInt16: [UInt8]] = [8496: [10, 0x4b], 8498: [1, 0x54], 8500: [6, 0x4f], 9416: [1, 0x54]]
    private var ack: Ack = .normal
    private var online = true
    private var held: CheckedContinuation<Void, Never>?
    private(set) var closes = 0
    private(set) var writeAddresses: [UInt16] = []
    private(set) var requests: [Data] = []
    private(set) var readsAfterWrite = 0
    private var concurrentWrites = 0
    private(set) var maximumConcurrentWrites = 0

    init() {
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        reports = stream.stream
        continuation = stream.continuation
    }

    func open() {}
    func close() { closes += 1; release(); continuation.finish() }
    func set(_ address: UInt16, _ bytes: [UInt8]) { storage[address] = bytes }
    func value(_ address: UInt16) -> [UInt8]? { storage[address] }
    func setAck(_ value: Ack) { ack = value }
    func setOnline(_ value: Bool) { online = value }
    func release() { held?.resume(); held = nil }
    func notify() { continuation.yield(fixturePacket(command: 10, fields: [0x10])) }
    func emitBattery() { continuation.yield(fixturePacket(command: 4, fields: [42, 0, 0x0f, 0x00])) }

    func write(_ report: Data) async throws {
        try FlowLite84Codec.validateOutput(report)
        requests.append(report)
        concurrentWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
        defer { concurrentWrites -= 1 }
        let p = Array(report.dropFirst())
        let address = UInt16(p[2]) << 8 | UInt16(p[3])
        let count = Int(p[4] & 0x7f)
        var fields: [UInt8] = []
        switch p[0] {
        case 1: fields = [0, 0, 0, 0, 1, 1, 0]
        case 3: fields = [online ? 1 : 0]
        case 4: fields = [80, 0, 0x0f, 0x00]
        case 18: fields = [1, 0x61]
        case 8:
            fields = storage[address] ?? [0, 2, 3, 0x50]
            if !writeAddresses.isEmpty { readsAfterWrite += 1 }
        case 7:
            writeAddresses.append(address)
            if ack != .rejected, ack != .doesNotPersist { storage[address] = Array(p[5..<(5 + count)]) }
            if ack == .silent { return }
            if ack == .sendFailure { throw FlowLite84Failure.transport }
        default: break
        }
        var response = fixturePacket(command: p[0], status: p[0] == 7 && ack == .rejected ? 1 : 0,
                                     address: p[0] == 7 && ack == .wrongAddress ? 8500 : address,
                                     count: p[0] == 7 && ack == .wrongCount ? 4 : p[4], fields: fields)
        if p[0] == 7 && ack == .badChecksum { response[16] &+= 1 }
        if p[0] == 7 && ack == .wrongIdentity { response = fixturePacket(command: 1, fields: [0, 0, 0, 0, 2, 1, 0]) }
        if p[0] == 7 && ack == .outOfScope { response = fixturePacket(command: 8, address: 10064, count: 2) }
        if p[0] == 7 && ack == .outOfScopeAck { response = fixturePacket(command: 7, address: 10064, count: 2) }
        continuation.yield(response)
        if p[0] == 7 && ack == .held { await withCheckedContinuation { held = $0 } }
    }
}
