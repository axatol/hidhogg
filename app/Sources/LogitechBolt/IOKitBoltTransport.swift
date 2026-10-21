import Foundation
import IOKit.hid

final class IOKitBoltTransport: BoltTransport, @unchecked Sendable {
    let events: AsyncStream<BoltTransportEvent>
    private let continuation: AsyncStream<BoltTransportEvent>.Continuation
    private let worker = BoltHIDWorker()

    init(onTerminal: @escaping @Sendable () -> Void) {
        let stream = AsyncStream<BoltTransportEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        events = stream.stream
        continuation = stream.continuation
        worker.sink = { [continuation] event in
            if case .failure = event { onTerminal() }
            if case .dropped = continuation.yield(event) {
                onTerminal()
                continuation.yield(.failure(.overflow))
                return false
            }
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

    func close() async {
        _ = try? await worker.submit { $0.close() }
        continuation.finish()
        worker.finish()
    }
}

private final class BoltHIDSend {
    weak var worker: BoltHIDWorker?
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 20)

    init(worker: BoltHIDWorker, frame: [UInt8]) {
        self.worker = worker
        bytes.initialize(from: frame, count: 20)
    }

    deinit { bytes.deallocate() }
}

final class BoltHIDWorker: @unchecked Sendable {
    var sink: (@Sendable (BoltTransportEvent) -> Bool)?
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var finished = false
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var input = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    private var removed = false
    private var inputFailed = false
    private var notificationStopped = false
    private var pendingSend = false
    private var sendResult: IOReturn?
    private var reply: Result<[UInt8], BoltFailure>?
    private var expected: BoltRequestTransaction?
    let requestIDs = BoltRequestIDLedger()
    private var sendDeadline: TimeInterval = 0
    private var sendCompleted: TimeInterval = 0
    private var requestDeadline: TimeInterval = 0

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
        let manager = IOHIDManagerCreate(nil, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: 0xC548, kIOHIDTransportKey: kIOHIDTransportUSBValue] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { throw BoltFailure.unavailable }
        let candidates = devices.filter { eligible($0) }
        guard candidates.count == 1, let selected = candidates.first else {
            throw candidates.isEmpty ? BoltFailure.unavailable : BoltFailure.ambiguous
        }
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
        }, context)
        IOHIDDeviceScheduleWithRunLoop(selected, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, added in
            guard let context else { return }
            let worker = Unmanaged<BoltHIDWorker>.fromOpaque(context).takeUnretainedValue()
            guard added != worker.device, worker.eligible(added) else { return }
            worker.inputFailed = true
            _ = worker.sink?(.failure(.ambiguous))
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func eligible(_ device: IOHIDDevice) -> Bool {
        guard let capacity = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber,
              (20...256).contains(capacity.intValue),
              let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return false }
        let reportElements = elements.filter { IOHIDElementGetReportID($0) == 0x11 }
        let inputTypes: Set<UInt32> = [1, 2, 3, 4, 5]
        return reportElements.contains { inputTypes.contains(IOHIDElementGetType($0).rawValue) }
            && reportElements.contains { IOHIDElementGetType($0) == kIOHIDElementTypeOutput }
    }

    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) throws -> [UInt8] {
        guard let device, !removed else { throw BoltFailure.disconnected }
        guard !pendingSend, expected == nil, !inputFailed, parameters.count <= 16, function <= 15 else { throw BoltFailure.transport }
        let transaction = try BoltRequestTransaction(ledger: requestIDs, slot: slot, feature: feature, function: function, parameters: parameters)
        defer { transaction.retire() }
        expected = transaction
        reply = nil
        sendResult = nil
        sendCompleted = 0
        sendDeadline = ProcessInfo.processInfo.systemUptime + 0.6
        requestDeadline = sendDeadline + 4
        pendingSend = true
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
        while pendingSend, !removed, ProcessInfo.processInfo.systemUptime <= sendDeadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        guard !pendingSend else {
            expected = nil
            inputFailed = true
            // The callback owns its packet storage until IOKit relinquishes it.
            throw BoltFailure.timeout
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
        return try transaction.complete(matchedReply: reply, sendSucceeded: true)
    }

    private func receive(result: IOReturn, type: IOHIDReportType, reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, count: CFIndex) {
        guard !removed else { return }
        guard result == kIOReturnSuccess else {
            inputFailed = true
            _ = sink?(.failure(.transport))
            return
        }
        guard type == kIOHIDReportTypeInput, reportID == 0x10 || reportID == 0x11, (4...256).contains(count) else { return }
        let report = Array(UnsafeBufferPointer(start: bytes, count: count))
        guard report[0] == UInt8(reportID) else { return }
        if let expected, reply == nil, ProcessInfo.processInfo.systemUptime <= requestDeadline {
            if let matched = expected.reply(report) {
                reply = matched
                if case .failure(let error) = matched, error != .unavailable { _ = sink?(.failure(error)) }
                return
            }
        }
        if (reportID == 0x10 || reportID == 0x11), report[2] != 0xFF, report[3] == 0 {
            guard !notificationStopped else { return }
            if sink?(.report(report, at: .now)) == false { notificationStopped = true }
            return
        }
    }

    func close() {
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        guard let device else { manager = nil; return }
        expected = nil
        IOHIDDeviceRegisterInputReportCallback(device, input, 256, nil, nil)
        IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        self.device = nil
        manager = nil
    }
}
