import Foundation
import IOKit
import Testing
@testable import LogitechBolt

private final class NativeCloseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var completed = false
    private var closingCompleted = false
    private var workerThread: Thread?

    var hasEntered: Bool { lock.withLock { entered } }
    var hasCompleted: Bool { lock.withLock { completed } }
    var hasClosed: Bool { lock.withLock { closingCompleted } }
    var threadHasFinished: Bool { lock.withLock { workerThread?.isFinished == true } }

    func block() {
        lock.withLock {
            workerThread = Thread.current
            entered = true
        }
        semaphore.wait()
        lock.withLock { completed = true }
    }

    func release() { semaphore.signal() }
    func recordClose() { lock.withLock { closingCompleted = true } }
}

private func closeEventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@Test func nativeCloseSealsSubmissionsDrainsAcceptedWorkAndWaitsForWorkerExit() async {
    let worker = BoltHIDWorker()
    let gate = NativeCloseGate()
    let accepted = Task {
        try await worker.submit { _ in
            gate.block()
            return 7
        }
    }
    guard await closeEventually({ gate.hasEntered }) else {
        gate.release()
        _ = await worker.closeAndWait()
        Issue.record("The synthetic worker body did not start.")
        return
    }
    let closing = Task {
        let result = await worker.closeAndWait()
        gate.recordClose()
        return result
    }
    guard await closeEventually({ worker.submissionsSealed }) else {
        gate.release()
        _ = await closing.value
        Issue.record("Close did not seal worker submissions.")
        return
    }
    #expect(gate.hasClosed == false)
    #expect(gate.hasCompleted == false)
    do {
        _ = try await worker.submit { _ in 8 }
        Issue.record("A sealed worker accepted new application work.")
    } catch {
        #expect(error as? BoltFailure == .disconnected)
    }
    gate.release()
    let acceptedValue = try? await accepted.value
    #expect(acceptedValue == 7)
    #expect(await closing.value == .closed)
    #expect(gate.hasCompleted)
    #expect(gate.threadHasFinished)
    #expect(await worker.closeAndWait() == .closed)
}

@Test func nativeCloseBeforeAnyWorkIsAcknowledgedAndCannotStartAWorkerLater() async {
    let worker = BoltHIDWorker()
    #expect(await worker.closeAndWait() == .closed)
    do {
        _ = try await worker.submit { _ in 1 }
        Issue.record("A closed unused worker accepted application work.")
    } catch {
        #expect(error as? BoltFailure == .disconnected)
    }
}

private struct LegacyCloseTransport: BoltTransport {
    let events = AsyncStream<BoltTransportEvent> { $0.finish() }
    func open() async {}
    func close() async {}
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int { 0 }
    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        throw BoltFailure.disconnected
    }
}

@Test func legacyTransportCloseDoesNotImplyLocalShutdownAcknowledgement() async {
    #expect(await LegacyCloseTransport().closeAndWait() == .unverified)
}

@Test(arguments: [kIOReturnSuccess, kIOReturnNotOpen], [false, true])
func nativeSuccessfulOrAlreadyClosedHandleAllowsLocalClose(result: IOReturn, removalObserved: Bool) {
    #expect(BoltHIDWorker.localCloseResult(result, removalObserved: removalObserved) == .closed)
}

@Test(arguments: [kIOReturnNoDevice, kIOReturnOffline], [false, true])
func nativeAbsentHandleRequiresObservedRemovalForLocalClose(result: IOReturn, removalObserved: Bool) {
    #expect(BoltHIDWorker.localCloseResult(result, removalObserved: removalObserved)
        == (removalObserved ? .closed : .unverified))
}

@Test(arguments: [kIOReturnBusy, kIOReturnStillOpen, kIOReturnError, kIOReturnIPCError, kIOReturnTimeout,
                  kIOReturnNotAttached, kIOReturnAborted, kIOReturnBadArgument, kIOReturnNotPermitted,
                  kIOReturnNotResponding, kIOReturnNotPrivileged, IOReturn(bitPattern: 0xDEADBEEF)], [false, true])
func nativeOtherCloseErrorsRemainUnverifiedAfterRemoval(result: IOReturn, removalObserved: Bool) {
    #expect(BoltHIDWorker.localCloseResult(result, removalObserved: removalObserved) == .unverified)
}
