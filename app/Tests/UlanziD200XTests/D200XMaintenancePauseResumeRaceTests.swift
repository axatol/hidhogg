import Foundation
import Testing
@testable import UlanziD200X

private actor ResumeMaintenanceClock {
    private struct Sleeper {
        let duration: Duration
        let waiter: CheckedContinuation<Void, Error>
    }

    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil || Task.isCancelled {
                    waiter.resume(throwing: CancellationError())
                    return
                }
                sleepers[id] = Sleeper(duration: duration, waiter: waiter)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else {
            cancelled.insert(id)
            return
        }
        sleeper.waiter.resume(throwing: CancellationError())
    }

    func count(_ duration: Duration) -> Int {
        sleepers.values.filter { $0.duration == duration }.count
    }

    func advance(_ duration: Duration) {
        let matching = sleepers.filter { $0.value.duration == duration }
        for (id, sleeper) in matching {
            sleepers.removeValue(forKey: id)
            sleeper.waiter.resume()
        }
    }
}

private actor ResumeMaintenanceTransport: D200XTransport {
    nonisolated let reports: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var holdNextQuery = false
    private var heldQuery: CheckedContinuation<Void, Error>?
    private(set) var failedHeldQueries = 0
    private(set) var writes = [[Data]]()
    private(set) var closes = 0

    init() {
        let stream = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        reports = stream.stream
        continuation = stream.continuation
    }

    func open() async throws {}

    func write(_ reports: [Data]) async throws {
        guard closes == 0, let frame = reports.first else { throw D200XFailure.disconnected }
        writes.append(reports)
        let command = D200XCommand(frame[2], frame[3])
        guard command == .getBase else { return }

        if holdNextQuery {
            holdNextQuery = false
            do {
                try await withCheckedThrowingContinuation { heldQuery = $0 }
            } catch {
                failedHeldQueries += 1
                throw error
            }
            return
        }

        continuation.yield(response(.identity, payload: syntheticIdentity, paddedLength: 1014))
    }

    func close() async {
        closes += 1
        continuation.finish()
        heldQuery?.resume(throwing: D200XFailure.cancelled)
        heldQuery = nil
    }

    func holdNextMaintenanceQuery() {
        holdNextQuery = true
    }

    func failHeldMaintenanceQuery() {
        heldQuery?.resume(throwing: D200XFailure.cancelled)
        heldQuery = nil
    }

    func hasHeldMaintenanceQuery() -> Bool {
        heldQuery != nil
    }

    func commands() -> [D200XCommand] {
        writes.compactMap { reports in
            guard let frame = reports.first else { return nil }
            return D200XCommand(frame[2], frame[3])
        }
    }
}

private func eventuallyResumeMaintenance(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

struct D200XMaintenancePauseResumeRaceTests {
    @Test func cancelledHeldQueryCannotStopOrDuplicateResumedMaintenanceLoop() async throws {
        let transport = ResumeMaintenanceTransport()
        let clock = ResumeMaintenanceClock()
        let session = D200XSession(
            timing: D200XTiming(sleep: { try await clock.sleep($0) }),
            makeTransport: { transport }
        )
        try await session.connect()
        await transport.holdNextMaintenanceQuery()
        #expect(await eventuallyResumeMaintenance { await clock.count(.seconds(5)) == 1 })

        await clock.advance(.seconds(5))
        #expect(await eventuallyResumeMaintenance { await transport.hasHeldMaintenanceQuery() })
        #expect(await transport.commands() == [.getBase, .getBase])

        try await session.setKeepAwakeEnabled(false)
        #expect(await eventuallyResumeMaintenance { await clock.count(.seconds(5)) == 0 })
        try await session.setKeepAwakeEnabled(true)
        #expect(await eventuallyResumeMaintenance { await clock.count(.seconds(5)) == 1 })
        await transport.failHeldMaintenanceQuery()
        #expect(await eventuallyResumeMaintenance { await transport.failedHeldQueries == 1 })
        #expect(await transport.closes == 0)
        guard case .connected = await session.status else {
            Issue.record("cancelled pre-pause query stopped the resumed session")
            return
        }

        await clock.advance(.seconds(5))
        #expect(await eventuallyResumeMaintenance {
            let commands = await transport.commands()
            let querySleeps = await clock.count(.seconds(5))
            return commands.count == 3 && querySleeps == 1
        })

        try await session.setKeepAwakeEnabled(false)
        #expect(await eventuallyResumeMaintenance { await clock.count(.seconds(5)) == 0 })
        try await session.setKeepAwakeEnabled(true)
        #expect(await eventuallyResumeMaintenance { await clock.count(.seconds(5)) == 1 })
        await clock.advance(.seconds(5))
        let fourthQueryStarted = await eventuallyResumeMaintenance {
            await transport.commands().count >= 4
        }
        let commandsAfterSecondResume = await transport.commands()
        let querySleepsAfterSecondResume = await clock.count(.seconds(5))
        #expect(fourthQueryStarted, "The resumed loop did not issue its next GETBASE query.")
        #expect(commandsAfterSecondResume.count == 4, "Expected one GETBASE query after the second resume.")
        #expect(querySleepsAfterSecondResume == 1, "Expected exactly one active maintenance loop after the second resume.")
        #expect(await clock.count(.seconds(3)) == 0)
        guard case .connected = await session.status else {
            Issue.record("repeated pause and resume lost the maintenance connection")
            return
        }

        await session.disconnect()
        #expect(await transport.closes == 1)
    }
}
