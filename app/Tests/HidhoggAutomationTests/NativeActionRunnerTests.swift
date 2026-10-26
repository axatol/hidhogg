import Foundation
import HidhoggDomain
import Testing
@testable import HidhoggAutomation

struct NativeActionRunnerTests {
    @Test func nativeLaneRunsAlongsideHeldProcessAndClearRetainsBothQueues() async throws {
        let processRunner = GatedProcessRunner()
        let nativeRunner = GatedNativeRunner()
        let runner = ConfiguredActionRunner(processRunner: processRunner, nativeRunner: nativeRunner)

        _ = try await runner.invoke(id: "script-one", action: .init(executable: "/synthetic/slow-script"))
        #expect(await eventually { await processRunner.startedCount == 1 })
        _ = try await runner.invoke(id: "native-one", nativeAction: .init(kind: .bell))
        #expect(await eventually { await nativeRunner.startedCount == 1 })
        _ = try await runner.invoke(id: "script-two", action: .init(executable: "/synthetic/second-script"))
        _ = try await runner.invoke(id: "native-two", nativeAction: .init(kind: .volume, volume: .up))
        #expect(await runner.queuedCount == 2)

        await runner.clearHistory()

        #expect(await runner.history().isEmpty)
        #expect(await runner.queuedCount == 2)
        #expect(await runner.isStopped == false)
        #expect(await processRunner.completedCount == 0)
        #expect(await nativeRunner.completedCount == 0)

        await nativeRunner.finish(.init(status: .succeeded))
        #expect(await eventually { await nativeRunner.startedCount == 2 })
        #expect(await processRunner.startedCount == 1)
        await nativeRunner.finish(.init(status: .failed, failureMessage: "synthetic failure"))
        #expect(await eventually { await nativeRunner.completedCount == 2 })
        #expect(await runner.history().isEmpty)

        await processRunner.finish(.init(status: .succeeded, exitCode: 0))
        #expect(await eventually { await processRunner.startedCount == 2 })
        await processRunner.finish(.init(status: .succeeded, exitCode: 0))
        #expect(await eventually { await processRunner.completedCount == 2 })
        #expect(await runner.history().isEmpty)

        await runner.stop()
    }

    @Test func stopCancelsActiveAndQueuedNativeAndProcessActions() async throws {
        let processRunner = GatedProcessRunner()
        let nativeRunner = GatedNativeRunner()
        let runner = ConfiguredActionRunner(processRunner: processRunner, nativeRunner: nativeRunner)

        _ = try await runner.invoke(id: "script-active", action: .init(executable: "/synthetic/active-script"))
        _ = try await runner.invoke(id: "native-active", nativeAction: .init(kind: .bell))
        for index in 0..<4 {
            _ = try await runner.invoke(id: "script-queued-\(index)", action: .init(executable: "/synthetic/queued-script"))
            _ = try await runner.invoke(id: "native-queued-\(index)", nativeAction: .init(kind: .volume, volume: .mute))
        }
        #expect(await eventually {
            let processStarted = await processRunner.startedCount == 1
            let nativeStarted = await nativeRunner.startedCount == 1
            return processStarted && nativeStarted
        })
        #expect(await runner.queuedCount == 8)
        await #expect(throws: ConfiguredActionError.busy) {
            try await runner.invoke(id: "queue-overflow", nativeAction: .init(kind: .bell))
        }

        await runner.stop()

        let records = await runner.history()
        #expect(await runner.isStopped)
        #expect(await runner.queuedCount == 0)
        #expect(records.count == 10)
        #expect(records.allSatisfy { $0.status == .cancelled && $0.finishedAt != nil })
        #expect(await processRunner.startedCount == 1)
        #expect(await nativeRunner.startedCount == 1)
        await #expect(throws: ConfiguredActionError.stopped) {
            try await runner.invoke(id: "after-stop", nativeAction: .init(kind: .bell))
        }
    }

    @Test func nativeHistoryCapturesTriggerMetadataWithoutActionPayload() async throws {
        let nativeRunner = RecordingNativeRunner()
        let runner = ConfiguredActionRunner(nativeRunner: nativeRunner)
        let action = NativeAction(kind: .deckNotification, topic: "private.synthetic", text: "private payload", ttlSeconds: 60)
        let trigger = ConfiguredActionTrigger(kind: .device, profile: "com.example.Editor", control: "key0")

        let executionID = try await runner.invoke(id: "notify-action", nativeAction: action, trigger: trigger)
        #expect(await eventually { await runner.history().first?.status == .succeeded })

        let records = await runner.history()
        #expect(records.map(\.executionID) == [executionID])
        #expect(records.first?.trigger == trigger)
        #expect(await nativeRunner.actions == [action])
        #expect(await nativeRunner.triggers == [trigger])

        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(encoded.contains("com.example.Editor"))
        #expect(encoded.contains("key0"))
        #expect(!encoded.contains("private.synthetic"))
        #expect(!encoded.contains("private payload"))
        #expect(!encoded.contains("ttl_seconds"))
        await runner.stop()
    }

    @Test func queuedNativeActionKeepsItsOriginalTrigger() async throws {
        let nativeRunner = GatedNativeRunner()
        let runner = ConfiguredActionRunner(nativeRunner: nativeRunner)
        let firstTrigger = ConfiguredActionTrigger(
            kind: .device,
            profile: "com.example.Editor",
            control: "key0",
            sessionEpoch: 4,
            applicationID: "com.example.Editor"
        )
        let secondTrigger = ConfiguredActionTrigger(
            kind: .device,
            profile: "com.example.Browser",
            control: "key1",
            sessionEpoch: 5,
            applicationID: "com.example.Browser"
        )

        _ = try await runner.invoke(id: "first-native", nativeAction: .init(kind: .bell), trigger: firstTrigger)
        #expect(await eventually { await nativeRunner.startedCount == 1 })
        _ = try await runner.invoke(id: "queued-native", nativeAction: .init(kind: .volume, volume: .up), trigger: secondTrigger)
        #expect(await runner.queuedCount == 1)
        #expect(await nativeRunner.triggers == [firstTrigger])

        await nativeRunner.finish(.init(status: .succeeded))
        #expect(await eventually { await nativeRunner.startedCount == 2 })
        #expect(await nativeRunner.triggers == [firstTrigger, secondTrigger])
        let records = await runner.history()
        #expect(records.compactMap(\.trigger) == [firstTrigger, secondTrigger])
        let encodedHistory = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(encodedHistory.contains("session_epoch"))
        #expect(encodedHistory.contains("application_id"))

        await nativeRunner.finish(.init(status: .succeeded))
        #expect(await eventually { await runner.history().allSatisfy { $0.status == .succeeded } })
        await runner.stop()
    }
}

private actor GatedProcessRunner: ConfiguredProcessRunning {
    private var continuation: CheckedContinuation<ConfiguredProcessResult, Never>?
    private(set) var actions: [ConfiguredExecutable] = []
    private(set) var completedCount = 0
    var startedCount: Int { actions.count }

    func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult {
        actions.append(action)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConfiguredProcessResult, Never>) in
                if Task.isCancelled { continuation.resume(returning: .init(status: .cancelled)) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.finish(.init(status: .cancelled)) }
        }
        completedCount += 1
        return result
    }

    func finish(_ result: ConfiguredProcessResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor GatedNativeRunner: ConfiguredNativeActionRunning {
    private var continuation: CheckedContinuation<ConfiguredProcessResult, Never>?
    private(set) var actions: [NativeAction] = []
    private(set) var triggers = [ConfiguredActionTrigger?]()
    private(set) var completedCount = 0
    var startedCount: Int { actions.count }

    func run(_ action: NativeAction) async -> ConfiguredProcessResult {
        await run(action, trigger: nil)
    }

    func run(_ action: NativeAction, trigger: ConfiguredActionTrigger?) async -> ConfiguredProcessResult {
        actions.append(action)
        triggers.append(trigger)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConfiguredProcessResult, Never>) in
                if Task.isCancelled { continuation.resume(returning: .init(status: .cancelled)) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { await self.finish(.init(status: .cancelled)) }
        }
        completedCount += 1
        return result
    }

    func finish(_ result: ConfiguredProcessResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor RecordingNativeRunner: ConfiguredNativeActionRunning {
    private(set) var actions: [NativeAction] = []
    private(set) var triggers = [ConfiguredActionTrigger?]()

    func run(_ action: NativeAction) async -> ConfiguredProcessResult {
        await run(action, trigger: nil)
    }

    func run(_ action: NativeAction, trigger: ConfiguredActionTrigger?) async -> ConfiguredProcessResult {
        actions.append(action)
        triggers.append(trigger)
        return .init(status: .succeeded)
    }
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
