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
        if let snapshot = try? await worker.submit({
            $0.close()
            return $0.nativeInputDiagnostics
        }) {
            diagnosticsLock.withLock { retainedInputDiagnostics = snapshot }
        }
        continuation.finish()
        receiverContinuation.finish()
        worker.finish()
    }
}

private final class BoltHIDSend {
    weak var worker: BoltHIDWorker?
    let bytes: UnsafeMutablePointer<UInt8>

    init(worker: BoltHIDWorker, frame: [UInt8]) {
        self.worker = worker
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
    private var finished = false
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var outputElement: IOHIDElement?
    private var input = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
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
         requireEndpoint: Bool = false) {
        self.connection = connection
        self.selectedEndpoint = selectedEndpoint
        self.requireEndpoint = requireEndpoint
    }

    deinit {
        input.deallocate()
    }

    func submit<T: Sendable>(_ body: @escaping @Sendable (BoltHIDWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if finished {
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
                    lock.withLock {
                        finished = true
                        runLoop = nil
                        self.thread = nil
                    }
                }
                thread.name = "Hidhogg Bolt HID"
                self.thread = thread
                thread.start()
                started.wait()
            }
            let loop = runLoop!
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                do { continuation.resume(returning: try body(self)) }
                catch { continuation.resume(throwing: error) }
            }
            lock.unlock()
            CFRunLoopWakeUp(loop)
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let loop = runLoop
        thread = nil
        lock.unlock()
        if let loop { CFRunLoopStop(loop); CFRunLoopWakeUp(loop) }
    }

    func open() throws {
        guard device == nil else { throw BoltFailure.transport }
        nativeInputDiagnostics = .init(available: true)
        let manager = IOHIDManagerCreate(nil, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [[String: Any]] = switch connection {
        case .bolt:
            [[kIOHIDVendorIDKey as String: LogitechEndpointEligibility.vendorID,
              kIOHIDProductIDKey as String: LogitechEndpointEligibility.boltProductID,
              kIOHIDTransportKey as String: kIOHIDTransportUSBValue]]
        case .bluetooth:
            LogitechEndpointEligibility.bluetoothProductIDs.sorted().map {
                [kIOHIDVendorIDKey as String: LogitechEndpointEligibility.vendorID,
                 kIOHIDProductIDKey as String: $0]
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let selected: IOHIDDevice
        if let selectedEndpoint {
            guard eligible(selectedEndpoint.device) else { throw BoltFailure.unavailable }
            selected = selectedEndpoint.device
        } else {
            guard !requireEndpoint,
                  let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { throw BoltFailure.unavailable }
            let candidates = devices.filter { eligible($0) }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw candidates.isEmpty ? BoltFailure.unavailable : BoltFailure.ambiguous
            }
            selected = candidate
        }
        outputElement = connection == .bluetooth ? bluetoothOutputElement(for: selected) : nil
        if connection == .bluetooth, outputElement == nil { throw BoltFailure.unavailable }
        guard IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { throw BoltFailure.transport }
        device = selected
        removed = false
        inputFailed = false
        notificationStopped = false
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(selected, input, 256, { context, result, _, type, reportID, bytes, count in
            guard let context else { return }
            Unmanaged<BoltHIDWorker>.fromOpaque(context).takeUnretainedValue().receive(result: result, type: type, reportID: reportID, bytes: bytes, count: count)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(selected, { context, _, _ in
            guard let context else { return }
            let worker = Unmanaged<BoltHIDWorker>.fromOpaque(context).takeUnretainedValue()
            worker.removed = true
            _ = worker.sink?(.failure(.disconnected))
            worker.emitReceiverFailure(.disconnected)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(selected, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, added in
            guard let context else { return }
            let worker = Unmanaged<BoltHIDWorker>.fromOpaque(context).takeUnretainedValue()
            guard added != worker.device, worker.eligible(added) else { return }
            guard worker.selectedEndpoint == nil else { return }
            worker.inputFailed = true
            _ = worker.sink?(.failure(.ambiguous))
            _ = worker.receiverSink?(.failure(.ambiguous))
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func eligible(_ device: IOHIDDevice) -> Bool {
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        let capacity = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return false }
        if connection == .bluetooth { return bluetoothOutputElement(for: device) != nil }
        let reportTypes = elements
            .filter { IOHIDElementGetReportID($0) == LogitechEndpointEligibility.hidppReportID }
            .map { (IOHIDElementGetReportID($0), IOHIDElementGetType($0).rawValue) }
        return LogitechEndpointEligibility.isEligibleBolt(vendorID: vendorID, productID: productID,
                                                           transport: transport, maxInputReportSize: capacity,
                                                           reportIDs: reportTypes)
    }

    private func bluetoothOutputElement(for device: IOHIDDevice) -> IOHIDElement? {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return nil }
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        let outputs = elements.filter { element in
            LogitechEndpointEligibility.bluetoothOutputIsEligible(
                vendorID: vendorID, productID: productID, transport: transport,
                output: LogitechBluetoothOutputDescriptor(
                    reportID: IOHIDElementGetReportID(element),
                    usagePage: IOHIDElementGetUsagePage(element),
                    isOutput: IOHIDElementGetType(element) == kIOHIDElementTypeOutput,
                    reportCount: IOHIDElementGetReportCount(element),
                    reportSize: IOHIDElementGetReportSize(element)
                )
            )
        }
        let hasInput = elements.contains {
            IOHIDElementGetReportID($0) == LogitechEndpointEligibility.hidppReportID
                && [1, 2, 3, 4, 5].contains(IOHIDElementGetType($0).rawValue)
        }
        return outputs.count == 1 && hasInput ? outputs[0] : nil
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
            guard let outputElement, transaction.frame.count == 20,
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
                return IOHIDDeviceSetValue(device, outputElement, value)
            }
            sendCompleted = ProcessInfo.processInfo.systemUptime
            sendResult = status
            pendingSend = false
        } else {
            let packet = BoltHIDSend(worker: self, frame: transaction.frame)
            let packetContext = Unmanaged.passRetained(packet).toOpaque()
            let status = IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, 0x11, packet.bytes, 20, 600, { context, result, _, _, _, _, _ in
                guard let context else { return }
                let packet = Unmanaged<BoltHIDSend>.fromOpaque(context).takeRetainedValue()
                guard let worker = packet.worker else { return }
                worker.sendCompleted = ProcessInfo.processInfo.systemUptime
                worker.sendResult = result
                worker.pendingSend = false
            }, packetContext)
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
        let status = IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, Int(frame[0]),
                                                      packet.bytes, frame.count, 600, { context, result, _, _, _, _, _ in
            guard let context else { return }
            let packet = Unmanaged<BoltHIDSend>.fromOpaque(context).takeRetainedValue()
            guard let worker = packet.worker else { return }
            worker.sendCompleted = ProcessInfo.processInfo.systemUptime
            worker.sendResult = result
            worker.pendingSend = false
        }, packetContext)
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

    private func dispatchCancellationWithoutReply(device: IOHIDDevice,
                                                  request: BoltReceiverRegisterRequest) throws -> BoltReceiverCancellationResult {
        let frame = request.frame()
        registerReply = nil
        sendResult = nil
        sendCompleted = 0
        sendDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        pendingSend = true

        let packet = BoltHIDSend(worker: self, frame: frame)
        let packetContext = Unmanaged.passRetained(packet).toOpaque()
        let status = IOHIDDeviceSetReportWithCallback(device, kIOHIDReportTypeOutput, Int(frame[0]),
                                                      packet.bytes, frame.count, 600, { context, result, _, _, _, _, _ in
            guard let context else { return }
            let packet = Unmanaged<BoltHIDSend>.fromOpaque(context).takeRetainedValue()
            guard let worker = packet.worker else { return }
            worker.sendCompleted = ProcessInfo.processInfo.systemUptime
            worker.sendResult = result
            worker.pendingSend = false
        }, packetContext)
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

    func close() {
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        guard let device else { manager = nil; return }
        expected = nil
        expectedRegister = nil
        registerReply = nil
        registerFailure = nil
        IOHIDDeviceRegisterInputReportCallback(device, input, 256, nil, nil)
        IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
        outputElement = nil
        manager = nil
    }
}
