import Foundation
import XCTest
@testable import HidhoggCore

final class D200XDeviceSessionTests: XCTestCase {
    func testSelectionRefusesZeroAndMultipleCandidatesBeforeOpen() async throws {
        let candidate = D200XFakeSessionBackend.candidate()
        let cases: [([D200XDeviceCandidate], D200XSessionError)] = [
            ([], .noMatchingDevice),
            ([candidate, .init(
                registryID: candidate.registryID + 1,
                vendorID: candidate.vendorID,
                productID: candidate.productID,
                interfaceNumber: candidate.interfaceNumber,
                usagePage: candidate.usagePage,
                usage: candidate.usage,
                maximumOutputReportSize: candidate.maximumOutputReportSize
            )], .ambiguousDevice(count: 2)),
        ]

        for (candidates, expected) in cases {
            let backend = D200XFakeSessionBackend(candidates: candidates)
            let session = D200XSession(backend: backend)
            do {
                _ = try await session.candidates()
                XCTFail("expected candidate selection failure")
            } catch {
                XCTAssertEqual(error as? D200XSessionError, expected)
            }
            XCTAssertEqual(backend.openedDeviceCount, 0)
            session.stop()
            await assertStopped(session, expected: .closed)
        }
    }

    func testOpenRevalidatesUniqueCurrentCandidateBeforeBackendOpen() async throws {
        let candidate = D200XFakeSessionBackend.candidate()
        let other = D200XFakeSessionBackend.candidate(registryID: candidate.registryID + 1)
        let backend = D200XFakeSessionBackend(candidates: [candidate, other])
        let session = D200XSession(backend: backend)

        do {
            try await session.open(candidate, onInput: { _ in }, onFailure: { _ in })
            XCTFail("expected ambiguous current selection")
        } catch {
            XCTAssertEqual(error as? D200XSessionError, .ambiguousDevice(count: 2))
        }

        XCTAssertEqual(backend.openedDeviceCount, 0)
        await assertStopped(session, expected: .closed)
    }

    func testStopDuringCandidateRevalidationPreventsDeviceOpen() async throws {
        let candidate = D200XFakeSessionBackend.candidate()
        let backend = D200XFakeSessionBackend(candidates: [candidate])
        let revalidationGate = D200XTestGate()
        backend.setCandidateReadHook { readCount in
            if readCount == 1 { revalidationGate.pause() }
        }
        let session = D200XSession(backend: backend)
        let openTask = Task {
            try await session.open(candidate, onInput: { _ in }, onFailure: { _ in })
        }

        XCTAssertEqual(revalidationGate.entered.wait(timeout: .now() + .seconds(3)), .success)
        session.stop()
        revalidationGate.open()
        do {
            try await openTask.value
            XCTFail("expected the stopped session to reject open")
        } catch {
            XCTAssertEqual(error as? D200XSessionError, .sessionClosed)
        }
        await assertStopped(session, expected: .closed)
        XCTAssertEqual(backend.openedDeviceCount, 0)
        XCTAssertEqual(backend.candidateReads, 1)
    }

    func testStopDuringAdmittedBackendOpenWaitsForOpenThenClosesOnce() async throws {
        let backend = D200XFakeSessionBackend(stopOutcome: .cleanupUncertain)
        let openGate = D200XTestGate()
        backend.pauseOpen(using: openGate)
        let session = D200XSession(backend: backend)
        let candidates = try await session.candidates()
        let candidate = try XCTUnwrap(candidates.first)
        let openResult = D200XTestRecorder<D200XSessionError?>()
        let openTask = Task {
            do {
                try await session.open(candidate, onInput: { _ in }, onFailure: { _ in })
                openResult.append(nil)
            } catch {
                openResult.append(error as? D200XSessionError)
            }
        }

        XCTAssertEqual(openGate.entered.wait(timeout: .now() + .seconds(3)), .success)
        XCTAssertEqual(backend.openedDeviceCount, 1, "the fake backend has admitted the open")

        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.stop()
            stopReturned.signal()
        }
        XCTAssertEqual(stopReturned.wait(timeout: .now() + .seconds(1)), .success, "stop must return without joining backend.open")
        XCTAssertEqual(backend.stoppedCount, 0, "teardown waits behind the admitted writer operation")

        openGate.open()
        await openTask.value
        XCTAssertEqual(openResult.values, [.sessionClosed], "stop wins before open can publish the opened state")
        do {
            try await session.perform(.keepAlive)
            XCTFail("a stopped session must not accept output")
        } catch {
            XCTAssertEqual(error as? D200XSessionError, .sessionNotOpen)
        }

        await assertStopped(session, expected: .cleanupUncertain)
        XCTAssertEqual(backend.stoppedCount, 1)
        XCTAssertTrue(backend.attemptedReports.isEmpty)
    }

    func testNoCandidateDiscoveryStartsAfterStop() async throws {
        let backend = D200XFakeSessionBackend()
        let session = D200XSession(backend: backend)
        session.stop()
        await assertStopped(session, expected: .closed)

        do {
            _ = try await session.candidates()
            XCTFail("expected stopped session to reject discovery")
        } catch {
            XCTAssertEqual(error as? D200XSessionError, .sessionClosed)
        }
        XCTAssertEqual(backend.candidateReads, 0)
    }

    func testStartupReportsStripOnlySyntheticIDAndKeepWholeTypedBatchOrder() async throws {
        let backend = D200XFakeSessionBackend()
        let session = try await openSession(backend)
        let page = try D200XPageRenderer.render(profile: decodeD200XProfile())
        let batch = D200XOutboundBatch.startup(page: page, brightness: 0)
        let expectedReports = try batch.makeFrames().flatMap(D200XFrameCodec.encode)

        try await session.perform(batch)

        let nativeReports = backend.attemptedReports
        XCTAssertEqual(nativeReports.count, expectedReports.count)
        XCTAssertTrue(nativeReports.allSatisfy { $0.reportID == 0 && $0.packet.count == 1024 })
        XCTAssertEqual(nativeReports.map { Data([0]) + $0.packet }, expectedReports)
        XCTAssertEqual(Array(nativeReports[0].packet.prefix(4)), [0x7c, 0x7c, 0x00, 0x10])
        XCTAssertEqual(Array(nativeReports.last!.packet.prefix(4)), [0x7c, 0x7c, 0x00, 0x02])

        session.stop()
        await assertStopped(session, expected: .closed)
    }

    func testCompleteBatchesSerializeAndNeverInterleaveReports() async throws {
        let backend = D200XFakeSessionBackend()
        let gate = D200XTestGate()
        backend.pauseWrite(at: 1, using: gate)
        let enqueueSignals = DispatchSemaphore(value: 0)
        let session = try await openSession(backend, onBatchEnqueued: { enqueueSignals.signal() })
        let page = try D200XPageRenderer.render(profile: decodeD200XProfile())
        let firstBatch = D200XOutboundBatch.startup(page: page, brightness: 37)
        let secondBatch = D200XOutboundBatch.setBrightness(42)
        let expected = try (firstBatch.makeFrames() + secondBatch.makeFrames()).flatMap(D200XFrameCodec.encode)

        let first = Task { try await session.perform(firstBatch) }
        XCTAssertEqual(enqueueSignals.wait(timeout: .now() + .seconds(3)), .success)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + .seconds(3)), .success)
        let second = Task { try await session.perform(secondBatch) }
        XCTAssertEqual(enqueueSignals.wait(timeout: .now() + .seconds(3)), .success)
        gate.open()

        try await first.value
        try await second.value
        XCTAssertEqual(backend.attemptedReports.map { Data([0]) + $0.packet }, expected)
        XCTAssertEqual(backend.attemptedReports.map(\.reportID), Array(repeating: 0, count: expected.count))

        session.stop()
        await assertStopped(session, expected: .closed)
    }

    func testFailedReportStopsRemainderAndAlreadyQueuedNextBatchBeforeQueueRelease() async throws {
        let backend = D200XFakeSessionBackend()
        let gate = D200XTestGate()
        backend.pauseWrite(at: 1, using: gate)
        backend.failWrite(at: 1)
        let enqueueSignals = DispatchSemaphore(value: 0)
        let failures = D200XTestRecorder<D200XSessionFailure>()
        let session = try await openSession(
            backend,
            onFailure: { failures.append($0) },
            onBatchEnqueued: { enqueueSignals.signal() }
        )
        let page = try D200XPageRenderer.render(profile: decodeD200XProfile())

        let first = Task { try await session.perform(.startup(page: page, brightness: 80)) }
        XCTAssertEqual(enqueueSignals.wait(timeout: .now() + .seconds(3)), .success)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + .seconds(3)), .success)
        let second = Task { try await session.perform(.setBrightness(12)) }
        XCTAssertEqual(enqueueSignals.wait(timeout: .now() + .seconds(3)), .success)
        gate.open()

        do {
            try await first.value
            XCTFail("expected the first report to fail")
        } catch {
            XCTAssertEqual(error as? D200XSessionError, .writeFailed)
        }
        do {
            try await second.value
            XCTFail("expected the queued batch to observe fail-stop")
        } catch {
            XCTAssertEqual(error as? D200XSessionError, .sessionFailed)
        }

        XCTAssertEqual(backend.attemptedReports.count, 1)
        XCTAssertEqual(failures.values, [.writeFailed])
        await assertStopped(session, expected: .closed)
        XCTAssertEqual(backend.stoppedCount, 1)
    }

    func testInputReceiptRunsWhileOutputWriteIsPausedAndPreservesRawEvent() async throws {
        let backend = D200XFakeSessionBackend()
        let gate = D200XTestGate()
        backend.pauseWrite(at: 1, using: gate)
        let inputs = D200XTestRecorder<D200XInputEvent>()
        let session = try await openSession(backend, onInput: { inputs.append($0) })
        let event = D200XInputEvent(deviceState: 0xa7, wireIndex: 13, marker: 0xf2, action: 0xf3, rawPayload: Data([0xa7, 13, 0xf2, 0xf3, 0x44]))
        let write = Task { try await session.perform(.keepAlive) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + .seconds(3)), .success)

        backend.emitInput(event)

        XCTAssertEqual(inputs.received.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(inputs.values, [event])
        gate.open()
        try await write.value
        session.stop()
        await assertStopped(session, expected: .closed)
    }

    func testRemovalDuringPausedWriteStopsRemainingReportsWithoutRetry() async throws {
        let backend = D200XFakeSessionBackend()
        let gate = D200XTestGate()
        backend.pauseWrite(at: 1, using: gate)
        let failures = D200XTestRecorder<D200XSessionFailure>()
        let session = try await openSession(backend, onFailure: { failures.append($0) })
        let page = try D200XPageRenderer.render(profile: decodeD200XProfile())
        let write = Task { try await session.perform(.startup(page: page, brightness: 50)) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + .seconds(3)), .success)

        backend.emitFailure(.deviceRemoved)
        gate.open()

        do {
            try await write.value
            XCTFail("expected removed session to stop the batch")
        } catch {
            XCTAssertTrue(error is D200XSessionError)
        }
        XCTAssertEqual(backend.attemptedReports.count, 1)
        XCTAssertEqual(failures.values, [.deviceRemoved])
        await assertStopped(session, expected: .closed)
    }

    func testStopFromInputCallbackIsNonblockingAndWaitersShareCleanupOutcome() async throws {
        let backend = D200XFakeSessionBackend()
        let closeGate = D200XTestGate()
        backend.pauseStop(using: closeGate)
        let sessionBox = D200XSessionBox()
        let callbackReturned = DispatchSemaphore(value: 0)
        let inputCount = D200XTestCounter()
        let session = D200XSession(backend: backend)
        sessionBox.session = session
        let candidates = try await session.candidates()
        let candidate = try XCTUnwrap(candidates.first)
        try await session.open(candidate, onInput: { _ in
            inputCount.increment()
            sessionBox.session?.stop()
            callbackReturned.signal()
        }, onFailure: { _ in })

        backend.emitInput(D200XInputEvent(deviceState: 1, wireIndex: 0, marker: 2, action: 3, rawPayload: Data([1, 0, 2, 3])))
        XCTAssertEqual(callbackReturned.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(closeGate.entered.wait(timeout: .now() + .seconds(3)), .success)
        XCTAssertEqual(inputCount.value, 1)

        let firstWaiter = Task { await session.waitUntilStopped() }
        let secondWaiter = Task { await session.waitUntilStopped() }
        closeGate.open()
        let firstOutcome = await firstWaiter.value
        let secondOutcome = await secondWaiter.value
        XCTAssertEqual(firstOutcome, .closed)
        XCTAssertEqual(secondOutcome, .closed)
        backend.emitInput(D200XInputEvent(deviceState: 1, wireIndex: 0, marker: 2, action: 3, rawPayload: Data([1, 0, 2, 3])))
        XCTAssertEqual(inputCount.value, 1)
        XCTAssertEqual(backend.stoppedCount, 1)
    }

    func testFakeCloseFailureIsReturnedByWaitUntilStopped() async throws {
        let backend = D200XFakeSessionBackend(stopOutcome: .cleanupUncertain)
        let session = D200XSession(backend: backend)
        session.stop()
        let outcome = await session.waitUntilStopped()
        XCTAssertEqual(outcome, .cleanupUncertain)
        XCTAssertEqual(backend.stoppedCount, 1)
    }

    private func openSession(
        _ backend: D200XFakeSessionBackend,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void = { _ in },
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void = { _ in },
        onBatchEnqueued: (@Sendable () -> Void)? = nil
    ) async throws -> D200XSession {
        let session = D200XSession(backend: backend, onBatchEnqueued: onBatchEnqueued)
        let candidates = try await session.candidates()
        let candidate = try XCTUnwrap(candidates.first)
        try await session.open(candidate, onInput: onInput, onFailure: onFailure)
        return session
    }

    private func assertStopped(
        _ session: D200XSession,
        expected: D200XSessionStopOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let outcome = await session.waitUntilStopped()
        XCTAssertEqual(outcome, expected, file: file, line: line)
    }
}

private final class D200XSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: D200XSession?

    var session: D200XSession? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}
