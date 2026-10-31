import Foundation
import Testing
@testable import LofreeFlowLite84

struct FlowLite84SystemModeTests {
    @Test func userChoicesAndSystemWriteRegionAreExact() throws {
        #expect(FlowLite84SystemMode.allCases.map(\.rawValue) == [0, 1])
        #expect(FlowLite84SystemMode.allCases.map(\.title) == ["Windows", "Mac"])
        #expect(FlowLite84SystemMode(rawValue: 2) == nil)
        #expect(FlowLite84SystemMode(rawValue: 3) == nil)
        #expect(FlowLite84SystemMode(rawValue: 255) == nil)
        for mode in FlowLite84SystemMode.allCases {
            let report = try FlowLite84Codec.encode(.systemModeWrite(mode))
            #expect(Array(report[1...7]) == [7, 0, 0x24, 0xc8, 0x82, mode.rawValue, 0x55 &- mode.rawValue])
            try FlowLite84Codec.validateOutput(report)
        }
        for bytes: [UInt8] in [[], [1], [1, 0], [0, 0, 0x55], [0, 0, 0, 0x55]] {
            #expect(throws: FlowLite84Failure.invalidRequest) {
                try FlowLite84Codec.encode(.restoreSystemMode(bytes))
            }
        }
        for (address, count): (UInt16, UInt8) in [(9414, 2), (9418, 2), (9416, 1), (9416, 4)] {
            let frame = fixturePacket(command: 7, address: address, count: count | 0x80, fields: [0, 0x55])
            #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.validateOutput(frame) }
            #expect(throws: FlowLite84Failure.invalidResponse(.writeHeader)) { try FlowLite84Codec.decode(frame) }
        }
        #expect(throws: FlowLite84Failure.invalidRequest) {
            try FlowLite84Codec.encode(.lightingWrite(address: 9416, bytes: [1, 0x54]))
        }
    }

    @Test func systemAcknowledgementRequiresExactHeaderAndSurvivesSanitization() throws {
        let request = FlowLite84Request.systemModeWrite(.windows)
        for count: UInt8 in [2, 0x82] {
            let packet = fixturePacket(command: 7, address: 9416, count: count, fields: [99, 98])
            let sanitized = try Array(packet).withUnsafeBufferPointer {
                try FlowLite84Codec.sanitizedInput(reportID: 8, bytes: $0)
            }
            let reply = try FlowLite84Codec.decode(#require(sanitized))
            try reply.validate(for: request)
            #expect(reply.fields.isEmpty)
        }
        #expect(throws: FlowLite84Failure.rejected(command: 7, status: 1)) {
            try FlowLite84Codec.decode(fixturePacket(command: 7, status: 1, address: 9416, count: 2)).validate(for: request)
        }
        #expect(throws: FlowLite84Failure.invalidResponse(.writeHeader)) {
            try FlowLite84Codec.decode(fixturePacket(command: 7, address: 8500, count: 2)).validate(for: request)
        }
        var corrupt = fixturePacket(command: 7, address: 9416, count: 2)
        corrupt[16] &+= 1
        #expect(throws: FlowLite84Failure.invalidResponse(.packetChecksum)) { try FlowLite84Codec.decode(corrupt) }
    }

    @Test(arguments: [UInt8(0), 2, 3, 255])
    func applyCapturesFreshOriginalAndExplicitRestorePreservesRawUnknown(_ original: UInt8) async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.set(9416, [original, 0x55 &- original])
        let applied = try await session.applySystemMode(.mac)
        #expect(applied.systemMode == 1)
        #expect(applied.canRestoreOriginalSystemMode)
        #expect(!applied.canRestoreOriginalLighting)
        #expect(applied.lighting?.mode == 10)
        let restored = try await session.restoreOriginalSystemMode()
        #expect(restored.systemMode == original)
        #expect(!restored.canRestoreOriginalSystemMode)
        #expect(await transport.value(9416) == [original, 0x55 &- original])
        #expect(await transport.writeAddresses == [9416, 9416])
        let writes = await transport.requests.filter { $0[1] == 7 }
        #expect(writes.allSatisfy { $0[3] == 0x24 && $0[4] == 0xc8 && $0[5] == 0x82 })
        await session.disconnect()
    }

    @Test func lightingAndSystemRestorationAreIndependentInEitherOrder() async throws {
        for restoreLightingFirst in [true, false] {
            let transport = LightingFixtureTransport()
            let session = FlowLite84Session(makeTransport: { transport })
            try await session.connect()
            _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false))
            let both = try await session.applySystemMode(.windows)
            #expect(both.canRestoreOriginalLighting && both.canRestoreOriginalSystemMode)
            if restoreLightingFirst {
                let lighting = try await session.restoreOriginalLighting()
                #expect(lighting.systemMode == 0)
                #expect(lighting.canRestoreOriginalSystemMode)
                #expect(!lighting.canRestoreOriginalLighting)
                #expect(await transport.value(9416) == [0, 0x55])
                _ = try await session.restoreOriginalSystemMode()
                #expect(await transport.writeAddresses == [8498, 9416, 8498, 9416])
            } else {
                let system = try await session.restoreOriginalSystemMode()
                #expect(system.lighting?.enabled == false)
                #expect(system.canRestoreOriginalLighting)
                #expect(!system.canRestoreOriginalSystemMode)
                #expect(await transport.value(8498) == [0, 0x55])
                _ = try await session.restoreOriginalLighting()
                #expect(await transport.writeAddresses == [8498, 9416, 9416, 8498])
            }
            #expect(await transport.value(9416) == [1, 0x54])
            #expect(await transport.value(8498) == [1, 0x54])
            await session.disconnect()
        }
    }

    @Test func repeatedApplyRestoresFirstOriginalAndRefreshRetainsBothFlags() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        _ = try await session.applySystemMode(.windows)
        _ = try await session.applySystemMode(.mac)
        _ = try await session.applySystemMode(.windows)
        _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false))
        try await session.refresh()
        try await session.refreshBattery()
        let refreshed = try await session.applySystemMode(.windows)
        #expect(refreshed.canRestoreOriginalLighting && refreshed.canRestoreOriginalSystemMode)
        await transport.setOnline(false)
        try await session.refreshBattery()
        let offlineBattery = try await session.applySystemMode(.windows)
        #expect(offlineBattery.canRestoreOriginalLighting && offlineBattery.canRestoreOriginalSystemMode)
        try await session.refresh()
        let offlineFull = try await session.applySystemMode(.windows)
        #expect(offlineFull.canRestoreOriginalLighting && offlineFull.canRestoreOriginalSystemMode)
        let restored = try await session.restoreOriginalSystemMode()
        #expect(restored.systemMode == 1)
        #expect(restored.canRestoreOriginalLighting)
        #expect(await transport.writeAddresses == [9416, 9416, 9416, 8498, 9416])
        await session.disconnect()
    }

    @Test func identicalApplyDoesNotWriteOrCaptureOriginal() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        let result = try await session.applySystemMode(.mac)
        #expect(!result.canRestoreOriginalSystemMode)
        #expect(await transport.writeAddresses.isEmpty)
        await systemFailure(.noOriginalSystemMode) { _ = try await session.restoreOriginalSystemMode() }
        await session.disconnect()
    }

    @Test func legacySessionsDefaultToUnavailableWithoutAddingWriteBehavior() async {
        let session = LegacySystemSession()
        await systemFailure(.unavailable) { _ = try await session.applySystemMode(.mac) }
        await systemFailure(.unavailable) { _ = try await session.restoreOriginalSystemMode() }
    }

    @Test func invalidFreshOriginalClosesBeforeAnyWrite() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.set(9416, [1, 0])
        await systemFailure(.invalidResponse(.scalarChecksum)) { _ = try await session.applySystemMode(.windows) }
        #expect(await transport.writeAddresses.isEmpty)
        #expect(await systemEventually { await transport.closes == 1 })
        await systemFailure(.noOriginalSystemMode) { _ = try await session.restoreOriginalSystemMode() }
    }

    @Test func ambiguousOnlineFlagDoesNotPreventFreshScopedSystemEdit() async throws {
        let transport = LightingFixtureTransport()
        await transport.setOnline(false)
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        let result = try await session.applySystemMode(.windows)
        #expect(!result.online)
        #expect(result.systemMode == 0)
        #expect(!result.unavailableFields.contains("systemMode"))
        #expect(await transport.writeAddresses == [9416])
        await session.disconnect()
    }

    @Test(arguments: [LightingFixtureTransport.Ack.silent, .wrongAddress, .sendFailure])
    func ambiguousOutcomeReconcilesWithoutSuccessOrRetry(_ ack: LightingFixtureTransport.Ack) async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(timing: FlowLite84Timing(responseTimeout: .milliseconds(250)), makeTransport: { transport })
        try await session.connect()
        await transport.setAck(ack)
        await systemFailure(.systemModeOutcomeUnknown) { _ = try await session.applySystemMode(.windows) }
        #expect(await transport.writeAddresses == [9416])
        #expect(await transport.value(9416) == [0, 0x55])
        #expect(await transport.readsAfterWrite > 0)
        #expect(await session.status == .connected(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)))
        await transport.setAck(.normal)
        let restored = try await session.restoreOriginalSystemMode()
        #expect(restored.systemMode == 1)
        await session.disconnect()
    }

    @Test(arguments: [LightingFixtureTransport.Ack.badChecksum, .wrongIdentity, .outOfScope, .wrongCount, .outOfScopeAck])
    func globallyInvalidReplyClosesSessionWithoutReconciliation(_ ack: LightingFixtureTransport.Ack) async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(ack)
        await systemFailure(.systemModeOutcomeUnknown) { _ = try await session.applySystemMode(.windows) }
        #expect(await systemEventually { await session.status == .failed(.systemModeOutcomeUnknown) })
        #expect(await transport.closes == 1)
        #expect(await transport.writeAddresses == [9416])
        #expect(await transport.readsAfterWrite == 0)
        await systemFailure(.disconnected) { _ = try await session.applySystemMode(.mac) }
        await systemFailure(.noOriginalSystemMode) { _ = try await session.restoreOriginalSystemMode() }
    }

    @Test func rejectionAndReadbackMismatchNeverReportSuccessOrRetry() async throws {
        for ack in [LightingFixtureTransport.Ack.rejected, .doesNotPersist] {
            let transport = LightingFixtureTransport()
            let session = FlowLite84Session(makeTransport: { transport })
            try await session.connect()
            await transport.setAck(ack)
            let expected: FlowLite84Failure = ack == .rejected ? .rejected(command: 7, status: 1) : .systemModeReadbackMismatch
            await systemFailure(expected) { _ = try await session.applySystemMode(.windows) }
            #expect(await transport.writeAddresses == [9416])
            #expect(await transport.value(9416) == [1, 0x54])
            await session.disconnect()
        }
    }

    @Test func systemWriteSerializesLightingRefreshBatteryAndVendorNotification() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        let applying = Task { try await session.applySystemMode(.windows) }
        #expect(await systemEventually { await transport.writeAddresses == [9416] })
        let requestCount = await transport.requests.count
        await transport.notify()
        await systemFailure(.busy) { _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false)) }
        await systemFailure(.busy) { _ = try await session.applySystemMode(.mac) }
        let refresh = Task { try await session.refresh() }
        let battery = Task { try await session.refreshBattery() }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await transport.requests.count == requestCount)
        await transport.release()
        let result = try await applying.value
        #expect(result.systemMode == 0)
        try await refresh.value
        try await battery.value
        #expect(await transport.maximumConcurrentWrites == 1)
        #expect(await transport.writeAddresses == [9416])
        await session.disconnect()
    }

    @Test func unsolicitedBatteryIsPreservedInConfirmedSystemResult() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        _ = try await session.applyLighting(FlowLite84LightingEdit(enabled: false))
        await transport.setAck(.held)
        let applying = Task { try await session.applySystemMode(.windows) }
        #expect(await systemEventually { await transport.writeAddresses == [8498, 9416] })
        await transport.emitBattery()
        await transport.release()
        let result = try await applying.value
        #expect(result.systemMode == 0)
        #expect(result.battery?.reportedLevel == 42)
        #expect(result.batteryReadAt != nil)
        #expect(!result.unavailableFields.contains("battery"))
        #expect(result.canRestoreOriginalLighting && result.canRestoreOriginalSystemMode)
        await session.disconnect()
    }

    @Test func sendCompletionTimeoutClosesBeforeReadback() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(timing: FlowLite84Timing(responseTimeout: .milliseconds(250)), makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        await systemFailure(.systemModeOutcomeUnknown) { _ = try await session.applySystemMode(.windows) }
        #expect(await systemEventually { await session.status == .failed(.systemModeOutcomeUnknown) })
        #expect(await transport.writeAddresses == [9416])
        #expect(await transport.readsAfterWrite == 0)
        #expect(await transport.maximumConcurrentWrites == 1)
    }

    @Test func cancellationDuringWriteClosesWithoutRetry() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        let applying = Task { try await session.applySystemMode(.windows) }
        #expect(await systemEventually { await transport.writeAddresses == [9416] })
        applying.cancel()
        await systemFailure(.systemModeOutcomeUnknown) { _ = try await applying.value }
        #expect(await systemEventually { await session.status == .failed(.systemModeOutcomeUnknown) })
        #expect(await transport.writeAddresses == [9416])
    }

    @Test func disconnectClearsOriginalAndReconnectNeverReapplies() async throws {
        let first = LightingFixtureTransport()
        let second = LightingFixtureTransport()
        let factory = SystemTransportFactory([first, second])
        let session = FlowLite84Session(makeTransport: { factory.next() })
        try await session.connect()
        _ = try await session.applySystemMode(.windows)
        await session.disconnect()
        await systemFailure(.noOriginalSystemMode) { _ = try await session.restoreOriginalSystemMode() }
        try await session.connect()
        let unchanged = try await session.applySystemMode(.mac)
        #expect(!unchanged.canRestoreOriginalSystemMode)
        #expect(await second.writeAddresses.isEmpty)
        await systemFailure(.noOriginalSystemMode) { _ = try await session.restoreOriginalSystemMode() }
        await session.disconnect()
    }

    @Test func disconnectDuringWriteReportsUnknownAndDropsOriginal() async throws {
        let transport = LightingFixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        await transport.setAck(.held)
        let applying = Task { try await session.applySystemMode(.windows) }
        #expect(await systemEventually { await transport.writeAddresses == [9416] })
        await session.disconnect()
        await systemFailure(.systemModeOutcomeUnknown) { _ = try await applying.value }
        #expect(await transport.writeAddresses == [9416])
        await systemFailure(.noOriginalSystemMode) { _ = try await session.restoreOriginalSystemMode() }
    }
}

private struct LegacySystemSession: FlowLite84SessionProtocol {
    let events = AsyncStream<FlowLite84Event> { $0.finish() }
    func connect() async throws {}
    func refresh() async throws {}
    func refreshBattery() async throws {}
    func disconnect() async {}
}

private final class SystemTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [LightingFixtureTransport]

    init(_ transports: [LightingFixtureTransport]) { self.transports = transports }

    func next() -> LightingFixtureTransport {
        lock.withLock { transports.removeFirst() }
    }
}

private func systemFailure(_ expected: FlowLite84Failure, operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected bounded system-mode failure") }
    catch { #expect(error as? FlowLite84Failure == expected) }
}

private func systemEventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
