import Foundation

enum RuntimeExecutionState: String, Sendable, Equatable {
    case running
    case exited
    case timedOut
    case cancelled
    case startFailed
    case cleanupUncertain
    case rejectedBusy
}

enum RuntimeExecutionStream: Sendable {
    case standardOutput
    case standardError
}

struct RuntimeExecutionLaunch: Sendable, Equatable {
    static let minimalPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    let executable: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String]
    let timeoutSeconds: Int

    init(executable: String, arguments: [String], timeoutSeconds: Int) {
        self.executable = executable
        self.arguments = arguments
        workingDirectory = "/"
        environment = ["PATH=\(Self.minimalPath)"]
        self.timeoutSeconds = timeoutSeconds
    }
}

enum RuntimeProcessTermination: Sendable, Equatable {
    case exited(Int32)
    case timedOut(Int32?)
    case cancelled(Int32?)
    case startFailed
    case cleanupUncertain
}

final class RuntimeProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func cancel() {
        lock.lock()
        requested = true
        lock.unlock()
    }
}

protocol RuntimeProcessRunner: Sendable {
    func run(
        _ launch: RuntimeExecutionLaunch,
        cancellation: RuntimeProcessCancellation,
        onStarted: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable (RuntimeExecutionStream, Data) -> Void
    ) -> RuntimeProcessTermination
}

enum RuntimeExecutionAdmission: Sendable, Equatable {
    case admitted(String)
    case rejectedBusy(String)
    case rejectedInvalid
    case closed
}

enum RuntimeExecutionServiceError: Error, Sendable, Equatable {
    case invalidSummaryLimit
}

enum RuntimeExecutionStopOutcome: Sendable, Equatable {
    case closed
    case cleanupUncertain
}

struct RuntimeExecutionOutput: Sendable, Equatable {
    let tail: Data
    let totalBytes: UInt64
    let truncated: Bool
}

struct RuntimeExecutionSummary: Sendable, Equatable {
    let id: String
    let profileID: String
    let coordinate: String
    let state: RuntimeExecutionState
    let submittedAt: RuntimeMonotonicInstant
    let startedAt: RuntimeMonotonicInstant?
    let finishedAt: RuntimeMonotonicInstant?
    let duration: Duration?
    let exitCode: Int32?
    let supervisionUncertain: Bool
}

struct RuntimeExecutionRecord: Sendable, Equatable {
    let summary: RuntimeExecutionSummary
    let standardOutput: RuntimeExecutionOutput
    let standardError: RuntimeExecutionOutput

    fileprivate init(summary: RuntimeExecutionSummary, output: RuntimeOutputSnapshot) {
        self.summary = summary
        standardOutput = output.standardOutput
        standardError = output.standardError
    }
}

private struct RuntimeExecutionEntry: Sendable {
    var summary: RuntimeExecutionSummary
    var standardOutput = RuntimeExecutionOutput(tail: Data(), totalBytes: 0, truncated: false)
    var standardError = RuntimeExecutionOutput(tail: Data(), totalBytes: 0, truncated: false)

    var record: RuntimeExecutionRecord {
        RuntimeExecutionRecord(
            summary: summary,
            output: RuntimeOutputSnapshot(standardOutput: standardOutput, standardError: standardError)
        )
    }
}

private struct RuntimeOutputSnapshot: Sendable {
    let standardOutput: RuntimeExecutionOutput
    let standardError: RuntimeExecutionOutput
}

private final class RuntimeOutputCollector: @unchecked Sendable {
    static let tailLimit = 4_096

    private let lock = NSLock()
    private var standardOutput = RuntimeExecutionOutput(tail: Data(), totalBytes: 0, truncated: false)
    private var standardError = RuntimeExecutionOutput(tail: Data(), totalBytes: 0, truncated: false)

    func append(_ data: Data, to stream: RuntimeExecutionStream) {
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .standardOutput:
            standardOutput = Self.appending(data, to: standardOutput)
        case .standardError:
            standardError = Self.appending(data, to: standardError)
        }
    }

    var snapshot: RuntimeOutputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RuntimeOutputSnapshot(standardOutput: standardOutput, standardError: standardError)
    }

    private static func appending(_ data: Data, to output: RuntimeExecutionOutput) -> RuntimeExecutionOutput {
        guard !data.isEmpty else { return output }
        var tail = output.tail
        tail.append(data)
        if tail.count > tailLimit {
            tail.removeFirst(tail.count - tailLimit)
        }
        let (total, overflow) = output.totalBytes.addingReportingOverflow(UInt64(data.count))
        return RuntimeExecutionOutput(
            tail: tail,
            totalBytes: overflow ? UInt64.max : total,
            truncated: output.truncated || overflow || total > UInt64(tailLimit)
        )
    }
}

final class RuntimeExecutionService: @unchecked Sendable {
    private static let historyLimit = 32

    private let lock = NSLock()
    private let workerQueue = DispatchQueue(label: "hidhogg.runtime.execution", qos: .utility)
    private let runner: any RuntimeProcessRunner
    private let clock: any RuntimeMonotonicClock
    private var history = [RuntimeExecutionEntry]()
    private var activeID: String?
    private var activeCancellation: RuntimeProcessCancellation?
    private var closed = false
    private var cleanupUncertain = false
    private var stopWaiters = [CheckedContinuation<RuntimeExecutionStopOutcome, Never>]()
    private var stoppedOutcome: RuntimeExecutionStopOutcome?

    init(runner: any RuntimeProcessRunner, clock: any RuntimeMonotonicClock = SystemRuntimeMonotonicClock()) {
        self.runner = runner
        self.clock = clock
    }

    @discardableResult
    func submit(_ request: RuntimeStaticActionRequest) -> RuntimeExecutionAdmission {
        guard case let .execute(executable, arguments, timeoutSeconds, _) = request.action else {
            return .rejectedInvalid
        }
        guard Self.validMetadata(request.profileID), Self.validMetadata(request.coordinate), Self.isValid(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        ) else {
            return .rejectedInvalid
        }

        let id = UUID().uuidString.lowercased()
        let submittedAt = clock.now()
        let launch = RuntimeExecutionLaunch(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        )
        let cancellation = RuntimeProcessCancellation()

        lock.lock()
        guard !closed else {
            lock.unlock()
            return .closed
        }

        if activeID != nil {
            let entry = RuntimeExecutionEntry(summary: RuntimeExecutionSummary(
                id: id,
                profileID: request.profileID,
                coordinate: request.coordinate,
                state: .rejectedBusy,
                submittedAt: submittedAt,
                startedAt: nil,
                finishedAt: submittedAt,
                duration: .zero,
                exitCode: nil,
                supervisionUncertain: false
            ))
            appendHistoryLocked(entry)
            lock.unlock()
            return .rejectedBusy(id)
        }

        activeID = id
        activeCancellation = cancellation
        let entry = RuntimeExecutionEntry(summary: RuntimeExecutionSummary(
            id: id,
            profileID: request.profileID,
            coordinate: request.coordinate,
            state: .running,
            submittedAt: submittedAt,
            startedAt: nil,
            finishedAt: nil,
            duration: nil,
            exitCode: nil,
            supervisionUncertain: false
        ))
        appendHistoryLocked(entry)
        lock.unlock()

        workerQueue.async { [self] in
            run(id: id, launch: launch, cancellation: cancellation)
        }
        return .admitted(id)
    }

    func listSummaries(limit: Int) throws -> [RuntimeExecutionSummary] {
        guard (1...Self.historyLimit).contains(limit) else {
            throw RuntimeExecutionServiceError.invalidSummaryLimit
        }
        lock.lock()
        defer { lock.unlock() }
        return history.suffix(limit).reversed().map(\.summary)
    }

    func get(id: String) -> RuntimeExecutionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return history.last(where: { $0.summary.id == id })?.record
    }

    func stop() {
        var cancellation: RuntimeProcessCancellation?
        var waiters = [CheckedContinuation<RuntimeExecutionStopOutcome, Never>]()
        var immediateOutcome: RuntimeExecutionStopOutcome?

        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        cancellation = activeCancellation
        if activeID == nil {
            immediateOutcome = cleanupUncertain ? .cleanupUncertain : .closed
            stoppedOutcome = immediateOutcome
            waiters = stopWaiters
            stopWaiters.removeAll()
        }
        lock.unlock()

        cancellation?.cancel()
        if let immediateOutcome {
            waiters.forEach { $0.resume(returning: immediateOutcome) }
        }
    }

    func waitUntilStopped() async -> RuntimeExecutionStopOutcome {
        await withCheckedContinuation { continuation in
            let outcome: RuntimeExecutionStopOutcome?
            lock.lock()
            outcome = stoppedOutcome
            if outcome == nil {
                stopWaiters.append(continuation)
            }
            lock.unlock()
            if let outcome { continuation.resume(returning: outcome) }
        }
    }

    private func run(id: String, launch: RuntimeExecutionLaunch, cancellation: RuntimeProcessCancellation) {
        lock.lock()
        let mayStart = !closed && activeID == id
        lock.unlock()

        guard mayStart else {
            finish(id: id, termination: .cancelled(nil), output: RuntimeOutputCollector().snapshot)
            return
        }

        let output = RuntimeOutputCollector()
        let termination = runner.run(
            launch,
            cancellation: cancellation,
            onStarted: { [self] in markStarted(id: id) },
            receive: { stream, data in output.append(data, to: stream) }
        )
        finish(id: id, termination: termination, output: output.snapshot)
    }

    private func markStarted(id: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = history.firstIndex(where: { $0.summary.id == id }) else { return }
        let previous = history[index].summary
        guard previous.startedAt == nil else { return }
        history[index].summary = RuntimeExecutionSummary(
            id: id,
            profileID: previous.profileID,
            coordinate: previous.coordinate,
            state: previous.state,
            submittedAt: previous.submittedAt,
            startedAt: clock.now(),
            finishedAt: previous.finishedAt,
            duration: previous.duration,
            exitCode: previous.exitCode,
            supervisionUncertain: previous.supervisionUncertain
        )
    }

    private func finish(
        id: String,
        termination: RuntimeProcessTermination,
        output: RuntimeOutputSnapshot
    ) {
        var waiters = [CheckedContinuation<RuntimeExecutionStopOutcome, Never>]()
        var outcome: RuntimeExecutionStopOutcome?
        lock.lock()
        guard let index = history.firstIndex(where: { $0.summary.id == id }) else {
            lock.unlock()
            return
        }

        let previous = history[index].summary
        let finishedAt = clock.now()
        let (state, exitCode, uncertain) = Self.state(for: termination)
        let duration = previous.startedAt.map { $0.duration(to: finishedAt) }
        history[index].summary = RuntimeExecutionSummary(
            id: id,
            profileID: previous.profileID,
            coordinate: previous.coordinate,
            state: state,
            submittedAt: previous.submittedAt,
            startedAt: previous.startedAt,
            finishedAt: finishedAt,
            duration: duration,
            exitCode: exitCode,
            supervisionUncertain: uncertain
        )
        history[index].standardOutput = output.standardOutput
        history[index].standardError = output.standardError
        activeID = nil
        activeCancellation = nil
        cleanupUncertain = cleanupUncertain || uncertain
        if cleanupUncertain { closed = true }

        if closed {
            outcome = cleanupUncertain ? .cleanupUncertain : .closed
            stoppedOutcome = outcome
            waiters = stopWaiters
            stopWaiters.removeAll()
        }
        lock.unlock()

        if let outcome {
            waiters.forEach { $0.resume(returning: outcome) }
        }
    }

    private func appendHistoryLocked(_ entry: RuntimeExecutionEntry) {
        if history.count == Self.historyLimit {
            let evictIndex = history.firstIndex(where: { $0.summary.id != activeID }) ?? 0
            history.remove(at: evictIndex)
        }
        history.append(entry)
    }

    private static func state(
        for termination: RuntimeProcessTermination
    ) -> (RuntimeExecutionState, Int32?, Bool) {
        switch termination {
        case let .exited(code): return (.exited, code, false)
        case let .timedOut(code): return (.timedOut, code, false)
        case let .cancelled(code): return (.cancelled, code, false)
        case .startFailed: return (.startFailed, nil, false)
        case .cleanupUncertain: return (.cleanupUncertain, nil, true)
        }
    }

    private static func isValid(executable: String, arguments: [String], timeoutSeconds: Int) -> Bool {
        guard executable.utf8.first == 0x2F,
              !executable.unicodeScalars.contains(where: { $0.value == 0 }),
              (1...60).contains(timeoutSeconds),
              arguments.count <= 32,
              !arguments.contains(where: { $0.unicodeScalars.contains(where: { $0.value == 0 }) }) else {
            return false
        }

        var aggregateBytes = 0
        for argument in arguments {
            let byteCount = argument.utf8.count
            guard byteCount <= 1_024 else { return false }
            let (nextTotal, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
            guard !overflow, nextTotal <= 8_192 else { return false }
            aggregateBytes = nextTotal
        }
        return true
    }

    private static func validMetadata(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        for (index, byte) in bytes.enumerated() {
            let alphanumeric = (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
            if index == 0 {
                guard alphanumeric else { return false }
            } else if !alphanumeric && byte != 0x2E && byte != 0x5F && byte != 0x2D {
                return false
            }
        }
        return true
    }
}
