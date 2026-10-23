import Foundation

public enum D200XStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(D200XIdentity)
    case disconnecting
    case failed(D200XFailure)
}

public enum D200XSessionEvent: Equatable, Sendable {
    case status(D200XStatus, generation: UInt64)
    case input(D200XInput, generation: UInt64)
}

public protocol D200XSessionProtocol: Sendable {
    var events: AsyncStream<D200XSessionEvent> { get }
    func connect() async throws
    func disconnect() async
    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws
}

public protocol D200XTransport: Sendable {
    var reports: AsyncThrowingStream<Data, Error> { get }
    func open() async throws
    /// A write owns the complete frame; concurrent calls must never interleave reports.
    func write(_ reports: [Data]) async throws
    func close() async
}

public struct D200XTiming: Sendable {
    public let sleep: @Sendable (Duration) async throws -> Void
    public let queryInterval: Duration
    public let responseTimeout: Duration

    public init(
        queryInterval: Duration = .seconds(5), responseTimeout: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.queryInterval = queryInterval
        self.responseTimeout = responseTimeout
        self.sleep = sleep
    }
}

public actor D200XSession: D200XSessionProtocol {
    public nonisolated let events: AsyncStream<D200XSessionEvent>
    public private(set) var status: D200XStatus = .disconnected
    public private(set) var generation: UInt64 = 0
    private let continuation: AsyncStream<D200XSessionEvent>.Continuation
    private let makeTransport: @Sendable () -> any D200XTransport
    private let timing: D200XTiming
    private var transport: (any D200XTransport)?
    private var reader: Task<Void, Never>?
    private var initialization: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var fontReply: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var deadlineSequence: UInt64 = 0
    private var identityWaiter: CheckedContinuation<Void, Error>?
    private var awaitingIdentity = false

    public init(
        timing: D200XTiming = D200XTiming(),
        makeTransport: @escaping @Sendable () -> any D200XTransport = { IOKitD200XTransport() }
    ) {
        let stream = AsyncStream<D200XSessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        events = stream.stream
        continuation = stream.continuation
        self.timing = timing
        self.makeTransport = makeTransport
    }

    deinit {
        initialization?.cancel()
        reader?.cancel()
        maintenance?.cancel()
        fontReply?.cancel()
        deadline?.cancel()
        continuation.finish()
        identityWaiter?.resume(throwing: D200XFailure.cancelled)
        if let transport { Task { await transport.close() } }
    }

    public func connect() async throws {
        guard transport == nil, status != .disconnecting else { throw D200XFailure.busy }
        try Task.checkCancellation()
        generation &+= 1
        let token = generation
        let link = makeTransport()
        transport = link
        publish(.connecting)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                identityWaiter = waiter
                armDeadline(token)
                initialization = Task { [weak self] in
                    do {
                        try await link.open()
                        try Task.checkCancellation()
                        await self?.startReading(link, token: token)
                        try await self?.queryIdentity(token: token)
                    } catch {
                        await self?.fail(Self.failure(error), token: token)
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(.cancelled, token: token) }
        }
        try Task.checkCancellation()
    }

    public func disconnect() async {
        await stop(failure: nil, token: generation)
    }

    public func applyPage(_ page: D200XPage, update: D200XPageUpdate = .replace) async throws {
        guard case .connected = status, let transport else { throw D200XFailure.disconnected }
        let token = generation
        let bytes = try page.archive()
        do {
            try Task.checkCancellation()
            let reports = try D200XCodec.reports(for: D200XFrame(
                command: D200XCommand(0, update == .replace ? 1 : 13), payload: bytes
            ))
            try await withTaskCancellationHandler {
                try await transport.write(reports)
            } onCancel: {
                Task { await self.fail(.cancelled, token: token) }
            }
            guard token == generation, case .connected = status else { throw D200XFailure.disconnected }
            try Task.checkCancellation()
        } catch {
            await fail(Self.failure(error), token: token)
            throw Self.failure(error)
        }
    }

    private func startReading(_ link: any D200XTransport, token: UInt64) {
        guard token == generation, transport != nil else { return }
        reader = Task { [weak self] in
            do {
                for try await report in link.reports {
                    try Task.checkCancellation()
                    try await self?.receive(report, token: token)
                }
                if !Task.isCancelled { await self?.fail(.disconnected, token: token) }
            } catch {
                if !Task.isCancelled { await self?.fail(Self.failure(error), token: token) }
            }
        }
    }

    private func receive(_ report: Data, token: UInt64) async throws {
        guard token == generation, transport != nil, status != .disconnecting else { return }
        if report.count >= 4 {
            let bytes = [UInt8](report.prefix(4))
            let command = D200XCommand(bytes[2], bytes[3])
            guard command == .identity || command == .input || command == .fontRequest else { return }
        }
        let frame = try D200XCodec.decodeResponse(report)
        switch frame.command {
        case .identity:
            let identity = try D200XIdentity(payload: frame.payload)
            guard awaitingIdentity else { return }
            awaitingIdentity = false
            deadlineSequence &+= 1
            deadline?.cancel()
            deadline = nil
            guard status == .connecting else { return }
            publish(.connected(identity))
            identityWaiter?.resume()
            identityWaiter = nil
            startMaintenance(token)
        case .input:
            guard case .connected = status else { return }
            if case .dropped = continuation.yield(.input(try D200XInput(payload: frame.payload), generation: token)) {
                await fail(.overflow, token: token)
            }
        case .fontRequest:
            replyToFontRequest(token)
        default:
            break
        }
    }

    private func replyToFontRequest(_ token: UInt64) {
        guard fontReply == nil, let transport else { return }
        fontReply = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await transport.write(D200XCodec.reports(for: D200XFrame(command: D200XCommand(0, 11), payload: Self.font)))
                await self?.finishFontReply(token)
            } catch {
                await self?.fail(Self.failure(error), token: token)
            }
        }
    }

    private func finishFontReply(_ token: UInt64) {
        guard token == generation else { return }
        fontReply = nil
    }

    private func queryIdentity(token: UInt64) async throws {
        guard token == generation, let transport, status != .disconnecting else { throw D200XFailure.disconnected }
        awaitingIdentity = true
        try await transport.write(D200XCodec.reports(for: D200XFrame(command: .getBase)))
        if token == generation, awaitingIdentity { armDeadline(token) }
    }

    private func startMaintenance(_ token: UInt64) {
        let timing = timing
        maintenance = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await timing.sleep(timing.queryInterval)
                    try Task.checkCancellation()
                    try await self?.queryIdentity(token: token)
                }
            } catch {
                if !Task.isCancelled { await self?.fail(Self.failure(error), token: token) }
            }
        }
    }

    private func armDeadline(_ token: UInt64) {
        deadline?.cancel()
        deadlineSequence &+= 1
        let sequence = deadlineSequence
        let timing = timing
        deadline = Task { [weak self] in
            do {
                try await timing.sleep(timing.responseTimeout)
                try Task.checkCancellation()
                await self?.expireDeadline(token: token, sequence: sequence)
            } catch {}
        }
    }

    private func expireDeadline(token: UInt64, sequence: UInt64) async {
        guard sequence == deadlineSequence, awaitingIdentity || status == .connecting else { return }
        await fail(.timeout, token: token)
    }

    private func fail(_ failure: D200XFailure, token: UInt64) async {
        await stop(failure: failure, token: token)
    }

    private func stop(failure: D200XFailure?, token: UInt64) async {
        guard token == generation, let link = transport else { return }
        if status == .disconnecting { await link.close(); return }
        publish(.disconnecting)
        initialization?.cancel()
        initialization = nil
        reader?.cancel()
        reader = nil
        maintenance?.cancel()
        maintenance = nil
        fontReply?.cancel()
        fontReply = nil
        deadline?.cancel()
        deadlineSequence &+= 1
        deadline = nil
        awaitingIdentity = false
        let waiter = identityWaiter
        identityWaiter = nil
        waiter?.resume(throwing: failure ?? D200XFailure.cancelled)
        await link.close()
        guard token == generation else { return }
        transport = nil
        publish(failure.map(D200XStatus.failed) ?? .disconnected)
    }

    private func publish(_ value: D200XStatus) {
        status = value
        if case .dropped = continuation.yield(.status(value, generation: generation)), value != .disconnecting {
            let token = generation
            Task { await self.fail(.overflow, token: token) }
        }
    }

    private static func failure(_ error: Error) -> D200XFailure {
        if error is CancellationError { return .cancelled }
        return error as? D200XFailure ?? .transport
    }

    private static let font = Data(#"{"Font":{"Align":"bottom","Color":16777215,"FontName":"Source Han Sans SC","ShowTitle":false,"Size":10,"Weight":80}}"#.utf8)
}
