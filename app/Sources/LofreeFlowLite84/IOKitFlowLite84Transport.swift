import Foundation
import IOKit
import IOKit.hid

public final class IOKitFlowLite84Transport: FlowLite84Transport, Sendable {
    public let reports: AsyncThrowingStream<Data, Error>
    private let worker: FlowLite84HIDWorker

    public init() {
        let stream = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(32))
        reports = stream.stream
        worker = FlowLite84HIDWorker(continuation: stream.continuation)
    }

    deinit { worker.requestClose() }

    public func open() async throws {
        try Task.checkCancellation()
        try await worker.submit { try $0.open() }
        try Task.checkCancellation()
    }

    public func write(_ report: Data) async throws {
        try FlowLite84Codec.validateOutput(report)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await worker.submit { try $0.write(report) }
            try Task.checkCancellation()
        } onCancel: {
            self.worker.requestClose()
        }
    }

    public func close() async { await worker.close() }
}

private final class FlowLite84ReportWrite {
    let bytes: UnsafeMutablePointer<UInt8>
    var result: IOReturn?

    init(_ report: Data) {
        bytes = .allocate(capacity: FlowLite84Codec.reportSize)
        _ = report.copyBytes(to: UnsafeMutableBufferPointer(start: bytes, count: FlowLite84Codec.reportSize))
    }

    deinit { bytes.deallocate() }
}

private final class FlowLite84WriteRegistry: @unchecked Sendable {
    static let shared = FlowLite84WriteRegistry()
    private let lock = NSLock()
    private var sequence: UInt = 0
    private var pending: [UInt: FlowLite84ReportWrite] = [:]

    func insert(_ packet: FlowLite84ReportWrite) -> UInt {
        lock.withLock {
            repeat { sequence &+= 1 } while sequence == 0 || pending[sequence] != nil
            pending[sequence] = packet
            return sequence
        }
    }

    func remove(_ token: UInt) -> FlowLite84ReportWrite? {
        lock.withLock { pending.removeValue(forKey: token) }
    }
}

private final class FlowLite84HIDWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var jobs: [@Sendable () -> Void] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var thread: Thread?
    private var loop: CFRunLoop?
    private var wakeSource: CFRunLoopSource?
    private var closing = false
    private var finished = false
    private var device: IOHIDDevice?
    private var terminal: FlowLite84Failure?
    private var writeToken: UInt?
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: FlowLite84Codec.reportSize)

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }

    deinit { input.deallocate() }

    func submit<T: Sendable>(_ body: @escaping @Sendable (FlowLite84HIDWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { waiter in
            lock.lock()
            guard !closing, !finished else {
                lock.unlock()
                waiter.resume(throwing: FlowLite84Failure.disconnected)
                return
            }
            guard jobs.count < 16 else {
                lock.unlock()
                continuation.finish(throwing: FlowLite84Failure.overflow)
                requestClose()
                waiter.resume(throwing: FlowLite84Failure.overflow)
                return
            }
            jobs.append { [self] in
                do {
                    guard !isClosing else { throw FlowLite84Failure.disconnected }
                    waiter.resume(returning: try body(self))
                } catch {
                    continuation.finish(throwing: error as? FlowLite84Failure ?? .transport)
                    requestClose()
                    waiter.resume(throwing: error)
                }
            }
            startLocked()
            let loop = loop
            let source = wakeSource
            lock.unlock()
            if let source { CFRunLoopSourceSignal(source) }
            if let loop { CFRunLoopWakeUp(loop) }
        }
    }

    private var isClosing: Bool { lock.withLock { closing } }

    private func startLocked() {
        guard thread == nil else { return }
        let thread = Thread { [self] in run() }
        thread.name = "Hidhogg Flow Lite84 HID"
        self.thread = thread
        thread.start()
    }

    private func run() {
        let runLoop = CFRunLoopGetCurrent()!
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        let source = CFRunLoopSourceCreate(nil, 0, &context)!
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        lock.withLock { loop = runLoop; wakeSource = source }
        while true {
            let job = lock.withLock { jobs.isEmpty ? nil : jobs.removeFirst() }
            if let job { job(); continue }
            if isClosing { break }
            CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, true)
        }
        cleanup()
        continuation.finish()
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
        let waiters = lock.withLock {
            finished = true
            loop = nil
            wakeSource = nil
            thread = nil
            let waiters = closeWaiters
            closeWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func requestClose() {
        let (runLoop, source): (CFRunLoop?, CFRunLoopSource?) = lock.withLock {
            closing = true
            guard thread != nil else {
                finished = true
                return (nil, nil)
            }
            return (loop, wakeSource)
        }
        if let source { CFRunLoopSourceSignal(source) }
        if let runLoop { CFRunLoopWakeUp(runLoop) }
        continuation.finish()
    }

    func close() async {
        requestClose()
        await withCheckedContinuation { waiter in
            lock.lock()
            if finished { lock.unlock(); waiter.resume(); return }
            closeWaiters.append(waiter)
            lock.unlock()
        }
    }

    func open() throws {
        guard device == nil, terminal == nil else { throw FlowLite84Failure.disconnected }
        let selected = try Self.selectDevice()
        guard !isClosing else { throw FlowLite84Failure.cancelled }
        guard IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw FlowLite84Failure.transport
        }
        device = selected
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(selected, input, FlowLite84Codec.reportSize, { context, result, _, type, reportID, bytes, count in
            guard let context else { return }
            Unmanaged<FlowLite84HIDWorker>.fromOpaque(context).takeUnretainedValue().receive(
                result: result, type: type, reportID: reportID, bytes: bytes, count: count
            )
        }, context)
        IOHIDDeviceRegisterRemovalCallback(selected, { context, _, _ in
            guard let context else { return }
            Unmanaged<FlowLite84HIDWorker>.fromOpaque(context).takeUnretainedValue().fail(.disconnected)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(selected, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private static func selectDevice() throws -> IOHIDDevice {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) else { throw FlowLite84Failure.unavailable }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw FlowLite84Failure.transport
        }
        defer { IOObjectRelease(iterator) }
        var candidates: [UInt64: IOHIDDevice] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let device = IOHIDDeviceCreate(nil, service), eligible(device) else { continue }
            var serviceID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &serviceID) == KERN_SUCCESS else {
                throw FlowLite84Failure.transport
            }
            candidates[serviceID] = device
        }
        guard candidates.count == 1, let device = candidates.values.first else {
            throw candidates.isEmpty ? FlowLite84Failure.unavailable : .ambiguous
        }
        return device
    }

    private static func eligible(_ device: IOHIDDevice) -> Bool {
        guard (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue == 0x05ac,
              (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == 0x024f,
              IOHIDDeviceConformsTo(device, 0xff02, 2),
              let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else {
            return false
        }
        return FlowLite84Codec.hasConfigurationCollection(descriptor)
    }

    func write(_ report: Data) throws {
        try FlowLite84Codec.validateOutput(report)
        guard let device, terminal == nil else { throw terminal ?? FlowLite84Failure.disconnected }
        guard !isClosing else { throw FlowLite84Failure.cancelled }
        let packet = FlowLite84ReportWrite(report)
        let token = FlowLite84WriteRegistry.shared.insert(packet)
        writeToken = token
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        let result = IOHIDDeviceSetReportWithCallback(
            device, kIOHIDReportTypeOutput, CFIndex(FlowLite84Codec.reportID), packet.bytes,
            FlowLite84Codec.reportSize, 600,
            { context, result, _, _, _, _, _ in
                guard let context else { return }
                FlowLite84WriteRegistry.shared.remove(UInt(bitPattern: context))?.result = result
            }, UnsafeMutableRawPointer(bitPattern: token)
        )
        guard result == kIOReturnSuccess else {
            _ = FlowLite84WriteRegistry.shared.remove(token)
            writeToken = nil
            throw FlowLite84Failure.transport
        }
        while packet.result == nil, ContinuousClock.now < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.005, true)
        }
        guard !isClosing, terminal == nil else { throw terminal ?? FlowLite84Failure.cancelled }
        guard let result = packet.result else { throw FlowLite84Failure.timeout }
        guard result == kIOReturnSuccess else { throw FlowLite84Failure.transport }
        writeToken = nil
    }

    private func receive(result: IOReturn, type: IOHIDReportType, reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, count: CFIndex) {
        defer { input.initialize(repeating: 0, count: FlowLite84Codec.reportSize) }
        guard terminal == nil, !isClosing else { return }
        guard type == kIOHIDReportTypeInput, reportID == UInt32(FlowLite84Codec.reportID),
              count == FlowLite84Codec.payloadSize || count == FlowLite84Codec.reportSize else { return }
        guard result == kIOReturnSuccess else { fail(.transport); return }
        do {
            guard let safe = try FlowLite84Codec.sanitizedInput(
                reportID: reportID, bytes: UnsafeBufferPointer(start: bytes, count: count)
            ) else { return }
            if case .dropped = continuation.yield(safe) { fail(.overflow) }
        } catch {
            fail(error as? FlowLite84Failure ?? .invalidFrame)
        }
    }

    private func fail(_ failure: FlowLite84Failure) {
        guard terminal == nil else { return }
        terminal = failure
        continuation.finish(throwing: failure)
        requestClose()
    }

    private func cleanup() {
        if let device {
            IOHIDDeviceRegisterInputReportCallback(device, input, FlowLite84Codec.reportSize, nil, nil)
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        // A late callback holds only a token; closing the device releases the outstanding report buffer.
        if let writeToken { _ = FlowLite84WriteRegistry.shared.remove(writeToken) }
        writeToken = nil
        input.initialize(repeating: 0, count: FlowLite84Codec.reportSize)
    }
}
