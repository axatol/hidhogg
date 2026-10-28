import Foundation
import Testing
@testable import LofreeFlowLite84

struct FlowLite84SessionTests {
    @Test func idleBatteryTelemetryUpdatesOnlyBatteryWithoutSending() async throws {
        let transport = FlowLite84FixtureTransport()
        let clock = FlowLite84FixtureClock()
        let session = FlowLite84Session(timing: FlowLite84Timing(now: { clock.now() }), makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let initial = try #require(await events.snapshots.last)
        let commands = await transport.commands()

        await transport.emit(command: 4, fields: [42, 0, 0x0e, 0x74])

        #expect(await eventually { await events.snapshots.count == 2 })
        let updated = try #require(await events.snapshots.last)
        #expect(await session.status == .connected(initial.identity))
        #expect(updated.battery == FlowLite84Battery(reportedLevel: 42, charging: false, voltageMillivolts: 3700))
        #expect(updated.batteryReadAt != initial.batteryReadAt)
        #expect(updated.readAt == initial.readAt)
        #expect(updated.lighting == initial.lighting)
        #expect(await transport.commands() == commands)
        #expect(await transport.closes == 0)
        await session.disconnect()
    }

    @Test func invalidOrRejectedUnsolicitedBatteryDoesNotReplaceKnownData() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let initial = try #require(await events.snapshots.last)
        let commands = await transport.commands()
        for fields: [UInt8] in [[101, 0, 0x0e, 0x74], [50, 2, 0x0e, 0x74], [50, 0, 0, 0], [50, 0, 255, 255], [255, 255, 255, 255]] {
            await transport.emit(command: 4, fields: fields)
        }
        await transport.emit(command: 4, status: 1, fields: [42, 0, 0x0e, 0x74])
        await transport.emit(command: 4, fields: [41, 0, 0, 1])
        #expect(await eventually { await events.snapshots.count == 2 })
        let updated = try #require(await events.snapshots.last)
        #expect(updated.battery == FlowLite84Battery(reportedLevel: 41, charging: false, voltageMillivolts: 1))
        #expect(updated.readAt == initial.readAt)
        #expect(await transport.commands() == commands)
        #expect(await session.status == .connected(initial.identity))
        await session.disconnect()
    }

    @Test func solicitedPartialAndUnavailableBatteryFieldsKeepTheirExistingSemantics() async throws {
        let cases: [([UInt8], FlowLite84Battery?, Set<String>)] = [
            ([42, 2, 0x0e, 0x74], FlowLite84Battery(reportedLevel: 42, voltageMillivolts: 3700), ["battery.charging"]),
            ([255, 255, 255, 255], nil, ["battery.reportedLevel", "battery.charging", "battery.voltageMillivolts"]),
        ]
        for (fields, expected, unavailable) in cases {
            let transport = FlowLite84FixtureTransport()
            await transport.setBatteryFields(fields)
            let session = FlowLite84Session(makeTransport: { transport })
            let events = FlowLite84EventRecorder(session.events)
            try await session.connect()
            #expect(await eventually { await events.snapshots.count == 1 })
            let snapshot = try #require(await events.snapshots.last)
            #expect(snapshot.battery == expected)
            #expect(snapshot.batteryReadAt != nil)
            #expect(Set(snapshot.unavailableFields) == unavailable.union(["receiverVersion"]))
            try await session.refreshBattery()
            #expect(await eventually { await events.snapshots.count == 2 })
            let refreshed = try #require(await events.snapshots.last)
            #expect(refreshed.battery == expected)
            #expect(refreshed.batteryReadAt != nil)
            #expect(Set(refreshed.unavailableFields) == Set(snapshot.unavailableFields))
            await session.disconnect()
        }
    }

    @Test func rejectedBatteryReadDoesNotInventUsefulReceivedAtFreshness() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        await transport.reject(commands: [4])
        try await session.refreshBattery()
        #expect(await eventually { await events.snapshots.count == 2 })
        let snapshot = try #require(await events.snapshots.last)
        #expect(snapshot.battery == nil)
        #expect(snapshot.batteryReadAt == nil)
        #expect(snapshot.unavailableFields.contains("battery"))
        await session.disconnect()
    }

    @Test func telemetryDoesNotCompleteOrExtendAnUnrelatedReadDeadline() async throws {
        let transport = FlowLite84FixtureTransport()
        let deadlines = FlowLite84FixtureDeadlines()
        let session = FlowLite84Session(
            timing: FlowLite84Timing(sleep: { _ in try await deadlines.sleep() }),
            makeTransport: { transport }
        )
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let initial = try #require(await events.snapshots.last)
        let commands = await transport.commands()
        await transport.drop(command: 3)
        let refreshing = Task { try await session.refreshBattery() }
        #expect(await eventually { await transport.commands().count == commands.count + 1 })
        #expect(await eventually { await deadlines.activeCount == 1 })
        let started = await deadlines.started
        await transport.emit(command: 4, fields: [42, 0, 0x0e, 0x74])
        await transport.emit(command: 18, status: 1, fields: [2, 0x13])
        await transport.emit(command: 8, address: 8496, count: 2, fields: [10, 0])
        #expect(await eventually { await events.snapshots.count == 2 })
        #expect(await deadlines.started == started)
        #expect(await deadlines.activeCount == 1)
        #expect(await transport.commands().count == commands.count + 1)
        let telemetry = try #require(await events.snapshots.last)
        #expect(telemetry.readAt == initial.readAt)
        #expect(telemetry.battery?.reportedLevel == 42)
        await deadlines.expire()
        await expectFailure(.timeout) { try await refreshing.value }
        #expect(await events.snapshots.count == 2)
        #expect(await transport.closes == 1)
    }

    @Test func lateFirmwareReplyCannotSatisfyBatteryQuery() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.drop(command: 4)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1, 3, 18, 4] })
        await transport.emit(command: 18, fields: [2, 0x13])
        await transport.emit(command: 29, status: 1, fields: [255, 255])
        await transport.emit(command: 4, fields: [42, 0, 0x0e, 0x74])
        try await connecting.value
        #expect(await eventually { await events.snapshots.count == 1 })
        let snapshot = try #require(await events.snapshots.last)
        #expect(snapshot.keyboardVersion == "v1.61")
        #expect(snapshot.battery?.reportedLevel == 42)
        #expect(await transport.commands() == [1, 3, 18, 4, 8, 8, 8, 8, 8])
        await session.disconnect()
    }

    @Test func offCurrentReadAddressesAndCountsDoNotReplaceThePendingScalar() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.drop(command: 8)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands().count == 5 })
        await transport.emit(command: 8, status: 1, address: 8498, count: 2, fields: [1, 0])
        await transport.emit(command: 8, address: 8544, count: 4, fields: [0, 0, 0, 0])
        await transport.emit(command: 8, address: 8496, count: 0x82, fields: [10, 0x4b])
        #expect(await eventually { await transport.commands().count == 6 })
        await transport.emit(command: 8, address: 8498, count: 2, fields: [1, 0x54])
        #expect(await eventually { await transport.commands().count == 7 })
        await transport.emit(command: 8, address: 8500, count: 2, fields: [6, 0x4f])
        #expect(await eventually { await transport.commands().count == 8 })
        await transport.emit(command: 8, address: 9416, count: 2, fields: [1, 0x54])
        #expect(await eventually { await transport.commands().count == 9 })
        await transport.emit(command: 8, address: 8864, count: 4, fields: [0, 2, 3, 0x50])
        try await connecting.value
        #expect(await eventually { await events.snapshots.count == 1 })
        #expect(await events.snapshots.last?.lighting?.mode == 10)
        await session.disconnect()
    }

    @Test func identicalBufferedBatteryReplyDoesNotBypassSendCompletion() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.hold(command: 4)
        let clock = FlowLite84FixtureClock()
        let session = FlowLite84Session(timing: FlowLite84Timing(now: { clock.now() }), makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1, 3, 18, 4] })
        await transport.emit(command: 4, count: 0x80, fields: [87, 1, 0x0f, 0xe3])
        await transport.emit(command: 18, fields: [2, 0x13])
        try await Task.sleep(for: .milliseconds(10))
        #expect(await session.status == .connecting)
        #expect(await events.snapshots.isEmpty)
        #expect(await transport.commands() == [1, 3, 18, 4])
        #expect(clock.now() == Date(timeIntervalSince1970: 1_800_000_001))
        await transport.releaseWrite()
        try await connecting.value
        #expect(await eventually { await events.snapshots.count == 1 })
        #expect(await events.snapshots.last?.batteryReadAt == Date(timeIntervalSince1970: 1_800_000_000))
        await session.disconnect()
    }

    @Test func validBufferedBatteryReplyCannotHideASendFailure() async {
        let transport = FlowLite84FixtureTransport()
        await transport.hold(command: 4)
        await transport.failWrite(command: 4)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1, 3, 18, 4] })
        await transport.emit(command: 4, count: 0x80, fields: [87, 1, 0x0f, 0xe3])
        await transport.releaseWrite()
        await expectFailure(.transport) { try await connecting.value }
        #expect(await events.snapshots.isEmpty)
        #expect(await transport.closes == 1)
    }

    @Test func telemetryDuringInitialAndFullReadsSurvivesCommitWithEqualDates() async throws {
        let transport = FlowLite84FixtureTransport()
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let session = FlowLite84Session(timing: FlowLite84Timing(now: { instant }), makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        await transport.hold(command: 8)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands().count == 5 })
        await transport.emit(command: 4, fields: [42, 0, 0x0e, 0x74])
        await transport.releaseWrite()
        try await connecting.value
        #expect(await eventually { await events.snapshots.count == 1 })
        #expect(await events.snapshots.last?.battery?.reportedLevel == 42)

        await transport.setBatteryLevel(60)
        await transport.hold(command: 8)
        let refreshing = Task { try await session.refresh() }
        #expect(await eventually { await transport.commands().count == 13 })
        await transport.emit(command: 4, fields: [41, 0, 0x0e, 0x74])
        #expect(await eventually { await events.snapshots.count == 2 })
        await transport.releaseWrite()
        try await refreshing.value
        #expect(await eventually { await events.snapshots.count == 3 })
        #expect(await events.snapshots.map { $0.battery?.reportedLevel } == [42, 41, 41])
        #expect(await events.snapshots.allSatisfy { $0.batteryReadAt == instant })
        await session.disconnect()
    }

    @Test func telemetryBurstAroundBatteryBatchCommitKeepsTheLastReceipt() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let initial = try #require(await events.snapshots.last)
        await transport.drop(command: 4)
        let refreshing = Task { try await session.refreshBattery() }
        #expect(await eventually { await transport.commands().count == 11 })
        await transport.emitBatteryBurst(levels: [60, 42, 41])
        try await refreshing.value
        #expect(await eventually { await events.snapshots.last?.battery?.reportedLevel == 41 })
        await transport.emit(command: 18, fields: [1, 0x61])
        try await Task.sleep(for: .milliseconds(10))
        let snapshots = await events.snapshots
        #expect(snapshots.last?.battery?.reportedLevel == 41)
        if let newer = snapshots.firstIndex(where: { $0.battery?.reportedLevel == 41 }) {
            #expect(snapshots[newer...].allSatisfy { $0.battery?.reportedLevel == 41 })
        }
        #expect(snapshots.allSatisfy { $0.readAt == initial.readAt })
        #expect(await transport.commands().count == 11)
        await session.disconnect()
    }

    @Test func batteryBeforeConfirmedIdentityAndFromOldGenerationIsNotPublished() async throws {
        let first = FlowLite84FixtureTransport()
        let second = FlowLite84FixtureTransport()
        await first.hold(command: 1)
        let factory = FlowLite84FixtureFactory([first, second])
        let session = FlowLite84Session(makeTransport: { factory.next() })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await first.commands() == [1] })
        await first.emit(command: 4, fields: [42, 0, 0x0e, 0x74])
        await first.releaseWrite()
        try await connecting.value
        await session.disconnect()
        try await session.connect()
        await first.emit(command: 4, fields: [41, 0, 0x0e, 0x74])
        #expect(await eventually { await events.snapshotGenerations == [1, 2] })
        #expect(await events.snapshots.allSatisfy { $0.battery?.reportedLevel == 87 })
        await session.disconnect()
    }

    @Test func invalidUnsolicitedFramesRemainFatal() async throws {
        let cases: [(Data, FlowLite84ValidationIssue)] = [
            (fixturePacket(command: 8, address: 0, count: 2), .readHeader),
            (fixturePacket(command: 8, address: 8496, count: 4), .readHeader),
            (fixturePacket(command: 254), .unsupportedCommand),
        ]
        var checksum = fixturePacket(command: 4, fields: [42, 0, 0x0e, 0x74])
        checksum[16] &+= 1
        for (packet, issue) in cases + [(checksum, .packetChecksum)] {
            let transport = FlowLite84FixtureTransport()
            let session = FlowLite84Session(makeTransport: { transport })
            let events = FlowLite84EventRecorder(session.events)
            try await session.connect()
            #expect(await eventually { await events.snapshots.count == 1 })
            transport.continuation.yield(packet)
            #expect(await eventually { await session.status == .failed(.invalidResponse(issue)) })
            #expect(await events.snapshots.count == 1)
            #expect(await transport.closes == 1)
        }
    }

    @Test func completedIdentityRepeatDoesNotFailOrSatisfyPendingOnlineQuery() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.drop(command: 3)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1, 3] })

        await transport.emit(command: 1, fields: [0, 0, 0, 0, 1, 1, 0])
        await transport.emit(command: 3, fields: [1])
        do {
            try await connecting.value
        } catch let failure as FlowLite84Failure {
            Issue.record("Completed identity repeat while online query pending failed: \(failure)")
            return
        }

        #expect(await eventually { await events.snapshots.count == 1 })
        let snapshot = try #require(await events.snapshots.last)
        #expect(snapshot.online)
        #expect(snapshot.battery?.reportedLevel == 87)
        #expect(await transport.commands() == [1, 3, 18, 4, 8, 8, 8, 8, 8])
        #expect(await session.status == .connected(snapshot.identity))
        await session.disconnect()
        #expect(await transport.closes == 1)
    }

    @Test func completedIdentityAndOrdinaryRepliesAtIdleDoNotRefresh() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let commands = await transport.commands()

        for _ in 0..<3 { await transport.emit(command: 1, fields: [0, 0, 0, 0, 1, 1, 0]) }
        await transport.emit(command: 3, fields: [1])
        await transport.emit(command: 18, fields: [2, 0x13])
        await transport.emit(command: 29, status: 1, fields: [0xff, 0xff])
        try await Task.sleep(for: .milliseconds(10))

        #expect(await session.status == .connected(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)))
        #expect(await events.snapshots.count == 1)
        #expect(await transport.commands() == commands)
        #expect(await transport.closes == 0)
        await session.disconnect()
    }

    @Test func wrongOrRejectedIdentityRepeatsStillFailPendingOnlineQuery() async {
        let cases: [([UInt8], UInt8)] = [
            ([0, 0, 0, 0, 2, 1, 0], 0), ([0, 0, 0, 0, 1, 2, 0], 0),
            ([0, 0, 0, 0, 1, 1, 1], 0), ([0, 0, 0, 0, 1, 1, 0], 1),
        ]
        for (fields, status) in cases {
            let transport = FlowLite84FixtureTransport()
            await transport.drop(command: 3)
            let session = FlowLite84Session(makeTransport: { transport })
            let events = FlowLite84EventRecorder(session.events)
            let connecting = Task { try await session.connect() }
            #expect(await eventually { await transport.commands() == [1, 3] })
            await transport.emit(command: 1, status: status, fields: fields)
            await expectFailure(.invalidResponse(.replyCommand(expected: 3, received: 1))) { try await connecting.value }
            #expect(await events.snapshots.isEmpty)
            #expect(await transport.closes == 1)
        }
    }

    @Test func batteryTelemetryDoesNotSatisfyPendingOnlineQuery() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.drop(command: 3)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1, 3] })
        await transport.emit(command: 4, fields: [87, 1, 0x0f, 0xe3])
        await transport.emit(command: 18, fields: [1, 0x61])
        try await Task.sleep(for: .milliseconds(10))
        #expect(await session.status == .connecting)
        #expect(await events.snapshots.isEmpty)
        #expect(await transport.commands() == [1, 3])
        await transport.emit(command: 3, fields: [1])
        try await connecting.value
        #expect(await eventually { await events.snapshots.count == 1 })
        #expect(await transport.closes == 0)
        await session.disconnect()
    }

    @Test func completedIdentityRepeatStillRequiresPacketChecksum() async {
        let transport = FlowLite84FixtureTransport()
        await transport.drop(command: 3)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1, 3] })
        var packet = fixturePacket(command: 1, fields: [0, 0, 0, 0, 1, 1, 0])
        packet[16] &+= 1
        transport.continuation.yield(packet)
        await expectFailure(.invalidResponse(.packetChecksum)) { try await connecting.value }
        #expect(await events.snapshots.isEmpty)
        #expect(await transport.closes == 1)
    }

    @Test func explicitRefreshSucceedsWhenReceiverFirmwareStopsRespondingAfterInitialRejection() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.reject(commands: [29])
        let session = FlowLite84Session(timing: FlowLite84Timing(responseTimeout: .milliseconds(30)), makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)

        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let initial = try #require(await events.snapshots.last)
        #expect(initial.online)
        #expect(initial.receiverVersion == nil)
        #expect(initial.unavailableFields == ["receiverVersion"])

        await transport.drop(command: 29)
        do {
            try await session.refresh()
        } catch let failure as FlowLite84Failure {
            Issue.record("Explicit Refresh failed after successful Connect: \(failure)")
            return
        }

        #expect(await eventually { await events.snapshots.count == 2 })
        let refreshed = try #require(await events.snapshots.last)
        #expect(refreshed.online)
        #expect(refreshed.receiverVersion == nil)
        #expect(refreshed.unavailableFields == ["receiverVersion"])
        #expect(refreshed.keyboardVersion == "v1.61")
        #expect(refreshed.battery?.reportedLevel == 87)
        #expect(!(await transport.commands()).contains(29))
        #expect(await session.status == .connected(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)))
        await session.disconnect()
        #expect(await transport.closes == 1)
    }

    @Test func routineConnectAndRefreshSucceedWithoutQueryingSilentReceiverFirmware() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.drop(command: 29)
        let session = FlowLite84Session(timing: FlowLite84Timing(responseTimeout: .milliseconds(30)), makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)

        try await session.connect()
        try await session.refresh()

        #expect(await eventually { await events.snapshots.count == 2 })
        let snapshots = await events.snapshots
        #expect(snapshots.allSatisfy { $0.online && $0.receiverVersion == nil && $0.unavailableFields == ["receiverVersion"] })
        #expect(snapshots.allSatisfy { $0.keyboardVersion == "v1.61" && $0.battery?.reportedLevel == 87 && $0.lighting?.mode == 10 && $0.systemMode == 1 })
        let commands = await transport.commands()
        #expect(!commands.contains(29))
        #expect(commands == [1, 3, 18, 4, 8, 8, 8, 8, 8, 3, 18, 4, 8, 8, 8, 8, 8])
        #expect(await session.status == .connected(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)))
        await session.disconnect()
        #expect(await transport.closes == 1)
    }

    @Test func initializationIsInertAndConnectReadsOnlyTheApprovedSnapshot() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        #expect(await transport.opens == 0)
        #expect(await transport.requests.isEmpty)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let snapshot = try #require(await events.snapshots.last)
        #expect(snapshot.identity.isSupported)
        #expect(snapshot.online)
        #expect(snapshot.keyboardVersion == "v1.61")
        #expect(snapshot.receiverVersion == nil)
        #expect(snapshot.battery == FlowLite84Battery(reportedLevel: 87, charging: true, voltageMillivolts: 4067))
        #expect(snapshot.lighting == FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 3, speedLevel: 2))
        #expect(snapshot.systemMode == 1)
        #expect(snapshot.unavailableFields == ["receiverVersion"])
        let requests = await transport.requests
        #expect(requests.map { $0[1] } == [1, 3, 18, 4, 8, 8, 8, 8, 8])
        for request in requests { try FlowLite84Codec.validateOutput(request) }
        await session.disconnect()
        #expect(await session.status == .disconnected)
        #expect(await transport.closes == 1)
    }

    @Test func offlineSnapshotSkipsKeyboardReadsWithoutFailingTheReceiver() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.setOnline(false)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let snapshot = try #require(await events.snapshots.last)
        #expect(!snapshot.online)
        #expect(snapshot.battery == nil)
        #expect(snapshot.lighting == nil)
        #expect(snapshot.receiverVersion == nil)
        #expect(snapshot.unavailableFields.contains("receiverVersion"))
        #expect(await transport.commands() == [1, 3])
        #expect(await session.status == .connected(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)))
        await session.disconnect()
    }

    @Test func wrongIdentityStopsBeforeStatusQueries() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.setIdentity(FlowLite84Identity(cid: 1, mid: 2, connectionType: 0))
        let session = FlowLite84Session(makeTransport: { transport })
        await expectFailure(.unsupportedDevice) { try await session.connect() }
        #expect(await transport.commands() == [1])
        #expect(await session.status == .failed(.unsupportedDevice))
        #expect(await transport.closes == 1)
    }

    @Test func explicitDisconnectClearsAFailedTerminalStatusWithoutClosingAgain() async {
        let transport = FlowLite84FixtureTransport()
        await transport.setIdentity(FlowLite84Identity(cid: 0, mid: 0, connectionType: 0))
        let session = FlowLite84Session(makeTransport: { transport })
        await expectFailure(.unsupportedDevice) { try await session.connect() }
        #expect(await session.status == .failed(.unsupportedDevice))
        await session.disconnect()
        #expect(await session.status == .disconnected)
        #expect(await transport.closes == 1)
    }

    @Test func explicitDisconnectDuringFailureCleanupOwnsTheFinalStatus() async {
        let transport = FlowLite84FixtureTransport()
        await transport.failWrite(command: 1)
        await transport.holdClose()
        let session = FlowLite84Session(makeTransport: { transport })
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.closes == 1 })
        #expect(await session.status == .disconnecting)
        let release = Task {
            try? await Task.sleep(for: .milliseconds(20))
            await transport.releaseClose()
        }
        await session.disconnect()
        await release.value
        await expectFailure(.transport) { try await connecting.value }
        #expect(await session.status == .disconnected)
        #expect(await transport.closes == 1)
    }

    @Test func validOptionalRejectionsProduceUnavailableFields() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.reject(commands: [4, 18], addresses: [9416])
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let snapshot = try #require(await events.snapshots.last)
        #expect(snapshot.battery == nil)
        #expect(snapshot.keyboardVersion == nil)
        #expect(snapshot.systemMode == nil)
        #expect(Set(snapshot.unavailableFields) == Set(["receiverVersion", "battery", "keyboardVersion", "systemMode"]))
        #expect(snapshot.lighting != nil)
        await session.disconnect()
    }

    @Test func requiredOnlineRejectionFailsTheAttempt() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.reject(commands: [3])
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        await expectFailure(.rejected(command: 3, status: 1)) { try await session.connect() }
        #expect(await events.snapshots.isEmpty)
        #expect(await transport.commands() == [1, 3])
    }

    @Test func optionalTimeoutIsAnAmbiguousFailureWithoutAFreshSnapshotOrRetry() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.drop(command: 4)
        let session = FlowLite84Session(timing: FlowLite84Timing(responseTimeout: .milliseconds(30)), makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        await expectFailure(.timeout) { try await session.connect() }
        #expect(await events.snapshots.isEmpty)
        #expect(await transport.commands() == [1, 3, 18, 4])
        #expect(await transport.closes == 1)
        await transport.emit(command: 4, fields: [50, 0, 15, 0])
        #expect(await session.status == .failed(.timeout))
    }

    @Test func replyAloneCannotSucceedBeforeSendCompletion() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.hold(command: 1)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1] })
        #expect(await session.status == .connecting)
        #expect(await events.snapshots.isEmpty)
        await transport.releaseWrite()
        try await connecting.value
        #expect(await eventually { await events.snapshots.count == 1 })
        await session.disconnect()
    }

    @Test func sendFailureAfterAReplyNeverPublishesSuccess() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.failWrite(command: 1)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        await expectFailure(.transport) { try await session.connect() }
        #expect(await events.snapshots.isEmpty)
        #expect(await transport.commands() == [1])
    }

    @Test func refreshCallsShareOneSerializedBatchAndStatusEventsCoalesceBehindIt() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        await transport.hold(command: 3)
        let first = Task { try await session.refresh() }
        #expect(await eventually { await transport.commands().count == 10 })
        let second = Task { try await session.refresh() }
        for _ in 0..<12 { await transport.emit(command: 10, fields: [0x40]) }
        #expect(await transport.commands().count == 10)
        await transport.releaseWrite()
        try await first.value
        try await second.value
        #expect(await eventually { await events.snapshots.count == 3 })
        #expect(await transport.commands().count == 25)
        #expect(await transport.maximumConcurrentWrites == 1)
        await session.disconnect()
    }

    @Test func batteryRefreshReadsOnlyOnlineAndBatteryAndPreservesFullSnapshotMetadata() async throws {
        let transport = FlowLite84FixtureTransport()
        let clock = FlowLite84FixtureClock()
        let session = FlowLite84Session(
            timing: FlowLite84Timing(now: { clock.now() }),
            makeTransport: { transport }
        )
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let initial = try #require(await events.snapshots.last)
        let initialCommands = await transport.commands()

        await transport.setBatteryLevel(42)
        await transport.setLightingMode(3)
        try await session.refreshBattery()

        #expect(await eventually { await events.snapshots.count == 2 })
        let refreshed = try #require(await events.snapshots.last)
        let refreshedCommands = await transport.commands()
        #expect(Array(refreshedCommands.dropFirst(initialCommands.count)) == [3, 4])
        #expect(refreshed.online)
        #expect(refreshed.battery?.reportedLevel == 42)
        #expect(refreshed.keyboardVersion == initial.keyboardVersion)
        #expect(refreshed.receiverVersion == initial.receiverVersion)
        #expect(refreshed.lighting == initial.lighting)
        #expect(refreshed.systemMode == initial.systemMode)
        #expect(refreshed.readAt == initial.readAt)
        #expect(initial.batteryReadAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(refreshed.batteryReadAt == Date(timeIntervalSince1970: 1_800_000_002))
        #expect(refreshed.unavailableFields == initial.unavailableFields)
        await session.disconnect()
    }

    @Test func batteryRefreshWhenKeyboardIsOfflineSkipsBatteryAndPreservesLastMetadata() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let initial = try #require(await events.snapshots.last)
        let initialCommands = await transport.commands()

        await transport.setOnline(false)
        try await session.refreshBattery()

        #expect(await eventually { await events.snapshots.count == 2 })
        let refreshed = try #require(await events.snapshots.last)
        let refreshedCommands = await transport.commands()
        #expect(Array(refreshedCommands.dropFirst(initialCommands.count)) == [3])
        #expect(!refreshed.online)
        #expect(refreshed.battery == nil)
        #expect(refreshed.keyboardVersion == initial.keyboardVersion)
        #expect(refreshed.receiverVersion == initial.receiverVersion)
        #expect(refreshed.lighting == initial.lighting)
        #expect(refreshed.systemMode == initial.systemMode)
        #expect(refreshed.readAt == initial.readAt)
        #expect(refreshed.batteryReadAt == nil)
        #expect(refreshed.unavailableFields.contains("battery"))
        await session.disconnect()
    }

    @Test func fullRefreshDuringBatteryRefreshQueuesOneFullBatchForAllWaiters() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let initialCommands = await transport.commands()

        await transport.hold(command: 3)
        let firstBatteryRefresh = Task { try await session.refreshBattery() }
        #expect(await eventually { await transport.commands().count == initialCommands.count + 1 })
        let secondBatteryRefresh = Task { try await session.refreshBattery() }
        let fullRefresh = Task { try await session.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.commands().count == initialCommands.count + 1)

        await transport.releaseWrite()
        try await firstBatteryRefresh.value
        try await secondBatteryRefresh.value
        try await fullRefresh.value

        #expect(await eventually { await events.snapshots.count == 3 })
        let refreshedCommands = await transport.commands()
        #expect(Array(refreshedCommands.dropFirst(initialCommands.count)) == [3, 4, 3, 18, 4, 8, 8, 8, 8, 8])
        #expect(await transport.maximumConcurrentWrites == 1)
        await session.disconnect()
    }

    @Test func disconnectDuringBatteryRefreshCancelsTheBatchAndClosesTransport() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        let initialCommands = await transport.commands()

        await transport.hold(command: 3)
        let refreshing = Task { try await session.refreshBattery() }
        #expect(await eventually { await transport.commands().count == initialCommands.count + 1 })
        await session.disconnect()

        await expectFailure(.disconnected) { try await refreshing.value }
        #expect(await transport.closes == 1)
        #expect(await session.status == .disconnected)
    }

    @Test func disconnectDuringAReadCancelsTheAttemptAndReleasesTheHandle() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.hold(command: 1)
        let session = FlowLite84Session(makeTransport: { transport })
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1] })
        await session.disconnect()
        await expectFailure(.disconnected) { try await connecting.value }
        #expect(await session.status == .disconnected)
        #expect(await transport.closes == 1)
        #expect(await transport.commands() == [1])
    }

    @Test func cancellationInvalidatesAnOutstandingQuery() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.drop(command: 1)
        let session = FlowLite84Session(makeTransport: { transport })
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1] })
        connecting.cancel()
        await expectFailure(.cancelled) { try await connecting.value }
        #expect(await eventually { await transport.closes == 1 })
        #expect(await session.status == .failed(.cancelled))
    }

    @Test func reconnectUsesNewGenerationAndIgnoresOldStreamEvents() async throws {
        let first = FlowLite84FixtureTransport()
        let second = FlowLite84FixtureTransport()
        let factory = FlowLite84FixtureFactory([first, second])
        let session = FlowLite84Session(makeTransport: { factory.next() })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        await session.disconnect()
        try await session.connect()
        await first.emit(command: 10, fields: [0x40])
        #expect(await session.generation == 2)
        #expect(await second.commands().count == 9)
        #expect(await eventually { await events.snapshotGenerations == [1, 2] })
        await session.disconnect()
    }

    @Test func invalidSnapshotRepliesPreserveTheirCategoryAndFailBeforePublishing() async throws {
        let cases: [(FlowLite84FixtureTransport.Corruption, FlowLite84ValidationIssue)] = [
            (.address, .readHeader), (.checksum, .packetChecksum),
            (.scalarChecksum, .scalarChecksum), (.effectChecksum, .effectChecksum),
            (.onlineFlag, .onlineFlag), (.replyCommand, .replyCommand(expected: 3, received: 1)),
        ]
        for (corruption, issue) in cases {
            let transport = FlowLite84FixtureTransport()
            await transport.corrupt(corruption)
            let session = FlowLite84Session(makeTransport: { transport })
            let events = FlowLite84EventRecorder(session.events)
            await expectFailure(.invalidResponse(issue)) { try await session.connect() }
            #expect(await events.snapshots.isEmpty)
            #expect(await transport.closes == 1)
        }
    }

    @Test func unknownLightingModeRemainsRawAndDoesNotExpandTheReadRange() async throws {
        let transport = FlowLite84FixtureTransport()
        await transport.setLightingMode(200)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        let snapshot = try #require(await events.snapshots.last)
        #expect(snapshot.lighting?.mode == 200)
        #expect(snapshot.lighting?.brightnessLevel == nil)
        #expect(await transport.commands().count == 8)
        await session.disconnect()
    }

    @Test func transportTerminationInvalidatesTheGeneration() async throws {
            let transport = FlowLite84FixtureTransport()
            let session = FlowLite84Session(makeTransport: { transport })
            try await session.connect()
            transport.continuation.finish(throwing: FlowLite84Failure.transport)
            #expect(await eventually { await session.status == .failed(.transport) })
            #expect(await transport.closes == 1)
    }

    @Test func changedDuplicateReplyBeforeSendCompletionFailsWithItsCategory() async {
        let transport = FlowLite84FixtureTransport()
        await transport.hold(command: 4)
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [1, 3, 18, 4] })
        await transport.emit(command: 4, fields: [42, 1, 0x0f, 0xe3])
        await expectFailure(.invalidResponse(.duplicateReply(command: 4))) { try await connecting.value }
        #expect(await events.snapshots.isEmpty)
        #expect(await transport.closes == 1)
    }

    @Test func invalidNotificationStatusFailsWithoutPublishingAnotherSnapshot() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        let events = FlowLite84EventRecorder(session.events)
        try await session.connect()
        #expect(await eventually { await events.snapshots.count == 1 })
        await transport.emit(command: 10, status: 1, fields: [0x40])
        #expect(await eventually { await session.status == .failed(.invalidResponse(.notificationStatus)) })
        #expect(await events.snapshots.count == 1)
        #expect(await transport.closes == 1)
    }

    @Test func typedTransportValidationFailureSurvivesReaderCleanup() async throws {
        let transport = FlowLite84FixtureTransport()
        let session = FlowLite84Session(makeTransport: { transport })
        try await session.connect()
        transport.continuation.finish(throwing: FlowLite84Failure.invalidResponse(.packetChecksum))
        #expect(await eventually { await session.status == .failed(.invalidResponse(.packetChecksum)) })
        #expect(await transport.closes == 1)
    }
}

private actor FlowLite84FixtureTransport: FlowLite84Transport {
    enum Corruption { case address, checksum, scalarChecksum, effectChecksum, onlineFlag, replyCommand }
    nonisolated let reports: AsyncThrowingStream<Data, Error>
    nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var opens = 0
    private(set) var closes = 0
    private(set) var requests: [Data] = []
    private(set) var maximumConcurrentWrites = 0
    private var concurrentWrites = 0
    private var online = true
    private var batteryLevel: UInt8 = 87
    private var batteryFields: [UInt8]?
    private var identity = FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)
    private var mode: UInt8 = 10
    private var rejectedCommands: Set<UInt8> = []
    private var rejectedAddresses: Set<UInt16> = []
    private var droppedCommand: UInt8?
    private var heldCommand: UInt8?
    private var failedCommand: UInt8?
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var closingHeld = false
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var corruption: Corruption?

    init() {
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        reports = stream.stream
        continuation = stream.continuation
    }

    func open() { opens += 1 }
    func commands() -> [UInt8] { requests.map { $0[1] } }
    func setOnline(_ value: Bool) { online = value }
    func setBatteryLevel(_ value: UInt8) { batteryLevel = value }
    func setBatteryFields(_ value: [UInt8]) { batteryFields = value }
    func setIdentity(_ value: FlowLite84Identity) { identity = value }
    func setLightingMode(_ value: UInt8) { mode = value }
    func reject(commands: Set<UInt8>, addresses: Set<UInt16> = []) { rejectedCommands = commands; rejectedAddresses = addresses }
    func drop(command: UInt8) { droppedCommand = command }
    func hold(command: UInt8) { heldCommand = command }
    func failWrite(command: UInt8) { failedCommand = command }
    func corrupt(_ value: Corruption) { corruption = value }
    func releaseWrite() { heldCommand = nil; heldWrite?.resume(); heldWrite = nil }
    func holdClose() { closingHeld = true }
    func releaseClose() { closingHeld = false; closeWaiter?.resume(); closeWaiter = nil }

    func emit(command: UInt8, status: UInt8 = 0, address: UInt16 = 0, count: UInt8 = 0, fields: [UInt8]) {
        continuation.yield(fixturePacket(command: command, status: status, address: address, count: count, fields: fields))
    }

    func emitBatteryBurst(levels: [UInt8]) {
        for level in levels { emit(command: 4, fields: [level, 0, 0x0e, 0x74]) }
    }

    func write(_ report: Data) async throws {
        try FlowLite84Codec.validateOutput(report)
        concurrentWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
        defer { concurrentWrites -= 1 }
        requests.append(report)
        let payload = Array(report.dropFirst())
        let command = payload[0]
        let address = UInt16(payload[2]) << 8 | UInt16(payload[3])
        if droppedCommand != command {
            var fields: [UInt8]
            switch command {
            case 1: fields = [0, 0, 0, 0, identity.cid, identity.mid, identity.connectionType]
            case 3: fields = [corruption == .onlineFlag ? 2 : online ? 1 : 0]
            case 4: fields = batteryFields ?? [batteryLevel, 1, 0x0f, 0xe3]
            case 18: fields = [1, 0x61]
            case 29: fields = [2, 0x13]
            case 8:
                let value: UInt8
                switch address {
                case 8496: value = mode
                case 8498, 9416: value = 1
                default: value = 6
                }
                fields = payload[4] & 0x7f == 2 ? [value, 0x55 &- value] : [0, 2, 3, 0x50]
                if corruption == .scalarChecksum, address == 8496 { fields[1] = 0 }
                if corruption == .effectChecksum, payload[4] & 0x7f == 4 { fields[3] = 0 }
            default: fields = []
            }
            let rejected = rejectedCommands.contains(command) || rejectedAddresses.contains(address)
            var response = fixturePacket(
                command: corruption == .replyCommand && command == 3 ? 1 : command, status: rejected ? 1 : 0,
                address: corruption == .address && command == 8 ? address + 1 : address,
                count: payload[4], fields: fields
            )
            if corruption == .checksum { response[16] &+= 1 }
            continuation.yield(response)
        }
        if heldCommand == command { await withCheckedContinuation { heldWrite = $0 } }
        if failedCommand == command { throw FlowLite84Failure.transport }
    }

    func close() async {
        closes += 1
        releaseWrite()
        if closingHeld { await withCheckedContinuation { closeWaiter = $0 } }
        continuation.finish()
    }
}

private actor FlowLite84FixtureDeadlines {
    private(set) var started = 0
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    var activeCount: Int { waiters.count }

    func sleep() async throws {
        try Task.checkCancellation()
        started += 1
        let id = started
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func expire() {
        let current = waiters.values
        waiters = [:]
        for waiter in current { waiter.resume() }
    }

    private func cancel(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class FlowLite84FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0

    func now() -> Date {
        lock.withLock {
            defer { readCount += 1 }
            return Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(readCount))
        }
    }
}

private final class FlowLite84FixtureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [FlowLite84FixtureTransport]

    init(_ transports: [FlowLite84FixtureTransport]) { remaining = transports }
    func next() -> FlowLite84FixtureTransport { lock.withLock { remaining.removeFirst() } }
}

private actor FlowLite84EventRecorder {
    private(set) var snapshots: [FlowLite84Snapshot] = []
    private(set) var snapshotGenerations: [UInt64] = []

    init(_ events: AsyncStream<FlowLite84Event>) {
        Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.record(event)
            }
        }
    }

    private func record(_ event: FlowLite84Event) {
        if case .snapshot(let snapshot, let generation) = event {
            snapshots.append(snapshot)
            snapshotGenerations.append(generation)
        }
    }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func expectFailure(_ failure: FlowLite84Failure, operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected a typed status failure") }
    catch { #expect(error as? FlowLite84Failure == failure) }
}
