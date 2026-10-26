import Foundation
import Testing
@testable import UlanziD200X

private actor BrightnessFixtureTransport: D200XTransport {
    nonisolated let reports: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let delayBrightness: Bool
    private let releaseWriteOnClose: Bool
    private(set) var writes: [[Data]] = []
    private(set) var closes = 0
    private var brightnessWaiter: CheckedContinuation<Void, Error>?

    init(delayBrightness: Bool = false, releaseWriteOnClose: Bool = true) {
        let stream = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        reports = stream.stream
        continuation = stream.continuation
        self.delayBrightness = delayBrightness
        self.releaseWriteOnClose = releaseWriteOnClose
    }

    func open() async throws {}

    func write(_ reports: [Data]) async throws {
        guard closes == 0, let frame = reports.first else { throw D200XFailure.disconnected }
        writes.append(reports)
        let command = D200XCommand(frame[2], frame[3])
        if command == .getBase {
            continuation.yield(response(.identity, payload: syntheticIdentity, paddedLength: 1014))
        }
        guard command == D200XCommand(0, 10), delayBrightness else { return }
        try await withCheckedThrowingContinuation { brightnessWaiter = $0 }
    }

    func close() async {
        closes += 1
        continuation.finish()
        if releaseWriteOnClose {
            brightnessWaiter?.resume(throwing: D200XFailure.cancelled)
            brightnessWaiter = nil
        }
    }

    func commands() -> [D200XCommand] {
        writes.compactMap { reports in
            guard let frame = reports.first else { return nil }
            return D200XCommand(frame[2], frame[3])
        }
    }

    func releaseBrightnessWrite() {
        brightnessWaiter?.resume()
        brightnessWaiter = nil
    }
}

private final class BrightnessTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [BrightnessFixtureTransport]

    init(_ transports: [BrightnessFixtureTransport]) { self.transports = transports }

    func next() -> any D200XTransport { lock.withLock { transports.removeFirst() } }
}

private actor InertBrightnessSession: D200XSessionProtocol {
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

struct D200XBrightnessTests {
    @Test func connectedBrightnessWritesDecimalASCIIFramesAtSupportedBounds() async throws {
        let transport = BrightnessFixtureTransport()
        let session = D200XSession(makeTransport: { transport })
        try await session.connect()

        for percent in [0, 1, 25, 60, 100] {
            try await session.setBrightness(percent)
        }

        let writes = await transport.writes
        #expect(await transport.commands() == [.getBase] + Array(repeating: D200XCommand(0, 10), count: 5))
        for (reports, percent) in zip(writes.dropFirst(), [0, 1, 25, 60, 100]) {
            let payload = Data(String(percent).utf8)
            let frame = reports.reduce(into: Data()) { $0.append($1) }
            #expect(Array(frame.prefix(8)) == [0x7c, 0x7c, 0, 10, UInt8(payload.count), 0, 0, 0])
            #expect(Data(frame[8..<(8 + payload.count)]) == payload)
            #expect(Data(frame[(8 + payload.count)..<(10 + payload.count)]) == Data([0, 0]))
            #expect(frame.dropFirst(10 + payload.count).allSatisfy { $0 == 0 })
        }

        await session.disconnect()
    }

    @Test func invalidAndDisconnectedBrightnessDoNotWrite() async throws {
        let transport = BrightnessFixtureTransport()
        let session = D200XSession(makeTransport: { transport })

        do {
            try await session.setBrightness(60)
            Issue.record("disconnected session accepted brightness")
        } catch {
            #expect(error as? D200XFailure == .disconnected)
        }

        try await session.connect()
        for percent in [-1, 101] {
            do {
                try await session.setBrightness(percent)
                Issue.record("out-of-range brightness was accepted")
            } catch {
                #expect(error as? D200XFailure == .invalidPage)
            }
        }

        #expect(await transport.commands() == [.getBase])
        guard case .connected = await session.status else { Issue.record("invalid brightness changed session status"); return }
        await session.disconnect()
    }

    @Test func defaultProtocolImplementationReportsUnavailable() async {
        let session = InertBrightnessSession()
        do {
            try await session.setBrightness(60)
            Issue.record("inert session accepted brightness")
        } catch {
            #expect(error as? D200XFailure == .unavailable)
        }
    }

    @Test func cancellationClosesSessionAndUnblocksBrightnessWrite() async throws {
        let transport = BrightnessFixtureTransport(delayBrightness: true)
        let session = D200XSession(makeTransport: { transport })
        try await session.connect()
        let writing = Task { try await session.setBrightness(60) }
        #expect(await eventually { await transport.commands().last == D200XCommand(0, 10) })

        writing.cancel()
        do {
            try await writing.value
            Issue.record("cancelled brightness write succeeded")
        } catch {
            #expect(error as? D200XFailure == .cancelled)
        }
        #expect(await eventually { await session.status == .failed(.cancelled) })
        #expect(await transport.closes == 1)
    }

    @Test func staleBrightnessCompletionCannotFailReconnectedSession() async throws {
        let first = BrightnessFixtureTransport(delayBrightness: true, releaseWriteOnClose: false)
        let second = BrightnessFixtureTransport()
        let factory = BrightnessTransportFactory([first, second])
        let session = D200XSession(makeTransport: { factory.next() })
        try await session.connect()
        let writing = Task { try await session.setBrightness(60) }
        #expect(await eventually { await first.commands().last == D200XCommand(0, 10) })

        await session.disconnect()
        try await session.connect()
        await first.releaseBrightnessWrite()
        do {
            try await writing.value
            Issue.record("stale brightness completion succeeded")
        } catch {
            #expect(error as? D200XFailure == .disconnected)
        }

        #expect(await session.generation == 2)
        guard case .connected = await session.status else { Issue.record("stale write failed the new session"); return }
        #expect(await second.commands() == [.getBase])
        await session.disconnect()
    }
}
