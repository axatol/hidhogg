import CoreFoundation
import Dispatch
import Foundation
import IOKit
import IOKit.hid

enum D200XNativeCandidateValidator {
    static func candidate(
        registryID: UInt64,
        deviceProperties: [String: Any],
        usbParentProperties: [[String: Any]]
    ) -> D200XDeviceCandidate? {
        guard let vendorID = unsignedInteger(deviceProperties[kIOHIDVendorIDKey as String]),
              let productID = unsignedInteger(deviceProperties[kIOHIDProductIDKey as String]),
              let outputSize = unsignedInteger(deviceProperties[kIOHIDMaxOutputReportSizeKey as String]),
              let usagePair = targetUsagePair(deviceProperties[kIOHIDDeviceUsagePairsKey as String]),
              let interfaceNumber = usbInterfaceNumber(usbParentProperties),
              vendorID <= UInt64(UInt16.max),
              productID <= UInt64(UInt16.max),
              outputSize <= UInt64(Int.max),
              interfaceNumber <= UInt64(Int.max) else {
            return nil
        }

        let candidate = D200XDeviceCandidate(
            registryID: registryID,
            vendorID: UInt16(vendorID),
            productID: UInt16(productID),
            interfaceNumber: Int(interfaceNumber),
            usagePage: usagePair.page,
            usage: usagePair.usage,
            maximumOutputReportSize: Int(outputSize)
        )
        return candidate.isEligible ? candidate : nil
    }

    private static func usbInterfaceNumber(_ parents: [[String: Any]]) -> UInt64? {
        for parent in parents {
            guard let value = parent["bInterfaceNumber"] else { continue }
            return unsignedInteger(value)
        }
        return nil
    }

    private static func targetUsagePair(_ value: Any?) -> (page: UInt16, usage: UInt16)? {
        guard let entries = value as? [Any], !entries.isEmpty else { return nil }
        var target: (page: UInt16, usage: UInt16)?
        for entry in entries {
            guard let pair = entry as? [String: Any],
                  let page = unsignedInteger(pair[kIOHIDDeviceUsagePageKey as String]),
                  let usage = unsignedInteger(pair[kIOHIDDeviceUsageKey as String]),
                  page <= UInt64(UInt16.max),
                  usage <= UInt64(UInt16.max) else {
                return nil
            }
            if page == 0x000c && usage == 0x0001 { target = (UInt16(page), UInt16(usage)) }
        }
        return target
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let value, let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return nil
        }
        let signedValue = number.int64Value
        guard signedValue >= 0 else { return nil }
        return UInt64(signedValue)
    }
}

enum D200XNativeCloseResult {
    static func stopOutcome(status: Int32) -> D200XSessionStopOutcome {
        status == Int32(kIOReturnSuccess) ? .closed : .cleanupUncertain
    }
}

final class NativeD200XBackend: D200XSessionBackend, @unchecked Sendable {
    private struct DiscoveryRecord: @unchecked Sendable {
        let manager: IOHIDManager
        let device: IOHIDDevice
        let candidate: D200XDeviceCandidate
    }

    private struct CallbackRegistrationResources: @unchecked Sendable {
        let buffer: UnsafeMutablePointer<UInt8>
        let context: UnsafeMutableRawPointer
    }

    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var manager: IOHIDManager?
    private var inputLoop: D200XNativeInputLoop?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var retainedCallbackContext: UnsafeMutableRawPointer?
    private var reportAssembler: D200XFrameAssembler?
    private let stopCleanupForTesting: (@Sendable () -> D200XSessionStopOutcome)?
    private let afterCallbackResourceReleaseForTesting: (@Sendable () -> Void)?
    private let stopWaiterObserverForTesting: (@Sendable (Int) -> Void)?
    private var onInput: (@Sendable (D200XInputEvent) -> Void)?
    private var onFailure: (@Sendable (D200XSessionFailure) -> Void)?
    private var deviceIsOpen = false
    private var stopStarted = false
    private var stopOutcome: D200XSessionStopOutcome?
    private var stopWaiters: [CheckedContinuation<D200XSessionStopOutcome, Never>] = []

    init(
        inputLoopForTesting: D200XNativeInputLoop? = nil,
        stopCleanupForTesting: (@Sendable () -> D200XSessionStopOutcome)? = nil,
        afterCallbackResourceReleaseForTesting: (@Sendable () -> Void)? = nil,
        stopWaiterObserverForTesting: (@Sendable (Int) -> Void)? = nil
    ) {
        inputLoop = inputLoopForTesting
        self.stopCleanupForTesting = stopCleanupForTesting
        self.afterCallbackResourceReleaseForTesting = afterCallbackResourceReleaseForTesting
        self.stopWaiterObserverForTesting = stopWaiterObserverForTesting
    }

    func candidates() throws -> [D200XDeviceCandidate] {
        try discoverRecords().map(\.candidate)
    }

    func open(
        _ candidate: D200XDeviceCandidate,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void,
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void
    ) throws {
        guard candidate.isEligible else { throw D200XSessionError.ineligibleCandidate }
        let eligible = try discoverRecords()
        guard eligible.count == 1 else {
            if eligible.isEmpty { throw D200XSessionError.noMatchingDevice }
            throw D200XSessionError.ambiguousDevice(count: eligible.count)
        }
        let record = eligible[0]
        guard record.candidate == candidate else { throw D200XSessionError.selectedDeviceChanged }

        let loop = D200XNativeInputLoop()
        withLock { inputLoop = loop }
        guard loop.isReady else { throw D200XSessionError.sessionClosed }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: D200XFrameCodec.packetSize)
        buffer.initialize(repeating: 0, count: D200XFrameCodec.packetSize)
        let context = Unmanaged.passRetained(self).toOpaque()
        let resources = CallbackRegistrationResources(buffer: buffer, context: context)

        withLock {
            self.manager = record.manager
            self.device = record.device
            inputLoop = loop
            reportBuffer = buffer
            retainedCallbackContext = context
            self.onInput = onInput
            self.onFailure = onFailure
            reportAssembler = nil
        }

        let openStatus = loop.performAndWait { [self, record, resources] in
            IOHIDDeviceScheduleWithRunLoop(record.device, loop.runLoop, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceRegisterInputReportCallback(
                record.device,
                resources.buffer,
                D200XFrameCodec.packetSize,
                nativeD200XInputReportCallback,
                resources.context
            )
            IOHIDDeviceRegisterRemovalCallback(record.device, nativeD200XRemovalCallback, resources.context)
            let status = IOHIDDeviceOpen(record.device, IOOptionBits(kIOHIDOptionsTypeNone))
            self.withLock { self.deviceIsOpen = status == kIOReturnSuccess }
            return status
        }
        guard openStatus == kIOReturnSuccess else { throw D200XSessionError.sessionClosed }
    }

    func send(reportID: UInt32, packet: Data) throws {
        guard reportID == 0, packet.count == D200XFrameCodec.packetSize,
              let device = withLock({ device }),
              withLock({ deviceIsOpen && !stopStarted }) else {
            throw D200XSessionError.invalidSyntheticReport
        }

        let status = packet.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(reportID),
                bytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                packet.count
            )
        }
        guard status == kIOReturnSuccess else { throw D200XSessionError.writeFailed }
    }

    func stop() async -> D200XSessionStopOutcome {
        await withCheckedContinuation { continuation in
            let decision = withLock { () -> (D200XSessionStopOutcome?, D200XNativeInputLoop?, Bool, Int) in
                if let stopOutcome { return (stopOutcome, nil, false, stopWaiters.count) }
                stopWaiters.append(continuation)
                guard !stopStarted else { return (nil, inputLoop, false, stopWaiters.count) }
                stopStarted = true
                return (nil, inputLoop, true, stopWaiters.count)
            }

            stopWaiterObserverForTesting?(decision.3)
            if let outcome = decision.0 {
                continuation.resume(returning: outcome)
                return
            }
            guard decision.2 else { return }

            guard let inputLoop = decision.1 else {
                let shouldFinish = withLock { !deviceIsOpen && self.inputLoop == nil }
                finishStop(shouldFinish ? .closed : .cleanupUncertain)
                return
            }

            inputLoop.stop(
                cleanup: { [self] in
                    stopCleanupForTesting?() ?? cleanupOnInputLoop()
                },
                completion: { [self] outcome in
                    releaseCallbackResources()
                    afterCallbackResourceReleaseForTesting?()
                    finishStop(outcome)
                }
            )
        }
    }

    private func discoverRecords() throws -> [DiscoveryRecord] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [
            kIOHIDVendorIDKey as String: 0x2207,
            kIOHIDProductIDKey as String: 0x0019,
            kIOHIDDeviceUsagePageKey as String: 0x000c,
            kIOHIDDeviceUsageKey as String: 0x0001,
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)
        guard let devices = IOHIDManagerCopyDevices(manager) else { return [] }

        var values = [UnsafeRawPointer?](repeating: nil, count: CFSetGetCount(devices))
        CFSetGetValues(devices, &values)
        return values.compactMap { pointer in
            guard let pointer else { return nil }
            let device = unsafeBitCast(pointer, to: IOHIDDevice.self)
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID) == KERN_SUCCESS else {
                return nil
            }
            let properties = deviceProperties(device)
            let parents = usbParentProperties(device)
            guard let candidate = D200XNativeCandidateValidator.candidate(
                registryID: registryID,
                deviceProperties: properties,
                usbParentProperties: parents
            ) else {
                return nil
            }
            return DiscoveryRecord(manager: manager, device: device, candidate: candidate)
        }
    }

    private func deviceProperties(_ device: IOHIDDevice) -> [String: Any] {
        let keys = [
            kIOHIDVendorIDKey,
            kIOHIDProductIDKey,
            kIOHIDDeviceUsagePageKey,
            kIOHIDDeviceUsageKey,
            kIOHIDDeviceUsagePairsKey,
            kIOHIDMaxOutputReportSizeKey,
        ]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
            return (key as String, value)
        })
    }

    private func usbParentProperties(_ device: IOHIDDevice) -> [[String: Any]] {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return [] }
        var current = service
        var retainedParent: io_registry_entry_t = IO_OBJECT_NULL
        var parents = [[String: Any]]()

        while true {
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            if retainedParent != IO_OBJECT_NULL { IOObjectRelease(retainedParent) }
            retainedParent = parent
            current = parent
            if let property = IORegistryEntryCreateCFProperty(
                parent,
                "bInterfaceNumber" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() {
                parents.append(["bInterfaceNumber": property])
            } else {
                parents.append([:])
            }
        }

        if retainedParent != IO_OBJECT_NULL { IOObjectRelease(retainedParent) }
        return parents
    }

    fileprivate func receiveInput(
        result: IOReturn,
        reportType: IOHIDReportType,
        reportID: UInt32,
        report: UnsafePointer<UInt8>?,
        reportLength: CFIndex
    ) {
        guard result == kIOReturnSuccess else {
            onFailure?(.inputReadFailed)
            return
        }
        guard reportType == kIOHIDReportTypeInput,
              reportID == 0,
              reportLength == D200XFrameCodec.packetSize,
              let report else {
            onFailure?(.malformedInput)
            return
        }

        let copiedReport = Data(bytes: report, count: reportLength)
        do {
            if reportAssembler == nil {
                reportAssembler = try D200XFrameAssembler(firstReport: copiedReport)
            } else {
                try reportAssembler?.append(copiedReport)
            }
            guard let assembler = reportAssembler, assembler.isComplete else { return }
            let frame = try assembler.frame()
            reportAssembler = nil
            guard let event = try D200XFrameCodec.decodeInput(frame) else { return }
            onInput?(event)
        } catch {
            reportAssembler = nil
            onFailure?(.malformedInput)
        }
    }

    fileprivate func receiveRemoval(result: IOReturn) {
        guard result == kIOReturnSuccess else {
            onFailure?(.deviceRemoved)
            return
        }
        onFailure?(.deviceRemoved)
    }

    private func cleanupOnInputLoop() -> D200XSessionStopOutcome {
        guard let device = withLock({ device }), let inputLoop = withLock({ inputLoop }),
              let reportBuffer = withLock({ reportBuffer }) else {
            return .closed
        }
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, D200XFrameCodec.packetSize, nil, nil)
        IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, inputLoop.runLoop, CFRunLoopMode.defaultMode.rawValue)
        guard withLock({ deviceIsOpen }) else { return .closed }
        let status = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        withLock { deviceIsOpen = false }
        return D200XNativeCloseResult.stopOutcome(status: Int32(status))
    }

    private func releaseCallbackResources() {
        withLock {
            onInput = nil
            onFailure = nil
            reportAssembler = nil
            device = nil
            manager = nil
            inputLoop = nil
        }

        let resources = withLock { () -> (UnsafeMutablePointer<UInt8>?, UnsafeMutableRawPointer?) in
            let current = (reportBuffer, retainedCallbackContext)
            reportBuffer = nil
            retainedCallbackContext = nil
            return current
        }
        if let buffer = resources.0 {
            buffer.deinitialize(count: D200XFrameCodec.packetSize)
            buffer.deallocate()
        }
        if let context = resources.1 {
            Unmanaged<NativeD200XBackend>.fromOpaque(context).release()
        }
    }

    private func finishStop(_ outcome: D200XSessionStopOutcome) {
        let waiters = withLock { () -> [CheckedContinuation<D200XSessionStopOutcome, Never>] in
            guard stopOutcome == nil else { return [] }
            stopOutcome = outcome
            defer { stopWaiters.removeAll() }
            return stopWaiters
        }
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

final class D200XNativeInputLoop: @unchecked Sendable {
    private let condition = NSCondition()
    private let startupTimeout: TimeInterval
    private let beforeRunLoopStart: @Sendable () -> Void
    private let onThreadExit: @Sendable () -> Void
    private var thread: Thread?
    private var currentRunLoop: CFRunLoop?
    private var loopReady = false
    private var isFinishing = false
    private var isFinished = false
    private var startupCancelled = false
    private var stopRequested = false
    private var requestedOutcome: D200XSessionStopOutcome?
    private var cleanup: (@Sendable () -> D200XSessionStopOutcome)?
    private var completions: [@Sendable (D200XSessionStopOutcome) -> Void] = []

    var isReady: Bool {
        condition.lock()
        defer { condition.unlock() }
        return loopReady
    }

    var runLoop: CFRunLoop {
        condition.lock()
        defer { condition.unlock() }
        return currentRunLoop!
    }

    init(
        startupTimeout: TimeInterval = 5,
        beforeRunLoopStart: @escaping @Sendable () -> Void = {},
        onThreadExit: @escaping @Sendable () -> Void = {}
    ) {
        self.startupTimeout = startupTimeout
        self.beforeRunLoopStart = beforeRunLoopStart
        self.onThreadExit = onThreadExit
        let inputThread = Thread { [weak self] in
            guard let self else { return }
            self.beforeRunLoopStart()
            self.runLoopMain()
        }
        inputThread.name = "hidhogg.d200x.input"
        inputThread.qualityOfService = .userInitiated
        thread = inputThread
        inputThread.start()

        condition.lock()
        let deadline = Date(timeIntervalSinceNow: startupTimeout)
        while !loopReady && !isFinished {
            guard condition.wait(until: deadline) else {
                startupCancelled = true
                thread?.cancel()
                break
            }
        }
        condition.unlock()
    }

    func performAndWait<T: Sendable>(_ operation: @escaping @Sendable () -> T) -> T {
        let result = D200XNativeResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        let runLoop = self.runLoop
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            result.store(operation())
            semaphore.signal()
        }
        CFRunLoopWakeUp(runLoop)
        semaphore.wait()
        return result.load()!
    }

    func stop(
        cleanup: @escaping @Sendable () -> D200XSessionStopOutcome,
        completion: @escaping @Sendable (D200XSessionStopOutcome) -> Void
    ) {
        condition.lock()
        if isFinished {
            let outcome = requestedOutcome ?? .cleanupUncertain
            condition.unlock()
            completion(outcome)
            return
        }
        completions.append(completion)
        guard !stopRequested else {
            condition.unlock()
            return
        }
        stopRequested = true
        self.cleanup = cleanup
        guard let runLoop = currentRunLoop else {
            startupCancelled = true
            thread?.cancel()
            condition.unlock()
            return
        }
        condition.unlock()

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }
            let outcome = self.cleanup?() ?? .cleanupUncertain
            self.condition.lock()
            self.requestedOutcome = outcome
            self.condition.unlock()
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func runLoopMain() {
        guard !Thread.current.isCancelled else {
            finishWithoutRunLoop()
            return
        }
        var sourceContext = CFRunLoopSourceContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: nil,
            cancel: nil,
            perform: nil
        )
        guard let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext) else {
            finishWithoutRunLoop()
            return
        }
        let runLoop = CFRunLoopGetCurrent()

        condition.lock()
        guard !startupCancelled, !Thread.current.isCancelled else {
            condition.unlock()
            CFRunLoopRemoveSource(runLoop, source, CFRunLoopMode.defaultMode)
            CFRunLoopSourceInvalidate(source)
            finishWithoutRunLoop()
            return
        }
        CFRunLoopAddSource(runLoop, source, CFRunLoopMode.defaultMode)
        currentRunLoop = runLoop
        loopReady = true
        condition.broadcast()
        condition.unlock()

        CFRunLoopRun()
        CFRunLoopRemoveSource(runLoop, source, CFRunLoopMode.defaultMode)
        CFRunLoopSourceInvalidate(source)

        condition.lock()
        let outcome = requestedOutcome ?? .cleanupUncertain
        condition.unlock()
        finishOnThread(outcome)
    }

    private func finishWithoutRunLoop() {
        condition.lock()
        let outcome = requestedOutcome ?? .closed
        condition.unlock()
        finishOnThread(outcome)
    }

    private func finishOnThread(_ outcome: D200XSessionStopOutcome) {
        condition.lock()
        guard !isFinishing, !isFinished else {
            condition.unlock()
            return
        }
        isFinishing = true
        loopReady = false
        currentRunLoop = nil
        requestedOutcome = outcome
        condition.unlock()

        onThreadExit()

        condition.lock()
        isFinished = true
        let completions = self.completions
        self.completions.removeAll()
        condition.broadcast()
        condition.unlock()

        for completion in completions { completion(outcome) }
    }
}

private final class D200XNativeResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private let nativeD200XInputReportCallback: IOHIDReportCallback = { context, result, _, reportType, reportID, report, reportLength in
    guard let context else { return }
    let backend = Unmanaged<NativeD200XBackend>.fromOpaque(context).takeUnretainedValue()
    backend.receiveInput(result: result, reportType: reportType, reportID: reportID, report: report, reportLength: reportLength)
}

private let nativeD200XRemovalCallback: IOHIDCallback = { context, result, _ in
    guard let context else { return }
    let backend = Unmanaged<NativeD200XBackend>.fromOpaque(context).takeUnretainedValue()
    backend.receiveRemoval(result: result)
}
