import Foundation
import HidhoggDomain
import Testing
@testable import HidhoggAutomation

struct ConfiguredActionRunnerTests {
    @Test func admissionIsOneActiveAndEightQueuedAndStopCancelsOwnedWork() async throws {
        let fake = ControlledProcessRunner()
        let runner = ConfiguredActionRunner(processRunner: fake)
        let action = ConfiguredExecutable(executable: "/synthetic/action", arguments: ["literal; no shell", "$(no-execution)"])
        for index in 0..<9 { _ = try await runner.invoke(id: "action-\(index)", action: action) }
        await #expect(throws: ConfiguredActionError.busy) { try await runner.invoke(id: "overflow", action: action) }
        #expect(await runner.queuedCount == 8)
        #expect(await eventually { await fake.startedCount == 1 })
        #expect(await fake.actions == [action])

        await runner.stop()

        let records = await runner.history()
        #expect(records.count == 9)
        #expect(records.allSatisfy { $0.status == .cancelled && $0.finishedAt != nil })
        #expect(await fake.startedCount == 1)
        await #expect(throws: ConfiguredActionError.stopped) { try await runner.invoke(id: "after-stop", action: action) }
        var statuses: [ConfiguredActionStatus] = []
        for await event in runner.events { statuses.append(event.status) }
        #expect(statuses.contains(.running))
        #expect(statuses.filter { $0 == .cancelled }.count == 9)
    }

    @Test func completionStartsNextInOrderAndDoesNotRetryFailures() async throws {
        let fake = ControlledProcessRunner()
        let runner = ConfiguredActionRunner(processRunner: fake)
        let first = ConfiguredExecutable(executable: "/synthetic/first")
        let second = ConfiguredExecutable(executable: "/synthetic/second")
        _ = try await runner.invoke(id: "first", action: first)
        _ = try await runner.invoke(id: "second", action: second)
        #expect(await eventually { await fake.startedCount == 1 })
        await fake.finish(.init(status: .timedOut))
        #expect(await eventually { await fake.startedCount == 2 })
        #expect(await fake.actions == [first, second])
        await fake.finish(.init(status: .failed, exitCode: 7))
        #expect(await eventually { await runner.history().last?.status == .failed })
        let records = await runner.history()
        #expect(records.map(\.status) == [.timedOut, .failed])
        #expect(records.last?.exitCode == 7)
        #expect(await fake.startedCount == 2)
        await runner.stop()
    }

    @Test func clearHistoryDoesNotCancelRunningOrQueuedActions() async throws {
        let fake = ControlledProcessRunner()
        let runner = ConfiguredActionRunner(processRunner: fake)
        let first = ConfiguredExecutable(executable: "/synthetic/first")
        let second = ConfiguredExecutable(executable: "/synthetic/second")

        _ = try await runner.invoke(id: "first", action: first)
        _ = try await runner.invoke(id: "second", action: second)
        #expect(await eventually { await fake.startedCount == 1 })
        #expect(await runner.history().map(\.status) == [.running, .queued])

        await runner.clearHistory()

        #expect(await runner.history().isEmpty)
        #expect(await runner.queuedCount == 1)
        #expect(await runner.isStopped == false)

        await fake.finish(.init(status: .succeeded, exitCode: 0))
        #expect(await eventually { await fake.startedCount == 2 })
        #expect(await runner.history().isEmpty)
        await fake.finish(.init(status: .succeeded, exitCode: 0))
        #expect(await eventually { await fake.completedCount == 2 })
        #expect(await runner.history().isEmpty)
        #expect(await runner.isStopped == false)

        await runner.stop()
    }

    @Test func historyAttributesTriggerMetadataWithoutCommandOrOutputData() async throws {
        let runner = ConfiguredActionRunner(processRunner: ImmediateProcessRunner())
        let action = ConfiguredExecutable(
            executable: "/synthetic/private-script",
            arguments: ["private-argument", "synthetic-output-is-not-history"]
        )
        let deviceTrigger = ConfiguredActionTrigger(kind: .device, profile: "com.example.Editor", control: "key0")
        let apiTrigger = ConfiguredActionTrigger(kind: .localAPI)

        let deviceExecutionID = try await runner.invoke(id: "device-action", action: action, trigger: deviceTrigger)
        let apiExecutionID = try await runner.invoke(id: "api-action", action: action, trigger: apiTrigger)
        #expect(await eventually {
            let records = await runner.history()
            return records.count == 2 && records.allSatisfy { $0.status == .succeeded }
        })

        let records = await runner.history()
        #expect(records.map(\.executionID) == [deviceExecutionID, apiExecutionID])
        #expect(records.compactMap(\.trigger) == [deviceTrigger, apiTrigger])
        #expect(records.allSatisfy { $0.trigger != nil })

        let encodedData = try JSONEncoder().encode(records)
        let encoded = String(decoding: encodedData, as: UTF8.self)
        let json = try JSONSerialization.jsonObject(with: encodedData)
        let serializedRecords = try #require(json as? [[String: Any]])
        let serializedDeviceTrigger = try #require(serializedRecords[0]["trigger"] as? [String: Any])
        let serializedAPITrigger = try #require(serializedRecords[1]["trigger"] as? [String: Any])

        #expect(Set(serializedDeviceTrigger.keys) == Set(["kind", "profile", "control"]))
        #expect(serializedDeviceTrigger["kind"] as? String == "device")
        #expect(serializedDeviceTrigger["profile"] as? String == "com.example.Editor")
        #expect(serializedDeviceTrigger["control"] as? String == "key0")
        #expect(Set(serializedAPITrigger.keys) == Set(["kind"]))
        #expect(serializedAPITrigger["kind"] as? String == "localAPI")
        #expect(serializedRecords.allSatisfy {
            $0["output"] == nil && $0["stdout"] == nil && $0["stderr"] == nil
                && $0["executable"] == nil && $0["arguments"] == nil
        })
        #expect(!encoded.contains("/synthetic/private-script"))
        #expect(!encoded.contains("private-argument"))
        #expect(!encoded.contains("synthetic-output-is-not-history"))

        await runner.stop()
    }

    @Test func historyIsBoundedAndContainsOnlyMetadata() async throws {
        let runner = ConfiguredActionRunner(processRunner: ImmediateProcessRunner())
        let action = ConfiguredExecutable(executable: "/synthetic/private-path", arguments: ["private-argument"])
        for index in 0..<105 {
            let id = try await runner.invoke(id: "action-\(index)", action: action)
            #expect(await eventually { await runner.history().last.map { $0.executionID == id && $0.status == .succeeded } ?? false })
        }
        let records = await runner.history()
        #expect(records.count == 100)
        #expect(records.first?.actionID == "action-5")
        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        #expect(!encoded.contains("private-path"))
        #expect(!encoded.contains("private-argument"))
        _ = try AutomationValue.encoding(records)
        await runner.stop()
    }

    @Test func invalidInputIsRejectedBeforeFakeExecution() async {
        let fake = ControlledProcessRunner()
        let runner = ConfiguredActionRunner(processRunner: fake)
        await #expect(throws: ConfiguredActionError.invalidIdentifier) {
            try await runner.invoke(id: "../invalid", action: ConfiguredExecutable(executable: "/synthetic/action"))
        }
        await #expect(throws: (any Error).self) {
            try await runner.invoke(id: "valid", action: ConfiguredExecutable(executable: "relative"))
        }
        await #expect(throws: (any Error).self) {
            try await runner.invoke(id: "valid", action: ConfiguredExecutable(executable: "/synthetic/action", timeoutSeconds: 61))
        }
        #expect(await fake.startedCount == 0)
        #expect(await runner.history().isEmpty)
        await runner.stop()
    }
}

private actor ControlledProcessRunner: ConfiguredProcessRunning {
    private var continuation: CheckedContinuation<ConfiguredProcessResult, Never>?
    private(set) var actions: [ConfiguredExecutable] = []
    private(set) var completedCount = 0
    var startedCount: Int { actions.count }

    func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult {
        actions.append(action)
        let result: ConfiguredProcessResult = await withTaskCancellationHandler {
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

private struct ImmediateProcessRunner: ConfiguredProcessRunning {
    func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult { .init(status: .succeeded, exitCode: 0) }
}

private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
