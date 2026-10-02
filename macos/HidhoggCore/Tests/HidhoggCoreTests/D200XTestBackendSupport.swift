import Foundation
@testable import HidhoggCore

struct D200XFakeNativeReport: Equatable, Sendable {
    let reportID: UInt32
    let packet: Data
}

final class D200XTestGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func pause() {
        entered.signal()
        _ = release.wait(timeout: .now() + .seconds(10))
    }

    func open() {
        release.signal()
    }
}

final class D200XFakeSessionBackend: D200XSessionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var currentCandidates: [D200XDeviceCandidate]
    private var inputHandler: (@Sendable (D200XInputEvent) -> Void)?
    private var failureHandler: (@Sendable (D200XSessionFailure) -> Void)?
    private var candidateReadHook: (@Sendable (Int) -> Void)?
    private var openGate: D200XTestGate?
    private var writeGate: D200XTestGate?
    private var writeGateAttempt: Int?
    private var stopGate: D200XTestGate?
    private var failedWriteAttempt: Int?
    private var stopOutcome: D200XSessionStopOutcome
    private var candidateReadCount = 0
    private var openCount = 0
    private var stopCount = 0
    private var stopped = false
    private var reports = [D200XFakeNativeReport]()

    init(
        candidates: [D200XDeviceCandidate] = [D200XFakeSessionBackend.candidate()],
        stopOutcome: D200XSessionStopOutcome = .closed
    ) {
        currentCandidates = candidates
        self.stopOutcome = stopOutcome
    }

    static func candidate(registryID: UInt64 = 17) -> D200XDeviceCandidate {
        D200XDeviceCandidate(
            registryID: registryID,
            vendorID: 0x2207,
            productID: 0x0019,
            interfaceNumber: 0,
            usagePage: 0x000c,
            usage: 0x0001,
            maximumOutputReportSize: D200XFrameCodec.packetSize
        )
    }

    var openedDeviceCount: Int { withLock { openCount } }
    var stoppedCount: Int { withLock { stopCount } }
    var candidateReads: Int { withLock { candidateReadCount } }
    var attemptedReports: [D200XFakeNativeReport] { withLock { reports } }

    func setCandidates(_ candidates: [D200XDeviceCandidate]) {
        withLock { currentCandidates = candidates }
    }

    func setCandidateReadHook(_ hook: (@Sendable (Int) -> Void)?) {
        withLock { candidateReadHook = hook }
    }

    func pauseWrite(at attempt: Int, using gate: D200XTestGate) {
        withLock {
            writeGateAttempt = attempt
            writeGate = gate
        }
    }

    func pauseOpen(using gate: D200XTestGate) {
        withLock { openGate = gate }
    }

    func failWrite(at attempt: Int) {
        withLock { failedWriteAttempt = attempt }
    }

    func pauseStop(using gate: D200XTestGate) {
        withLock { stopGate = gate }
    }

    func candidates() throws -> [D200XDeviceCandidate] {
        let result = withLock { () -> ([D200XDeviceCandidate], (@Sendable (Int) -> Void)?, Int) in
            candidateReadCount += 1
            return (currentCandidates, candidateReadHook, candidateReadCount)
        }
        result.1?(result.2)
        return result.0
    }

    func open(
        _ candidate: D200XDeviceCandidate,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void,
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void
    ) throws {
        let gate = try withLock { () throws -> D200XTestGate? in
            guard !stopped, currentCandidates.filter(\.isEligible) == [candidate] else {
                throw D200XSessionError.selectedDeviceChanged
            }
            openCount += 1
            inputHandler = onInput
            failureHandler = onFailure
            return openGate
        }
        gate?.pause()
    }

    func send(reportID: UInt32, packet: Data) throws {
        let attempt = withLock { () -> (Int, D200XTestGate?, Bool) in
            reports.append(D200XFakeNativeReport(reportID: reportID, packet: Data(packet)))
            let count = reports.count
            let gate = writeGateAttempt == count ? writeGate : nil
            return (count, gate, failedWriteAttempt == count)
        }
        attempt.1?.pause()
        if attempt.2 { throw D200XSessionError.writeFailed }
    }

    func stop() async -> D200XSessionStopOutcome {
        let result = withLock { () -> (D200XSessionStopOutcome, D200XTestGate?) in
            stopCount += 1
            stopped = true
            inputHandler = nil
            failureHandler = nil
            return (stopOutcome, stopGate)
        }
        result.1?.pause()
        return result.0
    }

    func emitInput(_ event: D200XInputEvent) {
        let callback = withLock { inputHandler }
        callback?(event)
    }

    func emitFailure(_ failure: D200XSessionFailure) {
        let callback = withLock { failureHandler }
        callback?(failure)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

final class D200XTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var currentValue = 0

    func increment() {
        lock.lock()
        currentValue += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentValue
    }
}

final class D200XTestRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues = [Value]()
    let received = DispatchSemaphore(value: 0)

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Value) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
        received.signal()
    }
}
