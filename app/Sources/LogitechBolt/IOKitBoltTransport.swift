import Foundation
import IOKit.hid
import HidhoggDomain

final class IOKitBoltTransport: BoltReceiverTransport, @unchecked Sendable {
    let events: AsyncStream<BoltTransportEvent>
    let receiverEvents: AsyncStream<BoltReceiverEvent>
    private let continuation: AsyncStream<BoltTransportEvent>.Continuation
    private let receiverContinuation: AsyncStream<BoltReceiverEvent>.Continuation
    private let worker: BoltHIDWorker
    private let diagnosticsLock = NSLock()
    private var retainedInputDiagnostics = BoltNativeInputDiagnostics(available: true)

    init(connection: LogitechConnection = .bolt, endpoint: IOKitEndpointHandle? = nil,
         requireEndpoint: Bool = false, onTerminal: @escaping @Sendable () -> Void) {
        let stream = AsyncStream<BoltTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let receiverStream = AsyncStream<BoltReceiverEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        events = stream.stream
        receiverEvents = receiverStream.stream
        continuation = stream.continuation
        receiverContinuation = receiverStream.continuation
        worker = BoltHIDWorker(connection: connection, selectedEndpoint: endpoint, requireEndpoint: requireEndpoint)
        worker.sink = { [continuation] event in
            if case .failure = event { onTerminal() }
            if case .dropped = continuation.yield(event) {
                onTerminal()
                continuation.yield(.failure(.overflow))
                return false
            }
            return true
        }
        worker.receiverSink = { [receiverContinuation] event in
            if case .dropped = receiverContinuation.yield(event) {
                onTerminal()
                receiverContinuation.yield(.failure(.eventOverflow))
                receiverContinuation.finish()
                return false
            }
            if case .failure = event { receiverContinuation.finish() }
            return true
        }
    }

    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int {
        worker.requestIDs.available(slot: slot, feature: feature, function: function)
    }

    func open() async throws { try await worker.submit { try $0.open() } }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        try await worker.submit { try $0.request(slot: slot, feature: feature, function: function, parameters: parameters) }
    }

    func requestDeviceInformation(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        try await worker.submit {
            try $0.request(slot: slot, feature: feature, function: function, parameters: parameters, optionalInformation: true)
        }
    }

    func registerRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverRegisterReply {
        try await worker.submit { try $0.registerRequest(request) }
    }

    func cancelRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverCancellationResult {
        try await worker.submit { try $0.cancelRequest(request) }
    }

    func inputDiagnostics() async -> BoltNativeInputDiagnostics {
        if let snapshot = try? await worker.submit({ $0.nativeInputDiagnostics }) {
            return snapshot
        }
        return diagnosticsLock.withLock { retainedInputDiagnostics }
    }

    func close() async {
        _ = await closeAndWait()
    }

    func closeAndWait() async -> BoltTransportCloseResult {
        let result = await worker.closeAndWait()
        diagnosticsLock.withLock { retainedInputDiagnostics = worker.nativeInputDiagnostics }
        continuation.finish()
        receiverContinuation.finish()
        return result
    }
}

private final class BoltHIDSend {
    static let completion: IOHIDReportCallback = { context, result, _, _, _, _, _ in
        guard let context else { return }
        let packet = Unmanaged<BoltHIDSend>.fromOpaque(context).takeRetainedValue()
        BoltHIDCallbackRegistry.shared.withOwner(packet.callbackToken) { worker in
            worker.completeSend(result)
        }
    }

    let callbackToken: UnsafeMutableRawPointer?
    let bytes: UnsafeMutablePointer<UInt8>

    init(worker: BoltHIDWorker, frame: [UInt8]) {
        callbackToken = worker.callbackToken
        bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: frame.count)
        bytes.initialize(from: frame, count: frame.count)
    }

    deinit { bytes.deallocate() }
}

final class BoltHIDWorker: @unchecked Sendable {
    private let connection: LogitechConnection
    private let selectedEndpoint: IOKitEndpointHandle?
    private let requireEndpoint: Bool
    var sink: (@Sendable (BoltTransportEvent) -> Bool)?
    var receiverSink: (@Sendable (BoltReceiverEvent) -> Bool)?
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private weak var finishingThread: Thread?
    private var finished = false
    private var acceptingSubmissions = true
    private var acceptedSubmissions = 0
    private var closeScheduled = false
    private var closeResult: BoltTransportCloseResult = .unverified
    private var nativeTeardownUnverified = false
    private var closeWaiters: [CheckedContinuation<BoltTransportCloseResult, Never>] = []
    private var device: BoltNativeDevice?
    private var manager: BoltNativeManager?
    private var outputElement: BoltNativeOutputElement?
    private let native: any BoltHIDNativeAPI
    private var input: BoltHIDInputBuffer?
    fileprivate var callbackToken: UnsafeMutableRawPointer?
    private var removed = false
    private var inputFailed = false
    private var notificationStopped = false
    private var pendingSend = false
    private var sendResult: IOReturn?
    private var reply: Result<[UInt8], BoltFailure>?
    private var expected: BoltRequestTransaction?
    private var registerReply: BoltReceiverRegisterResponse?
    private var registerFailure: BoltReceiverTransportFailure?
    private var expectedRegister: BoltReceiverRegisterRequest?
    private var optionalInformation = false
    private var registerLaneUncertain = false
    private var cancellationLedger = BoltReceiverCancellationLedger()
    private var receiverNotificationsStopped = false
    let requestIDs = BoltRequestIDLedger()
    private var sendDeadline: TimeInterval = 0
    private var sendCompleted: TimeInterval = 0
    private var requestDeadline: TimeInterval = 0
    private(set) var nativeInputDiagnostics = BoltNativeInputDiagnostics(available: true)

    init(connection: LogitechConnection = .bolt, selectedEndpoint: IOKitEndpointHandle? = nil,
         requireEndpoint: Bool = false, native: any BoltHIDNativeAPI = IOKitBoltNativeAPI()) {
        self.native = native
        self.connection = connection
        self.selectedEndpoint = selectedEndpoint
        self.requireEndpoint = requireEndpoint
    }

    var submissionsSealed: Bool { lock.withLock { !acceptingSubmissions } }

    func submit<T: Sendable>(_ body: @escaping @Sendable (BoltHIDWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if finished || !acceptingSubmissions {
                lock.unlock()
                continuation.resume(throwing: BoltFailure.disconnected)
                return
            }
            if thread == nil {
                let started = DispatchSemaphore(value: 0)
                let thread = Thread { [self] in
                    let loop = CFRunLoopGetCurrent()!
                    var context = CFRunLoopSourceContext()
                    let source = CFRunLoopSourceCreate(nil, 0, &context)!
                    CFRunLoopAddSource(loop, source, .defaultMode)
                    runLoop = loop
                    started.signal()
                    CFRunLoopRun()
                    CFRunLoopRemoveSource(loop, source, .defaultMode)
                    let completion = lock.withLock {
                        finished = true
                        runLoop = nil
                        finishingThread = self.thread
                        self.thread = nil
                        let waiters = closeWaiters
                        closeWaiters.removeAll()
                        return (waiters, closeResult)
                    }
                    for waiter in completion.0 { waiter.resume(returning: completion.1) }
                }
                thread.name = "Hidhogg Bolt HID"
                self.thread = thread
                thread.start()
                started.wait()
            }
            let loop = runLoop!
            acceptedSubmissions += 1
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                defer { completeSubmission() }
                do { continuation.resume(returning: try body(self)) }
                catch { continuation.resume(throwing: error) }
            }
            lock.unlock()
            CFRunLoopWakeUp(loop)
        }
    }

    func closeAndWait() async -> BoltTransportCloseResult {
        let result = await withCheckedContinuation { continuation in
            lock.lock()
            acceptingSubmissions = false
            if finished {
                let result = closeResult
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            if thread == nil {
                finished = true
                closeResult = .closed
                lock.unlock()
                continuation.resume(returning: .closed)
                return
            }
            closeWaiters.append(continuation)
            scheduleCloseIfDrainedWhileLocked()
            lock.unlock()
        }
        let finishingThread = lock.withLock { self.finishingThread }
        while let finishingThread, !finishingThread.isFinished { await Task.yield() }
        return result
    }

    private func completeSubmission() {
        lock.withLock {
            acceptedSubmissions -= 1
            scheduleCloseIfDrainedWhileLocked()
        }
    }

    private func scheduleCloseIfDrainedWhileLocked() {
        guard !acceptingSubmissions, acceptedSubmissions == 0, !closeScheduled,
              let runLoop else { return }
        closeScheduled = true
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            let result = closeNativeHandle()
            lock.withLock { closeResult = result }
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    func open() throws {
        guard device == nil, !nativeTeardownUnverified else { throw BoltFailure.transport }
        nativeInputDiagnostics = .init(available: true)
        let manager = native.makeManager(connection: connection)
        self.manager = manager
        let selected: BoltNativeDevice
        if let selectedEndpoint {
            selected = native.catalogDevice(selectedEndpoint)
            guard native.eligible(selected, connection: connection) else { throw BoltFailure.unavailable }
        } else {
            guard !requireEndpoint else { throw BoltFailure.unavailable }
            let candidates = native.devices(manager).filter { native.eligible($0, connection: connection) }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw candidates.isEmpty ? BoltFailure.unavailable : BoltFailure.ambiguous
            }
            selected = candidate
        }
        guard let key = native.registryKey(selected),
              selectedEndpoint.map({ $0.key == key }) ?? true,
              let privateDevice = native.makePrivateDevice(selected),
              native.registryKey(privateDevice) == key,
              native.eligible(privateDevice, connection: connection) else { throw BoltFailure.unavailable }
        let output = connection == .bluetooth ? native.outputElement(privateDevice) : nil
        if connection == .bluetooth, output == nil { throw BoltFailure.unavailable }
        guard native.open(privateDevice) == kIOReturnSuccess else { throw BoltFailure.transport }
        outputElement = output
        device = privateDevice
        removed = false
        inputFailed = false
        notificationStopped = false
        let buffer = BoltHIDInputBuffer()
        input = buffer
        let context = BoltHIDCallbackRegistry.shared.register(self)
        callbackToken = context
        guard native.registerInput(privateDevice, buffer: buffer, callback: BoltHIDCallbacks.inputReport, context: context) else {
            _ = closeNativeHandle()
            throw BoltFailure.transport
        }
        native.registerRemoval(privateDevice, callback: BoltHIDCallbacks.removalReport, context: context)
        native.schedule(privateDevice)
        native.registerMatching(manager, callback: BoltHIDCallbacks.matchingReport, context: context)
        native.schedule(manager)
    }

    func receiveRemoval() {
        removed = true
        _ = sink?(.failure(.disconnected))
        emitReceiverFailure(.disconnected)
    }

    func receiveMatching(_ added: BoltNativeDevice) {
        guard let device, let addedKey = native.registryKey(added),
              addedKey != native.registryKey(device),
              native.eligible(added, connection: connection) else { return }
        guard selectedEndpoint == nil else { return }
        inputFailed = true
        _ = sink?(.failure(.ambiguous))
        _ = receiverSink?(.failure(.ambiguous))
    }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8], optionalInformation: Bool = false) throws -> [UInt8] {
        guard let device, !removed else { throw BoltFailure.disconnected }
        guard !pendingSend, expected == nil, expectedRegister == nil, !registerLaneUncertain,
              !inputFailed, parameters.count <= 16, function <= 15 else { throw BoltFailure.transport }
        let transaction = try BoltRequestTransaction(ledger: requestIDs, slot: slot, feature: feature, function: function, parameters: parameters)
        defer { transaction.retire() }
        expected = transaction
        self.optionalInformation = optionalInformation
        defer { self.optionalInformation = false }
        reply = nil
        sendResult = nil
        sendCompleted = 0
        sendDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        requestDeadline = sendDeadline + 4
        pendingSend = true
        if connection == .bluetooth {
            guard let raw = device.raw, let outputElement = outputElement?.raw, transaction.frame.count == 20,
                  transaction.frame[0] == 0x11, transaction.frame[1] == 0xFF else {
                pendingSend = false
                expected = nil
                throw BoltFailure.transport
            }
            let body = Array(transaction.frame.dropFirst())
            let status = body.withUnsafeBufferPointer { bytes -> IOReturn in
                guard let baseAddress = bytes.baseAddress,
                      let value = IOHIDValueCreateWithBytes(kCFAllocatorDefault, outputElement, 0,
                                                            baseAddress, bytes.count) else { return kIOReturnError }
                return IOHIDDeviceSetValue(raw, outputElement, value)
            }
            sendCompleted = ProcessInfo.processInfo.systemUptime
            sendResult = status
            pendingSend = false
        } else {
            let packet = BoltHIDSend(worker: self, frame: transaction.frame)
            let packetContext = Unmanaged.passRetained(packet).toOpaque()
            let status = native.sendReport(device, reportID: 0x11, bytes: packet.bytes, count: 20,
                                           callback: BoltHIDSend.completion, context: packetContext)
            if status != kIOReturnSuccess {
                Unmanaged<BoltHIDSend>.fromOpaque(packetContext).release()
                pendingSend = false
                expected = nil
                throw BoltFailure.transport
            }
        }
        while pendingSend, !removed, ProcessInfo.processInfo.systemUptime <= sendDeadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        guard !pendingSend else {
            expected = nil
            inputFailed = true
            // The callback owns its packet storage until IOKit relinquishes it.
            throw optionalInformation ? BoltFailure.transport : BoltFailure.timeout
        }
        defer { expected = nil }
        guard !removed else { throw BoltFailure.disconnected }
        guard sendResult == kIOReturnSuccess, sendCompleted <= sendDeadline else { throw BoltFailure.transport }
        let deadline = min(requestDeadline, sendCompleted + 4)
        while reply == nil, !removed, !inputFailed, ProcessInfo.processInfo.systemUptime <= deadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        guard !removed else { throw BoltFailure.disconnected }
        guard !inputFailed else { throw BoltFailure.transport }
        guard let reply else { throw BoltFailure.timeout }
        do {
            return try transaction.complete(matchedReply: reply, sendSucceeded: true)
        } catch {
            if optionalInformation, case .failure = reply { throw BoltDeviceInformationRequestError.protocolRejected }
            throw error
        }
    }

    func registerRequest(_ request: BoltReceiverRegisterRequest) throws -> BoltReceiverRegisterReply {
        guard connection == .bolt, let device, !removed else { throw BoltReceiverTransportFailure.disconnected }
        guard !pendingSend, expected == nil, expectedRegister == nil, !inputFailed else {
            throw BoltReceiverTransportFailure.busy
        }
        guard !registerLaneUncertain else { throw BoltReceiverTransportFailure.timeout }

        let frame = request.frame()
        expectedRegister = request
        registerReply = nil
        registerFailure = nil
        sendResult = nil
        sendCompleted = 0
        sendDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        requestDeadline = sendDeadline + 4
        pendingSend = true

        let packet = BoltHIDSend(worker: self, frame: frame)
        let packetContext = Unmanaged.passRetained(packet).toOpaque()
        let status = native.sendReport(device, reportID: Int(frame[0]),
                                       bytes: packet.bytes, count: frame.count,
                                       callback: BoltHIDSend.completion, context: packetContext)
        if status != kIOReturnSuccess {
            Unmanaged<BoltHIDSend>.fromOpaque(packetContext).release()
            pendingSend = false
            expectedRegister = nil
            throw BoltReceiverTransportFailure.transport
        }

        while pendingSend, !removed, ProcessInfo.processInfo.systemUptime <= sendDeadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        guard !pendingSend else {
            expectedRegister = nil
            registerLaneUncertain = true
            inputFailed = true
            throw BoltReceiverTransportFailure.timeout
        }
        guard !removed else { expectedRegister = nil; throw BoltReceiverTransportFailure.disconnected }
        guard sendResult == kIOReturnSuccess, sendCompleted <= sendDeadline else {
            expectedRegister = nil
            registerLaneUncertain = true
            throw BoltReceiverTransportFailure.transport
        }

        let deadline = min(requestDeadline, sendCompleted + 4)
        while registerReply == nil, registerFailure == nil, !removed, !inputFailed,
              ProcessInfo.processInfo.systemUptime <= deadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        guard !removed else { expectedRegister = nil; throw BoltReceiverTransportFailure.disconnected }
        guard !inputFailed else { expectedRegister = nil; throw BoltReceiverTransportFailure.transport }
        if let registerFailure {
            expectedRegister = nil
            self.registerFailure = nil
            throw registerFailure
        }
        guard let registerReply else {
            expectedRegister = nil
            registerLaneUncertain = true
            throw BoltReceiverTransportFailure.timeout
        }
        expectedRegister = nil
        self.registerReply = nil

        switch registerReply {
        case .reply(let reply):
            return reply
        case .error(let error):
            throw BoltReceiverTransportFailure.registerRejected(code: error.code)
        }
    }

    func cancelRequest(_ request: BoltReceiverRegisterRequest) throws -> BoltReceiverCancellationResult {
        guard BoltReceiverProtocol.isCancellation(request) else { throw BoltReceiverTransportFailure.malformed }
        guard connection == .bolt, let device, !removed else { throw BoltReceiverTransportFailure.disconnected }
        guard !pendingSend, expected == nil, expectedRegister == nil, !inputFailed else {
            throw BoltReceiverTransportFailure.busy
        }
        guard cancellationLedger.claim(request) else {
            throw BoltReceiverTransportFailure.cancellationAlreadyAttempted
        }

        guard registerLaneUncertain else {
            return .acknowledged(try registerRequest(request))
        }
        return try dispatchCancellationWithoutReply(device: device, request: request)
    }

    private func dispatchCancellationWithoutReply(device: BoltNativeDevice,
                                                  request: BoltReceiverRegisterRequest) throws -> BoltReceiverCancellationResult {
        let frame = request.frame()
        registerReply = nil
        sendResult = nil
        sendCompleted = 0
        sendDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        pendingSend = true

        let packet = BoltHIDSend(worker: self, frame: frame)
        let packetContext = Unmanaged.passRetained(packet).toOpaque()
        let status = native.sendReport(device, reportID: Int(frame[0]),
                                       bytes: packet.bytes, count: frame.count,
                                       callback: BoltHIDSend.completion, context: packetContext)
        if status != kIOReturnSuccess {
            Unmanaged<BoltHIDSend>.fromOpaque(packetContext).release()
            pendingSend = false
            throw BoltReceiverTransportFailure.transport
        }

        while pendingSend, !removed, ProcessInfo.processInfo.systemUptime <= sendDeadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        guard !pendingSend else {
            inputFailed = true
            throw BoltReceiverTransportFailure.timeout
        }
        guard !removed else { throw BoltReceiverTransportFailure.disconnected }
        guard sendResult == kIOReturnSuccess, sendCompleted <= sendDeadline else {
            throw BoltReceiverTransportFailure.transport
        }

        registerLaneUncertain = true
        return .dispatchedUnconfirmed
    }

    fileprivate func completeSend(_ result: IOReturn) {
        sendCompleted = ProcessInfo.processInfo.systemUptime
        sendResult = result
        pendingSend = false
    }

    func receive(result: IOReturn, type: IOHIDReportType, reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, count: CFIndex) {
        nativeInputDiagnostics.recordCallback()
        var disposition = BoltNativeInputDisposition.unmatchedReport
        defer { nativeInputDiagnostics.record(disposition) }
        guard !removed else { return }
        guard result == kIOReturnSuccess else {
            disposition = .callbackError
            inputFailed = true
            _ = sink?(.failure(.transport))
            emitReceiverFailure(.transport)
            return
        }
        guard type == kIOHIDReportTypeInput, reportID == 0x10 || reportID == 0x11, (4...256).contains(count) else {
            disposition = .metadataRejected
            return
        }
        let report = Array(UnsafeBufferPointer(start: bytes, count: count))
        guard report[0] == UInt8(reportID) else {
            disposition = .reportIDMismatch
            return
        }
        if let expectedRegister, registerReply == nil, registerFailure == nil,
           ProcessInfo.processInfo.systemUptime <= requestDeadline {
            switch BoltReceiverProtocol.responseMatch(report, for: expectedRegister) {
            case .matched(let response):
                disposition = .registerReply
                registerReply = response
                return
            case .malformed:
                registerFailure = .malformed
                registerLaneUncertain = true
                emitReceiverFailure(.malformed)
                return
            case .unrelated:
                break
            }
        }
        if !receiverNotificationsStopped {
            do {
                if let notification = try BoltReceiverProtocol.notification(report) {
                    disposition = .receiverNotification
                    if receiverSink?(.notification(notification, at: .now)) == false {
                        receiverNotificationsStopped = true
                    }
                    return
                }
            } catch {
                emitReceiverFailure(.malformed)
            }
        }
        if let expected, reply == nil, ProcessInfo.processInfo.systemUptime <= requestDeadline {
            if let matched = expected.reply(report) {
                disposition = .featureReply
                reply = matched
                if let error = Self.matchedReplyFailure(matched, optionalInformation: optionalInformation) {
                    _ = sink?(.failure(error))
                }
                return
            }
        }
        if (reportID == 0x10 || reportID == 0x11), report[2] != 0xFF, report[3] == 0 {
            guard !notificationStopped else { return }
            if sink?(.report(report, at: .now)) == false { notificationStopped = true }
            return
        }
    }

    private func emitReceiverFailure(_ failure: BoltReceiverTransportFailure) {
        guard !receiverNotificationsStopped else { return }
        receiverNotificationsStopped = true
        _ = receiverSink?(.failure(failure))
    }

    static func matchedReplyFailure(_ reply: Result<[UInt8], BoltFailure>, optionalInformation: Bool) -> BoltFailure? {
        guard !optionalInformation, case .failure(let error) = reply, error != .unavailable else { return nil }
        return error
    }

    static func localCloseResult(_ result: IOReturn, removalObserved: Bool) -> BoltTransportCloseResult {
        if result == kIOReturnSuccess || result == kIOReturnNotOpen { return .closed }
        if removalObserved, result == kIOReturnNoDevice || result == kIOReturnOffline { return .closed }
        return .unverified
    }

    private func closeNativeHandle() -> BoltTransportCloseResult {
        let context = callbackToken
        BoltHIDCallbackRegistry.shared.retireAndWait(context)
        callbackToken = nil
        let result = tearDownNativeObjects(context: context)
        input = nil
        if result == .unverified { nativeTeardownUnverified = true }
        return nativeTeardownUnverified ? .unverified : result
    }

    private func tearDownNativeObjects(context: UnsafeMutableRawPointer?) -> BoltTransportCloseResult {
        if let manager {
            native.unregister(manager, context: context)
            native.unschedule(manager)
        }
        guard let device else { manager = nil; return .closed }
        expected = nil
        expectedRegister = nil
        registerReply = nil
        registerFailure = nil
        native.unregister(device, context: context)
        native.unschedule(device)
        let result = native.close(device)
        self.device = nil
        outputElement = nil
        manager = nil
        sink = nil
        receiverSink = nil
        return Self.localCloseResult(result, removalObserved: removed)
    }
}
