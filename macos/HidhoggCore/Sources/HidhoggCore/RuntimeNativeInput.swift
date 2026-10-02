import CoreGraphics
import Foundation

enum RuntimeNativeInputPayload: Sendable, Equatable {
    case text(String)
    case enter
}

enum RuntimeNativeInputState: String, Sendable, Equatable {
    case queued
    case running
    case posted
    case permissionDenied
    case failed
    case cancelled
    case rejectedBusy
    case rejectedQueueFull
}

enum RuntimeNativePermission: String, Sendable, Equatable {
    case granted
    case denied
    case checkFailed
}

enum RuntimeNativeInputAdmission: Sendable, Equatable {
    case queued(String)
    case rejectedPermission(String)
    case rejectedBusy(String)
    case rejectedQueueFull(String)
    case rejectedInvalid
    case closed
}

enum RuntimeNativePermissionRequestResult: Sendable, Equatable {
    case granted
    case denied
    case checkFailed
    case busy
    case closed
}

enum RuntimeNativeInputBackendState: String, Sendable, Equatable {
    case ready
    case closed
}

struct RuntimeNativeInputStatus: Sendable, Equatable {
    let backend: RuntimeNativeInputBackendState
    let permission: RuntimeNativePermission
    let requestInProgress: Bool
    let queueDepth: Int
    let queueCapacity: Int
}

struct RuntimeNativeInputSummary: Sendable, Equatable {
    let id: String
    let profileID: String
    let coordinate: String
    let actionType: String
    let state: RuntimeNativeInputState
    let submittedAt: RuntimeMonotonicInstant
    let startedAt: RuntimeMonotonicInstant?
    let finishedAt: RuntimeMonotonicInstant?
    let duration: Duration?
}

protocol RuntimeNativeKeyboardPair: Sendable {
    func postDown()
    func postUp()
}

protocol RuntimeNativeInputBackend: Sendable {
    func preflightPermission() -> RuntimeNativePermission
    func requestPermission() -> RuntimeNativePermission
    func makePair(for payload: RuntimeNativeInputPayload) throws -> any RuntimeNativeKeyboardPair
}

enum RuntimeNativeInputServiceError: Error, Sendable, Equatable {
    case invalidSummaryLimit
}

enum RuntimeNativeInputStopOutcome: Sendable, Equatable {
    case closed
}

private final class RuntimeNativeCancellation: @unchecked Sendable {
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

private struct RuntimeNativeInputWork: Sendable {
    let id: String
    let payload: RuntimeNativeInputPayload
    let cancellation: RuntimeNativeCancellation
}

private struct RuntimeNativeInputEntry: Sendable {
    var summary: RuntimeNativeInputSummary
}

final class RuntimeNativeInputService: @unchecked Sendable {
    static let queueCapacity = 16
    private static let historyLimit = 32

    private let lock = NSLock()
    private let nativeOperationLock = NSLock()
    private let workerQueue = DispatchQueue(label: "hidhogg.runtime.native-input", qos: .userInitiated)
    private let backend: any RuntimeNativeInputBackend
    private let clock: any RuntimeMonotonicClock
    private var history = [RuntimeNativeInputEntry]()
    private var active: RuntimeNativeInputWork?
    private var waiting = [RuntimeNativeInputWork]()
    private var permission = RuntimeNativePermission.denied
    private var permissionRequestInProgress = false
    private var closed = false
    private var stopWaiters = [CheckedContinuation<RuntimeNativeInputStopOutcome, Never>]()
    private var stoppedOutcome: RuntimeNativeInputStopOutcome?

    init(backend: any RuntimeNativeInputBackend, clock: any RuntimeMonotonicClock = SystemRuntimeMonotonicClock()) {
        self.backend = backend
        self.clock = clock
    }

    @discardableResult
    func submit(_ request: RuntimeStaticActionRequest) -> RuntimeNativeInputAdmission {
        guard let payload = Self.payload(for: request.action),
              Self.validMetadata(request.profileID),
              Self.validMetadata(request.coordinate),
              Self.valid(payload) else {
            return .rejectedInvalid
        }

        let id = UUID().uuidString.lowercased()
        let submittedAt = clock.now()
        var scheduled: RuntimeNativeInputWork?
        var result: RuntimeNativeInputAdmission

        lock.lock()
        guard !closed else {
            lock.unlock()
            return .closed
        }

        if permissionRequestInProgress {
            appendLocked(Self.entry(
                id: id,
                profileID: request.profileID,
                coordinate: request.coordinate,
                payload: payload,
                state: .rejectedBusy,
                submittedAt: submittedAt,
                finishedAt: submittedAt
            ))
            lock.unlock()
            return .rejectedBusy(id)
        }

        permission = backend.preflightPermission()
        guard permission == .granted else {
            let state: RuntimeNativeInputState = permission == .denied ? .permissionDenied : .failed
            appendLocked(Self.entry(
                id: id,
                profileID: request.profileID,
                coordinate: request.coordinate,
                payload: payload,
                state: state,
                submittedAt: submittedAt,
                finishedAt: submittedAt
            ))
            result = .rejectedPermission(id)
            lock.unlock()
            return result
        }

        if active != nil && waiting.count >= Self.queueCapacity {
            appendLocked(Self.entry(
                id: id,
                profileID: request.profileID,
                coordinate: request.coordinate,
                payload: payload,
                state: .rejectedQueueFull,
                submittedAt: submittedAt,
                finishedAt: submittedAt
            ))
            lock.unlock()
            return .rejectedQueueFull(id)
        }

        appendLocked(Self.entry(
            id: id,
            profileID: request.profileID,
            coordinate: request.coordinate,
            payload: payload,
            state: .queued,
            submittedAt: submittedAt
        ))
        let work = RuntimeNativeInputWork(id: id, payload: payload, cancellation: RuntimeNativeCancellation())
        if active == nil {
            active = work
            scheduled = work
        } else {
            waiting.append(work)
        }
        result = .queued(id)
        lock.unlock()

        if let scheduled { schedule(scheduled) }
        return result
    }

    func status() -> RuntimeNativeInputStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            return RuntimeNativeInputStatus(
                backend: .closed,
                permission: permission,
                requestInProgress: false,
                queueDepth: 0,
                queueCapacity: Self.queueCapacity
            )
        }
        if !permissionRequestInProgress {
            permission = backend.preflightPermission()
        }
        return RuntimeNativeInputStatus(
            backend: .ready,
            permission: permission,
            requestInProgress: permissionRequestInProgress,
            queueDepth: waiting.count,
            queueCapacity: Self.queueCapacity
        )
    }

    func requestPermission() -> RuntimeNativePermissionRequestResult {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return .closed
        }
        guard !permissionRequestInProgress else {
            lock.unlock()
            return .busy
        }
        permissionRequestInProgress = true
        cancelWaitingLocked()
        active?.cancellation.cancel()
        lock.unlock()

        nativeOperationLock.lock()
        let requestResult = backend.requestPermission()
        let verified = requestResult == .granted ? backend.preflightPermission() : requestResult
        nativeOperationLock.unlock()

        var waiters = [CheckedContinuation<RuntimeNativeInputStopOutcome, Never>]()
        lock.lock()
        permission = verified
        permissionRequestInProgress = false
        if let outcome = finishStopIfReadyLocked() {
            stoppedOutcome = outcome
            waiters = stopWaiters
            stopWaiters.removeAll()
        }
        lock.unlock()
        waiters.forEach { $0.resume(returning: .closed) }

        switch verified {
        case .granted: return .granted
        case .denied: return .denied
        case .checkFailed: return .checkFailed
        }
    }

    func listSummaries(limit: Int) throws -> [RuntimeNativeInputSummary] {
        guard (1...Self.historyLimit).contains(limit) else {
            throw RuntimeNativeInputServiceError.invalidSummaryLimit
        }
        lock.lock()
        defer { lock.unlock() }
        return history.suffix(limit).reversed().map(\.summary)
    }

    func get(id: String) -> RuntimeNativeInputSummary? {
        lock.lock()
        defer { lock.unlock() }
        return history.last(where: { $0.summary.id == id })?.summary
    }

    func stop() {
        var waiters = [CheckedContinuation<RuntimeNativeInputStopOutcome, Never>]()
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        cancelWaitingLocked()
        active?.cancellation.cancel()
        if let outcome = finishStopIfReadyLocked() {
            stoppedOutcome = outcome
            waiters = stopWaiters
            stopWaiters.removeAll()
        }
        lock.unlock()
        waiters.forEach { $0.resume(returning: .closed) }
    }

    func waitUntilStopped() async -> RuntimeNativeInputStopOutcome {
        await withCheckedContinuation { continuation in
            let outcome: RuntimeNativeInputStopOutcome?
            lock.lock()
            outcome = stoppedOutcome
            if outcome == nil { stopWaiters.append(continuation) }
            lock.unlock()
            if let outcome { continuation.resume(returning: outcome) }
        }
    }

    private func schedule(_ work: RuntimeNativeInputWork) {
        workerQueue.async { [self] in run(work) }
    }

    private func run(_ work: RuntimeNativeInputWork) {
        nativeOperationLock.lock()
        defer { nativeOperationLock.unlock() }

        lock.lock()
        let mayStart = !closed && !permissionRequestInProgress && active?.id == work.id && !work.cancellation.isRequested
        if mayStart { updateLocked(work.id, state: .running) }
        lock.unlock()
        guard mayStart else {
            finish(work, state: .cancelled)
            return
        }

        let currentPermission = backend.preflightPermission()
        lock.lock()
        permission = currentPermission
        lock.unlock()
        guard currentPermission == .granted else {
            finish(work, state: currentPermission == .denied ? .permissionDenied : .failed)
            return
        }

        let pair: any RuntimeNativeKeyboardPair
        do {
            pair = try backend.makePair(for: work.payload)
        } catch {
            finish(work, state: .failed)
            return
        }

        lock.lock()
        let mayPost = !closed && !permissionRequestInProgress && active?.id == work.id && !work.cancellation.isRequested
        if mayPost { updateLocked(work.id, state: .running, startedAt: clock.now()) }
        lock.unlock()
        guard mayPost else {
            finish(work, state: .cancelled)
            return
        }

        pair.postDown()
        pair.postUp()
        finish(work, state: work.cancellation.isRequested ? .cancelled : .posted)
    }

    private func finish(_ work: RuntimeNativeInputWork, state: RuntimeNativeInputState) {
        var next: RuntimeNativeInputWork?
        var waiters = [CheckedContinuation<RuntimeNativeInputStopOutcome, Never>]()
        lock.lock()
        updateLocked(work.id, state: state, finishedAt: clock.now())
        if active?.id == work.id {
            active = nil
            if !closed && !permissionRequestInProgress && !waiting.isEmpty {
                next = waiting.removeFirst()
                active = next
            }
        }
        if let outcome = finishStopIfReadyLocked() {
            stoppedOutcome = outcome
            waiters = stopWaiters
            stopWaiters.removeAll()
        }
        lock.unlock()
        waiters.forEach { $0.resume(returning: .closed) }
        if let next { schedule(next) }
    }

    private func finishStopIfReadyLocked() -> RuntimeNativeInputStopOutcome? {
        guard closed, active == nil, !permissionRequestInProgress else { return nil }
        return .closed
    }

    private func cancelWaitingLocked() {
        let finishedAt = clock.now()
        for work in waiting {
            work.cancellation.cancel()
            updateLocked(work.id, state: .cancelled, finishedAt: finishedAt)
        }
        waiting.removeAll()
    }

    private func updateLocked(
        _ id: String,
        state: RuntimeNativeInputState,
        startedAt: RuntimeMonotonicInstant? = nil,
        finishedAt: RuntimeMonotonicInstant? = nil
    ) {
        guard let index = history.firstIndex(where: { $0.summary.id == id }) else { return }
        let previous = history[index].summary
        let actualStartedAt = startedAt ?? previous.startedAt
        let actualFinishedAt = finishedAt ?? previous.finishedAt
        history[index].summary = RuntimeNativeInputSummary(
            id: id,
            profileID: previous.profileID,
            coordinate: previous.coordinate,
            actionType: previous.actionType,
            state: state,
            submittedAt: previous.submittedAt,
            startedAt: actualStartedAt,
            finishedAt: actualFinishedAt,
            duration: actualStartedAt.flatMap { start in actualFinishedAt.map { start.duration(to: $0) } }
        )
    }

    private func appendLocked(_ entry: RuntimeNativeInputEntry) {
        if history.count == Self.historyLimit {
            let evictIndex = history.firstIndex(where: { candidate in
                candidate.summary.id != active?.id && !waiting.contains(where: { $0.id == candidate.summary.id })
            }) ?? 0
            history.remove(at: evictIndex)
        }
        history.append(entry)
    }

    private static func entry(
        id: String,
        profileID: String,
        coordinate: String,
        payload: RuntimeNativeInputPayload,
        state: RuntimeNativeInputState,
        submittedAt: RuntimeMonotonicInstant,
        finishedAt: RuntimeMonotonicInstant? = nil
    ) -> RuntimeNativeInputEntry {
        RuntimeNativeInputEntry(summary: RuntimeNativeInputSummary(
            id: id,
            profileID: profileID,
            coordinate: coordinate,
            actionType: payload.actionType,
            state: state,
            submittedAt: submittedAt,
            startedAt: nil,
            finishedAt: finishedAt,
            duration: nil
        ))
    }

    private static func payload(for action: ConfiguredAction) -> RuntimeNativeInputPayload? {
        switch action {
        case let .typeText(text, _): return .text(text)
        case let .keyPress(key, _): return key == "enter" ? .enter : nil
        case .activateProfile, .execute: return nil
        }
    }

    private static func valid(_ payload: RuntimeNativeInputPayload) -> Bool {
        switch payload {
        case let .text(text):
            return !text.isEmpty && text.utf16.count <= 64 && !text.unicodeScalars.contains(where: { $0.value == 0 })
        case .enter:
            return true
        }
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

private extension RuntimeNativeInputPayload {
    var actionType: String {
        switch self {
        case .text: return "type_text"
        case .enter: return "key_press"
        }
    }
}

struct RuntimeCoreGraphicsInputBackend: RuntimeNativeInputBackend, Sendable {
    func preflightPermission() -> RuntimeNativePermission {
        CGPreflightPostEventAccess() ? .granted : .denied
    }

    func requestPermission() -> RuntimeNativePermission {
        guard CGRequestPostEventAccess() else { return .denied }
        return preflightPermission()
    }

    func makePair(for payload: RuntimeNativeInputPayload) throws -> any RuntimeNativeKeyboardPair {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw RuntimeNativeInputBackendError.eventAllocationFailed
        }

        let keyCode: CGKeyCode
        switch payload {
        case .text: keyCode = CGKeyCode(0)
        case .enter: keyCode = CGKeyCode(0x24)
        }

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw RuntimeNativeInputBackendError.eventAllocationFailed
        }
        down.flags = CGEventFlags(rawValue: 0)
        up.flags = CGEventFlags(rawValue: 0)

        if case let .text(text) = payload {
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }

        return RuntimeCoreGraphicsKeyboardPair(source: source, down: down, up: up)
    }
}

enum RuntimeNativeInputBackendError: Error, Sendable {
    case eventAllocationFailed
}

private final class RuntimeCoreGraphicsKeyboardPair: RuntimeNativeKeyboardPair, @unchecked Sendable {
    private let source: CGEventSource
    private let down: CGEvent
    private let up: CGEvent

    init(source: CGEventSource, down: CGEvent, up: CGEvent) {
        self.source = source
        self.down = down
        self.up = up
    }

    func postDown() {
        _ = source
        down.post(tap: .cgSessionEventTap)
    }

    func postUp() {
        up.post(tap: .cgSessionEventTap)
    }
}
