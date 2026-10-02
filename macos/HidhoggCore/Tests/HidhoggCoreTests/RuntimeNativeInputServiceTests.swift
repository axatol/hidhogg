import Foundation
import XCTest
@testable import HidhoggCore

final class RuntimeNativeInputServiceTests: XCTestCase {
    func testStatusAndAdmissionPreflightNeverRequestPermission() async throws {
        let backend = RuntimeFakeNativeInputBackend(permission: .denied)
        let service = RuntimeNativeInputService(backend: backend)

        let status = service.status()
        XCTAssertEqual(status.backend, .ready)
        XCTAssertEqual(status.permission, .denied)
        XCTAssertFalse(status.requestInProgress)
        XCTAssertEqual(backend.requestCount, 0)

        guard case let .rejectedPermission(id) = service.submit(RuntimeServiceTestValues.textRequest("private text")) else {
            return XCTFail("denied permission should reject without posting")
        }
        XCTAssertEqual(service.get(id: id)?.state, .permissionDenied)
        XCTAssertNil(service.get(id: id)?.startedAt)
        XCTAssertEqual(backend.requestCount, 0)
        XCTAssertTrue(backend.payloads.isEmpty)

        let permissionResult = service.requestPermission()
        XCTAssertEqual(permissionResult, .granted)
        XCTAssertEqual(backend.requestCount, 1)
        XCTAssertEqual(service.status().permission, .granted)
        XCTAssertEqual(backend.requestCount, 1)

        guard case let .queued(enterID) = service.submit(RuntimeServiceTestValues.enterRequest()) else {
            return XCTFail("explicitly granted permission should admit Enter")
        }
        let posted = await RuntimeServiceTestValues.eventually {
            service.get(id: enterID)?.state == .posted
        }
        XCTAssertTrue(posted)
        XCTAssertEqual(backend.events.values, ["down", "up"])
        XCTAssertEqual(backend.payloads, [.enter])
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testTextAcceptsSixtyFourUTF16UnitsAndRejectsOverflowOrNUL() async throws {
        let backend = RuntimeFakeNativeInputBackend()
        let service = RuntimeNativeInputService(backend: backend)
        let maximumText = String(repeating: "😀", count: 32)

        guard case let .queued(id) = service.submit(RuntimeServiceTestValues.textRequest(maximumText)) else {
            return XCTFail("64 UTF-16 units should be accepted")
        }
        let posted = await RuntimeServiceTestValues.eventually {
            service.get(id: id)?.state == .posted
        }
        XCTAssertTrue(posted)
        XCTAssertEqual(backend.payloads, [.text(maximumText)])
        XCTAssertEqual(service.submit(RuntimeServiceTestValues.textRequest(String(repeating: "😀", count: 33))), .rejectedInvalid)
        XCTAssertEqual(service.submit(RuntimeServiceTestValues.textRequest("bad\0text")), .rejectedInvalid)
        XCTAssertEqual(service.submit(RuntimeServiceTestValues.enterRequest().withAction(.keyPress(key: "escape", gesture: .release))), .rejectedInvalid)
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testQueueIsFifoAndNeverRunsMoreThanOnePairAtOnce() async throws {
        let firstDown = RuntimeServiceTestGate()
        let backend = RuntimeFakeNativeInputBackend()
        backend.pauseAfterDown(using: firstDown)
        let service = RuntimeNativeInputService(backend: backend)

        guard case .queued = service.submit(RuntimeServiceTestValues.textRequest("first")) else {
            return XCTFail("expected first request")
        }
        XCTAssertEqual(firstDown.entered.wait(timeout: .now() + .seconds(3)), .success)
        guard case .queued = service.submit(RuntimeServiceTestValues.textRequest("second")) else {
            return XCTFail("expected second request queued")
        }
        guard case .queued = service.submit(RuntimeServiceTestValues.enterRequest()) else {
            return XCTFail("expected third request queued")
        }
        XCTAssertEqual(service.status().queueDepth, 2)

        firstDown.open()
        let drained = await RuntimeServiceTestValues.eventually {
            backend.events.values.count == 6
        }
        XCTAssertTrue(drained)
        XCTAssertEqual(backend.payloads, [.text("first"), .text("second"), .enter])
        XCTAssertEqual(backend.events.values, ["down", "up", "down", "up", "down", "up"])
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testOneActivePlusSixteenWaitingAndStopStillPostsMatchingKeyUp() async throws {
        let firstDown = RuntimeServiceTestGate()
        let backend = RuntimeFakeNativeInputBackend()
        backend.pauseAfterDown(using: firstDown)
        let service = RuntimeNativeInputService(backend: backend)

        guard case let .queued(activeID) = service.submit(RuntimeServiceTestValues.textRequest("do-not-store-this")) else {
            return XCTFail("expected active request")
        }
        XCTAssertEqual(firstDown.entered.wait(timeout: .now() + .seconds(3)), .success)
        var waitingIDs = [String]()
        for index in 0..<RuntimeNativeInputService.queueCapacity {
            guard case let .queued(id) = service.submit(RuntimeServiceTestValues.textRequest("q\(index)")) else {
                XCTFail("expected FIFO item \(index)")
                return
            }
            waitingIDs.append(id)
        }
        XCTAssertEqual(service.status().queueDepth, 16)
        guard case let .rejectedQueueFull(rejectedID) = service.submit(RuntimeServiceTestValues.enterRequest()) else {
            return XCTFail("the seventeenth waiting item must be refused")
        }
        XCTAssertEqual(service.get(id: rejectedID)?.state, .rejectedQueueFull)

        let summary = try XCTUnwrap(service.get(id: activeID))
        XCTAssertFalse(String(describing: summary).contains("do-not-store-this"))
        XCTAssertTrue(waitingIDs.allSatisfy { service.get(id: $0)?.state == .queued })

        service.stop()
        firstDown.open()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
        XCTAssertEqual(backend.events.values, ["down", "up"])
        XCTAssertEqual(service.get(id: activeID)?.state, .cancelled)
        XCTAssertTrue(waitingIDs.allSatisfy { service.get(id: $0)?.state == .cancelled })
    }

    func testCancellationBeforeDownPostsNoKeyEvent() async throws {
        let makeGate = RuntimeServiceTestGate()
        let backend = RuntimeFakeNativeInputBackend()
        backend.pausePairCreation(using: makeGate)
        let service = RuntimeNativeInputService(backend: backend)

        guard case let .queued(id) = service.submit(RuntimeServiceTestValues.textRequest("cancel-before-down")) else {
            return XCTFail("expected admission before cancellation")
        }
        XCTAssertEqual(makeGate.entered.wait(timeout: .now() + .seconds(3)), .success)
        service.stop()
        makeGate.open()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
        XCTAssertTrue(backend.events.values.isEmpty)
        XCTAssertEqual(service.get(id: id)?.state, .cancelled)
    }

    func testPermissionRequestCancelsQueueAndLetsAnAdmittedKeyUpFinish() async throws {
        let firstDown = RuntimeServiceTestGate()
        let backend = RuntimeFakeNativeInputBackend()
        backend.pauseAfterDown(using: firstDown)
        let service = RuntimeNativeInputService(backend: backend)
        guard case let .queued(activeID) = service.submit(RuntimeServiceTestValues.textRequest("active")) else {
            return XCTFail("expected active admission")
        }
        XCTAssertEqual(firstDown.entered.wait(timeout: .now() + .seconds(3)), .success)
        guard case let .queued(waitingID) = service.submit(RuntimeServiceTestValues.enterRequest()) else {
            return XCTFail("expected waiting admission")
        }

        let requestTask = Task { service.requestPermission() }
        let requesting = await RuntimeServiceTestValues.eventually { service.status().requestInProgress }
        XCTAssertTrue(requesting)
        XCTAssertEqual(service.get(id: waitingID)?.state, .cancelled)
        guard case let .rejectedBusy(busyID) = service.submit(RuntimeServiceTestValues.textRequest("must-not-queue")) else {
            return XCTFail("new work is refused while explicit permission request is active")
        }
        XCTAssertEqual(service.get(id: busyID)?.state, .rejectedBusy)
        firstDown.open()
        let requestResult = await requestTask.value
        XCTAssertEqual(requestResult, .granted)
        XCTAssertEqual(backend.events.values, ["down", "up"])
        XCTAssertEqual(service.get(id: activeID)?.state, .cancelled)
        XCTAssertEqual(service.get(id: waitingID)?.state, .cancelled)
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testNativeHistoryKeepsOnlyTheNewestThirtyTwoMetadataEntries() async throws {
        let backend = RuntimeFakeNativeInputBackend()
        let service = RuntimeNativeInputService(backend: backend)
        var ids = [String]()

        for index in 0..<35 {
            guard case let .queued(id) = service.submit(RuntimeServiceTestValues.textRequest("private-\(index)")) else {
                XCTFail("expected sequential native input admission")
                return
            }
            ids.append(id)
            let posted = await RuntimeServiceTestValues.eventually {
                service.get(id: id)?.state == .posted
            }
            XCTAssertTrue(posted)
        }

        let summaries = try service.listSummaries(limit: 32)
        XCTAssertEqual(summaries.count, 32)
        XCTAssertFalse(summaries.contains(where: { $0.id == ids.first }))
        XCTAssertEqual(summaries.first?.id, ids.last)
        XCTAssertFalse(String(describing: summaries).contains("private-"))
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testPairAllocationFailureIsRecordedWithoutPayloadOrPosts() async throws {
        let backend = RuntimeFakeNativeInputBackend()
        backend.failPairCreation()
        let service = RuntimeNativeInputService(backend: backend)
        guard case let .queued(id) = service.submit(RuntimeServiceTestValues.textRequest("redact-me")) else {
            return XCTFail("expected request admission before backend allocation")
        }
        let failed = await RuntimeServiceTestValues.eventually {
            service.get(id: id)?.state == .failed
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(backend.events.values.isEmpty)
        let summary = try XCTUnwrap(service.get(id: id))
        XCTAssertFalse(String(describing: summary).contains("redact-me"))
        XCTAssertNil(summary.startedAt)
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }
}

private extension RuntimeStaticActionRequest {
    func withAction(_ action: ConfiguredAction) -> Self {
        RuntimeStaticActionRequest(profileID: profileID, coordinate: coordinate, action: action)
    }
}
