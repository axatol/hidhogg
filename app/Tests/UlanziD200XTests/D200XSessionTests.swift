import Foundation
import Testing
@testable import UlanziD200X

private actor TestClock {
    struct Sleeper {
        let duration: Duration
        let waiter: CheckedContinuation<Void, Error>
    }
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil || Task.isCancelled { waiter.resume(throwing: CancellationError()); return }
                sleepers[id] = Sleeper(duration: duration, waiter: waiter)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { cancelled.insert(id); return }
        sleeper.waiter.resume(throwing: CancellationError())
    }

    func count(_ duration: Duration) -> Int { sleepers.values.filter { $0.duration == duration }.count }

    func advance(_ duration: Duration) {
        let matching = sleepers.filter { $0.value.duration == duration }
        for (id, sleeper) in matching {
            sleepers.removeValue(forKey: id)
            sleeper.waiter.resume()
        }
    }
}

private actor FixtureTransport: D200XTransport {
    nonisolated let reports: AsyncThrowingStream<Data, Error>
    nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var writes: [[Data]] = []
    private(set) var opens = 0
    private(set) var closes = 0
    var respondToQuery = true
    var identity = syntheticIdentity
    var openFailure: D200XFailure?
    private var pauseOpen = false
    private var openWaiter: CheckedContinuation<Void, Error>?
    private var pausePage = false
    private var pageWaiter: CheckedContinuation<Void, Error>?
    private var pauseFont = false
    private var fontWaiter: CheckedContinuation<Void, Error>?
    private var pageInFlight = false
    private var queueQueriesBehindPage = false
    private var queuedQueries: [CheckedContinuation<Void, Error>] = []

    init() {
        let stream = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(256))
        reports = stream.stream
        continuation = stream.continuation
    }

    func open() async throws {
        opens += 1
        if let openFailure { throw openFailure }
        if pauseOpen { try await withCheckedThrowingContinuation { openWaiter = $0 } }
    }

    func write(_ reports: [Data]) async throws {
        guard closes == 0 else { throw D200XFailure.disconnected }
        if reports.first?[3] == 3, pageInFlight, queueQueriesBehindPage {
            try await withCheckedThrowingContinuation { queuedQueries.append($0) }
        }
        writes.append(reports)
        if reports.first?[3] == 1, pausePage {
            pageInFlight = true
            try await withCheckedThrowingContinuation { pageWaiter = $0 }
            pageInFlight = false
            let queries = queuedQueries
            queuedQueries.removeAll()
            for query in queries { query.resume() }
        }
        if reports.first?[3] == 11, pauseFont {
            try await withCheckedThrowingContinuation { fontWaiter = $0 }
        }
        if reports.first?[2] == 0, reports.first?[3] == 3, respondToQuery {
            continuation.yield(response(.identity, payload: identity, paddedLength: 1014))
        }
    }

    func close() {
        guard closes == 0 else { return }
        closes += 1
        openWaiter?.resume(throwing: D200XFailure.cancelled)
        openWaiter = nil
        pageWaiter?.resume(throwing: D200XFailure.cancelled)
        pageWaiter = nil
        fontWaiter?.resume(throwing: D200XFailure.cancelled)
        fontWaiter = nil
        for query in queuedQueries { query.resume(throwing: D200XFailure.cancelled) }
        queuedQueries.removeAll()
        continuation.finish()
    }

    func configure(respond: Bool, identity: Data = syntheticIdentity) {
        respondToQuery = respond
        self.identity = identity
    }

    func fail(_ failure: D200XFailure) { continuation.finish(throwing: failure) }
    func suspendOpen() { pauseOpen = true }
    func suspendPage(queueQueries: Bool = false) { pausePage = true; queueQueriesBehindPage = queueQueries }
    func suspendFont() { pauseFont = true }
    func releasePage() { pageWaiter?.resume(); pageWaiter = nil }
    func queuedQueryCount() -> Int { queuedQueries.count }
    func commands() -> [D200XCommand] { writes.map { D200XCommand($0[0][2], $0[0][3]) } }
}

private final class FixtureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [FixtureTransport]

    init(_ transports: [FixtureTransport]) { self.transports = transports }
    func next() -> FixtureTransport { lock.withLock { transports.removeFirst() } }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

struct D200XSessionTests {
    @Test func connectIdentityMaintenanceAndPageCommands() async throws {
        let transport = FixtureTransport()
        let clock = TestClock()
        let session = D200XSession(timing: D200XTiming(sleep: { try await clock.sleep($0) }), makeTransport: { transport })
        try await session.connect()
        guard case .connected(let identity) = await session.status else { Issue.record("missing connected identity"); return }
        #expect(identity.model == "A045")
        #expect(await transport.commands() == [.getBase])
        #expect(await eventually { await clock.count(.seconds(5)) == 1 })
        await clock.advance(.seconds(5))
        #expect(await eventually { await transport.commands().count == 2 })
        let page = D200XPage(slots: ["0_0": D200XSlot(image: syntheticPNG)])
        try await session.applyPage(page)
        try await session.applyPage(page, update: .incremental)
        #expect(await transport.commands() == [.getBase, .getBase, D200XCommand(0, 1), D200XCommand(0, 13)])
        transport.continuation.yield(response(.fontRequest, payload: Data()))
        #expect(await eventually { await transport.commands().last == D200XCommand(0, 11) })
        let fontReports = await transport.writes.last!
        let fontBytes = fontReports.reduce(into: Data()) { $0.append($1) }
        #expect(String(decoding: fontBytes, as: UTF8.self).contains("Source Han Sans SC"))
        await session.disconnect()
        #expect(await session.status == .disconnected)
        #expect(await transport.closes == 1)
        await clock.advance(.seconds(5))
        #expect(await transport.commands().count == 5)
    }

    @Test func failedIdentityClosesAndFreshReconnectUsesNewGeneration() async throws {
        let first = FixtureTransport()
        await first.configure(respond: true, identity: Data(#"{"SerialNumber":"01000A04500000000"}"#.utf8))
        let second = FixtureTransport()
        let factory = FixtureFactory([first, second])
        let session = D200XSession(makeTransport: { factory.next() })
        do { try await session.connect(); Issue.record("unsupported model connected") }
        catch { #expect(error as? D200XFailure == .unsupportedDevice) }
        #expect(await eventually { await first.closes == 1 })
        #expect(await eventually { await session.status == .failed(.unsupportedDevice) })
        try await session.connect()
        #expect(await session.generation == 2)
        #expect(await second.opens == 1)
        first.continuation.yield(response(.input, payload: Data([1, 0, 1, 1]), paddedLength: 1014))
        #expect(await session.generation == 2)
        await session.disconnect()
    }

    @Test func maintenanceMissingReplyFailsWithoutRendering() async throws {
        let transport = FixtureTransport()
        let clock = TestClock()
        let session = D200XSession(timing: D200XTiming(sleep: { try await clock.sleep($0) }), makeTransport: { transport })
        try await session.connect()
        await transport.configure(respond: false)
        #expect(await eventually { await clock.count(.seconds(5)) == 1 })
        await clock.advance(.seconds(5))
        #expect(await eventually { await transport.commands().count == 2 })
        #expect(await eventually { await clock.count(.seconds(3)) == 1 })
        await clock.advance(.seconds(3))
        #expect(await eventually { await session.status == .failed(.timeout) })
        #expect(await transport.closes == 1)
        #expect(await transport.commands() == [.getBase, .getBase])
    }

    @Test func cancelledConnectClosesAndCompletes() async throws {
        let transport = FixtureTransport()
        await transport.configure(respond: false)
        let session = D200XSession(makeTransport: { transport })
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await transport.commands() == [.getBase] })
        connecting.cancel()
        do { try await connecting.value; Issue.record("cancelled connection succeeded") }
        catch { #expect(error is CancellationError || error as? D200XFailure == .cancelled) }
        #expect(await eventually { await transport.closes == 1 })
    }

    @Test func rawInputsAndTransportFailureAreGenerationBound() async throws {
        let transport = FixtureTransport()
        let session = D200XSession(makeTransport: { transport })
        var events = session.events.makeAsyncIterator()
        try await session.connect()
        #expect(await events.next() == .status(.connecting, generation: 1))
        guard case .status(.connected, generation: 1) = await events.next() else { Issue.record("missing connected event"); return }
        let input = try D200XInput(payload: Data([1, 18, 2, 4]))
        transport.continuation.yield(response(.input, payload: Data([1, 18, 2, 4]), paddedLength: 1014))
        #expect(await events.next() == .input(input, generation: 1))
        await transport.fail(.disconnected)
        #expect(await eventually { await session.status == .failed(.disconnected) })
        #expect(await transport.closes == 1)
    }

    @Test func inputOverflowStopsSession() async throws {
        let transport = FixtureTransport()
        let session = D200XSession(makeTransport: { transport })
        try await session.connect()
        for _ in 0..<180 { transport.continuation.yield(response(.input, payload: Data([1, 0, 1, 1]), paddedLength: 1014)) }
        #expect(await eventually { await session.status == .failed(.overflow) })
        #expect(await transport.closes == 1)
    }

    @Test func disconnectDuringOpenRetiresOldConnectionBeforeReconnect() async throws {
        let first = FixtureTransport()
        await first.suspendOpen()
        let second = FixtureTransport()
        let factory = FixtureFactory([first, second])
        let session = D200XSession(makeTransport: { factory.next() })
        let connecting = Task { try await session.connect() }
        #expect(await eventually { await first.opens == 1 })
        await session.disconnect()
        do { try await connecting.value; Issue.record("disconnected open succeeded") }
        catch { #expect(error as? D200XFailure == .cancelled) }
        #expect(await session.status == .disconnected)
        try await session.connect()
        #expect(await session.generation == 2)
        #expect(await first.closes == 1)
        #expect(await first.commands().isEmpty)
        await session.disconnect()
    }

    @Test func pageCancellationClosesTransportAndUnblocksWrite() async throws {
        let transport = FixtureTransport()
        let session = D200XSession(makeTransport: { transport })
        try await session.connect()
        await transport.suspendPage()
        let writing = Task { try await session.applyPage(D200XPage(slots: ["0_0": D200XSlot(image: syntheticPNG)])) }
        #expect(await eventually { await transport.commands().last == D200XCommand(0, 1) })
        writing.cancel()
        do { try await writing.value; Issue.record("cancelled page succeeded") }
        catch { #expect(error as? D200XFailure == .cancelled) }
        #expect(await eventually { await session.status == .failed(.cancelled) })
        #expect(await transport.closes == 1)
    }

    @Test func unknownCommandsDoNotGuessChecksumPolicy() async throws {
        let transport = FixtureTransport()
        let session = D200XSession(makeTransport: { transport })
        try await session.connect()
        transport.continuation.yield(Data([124, 124, 3, 6, 0, 0, 0, 0, 0, 0]))
        let input = try D200XInput(payload: Data([1, 17, 2, 5]))
        transport.continuation.yield(response(.input, payload: Data([1, 17, 2, 5]), paddedLength: 1014))
        var events = session.events.makeAsyncIterator()
        _ = await events.next()
        _ = await events.next()
        #expect(await events.next() == .input(input, generation: 1))
        await session.disconnect()
    }

    @Test func blockedFontReplyDoesNotBlockIdentityOrInputReader() async throws {
        let transport = FixtureTransport()
        let clock = TestClock()
        let session = D200XSession(timing: D200XTiming(sleep: { try await clock.sleep($0) }), makeTransport: { transport })
        try await session.connect()
        await transport.configure(respond: false)
        await transport.suspendFont()
        #expect(await eventually { await clock.count(.seconds(5)) == 1 })
        await clock.advance(.seconds(5))
        #expect(await eventually { await clock.count(.seconds(3)) == 1 })
        transport.continuation.yield(response(.fontRequest, payload: Data()))
        #expect(await eventually { await transport.commands().last == D200XCommand(0, 11) })
        transport.continuation.yield(response(.fontRequest, payload: Data()))
        transport.continuation.yield(response(.identity, payload: syntheticIdentity, paddedLength: 1014))
        transport.continuation.yield(response(.input, payload: Data([1, 18, 2, 4]), paddedLength: 1014))
        var events = session.events.makeAsyncIterator()
        _ = await events.next()
        _ = await events.next()
        #expect(await events.next() == .input(try D200XInput(payload: Data([1, 18, 2, 4])), generation: 1))
        #expect(await eventually { await clock.count(.seconds(3)) == 0 })
        await clock.advance(.seconds(3))
        guard case .connected = await session.status else { Issue.record("blocked font caused false timeout"); return }
        #expect(await transport.commands().filter { $0 == D200XCommand(0, 11) }.count == 1)
        await session.disconnect()
    }

    @Test func queryDeadlineStartsAfterQueuedFrameIsIssued() async throws {
        let transport = FixtureTransport()
        let clock = TestClock()
        let session = D200XSession(timing: D200XTiming(sleep: { try await clock.sleep($0) }), makeTransport: { transport })
        try await session.connect()
        await transport.suspendPage(queueQueries: true)
        let writing = Task { try await session.applyPage(D200XPage(slots: ["0_0": D200XSlot(image: syntheticPNG)])) }
        #expect(await eventually { await transport.commands().last == D200XCommand(0, 1) })
        #expect(await eventually { await clock.count(.seconds(5)) == 1 })
        await clock.advance(.seconds(5))
        #expect(await eventually { await transport.queuedQueryCount() == 1 })
        #expect(await clock.count(.seconds(3)) == 0)
        await clock.advance(.seconds(3))
        guard case .connected = await session.status else { Issue.record("queued query timed out before send"); return }
        await transport.releasePage()
        try await writing.value
        #expect(await eventually { await transport.commands() == [.getBase, D200XCommand(0, 1), .getBase] })
        #expect(await eventually { await clock.count(.seconds(3)) == 0 })
        await session.disconnect()
    }
}
