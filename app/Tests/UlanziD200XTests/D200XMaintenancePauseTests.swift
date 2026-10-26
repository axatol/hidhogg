import Foundation
import Testing
@testable import UlanziD200X

private actor MaintenanceClock {
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
        guard let sleeper = sleepers.removeValue(forKey: id) else { cancelled.insert(id); return }
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

private actor MaintenanceFixtureTransport: D200XTransport {
    nonisolated let reports: AsyncThrowingStream<Data, Error>
    nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var heldQueryWaiter: CheckedContinuation<Void, Error>?
    private var holdNextQueryWrite = false
    private let releaseHeldQueryOnClose: Bool
    private var heldQueryCompletions = 0
    private(set) var writes: [[Data]] = []
    private(set) var closes = 0

    init(releaseHeldQueryOnClose: Bool = true) {
        let stream = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        reports = stream.stream
        continuation = stream.continuation
        self.releaseHeldQueryOnClose = releaseHeldQueryOnClose
    }

    func open() async throws {}

    func write(_ reports: [Data]) async throws {
        guard closes == 0, let frame = reports.first else { throw D200XFailure.disconnected }
        writes.append(reports)
        let command = D200XCommand(frame[2], frame[3])
        guard command == .getBase else { return }

        if holdNextQueryWrite {
            holdNextQueryWrite = false
            try await withCheckedThrowingContinuation { heldQueryWaiter = $0 }
            heldQueryCompletions += 1
            return
        }

        continuation.yield(response(.identity, payload: syntheticIdentity, paddedLength: 1014))
    }

    func close() async {
        closes += 1
        continuation.finish()
        if releaseHeldQueryOnClose {
            heldQueryWaiter?.resume(throwing: D200XFailure.cancelled)
            heldQueryWaiter = nil
        }
    }

    func holdNextQuery() { holdNextQueryWrite = true }

    func releaseHeldQuery() {
        heldQueryWaiter?.resume()
        heldQueryWaiter = nil
    }

    func hasHeldQuery() -> Bool { heldQueryWaiter != nil }
    func completedHeldQueries() -> Int { heldQueryCompletions }

    func commands() -> [D200XCommand] {
        writes.compactMap { reports in
            guard let frame = reports.first else { return nil }
            return D200XCommand(frame[2], frame[3])
        }
    }

    func sendInput() {
        continuation.yield(response(.input, payload: Data([1, 18, 2, 4]), paddedLength: 1014))
    }
}

private actor InputEventMailbox {
    private var input: D200XSessionEvent?

    func capture(_ events: AsyncStream<D200XSessionEvent>) async {
        for await event in events {
            if case .input = event {
                input = event
                return
            }
        }
    }

    func received(_ expected: D200XSessionEvent) -> Bool { input == expected }
}

private actor InertMaintenanceSession: D200XSessionProtocol {
    nonisolated let events = AsyncStream<D200XSessionEvent> { _ in }

    func connect() async throws {}
    func disconnect() async {}
    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws {}
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

struct D200XMaintenancePauseTests {
    @Test func defaultKeepAwakeImplementationReportsUnavailable() async {
        let session = InertMaintenanceSession()
        do {
            try await session.setKeepAwakeEnabled(false)
            Issue.record("inert session accepted keep-awake control")
        } catch {
            #expect(error as? D200XFailure == .unavailable)
        }
    }

    @Test func pausingRetainsConnectionAndReaderWhileSuppressingQueries() async throws {
        let transport = MaintenanceFixtureTransport()
        let clock = MaintenanceClock()
        let session = D200XSession(
            timing: D200XTiming(sleep: { try await clock.sleep($0) }),
            makeTransport: { transport }
        )
        let mailbox = InputEventMailbox()
        let capture = Task { await mailbox.capture(session.events) }
        let input = try D200XInput(payload: Data([1, 18, 2, 4]))

        try await session.connect()
        #expect(await eventually { await clock.count(.seconds(5)) == 1 })
        try await session.setKeepAwakeEnabled(false)
        try await session.setKeepAwakeEnabled(false)
        #expect(await eventually { await clock.count(.seconds(5)) == 0 })

        await clock.advance(.seconds(5))
        await transport.sendInput()
        #expect(await eventually {
            await mailbox.received(.input(input, generation: 1))
        })
        #expect(await transport.commands() == [.getBase])
        #expect(await transport.closes == 0)
        guard case .connected = await session.status else { Issue.record("pause changed the connection status"); return }

        capture.cancel()
        await session.disconnect()
    }

    @Test func resumeIsIdempotentAndStartsOneMaintenanceLoop() async throws {
        let transport = MaintenanceFixtureTransport()
        let clock = MaintenanceClock()
        let session = D200XSession(
            timing: D200XTiming(sleep: { try await clock.sleep($0) }),
            makeTransport: { transport }
        )
        try await session.connect()
        try await session.setKeepAwakeEnabled(false)
        #expect(await eventually { await clock.count(.seconds(5)) == 0 })
        try await session.setKeepAwakeEnabled(true)
        try await session.setKeepAwakeEnabled(true)

        #expect(await eventually { await clock.count(.seconds(5)) == 1 })
        await clock.advance(.seconds(5))
        #expect(await eventually { await transport.commands().count == 2 })
        #expect(await clock.count(.seconds(5)) == 1)
        #expect(await clock.count(.seconds(3)) == 0)

        await clock.advance(.seconds(5))
        #expect(await eventually { await transport.commands().count == 3 })
        #expect(await clock.count(.seconds(5)) == 1)
        guard case .connected = await session.status else { Issue.record("resume lost the connection"); return }
        await session.disconnect()
    }

    @Test func delayedQueryCompletionCannotArmDeadlineWhilePaused() async throws {
        let transport = MaintenanceFixtureTransport()
        let clock = MaintenanceClock()
        let session = D200XSession(
            timing: D200XTiming(sleep: { try await clock.sleep($0) }),
            makeTransport: { transport }
        )
        try await session.connect()
        await transport.holdNextQuery()
        #expect(await eventually { await clock.count(.seconds(5)) == 1 })
        await clock.advance(.seconds(5))
        #expect(await eventually { await transport.hasHeldQuery() })
        #expect(await transport.commands() == [.getBase, .getBase])

        try await session.setKeepAwakeEnabled(false)
        await transport.releaseHeldQuery()
        #expect(await eventually { await transport.completedHeldQueries() == 1 })
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await clock.count(.seconds(3)) == 0)
        await clock.advance(.seconds(3))
        try? await Task.sleep(for: .milliseconds(10))

        guard case .connected = await session.status else { Issue.record("paused query completion failed the connection"); return }
        #expect(await transport.closes == 0)
        #expect(await transport.commands() == [.getBase, .getBase])
        await session.disconnect()
    }

    @Test func reconnectResetsPauseAndRejectsAStaleQueryCompletion() async throws {
        let first = MaintenanceFixtureTransport(releaseHeldQueryOnClose: false)
        let second = MaintenanceFixtureTransport()
        let factory = MaintenanceTransportFactory([first, second])
        let clock = MaintenanceClock()
        let session = D200XSession(
            timing: D200XTiming(sleep: { try await clock.sleep($0) }),
            makeTransport: { factory.next() }
        )
        try await session.connect()
        await first.holdNextQuery()
        #expect(await eventually { await clock.count(.seconds(5)) == 1 })
        await clock.advance(.seconds(5))
        #expect(await eventually { await first.hasHeldQuery() })

        try await session.setKeepAwakeEnabled(false)
        await session.disconnect()
        try await session.connect()
        #expect(await eventually { await second.commands() == [.getBase] })
        #expect(await eventually { await clock.count(.seconds(5)) == 1 })

        await first.releaseHeldQuery()
        #expect(await eventually { await first.completedHeldQueries() == 1 })
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await clock.count(.seconds(3)) == 0)
        guard case .connected = await session.status else { Issue.record("stale query failed the replacement connection"); return }

        await clock.advance(.seconds(5))
        #expect(await eventually { await second.commands().count == 2 })
        guard case .connected = await session.status else { Issue.record("reconnect retained the paused state"); return }
        await session.disconnect()
    }
}

private final class MaintenanceTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [MaintenanceFixtureTransport]

    init(_ transports: [MaintenanceFixtureTransport]) { self.transports = transports }

    func next() -> any D200XTransport { lock.withLock { transports.removeFirst() } }
}
