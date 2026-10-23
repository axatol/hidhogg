import Foundation
import IOKit
import IOKit.hid

public final class IOKitD200XTransport: D200XTransport, Sendable {
    public let reports: AsyncThrowingStream<Data, Error>
    private let worker: D200XHIDWorker

    public init() {
        let stream = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(128))
        reports = stream.stream
        worker = D200XHIDWorker(continuation: stream.continuation)
    }

    deinit { worker.requestClose() }

    public func open() async throws {
        try await worker.submit { try $0.open() }
    }

    public func write(_ reports: [Data]) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await worker.submit { try $0.write(reports) }
            try Task.checkCancellation()
        } onCancel: {
            self.worker.requestClose()
        }
    }

    public func close() async { await worker.close() }
}

private final class D200XReportWrite {
    let bytes: UnsafeMutablePointer<UInt8>
    var result: IOReturn?

    init(_ report: Data) {
        bytes = .allocate(capacity: D200XCodec.reportSize)
        _ = report.copyBytes(to: UnsafeMutableBufferPointer(start: bytes, count: D200XCodec.reportSize))
    }

    deinit { bytes.deallocate() }
}

private final class D200XHIDWorker: @unchecked Sendable {
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
    private var manager: IOHIDManager?
    private var terminal: D200XFailure?
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: D200XCodec.reportSize)

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }

    deinit { input.deallocate() }

    func submit<T: Sendable>(_ body: @escaping @Sendable (D200XHIDWorker) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { waiter in
            lock.lock()
            guard !closing, !finished else {
                lock.unlock()
                waiter.resume(throwing: D200XFailure.disconnected)
                return
            }
            guard jobs.count < 64 else {
                lock.unlock()
                continuation.finish(throwing: D200XFailure.overflow)
                requestClose()
                waiter.resume(throwing: D200XFailure.overflow)
                return
            }
            jobs.append { [self] in
                do {
                    guard !isClosing else { throw D200XFailure.disconnected }
                    waiter.resume(returning: try body(self))
                } catch {
                    cleanup()
                    continuation.finish(throwing: error as? D200XFailure ?? .transport)
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
        thread.name = "Hidhogg D200X HID"
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
        guard device == nil, terminal == nil else { throw D200XFailure.disconnected }
        let manager = IOHIDManagerCreate(nil, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x2207, kIOHIDProductIDKey: 0x0019,
            kIOHIDPrimaryUsagePageKey: 12, kIOHIDPrimaryUsageKey: 1,
            kIOHIDTransportKey: kIOHIDTransportUSBValue,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw D200XFailure.transport
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { throw D200XFailure.unavailable }
        let candidates = devices.filter(Self.eligible)
        guard candidates.count == 1, let selected = candidates.first else {
            throw candidates.isEmpty ? D200XFailure.unavailable : D200XFailure.ambiguous
        }
        guard IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            throw D200XFailure.transport
        }
        device = selected
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(selected, input, D200XCodec.reportSize, { context, result, _, type, reportID, bytes, count in
            guard let context else { return }
            let worker = Unmanaged<D200XHIDWorker>.fromOpaque(context).takeUnretainedValue()
            worker.receive(result: result, type: type, reportID: reportID, bytes: bytes, count: count)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(selected, { context, _, _ in
            guard let context else { return }
            Unmanaged<D200XHIDWorker>.fromOpaque(context).takeUnretainedValue().fail(.disconnected)
        }, context)
        IOHIDDeviceScheduleWithRunLoop(selected, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    static func eligible(_ device: IOHIDDevice) -> Bool {
        let service = IOHIDDeviceGetService(device)
        let interface = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        ) as? NSNumber
        guard interface?.intValue == 0,
              (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue == 12,
              (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue == 1,
              (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue == 1024,
              (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue == 1024,
              let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return false }
        return elements.contains { IOHIDElementGetReportID($0) == 0 && IOHIDElementGetType($0) == kIOHIDElementTypeOutput }
    }

    func write(_ reports: [Data]) throws {
        guard !reports.isEmpty,
              reports.count <= D200XCodec.maximumPayloadSize / D200XCodec.reportSize + 1,
              reports.allSatisfy({ $0.count == D200XCodec.reportSize }) else { throw D200XFailure.invalidFrame }
        guard let device, terminal == nil else { throw terminal ?? D200XFailure.disconnected }
        let transactionDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        for report in reports {
            guard !isClosing, terminal == nil else { throw terminal ?? D200XFailure.cancelled }
            guard ContinuousClock.now < transactionDeadline else { throw D200XFailure.timeout }
            let packet = D200XReportWrite(report)
            let context = Unmanaged.passRetained(packet).toOpaque()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(650))
            let result = IOHIDDeviceSetReportWithCallback(
                device, kIOHIDReportTypeOutput, 0, packet.bytes, D200XCodec.reportSize, 600,
                { context, result, _, _, _, _, _ in
                    guard let context else { return }
                    let packet = Unmanaged<D200XReportWrite>.fromOpaque(context).takeRetainedValue()
                    packet.result = result
                }, context
            )
            guard result == kIOReturnSuccess else {
                Unmanaged<D200XReportWrite>.fromOpaque(context).release()
                throw D200XFailure.transport
            }
            // Finish the in-flight callback before releasing its scheduled run loop on cancellation.
            while packet.result == nil, ContinuousClock.now < deadline {
                CFRunLoopRunInMode(.defaultMode, 0.005, true)
            }
            guard !isClosing, terminal == nil else { throw terminal ?? D200XFailure.cancelled }
            guard let result = packet.result else { throw D200XFailure.timeout }
            guard result == kIOReturnSuccess else { throw D200XFailure.transport }
        }
    }

    private func receive(result: IOReturn, type: IOHIDReportType, reportID: UInt32, bytes: UnsafeMutablePointer<UInt8>, count: CFIndex) {
        guard terminal == nil, !isClosing else { return }
        guard result == kIOReturnSuccess else { fail(.transport); return }
        guard type == kIOHIDReportTypeInput, reportID == 0, (10...D200XCodec.reportSize).contains(count) else {
            fail(.invalidFrame)
            return
        }
        if case .dropped = continuation.yield(Data(bytes: bytes, count: count)) { fail(.overflow) }
    }

    private func fail(_ failure: D200XFailure) {
        guard terminal == nil else { return }
        terminal = failure
        continuation.finish(throwing: failure)
        requestClose()
    }

    private func cleanup() {
        if let device {
            IOHIDDeviceRegisterInputReportCallback(device, input, D200XCodec.reportSize, nil, nil)
            IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
    }
}
