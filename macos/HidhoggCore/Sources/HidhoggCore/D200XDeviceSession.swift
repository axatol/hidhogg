import Dispatch
import Foundation

enum D200XBackendSelection: Sendable {
    case native
    case simulated
}

struct D200XDeviceCandidate: Hashable, Sendable {
    let registryID: UInt64
    let vendorID: UInt16
    let productID: UInt16
    let interfaceNumber: Int
    let usagePage: UInt16
    let usage: UInt16
    let maximumOutputReportSize: Int

    var isEligible: Bool {
        vendorID == 0x2207 &&
            productID == 0x0019 &&
            interfaceNumber == 0 &&
            usagePage == 0x000c &&
            usage == 0x0001 &&
            maximumOutputReportSize == D200XFrameCodec.packetSize
    }
}

enum D200XSessionFailure: Error, Sendable, Equatable {
    case deviceRemoved
    case inputReadFailed
    case malformedInput
    case writeFailed
}

enum D200XSessionStopOutcome: Sendable, Equatable {
    case closed
    case cleanupUncertain
}

enum D200XSessionError: Error, Sendable, Equatable {
    case noMatchingDevice
    case ambiguousDevice(count: Int)
    case ineligibleCandidate
    case selectedDeviceChanged
    case sessionClosed
    case sessionNotOpen
    case sessionFailed
    case invalidSyntheticReport
    case writeFailed
}

protocol D200XDeviceSession: Sendable {
    func candidates() async throws -> [D200XDeviceCandidate]
    func open(
        _ candidate: D200XDeviceCandidate,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void,
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void
    ) async throws
    func perform(_ batch: D200XOutboundBatch) async throws
    func stop()
    func waitUntilStopped() async -> D200XSessionStopOutcome
}

protocol D200XSessionBackend: AnyObject, Sendable {
    func candidates() throws -> [D200XDeviceCandidate]
    func open(
        _ candidate: D200XDeviceCandidate,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void,
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void
    ) throws
    func send(reportID: UInt32, packet: Data) throws
    func stop() async -> D200XSessionStopOutcome
}

struct D200XDeviceSessionFactory: Sendable {
    private let makeNativeBackend: @Sendable () -> any D200XSessionBackend
    private let makeSimulatedBackend: @Sendable () -> any D200XSessionBackend

    init(
        makeNativeBackend: @escaping @Sendable () -> any D200XSessionBackend,
        makeSimulatedBackend: @escaping @Sendable () -> any D200XSessionBackend
    ) {
        self.makeNativeBackend = makeNativeBackend
        self.makeSimulatedBackend = makeSimulatedBackend
    }

    static var live: D200XDeviceSessionFactory {
        D200XDeviceSessionFactory(
            makeNativeBackend: { NativeD200XBackend() },
            makeSimulatedBackend: { SimulatedD200XBackend() }
        )
    }

    func make(selection: D200XBackendSelection) -> any D200XDeviceSession {
        let backend: any D200XSessionBackend
        switch selection {
        case .native:
            backend = makeNativeBackend()
        case .simulated:
            backend = makeSimulatedBackend()
        }
        return D200XSession(backend: backend)
    }
}

final class D200XSession: D200XDeviceSession, @unchecked Sendable {
    private enum State {
        case created
        case opening
        case opened
        case stopping
        case stopped(D200XSessionStopOutcome)
    }

    private let backend: any D200XSessionBackend
    private let writerQueue = DispatchQueue(label: "hidhogg.d200x.session.writer")
    private let onBatchEnqueued: (@Sendable () -> Void)?
    private let stateLock = NSLock()
    private var state = State.created
    private var terminalFailure: D200XSessionFailure?
    private var inputHandler: (@Sendable (D200XInputEvent) -> Void)?
    private var failureHandler: (@Sendable (D200XSessionFailure) -> Void)?
    private var stopWaiters: [CheckedContinuation<D200XSessionStopOutcome, Never>] = []

    init(backend: any D200XSessionBackend, onBatchEnqueued: (@Sendable () -> Void)? = nil) {
        self.backend = backend
        self.onBatchEnqueued = onBatchEnqueued
    }

    func candidates() async throws -> [D200XDeviceCandidate] {
        let candidates = try await performOnWriter {
            guard self.isCreated else { throw D200XSessionError.sessionClosed }
            return try self.backend.candidates()
        }
        let eligible = candidates.filter(\.isEligible)
        switch eligible.count {
        case 0:
            throw D200XSessionError.noMatchingDevice
        case 1:
            return eligible
        default:
            throw D200XSessionError.ambiguousDevice(count: eligible.count)
        }
    }

    func open(
        _ candidate: D200XDeviceCandidate,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void,
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void
    ) async throws {
        guard candidate.isEligible else { throw D200XSessionError.ineligibleCandidate }
        let mayOpen = withStateLock {
            guard case .created = state else { return false }
            state = .opening
            inputHandler = onInput
            failureHandler = onFailure
            return true
        }
        guard mayOpen else { throw D200XSessionError.sessionClosed }

        do {
            try await performOnWriter {
                let current = try self.backend.candidates().filter(\.isEligible)
                guard current.count == 1 else {
                    if current.isEmpty { throw D200XSessionError.noMatchingDevice }
                    throw D200XSessionError.ambiguousDevice(count: current.count)
                }
                guard current[0] == candidate else { throw D200XSessionError.selectedDeviceChanged }
                guard self.isOpening else { throw D200XSessionError.sessionClosed }
                try self.backend.open(
                    candidate,
                    onInput: { event in self.receive(event: event) },
                    onFailure: { failure in self.receive(failure: failure) }
                )
            }
        } catch {
            stop()
            throw error
        }

        let opened = withStateLock {
            guard case .opening = state else { return false }
            state = .opened
            return true
        }
        guard opened else { throw D200XSessionError.sessionClosed }
    }

    func perform(_ batch: D200XOutboundBatch) async throws {
        let frames = try batch.makeFrames()
        var packets = [Data]()
        for frame in frames {
            for report in try D200XFrameCodec.encode(frame) {
                guard report.count == D200XFrameCodec.reportSize, report.first == 0 else {
                    throw D200XSessionError.invalidSyntheticReport
                }
                packets.append(Data(report.dropFirst()))
            }
        }

        guard canWrite else { throw D200XSessionError.sessionNotOpen }
        let packetsToSend = packets
        do {
            try await performOnWriter(onEnqueued: onBatchEnqueued) {
                for packet in packetsToSend {
                    guard self.canWrite else { throw D200XSessionError.sessionFailed }
                    do {
                        try self.backend.send(reportID: 0, packet: packet)
                    } catch {
                        self.receive(failure: .writeFailed)
                        throw D200XSessionError.writeFailed
                    }
                }
            }
        } catch let error as D200XSessionError {
            throw error
        } catch {
            throw D200XSessionError.writeFailed
        }
    }

    func stop() {
        let shouldSchedule = withStateLock {
            switch state {
            case .stopping, .stopped:
                return false
            case .created, .opening, .opened:
                state = .stopping
                return true
            }
        }
        guard shouldSchedule else { return }

        writerQueue.async { [self] in
            Task {
                let outcome = await backend.stop()
                finishStop(outcome)
            }
        }
    }

    func waitUntilStopped() async -> D200XSessionStopOutcome {
        await withCheckedContinuation { continuation in
            let completed = withStateLock { () -> D200XSessionStopOutcome? in
                if case let .stopped(outcome) = state { return outcome }
                stopWaiters.append(continuation)
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    private var canWrite: Bool {
        withStateLock {
            guard case .opened = state else { return false }
            return terminalFailure == nil
        }
    }

    private var isCreated: Bool {
        withStateLock {
            guard case .created = state else { return false }
            return true
        }
    }

    private var isOpening: Bool {
        withStateLock {
            guard case .opening = state else { return false }
            return true
        }
    }

    private func receive(event: D200XInputEvent) {
        let callback = withStateLock { () -> (@Sendable (D200XInputEvent) -> Void)? in
            switch state {
            case .opening, .opened: return inputHandler
            case .created, .stopping, .stopped: return nil
            }
        }
        callback?(event)
    }

    private func receive(failure: D200XSessionFailure) {
        let callback = withStateLock { () -> (@Sendable (D200XSessionFailure) -> Void)? in
            guard terminalFailure == nil else { return nil }
            switch state {
            case .stopping, .stopped:
                return nil
            case .created, .opening, .opened:
                terminalFailure = failure
                return failureHandler
            }
        }
        guard let callback else { return }
        callback(failure)
        stop()
    }

    private func finishStop(_ outcome: D200XSessionStopOutcome) {
        let waiters = withStateLock { () -> [CheckedContinuation<D200XSessionStopOutcome, Never>] in
            guard case .stopping = state else { return [] }
            state = .stopped(outcome)
            inputHandler = nil
            failureHandler = nil
            defer { stopWaiters.removeAll() }
            return stopWaiters
        }
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    private func performOnWriter<T: Sendable>(
        onEnqueued: (@Sendable () -> Void)? = nil,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writerQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            onEnqueued?()
        }
    }

    private func withStateLock<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }
}
