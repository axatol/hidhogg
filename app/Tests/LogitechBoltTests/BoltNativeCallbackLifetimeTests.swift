import Foundation
import IOKit.hid
import Testing
import HidhoggDomain
@testable import LogitechBolt

private final class NativeLifetimeStub: BoltHIDNativeAPI, @unchecked Sendable {
    private final class Device: BoltNativeDevice, @unchecked Sendable {
        let nativeClient = NSObject()
    }

    final class Resources: @unchecked Sendable {
        weak var device: BoltNativeDevice?
        weak var buffer: BoltHIDInputBuffer?
        weak var manager: BoltNativeManager?
        weak var nativeClient: AnyObject?
    }

    struct Registration: @unchecked Sendable {
        let callback: IOHIDReportCallback
        let removal: IOHIDCallback
        let matching: IOHIDDeviceCallback
        let context: UnsafeMutableRawPointer?

        func input() {
            var report: [UInt8] = [0x11, 1, 2, 0]
            report.withUnsafeMutableBufferPointer {
                callback(context, kIOReturnSuccess, nil, kIOHIDReportTypeInput, 0x11, $0.baseAddress!, $0.count)
            }
        }

        func remove() { removal(context, kIOReturnSuccess, nil) }

        func match() {
            // The stub never calls IOKit with this inert CoreFoundation reference.
            let sentinel = unsafeBitCast(kCFBooleanTrue!, to: IOHIDDevice.self)
            matching(context, kIOReturnSuccess, nil, sentinel)
        }

        func replay() {
            input()
            remove()
            match()
        }
    }

    struct Send: @unchecked Sendable {
        let callback: IOHIDReportCallback
        let context: UnsafeMutableRawPointer?
        let frame: [UInt8]
        let loop: CFRunLoop

        func complete(result: IOReturn, reply: Registration?) {
            var report = frame
            report.withUnsafeMutableBufferPointer {
                callback(context, result, nil, kIOHIDReportTypeOutput, UInt32(frame[0]), $0.baseAddress!, $0.count)
                if let reply {
                    reply.callback(reply.context, kIOReturnSuccess, nil, kIOHIDReportTypeInput,
                                   UInt32(frame[0]), $0.baseAddress!, $0.count)
                }
            }
        }
    }

    let cached = BoltNativeDevice()
    let resources = Resources()
    private let candidateCount: Int
    private let creationSucceeds: Bool
    private let privateKey: UInt64
    private let privateEligible: Bool
    private let matchingKey: UInt64
    private let openResult: IOReturn
    private let closeResult: IOReturn
    private let replayDuringTeardown: Bool
    private var registrationSucceeds: Bool
    private let completeOutputDuringClose: Bool
    private let lock = NSLock()
    private var inputCallback: IOHIDReportCallback?
    private var removalCallback: IOHIDCallback?
    private var contexts: [UnsafeMutableRawPointer?] = []
    private var registrations: [Registration] = []
    private var registeredDevices: [ObjectIdentifier] = []
    private var scheduledDevices: [ObjectIdentifier] = []
    private var creations = 0
    private var closes = 0
    private var eligibilityChecks = 0
    private var outputDevices: [ObjectIdentifier] = []
    private var sends: [Send] = []

    init(candidateCount: Int = 1, creationSucceeds: Bool = true, privateKey: UInt64 = 41,
         privateEligible: Bool = true, matchingKey: UInt64 = 42,
         openResult: IOReturn = kIOReturnSuccess, closeResult: IOReturn = kIOReturnSuccess,
         replayDuringTeardown: Bool = false, registrationSucceeds: Bool = true,
         completeOutputDuringClose: Bool = false) {
        self.candidateCount = candidateCount
        self.creationSucceeds = creationSucceeds
        self.privateKey = privateKey
        self.privateEligible = privateEligible
        self.matchingKey = matchingKey
        self.openResult = openResult
        self.closeResult = closeResult
        self.replayDuringTeardown = replayDuringTeardown
        self.registrationSucceeds = registrationSucceeds
        self.completeOutputDuringClose = completeOutputDuringClose
    }

    var privateCreations: Int { lock.withLock { creations } }
    var closeCalls: Int { lock.withLock { closes } }
    var eligibleCalls: Int { lock.withLock { eligibilityChecks } }
    var outputLookups: [ObjectIdentifier] { lock.withLock { outputDevices } }
    var deviceRegistrations: [ObjectIdentifier] { lock.withLock { registeredDevices } }
    var deviceSchedules: [ObjectIdentifier] { lock.withLock { scheduledDevices } }
    var installed: [Registration] { lock.withLock { registrations } }
    var installedSends: [Send] { lock.withLock { sends } }

    func allowInputRegistration() { lock.withLock { registrationSucceeds = true } }

    func makeManager(connection: LogitechConnection) -> BoltNativeManager {
        let manager = BoltNativeManager()
        resources.manager = manager
        return manager
    }
    func devices(_ manager: BoltNativeManager) -> [BoltNativeDevice] { Array(repeating: cached, count: candidateCount) }
    func catalogDevice(_ endpoint: IOKitEndpointHandle) -> BoltNativeDevice { cached }
    func registryKey(_ device: BoltNativeDevice) -> UInt64? {
        if device === cached { return 41 }
        if let raw = device.raw, CFGetTypeID(raw) == CFBooleanGetTypeID() { return matchingKey }
        return privateKey
    }
    func makePrivateDevice(_ device: BoltNativeDevice) -> BoltNativeDevice? {
        lock.withLock { creations += 1 }
        guard creationSucceeds else { return nil }
        let device = Device()
        resources.device = device
        resources.nativeClient = device.nativeClient
        return device
    }
    func eligible(_ device: BoltNativeDevice, connection: LogitechConnection) -> Bool {
        lock.withLock { eligibilityChecks += 1 }
        if device === cached { return true }
        if let raw = device.raw, CFGetTypeID(raw) == CFBooleanGetTypeID() { return true }
        return privateEligible
    }
    func outputElement(_ device: BoltNativeDevice) -> BoltNativeOutputElement? {
        lock.withLock { outputDevices.append(ObjectIdentifier(device)) }
        return BoltNativeOutputElement()
    }
    func open(_ device: BoltNativeDevice) -> IOReturn { openResult }
    func registerInput(_ device: BoltNativeDevice, buffer: BoltHIDInputBuffer,
                       callback: IOHIDReportCallback, context: UnsafeMutableRawPointer?) -> Bool {
        resources.buffer = buffer
        guard lock.withLock({ registrationSucceeds }), let client = (device as? Device)?.nativeClient,
              BoltHIDInputBufferAssociation.bind(buffer, to: client) else { return false }
        device.inputBuffer = buffer
        resources.buffer = buffer
        lock.withLock {
            inputCallback = callback
            contexts.append(context)
            registeredDevices.append(ObjectIdentifier(device))
        }
        return true
    }
    func registerRemoval(_ device: BoltNativeDevice, callback: IOHIDCallback, context: UnsafeMutableRawPointer?) {
        lock.withLock { removalCallback = callback }
    }
    func registerMatching(_ manager: BoltNativeManager, callback: IOHIDDeviceCallback, context: UnsafeMutableRawPointer?) {
        lock.withLock {
            registrations.append(Registration(callback: inputCallback!, removal: removalCallback!,
                                                matching: callback, context: context))
        }
    }
    func schedule(_ device: BoltNativeDevice) { lock.withLock { scheduledDevices.append(ObjectIdentifier(device)) } }
    func schedule(_ manager: BoltNativeManager) {}
    func unregister(_ device: BoltNativeDevice, context: UnsafeMutableRawPointer?) {
        if replayDuringTeardown { installed.last?.replay() }
    }
    func unregister(_ manager: BoltNativeManager, context: UnsafeMutableRawPointer?) {
        if replayDuringTeardown { installed.last?.replay() }
    }
    func unschedule(_ device: BoltNativeDevice) {}
    func unschedule(_ manager: BoltNativeManager) {}
    func close(_ device: BoltNativeDevice) -> IOReturn {
        lock.withLock { closes += 1 }
        #expect(resources.buffer != nil)
        if replayDuringTeardown { installed.last?.replay() }
        if completeOutputDuringClose { installedSends.last?.complete(result: kIOReturnAborted, reply: nil) }
        return closeResult
    }

    func sendReport(_ device: BoltNativeDevice, reportID: Int, bytes: UnsafeMutablePointer<UInt8>, count: Int,
                    callback: IOHIDReportCallback, context: UnsafeMutableRawPointer?) -> IOReturn {
        let frame = Array(UnsafeBufferPointer(start: bytes, count: count))
        lock.withLock {
            sends.append(Send(callback: callback, context: context, frame: frame, loop: CFRunLoopGetCurrent()))
        }
        return kIOReturnSuccess
    }

    func completeSendOnWorker() {
        guard let send = installedSends.last, let input = installed.last else { return }
        CFRunLoopPerformBlock(send.loop, CFRunLoopMode.defaultMode.rawValue) {
            send.complete(result: kIOReturnSuccess, reply: input)
        }
        CFRunLoopWakeUp(send.loop)
    }
}

private final class LifetimeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var total: Int { lock.withLock { count } }
    func record() -> Bool { lock.withLock { count += 1 }; return true }
}

private final class LifetimeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var closed = false
    var hasEntered: Bool { lock.withLock { entered } }
    var hasClosed: Bool { lock.withLock { closed } }
    func block() {
        lock.withLock { entered = true }
        semaphore.wait()
    }
    func release() { semaphore.signal() }
    func recordClose() { lock.withLock { closed = true } }
}

private final class WeakLifetimeWorker: @unchecked Sendable {
    weak var value: BoltHIDWorker?
    init(_ value: BoltHIDWorker) { self.value = value }
}

private func lifetimeEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Suite(.serialized)
struct BoltNativeCallbackLifetimeTests {
    @Test func nilAndUnknownContextsCannotReadReportMemoryOrReachWorker() async throws {
        let native = NativeLifetimeStub()
        let worker = BoltHIDWorker(native: native)
        try await worker.submit { try $0.open() }
        let installed = try #require(native.installed.first)
        let checks = native.eligibleCalls
        try await worker.submit { _ in
            for token in [UInt(0), UInt.max] {
                let context = UnsafeMutableRawPointer(bitPattern: token)
                installed.callback(context, kIOReturnSuccess, nil, kIOHIDReportTypeInput,
                                   0x11, UnsafeMutablePointer<UInt8>(bitPattern: 1)!, 256)
                installed.removal(context, kIOReturnSuccess, nil)
                let sentinel = unsafeBitCast(kCFBooleanTrue!, to: IOHIDDevice.self)
                installed.matching(context, kIOReturnSuccess, nil, sentinel)
            }
        }
        #expect(worker.nativeInputDiagnostics.callbacks == 0)
        #expect(native.eligibleCalls == checks)
        #expect(await worker.closeAndWait() == .closed)
    }

    @Test func nativeBufferAssociationRejectsReplacementAndReclaimsAtFinalClientRelease() throws {
        var client: NSObject? = NSObject()
        weak var original: BoltHIDInputBuffer?
        weak var replacement: BoltHIDInputBuffer?
        do {
            let first = BoltHIDInputBuffer()
            let second = BoltHIDInputBuffer()
            original = first
            replacement = second
            #expect(BoltHIDInputBufferAssociation.bind(first, to: client!))
            #expect(BoltHIDInputBufferAssociation.bind(first, to: client!))
            #expect(!BoltHIDInputBufferAssociation.bind(second, to: client!))
        }
        #expect(original != nil)
        #expect(replacement == nil)
        client = nil
        #expect(original == nil)
    }

    @Test func retiredInstalledInputCallbackCannotReachClosedWorker() async throws {
        let native = NativeLifetimeStub()
        let worker = BoltHIDWorker(native: native)
        try await worker.submit { try $0.open() }
        let installed = try #require(native.installed.first)
        try await worker.submit { _ in installed.input() }
        #expect(worker.nativeInputDiagnostics.callbacks == 1)
        #expect(await worker.closeAndWait() == .closed)
        let events = LifetimeEvents()
        worker.sink = { _ in events.record() }
        worker.receiverSink = { _ in events.record() }
        let checks = native.eligibleCalls
        installed.replay()
        #expect(worker.nativeInputDiagnostics.callbacks == 1)
        #expect(events.total == 0)
        #expect(native.eligibleCalls == checks)
    }

    @Test func sameServiceReopenUsesDistinctPrivateClientsAndNeverSchedulesCatalogDevice() async throws {
        let native = NativeLifetimeStub()
        let first = BoltHIDWorker(native: native)
        let second = BoltHIDWorker(native: native)
        try await first.submit { try $0.open() }
        let firstClient = try #require(native.resources.device)
        let old = try #require(native.installed.first)
        #expect(await first.closeAndWait() == .closed)
        try await second.submit { try $0.open() }
        let secondClient = try #require(native.resources.device)
        #expect(firstClient !== secondClient)
        try await second.submit { _ in old.replay() }
        #expect(second.nativeInputDiagnostics.callbacks == 0)
        let current = try #require(native.installed.last)
        try await second.submit { _ in current.input() }
        #expect(second.nativeInputDiagnostics.callbacks == 1)
        #expect(await second.closeAndWait() == .closed)
        #expect(native.privateCreations == 2)
        #expect(native.deviceRegistrations.count == 2)
        #expect(native.deviceRegistrations[0] != native.deviceRegistrations[1])
        #expect(!native.deviceRegistrations.contains(ObjectIdentifier(native.cached)))
        #expect(!native.deviceSchedules.contains(ObjectIdentifier(native.cached)))
        withExtendedLifetime((firstClient, secondClient)) {}
    }

    @Test func privateClientAndBufferAreReclaimedAndLateCallbacksSurviveWorkerRelease() async throws {
        let native = NativeLifetimeStub()
        var worker: BoltHIDWorker? = BoltHIDWorker(native: native)
        let weakWorker = WeakLifetimeWorker(worker!)
        try await worker!.submit { try $0.open() }
        let installed = try #require(native.installed.first)
        #expect(native.resources.device != nil)
        #expect(native.resources.buffer != nil)
        #expect(await worker!.closeAndWait() == .closed)
        worker = nil
        #expect(await lifetimeEventually { weakWorker.value == nil })
        #expect(native.resources.device == nil)
        #expect(native.resources.manager == nil)
        #expect(native.resources.buffer == nil)
        installed.replay()
    }

    @Test func closeRetiresAdmissionAndWaitsForInflightCallbackBeforeNativeTeardown() async throws {
        let initial = BoltHIDCallbackRegistry.shared.registrationCount
        let native = NativeLifetimeStub(replayDuringTeardown: true)
        let worker = BoltHIDWorker(native: native)
        let gate = LifetimeGate()
        worker.sink = { event in
            if case .report = event { gate.block() }
            return true
        }
        try await worker.submit { try $0.open() }
        let installed = try #require(native.installed.first)
        let callback = Task.detached { installed.input() }
        guard await lifetimeEventually({ gate.hasEntered }) else {
            gate.release()
            await callback.value
            _ = await worker.closeAndWait()
            Issue.record("Input callback did not enter the event sink.")
            return
        }
        let closing = Task {
            let result = await worker.closeAndWait()
            gate.recordClose()
            return result
        }
        guard await lifetimeEventually({ worker.submissionsSealed && BoltHIDCallbackRegistry.shared.registrationCount == initial }) else {
            gate.release()
            _ = await closing.value
            Issue.record("Close did not seal submissions and retire callback admission.")
            return
        }
        #expect(!gate.hasClosed)
        #expect(native.closeCalls == 0)
        #expect(native.resources.buffer != nil)
        installed.replay()
        #expect(worker.nativeInputDiagnostics.callbacks == 1)
        gate.release()
        await callback.value
        #expect(await closing.value == .closed)
        #expect(worker.nativeInputDiagnostics.callbacks == 1)
        #expect(native.closeCalls == 1)
        #expect(native.resources.buffer == nil)
    }

    @Test(arguments: [kIOReturnSuccess, kIOReturnError])
    func nativeClientRetainedBeforeTrampolineOwnsBufferBeyondWorkerAndWrapper(status: IOReturn) async throws {
        let native = NativeLifetimeStub(closeResult: status)
        var worker: BoltHIDWorker? = BoltHIDWorker(native: native)
        let weakWorker = WeakLifetimeWorker(worker!)
        try await worker!.submit { try $0.open() }
        let installed = try #require(native.installed.first)
        var retainedClient = native.resources.nativeClient
        #expect(retainedClient != nil)
        #expect(await worker!.closeAndWait() == (status == kIOReturnSuccess ? .closed : .unverified))
        worker = nil
        #expect(await lifetimeEventually { weakWorker.value == nil })
        #expect(native.resources.device == nil)
        #expect(native.resources.buffer != nil)
        #expect(retainedClient != nil)
        if let bytes = native.resources.buffer?.bytes {
            bytes[0] = 0x11
            installed.callback(installed.context, kIOReturnSuccess, nil, kIOHIDReportTypeInput, 0x11, bytes, 1)
        }
        installed.replay()
        retainedClient = nil
        #expect(native.resources.nativeClient == nil)
        #expect(native.resources.buffer == nil)
    }

    @Test(arguments: [41, 42])
    func selectedCatalogServiceIsRevalidatedAndNeverRegistered(key: UInt64) async throws {
        let native = NativeLifetimeStub()
        let sentinel = unsafeBitCast(kCFBooleanTrue!, to: IOHIDDevice.self)
        let endpoint = IOKitEndpointHandle(device: sentinel, outputElement: nil, key: key)
        let worker = BoltHIDWorker(selectedEndpoint: endpoint, requireEndpoint: true, native: native)
        do {
            try await worker.submit { try $0.open() }
            #expect(key == 41)
            #expect(native.privateCreations == 1)
            #expect(!native.deviceRegistrations.contains(ObjectIdentifier(native.cached)))
        } catch {
            #expect(key == 42)
            #expect(error as? BoltFailure == .unavailable)
            #expect(native.privateCreations == 0)
        }
        #expect(await worker.closeAndWait() == .closed)
    }

    @Test func bluetoothOutputIsResolvedFromPrivateClient() async throws {
        let native = NativeLifetimeStub()
        let worker = BoltHIDWorker(connection: .bluetooth, native: native)
        try await worker.submit { try $0.open() }
        #expect(native.outputLookups == native.deviceRegistrations)
        #expect(!native.outputLookups.contains(ObjectIdentifier(native.cached)))
        #expect(await worker.closeAndWait() == .closed)
    }

    @Test func acceptedRequestSendCompletionStillRunsAfterCloseSealsSubmissions() async throws {
        let native = NativeLifetimeStub()
        let worker = BoltHIDWorker(native: native)
        try await worker.submit { try $0.open() }
        let request = Task {
            try await worker.submit { try $0.request(slot: 1, feature: 2, function: 1, parameters: [7]) }
        }
        guard await lifetimeEventually({ !native.installedSends.isEmpty }) else {
            _ = try? await request.value
            _ = await worker.closeAndWait()
            Issue.record("Native send was not submitted.")
            return
        }
        let closing = Task { await worker.closeAndWait() }
        #expect(await lifetimeEventually { worker.submissionsSealed })
        native.completeSendOnWorker()
        let response = try await request.value
        #expect(response == [7] + Array(repeating: 0, count: 15))
        #expect(await closing.value == .closed)
    }

    @Test(arguments: [false, true])
    func lateOutputCompletionReclaimsPacketWithoutBorrowingRetiredWorker(duringClose: Bool) async throws {
        let native = NativeLifetimeStub(completeOutputDuringClose: duringClose)
        var worker: BoltHIDWorker? = BoltHIDWorker(native: native)
        let weakWorker = WeakLifetimeWorker(worker!)
        try await worker!.submit { try $0.open() }
        do {
            _ = try await worker!.submit { try $0.request(slot: 1, feature: 2, function: 1, parameters: []) }
            Issue.record("An uncompleted native send did not time out.")
        } catch { #expect(error as? BoltFailure == .timeout) }
        let send = try #require(native.installedSends.first)
        #expect(await worker!.closeAndWait() == .closed)
        worker = nil
        #expect(await lifetimeEventually { weakWorker.value == nil })
        if !duringClose { send.complete(result: kIOReturnAborted, reply: nil) }
    }

    @Test(arguments: [41, 42])
    func matchingUsesServiceIdentityRatherThanWrapperIdentity(key: UInt64) async throws {
        let native = NativeLifetimeStub(matchingKey: key)
        let worker = BoltHIDWorker(native: native)
        let events = LifetimeEvents()
        worker.sink = { _ in events.record() }
        try await worker.submit { try $0.open() }
        let installed = try #require(native.installed.first)
        try await worker.submit { _ in installed.match() }
        #expect(events.total == (key == 41 ? 0 : 1))
        #expect(await worker.closeAndWait() == .closed)
    }

    @Test(arguments: [kIOReturnError, kIOReturnBusy, kIOReturnSuccess])
    func closeFailuresStillRetireCallbacksAndRepeatedCloseDoesNotRepeatNativeClose(status: IOReturn) async throws {
        let native = NativeLifetimeStub(closeResult: status, replayDuringTeardown: true)
        let worker = BoltHIDWorker(native: native)
        try await worker.submit { try $0.open() }
        let installed = try #require(native.installed.first)
        let expected: BoltTransportCloseResult = status == kIOReturnSuccess ? .closed : .unverified
        #expect(await worker.closeAndWait() == expected)
        #expect(await worker.closeAndWait() == expected)
        installed.replay()
        #expect(worker.nativeInputDiagnostics.callbacks == 0)
        #expect(native.closeCalls == 1)
        #expect(native.resources.device == nil)
        #expect(native.resources.buffer == nil)
    }

    @Test func failedSelectionCreationValidationAndOpenLeaveNoCallbackRegistration() async {
        let cases: [(NativeLifetimeStub, BoltFailure)] = [
            (NativeLifetimeStub(candidateCount: 0), .unavailable),
            (NativeLifetimeStub(candidateCount: 2), .ambiguous),
            (NativeLifetimeStub(creationSucceeds: false), .unavailable),
            (NativeLifetimeStub(privateKey: 42), .unavailable),
            (NativeLifetimeStub(privateEligible: false), .unavailable),
            (NativeLifetimeStub(openResult: kIOReturnError), .transport),
            (NativeLifetimeStub(registrationSucceeds: false), .transport)
        ]
        for (native, expected) in cases {
            let worker = BoltHIDWorker(native: native)
            do {
                try await worker.submit { try $0.open() }
                Issue.record("Invalid native selection unexpectedly opened.")
            } catch { #expect(error as? BoltFailure == expected) }
            #expect(native.installed.isEmpty)
            #expect(await worker.closeAndWait() == .closed)
            #expect(native.resources.device == nil)
            #expect(native.resources.manager == nil)
            #expect(native.resources.buffer == nil)
        }
    }

    @Test(arguments: [kIOReturnError, kIOReturnBusy])
    func registrationRollbackCloseFailureRemainsUnverifiedAcrossRepeatedClose(status: IOReturn) async {
        let initial = BoltHIDCallbackRegistry.shared.registrationCount
        let native = NativeLifetimeStub(closeResult: status, registrationSucceeds: false)
        let worker = BoltHIDWorker(native: native)
        do {
            try await worker.submit { try $0.open() }
            Issue.record("Rejected input registration unexpectedly opened the worker.")
        } catch { #expect(error as? BoltFailure == .transport) }
        #expect(native.closeCalls == 1)
        #expect(native.installed.isEmpty)
        #expect(BoltHIDCallbackRegistry.shared.registrationCount == initial)
        #expect(native.resources.device == nil)
        #expect(native.resources.buffer == nil)
        #expect(await worker.closeAndWait() == .unverified)
        #expect(await worker.closeAndWait() == .unverified)
        #expect(native.closeCalls == 1)
    }

    @Test(arguments: [kIOReturnError, kIOReturnBusy])
    func unverifiedRegistrationRollbackCannotAcquireAnotherNativeClient(status: IOReturn) async {
        let initial = BoltHIDCallbackRegistry.shared.registrationCount
        let native = NativeLifetimeStub(closeResult: status, registrationSucceeds: false)
        let worker = BoltHIDWorker(native: native)
        do {
            try await worker.submit { try $0.open() }
            Issue.record("Rejected input registration unexpectedly opened the worker.")
        } catch { #expect(error as? BoltFailure == .transport) }
        native.allowInputRegistration()
        do {
            try await worker.submit { try $0.open() }
            Issue.record("A retry acquired a native client after unverified rollback.")
        } catch { #expect(error as? BoltFailure == .transport) }
        #expect(native.privateCreations == 1)
        #expect(native.installed.isEmpty)
        #expect(BoltHIDCallbackRegistry.shared.registrationCount == initial)
        #expect(await worker.closeAndWait() == .unverified)
        #expect(await worker.closeAndWait() == .unverified)
        #expect(native.closeCalls == 1)
    }

    @Test func repeatedOpenCloseReclaimsRegistryAndNeverReusesCallbackTokens() async throws {
        let initial = BoltHIDCallbackRegistry.shared.registrationCount
        let native = NativeLifetimeStub()
        for _ in 0..<100 {
            let worker = BoltHIDWorker(native: native)
            try await worker.submit { try $0.open() }
            #expect(await worker.closeAndWait() == .closed)
            #expect(BoltHIDCallbackRegistry.shared.registrationCount == initial)
            #expect(native.resources.buffer == nil)
        }
        let installed = native.installed
        let tokens = installed.compactMap { $0.context.map { UInt(bitPattern: $0) } }
        #expect(tokens.count == 100)
        #expect(Set(tokens).count == tokens.count)
        for callback in installed { callback.replay() }
    }
}
