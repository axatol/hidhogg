import Foundation
import IOKit.hid
import Testing
@testable import LogitechBolt

@Test func nativeInputCountersClampAndSaturateWithoutRetainingReports() {
    var diagnostics = BoltNativeInputDiagnostics(available: true, callbacks: Int.max,
                                                  callbackErrors: -1, metadataRejected: Int.max,
                                                  reportIDMismatch: Int.max, registerReplies: Int.max,
                                                  featureReplies: Int.max, receiverNotifications: Int.max,
                                                  unmatchedReports: Int.max)
    diagnostics.recordCallback()
    for disposition: BoltNativeInputDisposition in [.callbackError, .metadataRejected, .reportIDMismatch,
                                                    .registerReply, .featureReply, .receiverNotification,
                                                    .unmatchedReport] {
        diagnostics.record(disposition)
    }
    #expect(diagnostics == BoltNativeInputDiagnostics(available: true, callbacks: Int.max,
                                                       callbackErrors: 1, metadataRejected: Int.max,
                                                       reportIDMismatch: Int.max, registerReplies: Int.max,
                                                       featureReplies: Int.max, receiverNotifications: Int.max,
                                                       unmatchedReports: Int.max))
}

@Test func nativeCallbackCountersObserveExistingMetadataAndNotificationRouting() {
    let worker = BoltHIDWorker()
    let notifications = NativeNotificationCount()
    worker.receiverSink = { event in
        if case .notification = event { notifications.increment() }
        return true
    }

    deliver([0x10, 0xFF, 0x53, 0, 0, 0, 0], to: worker)
    deliver([0x10, 0xFF, 0x53, 0, 0, 0, 0], to: worker, type: kIOHIDReportTypeOutput)
    deliver([0x10, 0xFF, 0x53, 0, 0, 0, 0], to: worker, reportID: 0x12)
    deliver([0x10, 0xFF, 0x53], to: worker)
    deliver([0x11, 0xFF, 0x53, 0, 0, 0, 0], to: worker)
    deliver([0x10, 0xFF, 0x90, 1, 0, 0, 0], to: worker)
    deliver([0x10, 1, 1, 0, 0, 0, 0], to: worker)

    #expect(notifications.value == 1)
    #expect(worker.nativeInputDiagnostics == BoltNativeInputDiagnostics(
        available: true, callbacks: 7, metadataRejected: 3, reportIDMismatch: 1,
        receiverNotifications: 1, unmatchedReports: 2
    ))
}

@Test func nativeSnapshotMergeRetainsAvailabilityAndEachCounterMaximum() {
    let first = BoltNativeInputDiagnostics(available: true, callbacks: Int.max, callbackErrors: 1,
                                             metadataRejected: 4, reportIDMismatch: 1,
                                             registerReplies: 4, featureReplies: 1,
                                             receiverNotifications: 4, unmatchedReports: 1)
    let second = BoltNativeInputDiagnostics(callbacks: 12, callbackErrors: 4,
                                              metadataRejected: 1, reportIDMismatch: 4,
                                              registerReplies: 1, featureReplies: 4,
                                              receiverNotifications: 1, unmatchedReports: 4)
    let expected = BoltNativeInputDiagnostics(available: true, callbacks: Int.max, callbackErrors: 4,
                                                metadataRejected: 4, reportIDMismatch: 4,
                                                registerReplies: 4, featureReplies: 4,
                                                receiverNotifications: 4, unmatchedReports: 4)
    var forward = first
    forward.merge(second)
    #expect(forward == expected)
    var reverse = second
    reverse.merge(first)
    #expect(reverse == expected)
    forward.merge(.init())
    #expect(forward == expected)
}

@Test func nativeCallbackErrorsStillEmitExistingTransportFailure() {
    let worker = BoltHIDWorker()
    let failures = NativeNotificationCount()
    worker.receiverSink = { event in
        if case .failure(.transport) = event { failures.increment() }
        return true
    }
    deliver([0x10, 0xFF, 0x53, 0, 0, 0, 0], to: worker, result: kIOReturnError)
    #expect(failures.value == 1)
    #expect(worker.nativeInputDiagnostics == .init(available: true, callbacks: 1, callbackErrors: 1))
}

@Test func receiverTransportWithoutNativeSupportReportsUnavailable() async {
    let receiver: any BoltReceiverTransport = DefaultDiagnosticsReceiver()
    #expect(await receiver.inputDiagnostics() == .init())
}

@Test func nativeTransportRetainsSnapshotAfterClosingWithoutOpeningHID() async {
    let transport = IOKitBoltTransport(onTerminal: {})
    #expect(await transport.inputDiagnostics() == .init(available: true))
    await transport.close()
    #expect(await transport.inputDiagnostics() == .init(available: true))
}

private func deliver(_ report: [UInt8], to worker: BoltHIDWorker,
                     result: IOReturn = kIOReturnSuccess,
                     type: IOHIDReportType = kIOHIDReportTypeInput, reportID: UInt32 = 0x10) {
    var report = report
    report.withUnsafeMutableBufferPointer { buffer in
        worker.receive(result: result, type: type, reportID: reportID,
                       bytes: buffer.baseAddress!, count: buffer.count)
    }
}

private final class NativeNotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private struct DefaultDiagnosticsReceiver: BoltReceiverTransport {
    let events = AsyncStream<BoltTransportEvent> { $0.finish() }
    let receiverEvents = AsyncStream<BoltReceiverEvent> { $0.finish() }
    func open() async throws {}
    func close() async {}
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int { 0 }
    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        throw BoltFailure.unavailable
    }
    func registerRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverRegisterReply {
        throw BoltReceiverTransportFailure.unavailable
    }
    func cancelRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverCancellationResult {
        throw BoltReceiverTransportFailure.unavailable
    }
}
