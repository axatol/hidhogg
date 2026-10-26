import Foundation
import Darwin
import HidhoggDomain

public enum ConfiguredActionStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed, timedOut = "timed_out", cancelled
}

public struct ConfiguredProcessResult: Sendable, Equatable {
    public let status: ConfiguredActionStatus
    public let exitCode: Int32?
    public let failureMessage: String?

    public init(status: ConfiguredActionStatus, exitCode: Int32? = nil, failureMessage: String? = nil) {
        self.status = status
        self.exitCode = exitCode
        self.failureMessage = failureMessage
    }
}

public protocol ConfiguredProcessRunning: Sendable {
    func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult
}

public struct ConfiguredActionTrigger: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case device, localAPI }
    public let kind: Kind
    public let profile: String?
    public let control: String?
    public let sessionEpoch: UInt64?
    public let applicationID: String?

    public init(kind: Kind, profile: String? = nil, control: String? = nil, sessionEpoch: UInt64? = nil, applicationID: String? = nil) {
        self.kind = kind
        self.profile = profile
        self.control = control
        self.sessionEpoch = sessionEpoch
        self.applicationID = applicationID
    }

    enum CodingKeys: String, CodingKey {
        case kind, profile, control
        case sessionEpoch = "session_epoch", applicationID = "application_id"
    }
}

public struct ConfiguredActionRecord: Codable, Sendable, Equatable {
    public let executionID: UUID
    public let actionID: String
    public internal(set) var status: ConfiguredActionStatus
    public let admittedAt: Date
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    public internal(set) var exitCode: Int32?
    public let trigger: ConfiguredActionTrigger?
    public internal(set) var failureMessage: String?

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id", actionID = "action_id", status
        case admittedAt = "admitted_at", startedAt = "started_at", finishedAt = "finished_at", exitCode = "exit_code"
        case trigger
        case failureMessage = "failure_message"
    }
}

public enum ConfiguredActionError: Error { case invalidIdentifier, busy, stopped }

public actor ConfiguredActionRunner {
    public nonisolated let events: AsyncStream<ConfiguredActionRecord>
    private let eventContinuation: AsyncStream<ConfiguredActionRecord>.Continuation
    private struct Pending: Sendable {
        let executionID: UUID
        let action: ConfiguredActionDefinition
        let trigger: ConfiguredActionTrigger?
    }

    private let processRunner: any ConfiguredProcessRunning
    private let nativeRunner: any ConfiguredNativeActionRunning
    private var pending: [Pending] = []
    private var records: [ConfiguredActionRecord] = []
    private var active: Task<Void, Never>?
    private var nativeActive: Task<Void, Never>?
    public private(set) var isStopped = false
    public var queuedCount: Int { pending.count }

    public init(processRunner: any ConfiguredProcessRunning = FoundationConfiguredProcessRunner(),
                nativeRunner: any ConfiguredNativeActionRunning = UnavailableNativeActionRunner()) {
        self.processRunner = processRunner
        self.nativeRunner = nativeRunner
        let stream = AsyncStream<ConfiguredActionRecord>.makeStream(bufferingPolicy: .bufferingNewest(100))
        events = stream.stream
        eventContinuation = stream.continuation
    }

    public func invoke(id: String, action: ConfiguredExecutable, trigger: ConfiguredActionTrigger? = nil) throws -> UUID {
        try admit(id: id, action: .executable(action.validated()), trigger: trigger)
    }

    public func invoke(id: String, nativeAction: NativeAction, trigger: ConfiguredActionTrigger? = nil) throws -> UUID {
        try admit(id: id, action: .native(nativeAction.validated()), trigger: trigger)
    }

    private func admit(id: String, action: ConfiguredActionDefinition, trigger: ConfiguredActionTrigger?) throws -> UUID {
        guard AutomationIdentifier.isValid(id) else { throw ConfiguredActionError.invalidIdentifier }
        guard !isStopped else { throw ConfiguredActionError.stopped }
        let laneIdle: Bool
        switch action {
        case .executable: laneIdle = active == nil
        case .native: laneIdle = nativeActive == nil
        }
        guard laneIdle || pending.count < 8 else { throw ConfiguredActionError.busy }
        let executionID = UUID()
        records.append(ConfiguredActionRecord(executionID: executionID, actionID: id, status: .queued, admittedAt: Date(), trigger: trigger))
        eventContinuation.yield(records[records.count - 1])
        if records.count > 100, let oldestFinished = records.firstIndex(where: { $0.status != .queued && $0.status != .running }) {
            records.remove(at: oldestFinished)
        }
        pending.append(Pending(executionID: executionID, action: action, trigger: trigger))
        startNext()
        return executionID
    }

    public func history() -> [ConfiguredActionRecord] { records }
    public func clearHistory() { records.removeAll() }

    public func stop() async {
        isStopped = true
        let now = Date()
        for item in pending {
            update(item.executionID) { $0.status = .cancelled; $0.finishedAt = now }
        }
        pending.removeAll()
        let task = active
        let nativeTask = nativeActive
        task?.cancel()
        nativeTask?.cancel()
        await task?.value
        await nativeTask?.value
        eventContinuation.finish()
    }

    private func startNext() {
        guard !isStopped else { return }
        if active == nil, let index = pending.firstIndex(where: {
            if case .executable = $0.action { true } else { false }
        }) { start(index: index, native: false) }
        if nativeActive == nil, let index = pending.firstIndex(where: {
            if case .native = $0.action { true } else { false }
        }) { start(index: index, native: true) }
    }

    private func start(index: Int, native: Bool) {
        let item = pending.remove(at: index)
        update(item.executionID) { $0.status = .running; $0.startedAt = Date() }
        let task = Task {
            let result: ConfiguredProcessResult
            switch item.action {
            case .executable(let action): result = await processRunner.run(action)
            case .native(let action): result = await nativeRunner.run(action, trigger: item.trigger)
            }
            complete(item.executionID, result: result, native: native)
        }
        if native { nativeActive = task } else { active = task }
    }

    private func complete(_ executionID: UUID, result: ConfiguredProcessResult, native: Bool) {
        update(executionID) {
            $0.status = result.status
            $0.exitCode = result.exitCode
            $0.failureMessage = result.failureMessage
            $0.finishedAt = Date()
        }
        if native { nativeActive = nil } else { active = nil }
        startNext()
    }

    private func update(_ executionID: UUID, body: (inout ConfiguredActionRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.executionID == executionID }) else { return }
        body(&records[index])
        eventContinuation.yield(records[index])
    }
}

public struct FoundationConfiguredProcessRunner: ConfiguredProcessRunning {
    public init() {}

    public func run(_ action: ConfiguredExecutable) async -> ConfiguredProcessResult {
        guard let action = try? action.validated() else { return .init(status: .failed) }
        let child = OwnedConfiguredProcess()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                child.start(action, continuation: continuation)
            }
        } onCancel: {
            child.cancel()
        }
    }
}

private final class OwnedConfiguredProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellation: ConfiguredActionStatus?
    private var timer: DispatchWorkItem?

    func start(_ action: ConfiguredExecutable, continuation: CheckedContinuation<ConfiguredProcessResult, Never>) {
        lock.lock()
        guard cancellation == nil else {
            lock.unlock()
            continuation.resume(returning: .init(status: .cancelled))
            return
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: action.executable)
        child.arguments = action.arguments
        child.environment = [:]
        child.currentDirectoryURL = action.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [self] process in
            lock.lock()
            timer?.cancel()
            timer = nil
            let result = ConfiguredProcessResult(
                status: cancellation ?? (process.terminationStatus == 0 ? .succeeded : .failed),
                exitCode: process.terminationStatus
            )
            self.process = nil
            lock.unlock()
            continuation.resume(returning: result)
        }
        process = child
        do {
            try child.run()
            let timeout = DispatchWorkItem { [weak self] in self?.cancel(status: .timedOut) }
            timer = timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(action.timeoutSeconds), execute: timeout)
            lock.unlock()
        } catch {
            process = nil
            child.terminationHandler = nil
            lock.unlock()
            continuation.resume(returning: .init(status: .failed))
        }
    }

    func cancel(status: ConfiguredActionStatus = .cancelled) {
        lock.lock()
        guard cancellation == nil else { lock.unlock(); return }
        cancellation = status
        guard let child = process, child.isRunning else { lock.unlock(); return }
        child.terminate()
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in
            lock.lock()
            if let child = process, child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            lock.unlock()
        }
    }
}
