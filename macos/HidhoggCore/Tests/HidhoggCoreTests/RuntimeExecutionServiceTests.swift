import Foundation
import XCTest
@testable import HidhoggCore

final class RuntimeExecutionServiceTests: XCTestCase {
    func testValidatedLaunchUsesLiteralArgumentsMinimalEnvironmentAndExactGetTails() async throws {
        let stdout = Data(repeating: 0x6f, count: 5_000)
        let stderr = Data(repeating: 0x65, count: 4_097)
        let runner = RuntimeFakeProcessRunner(
            termination: .exited(7),
            output: [(.standardOutput, stdout), (.standardError, stderr)]
        )
        let service = RuntimeExecutionService(runner: runner)
        let arguments = ["two words", "; literal", "$(not-a-shell)", "quote'and\"slash\\"]
        let request = RuntimeServiceTestValues.executeRequest(
            executable: "/\u{0301}tool",
            arguments: arguments,
            timeoutSeconds: 60
        )

        guard case let .admitted(id) = service.submit(request) else {
            return XCTFail("expected validated executable admission")
        }
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        let finished = await RuntimeServiceTestValues.eventually {
            service.get(id: id)?.summary.state == .exited
        }
        XCTAssertTrue(finished)

        let launch = try XCTUnwrap(runner.launches.first)
        XCTAssertEqual(launch.executable, "/\u{0301}tool")
        XCTAssertEqual(launch.arguments, arguments)
        XCTAssertEqual(launch.timeoutSeconds, 60)
        XCTAssertEqual(launch.workingDirectory, "/")
        XCTAssertEqual(launch.environment, ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"])

        let record = try XCTUnwrap(service.get(id: id))
        XCTAssertEqual(record.summary.exitCode, 7)
        XCTAssertEqual(record.standardOutput.tail, Data(stdout.suffix(4_096)))
        XCTAssertEqual(record.standardOutput.totalBytes, 5_000)
        XCTAssertTrue(record.standardOutput.truncated)
        XCTAssertEqual(record.standardError.tail, Data(stderr.suffix(4_096)))
        XCTAssertEqual(record.standardError.totalBytes, 4_097)
        XCTAssertTrue(record.standardError.truncated)
        XCTAssertNil(service.get(id: "not-the-exact-id"))

        let summaries = try service.listSummaries(limit: 32)
        XCTAssertEqual(summaries.map(\.id), [id])
        let renderedSummary = String(describing: try XCTUnwrap(summaries.first))
        XCTAssertFalse(renderedSummary.contains("/\u{0301}tool"))
        XCTAssertFalse(renderedSummary.contains(arguments[2]))

        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testDefaultTimeoutAndMaximumArgumentBoundariesAreAccepted() async throws {
        let runner = RuntimeFakeProcessRunner(termination: .exited(0))
        let service = RuntimeExecutionService(runner: runner)
        let arguments = Array(repeating: String(repeating: "a", count: 256), count: 32)
        let request = RuntimeServiceTestValues.executeRequest(
            executable: "/bin/tool",
            arguments: arguments
        )

        guard case let .admitted(id) = service.submit(request) else {
            return XCTFail("expected boundary request admission")
        }
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        let finished = await RuntimeServiceTestValues.eventually {
            service.get(id: id)?.summary.state == .exited
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(runner.launches.first?.timeoutSeconds, 10)
        XCTAssertEqual(runner.launches.first?.arguments, arguments)
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testInvalidExecutableArgumentsAndTimeoutsAreRejectedBeforeRunner() {
        let runner = RuntimeFakeProcessRunner()
        let service = RuntimeExecutionService(runner: runner)
        let invalidRequests = [
            RuntimeServiceTestValues.executeRequest(executable: "bin/tool"),
            RuntimeServiceTestValues.executeRequest(executable: "/bin/tool\0suffix"),
            RuntimeServiceTestValues.executeRequest(arguments: Array(repeating: "a", count: 33)),
            RuntimeServiceTestValues.executeRequest(arguments: [String(repeating: "a", count: 1_025)]),
            RuntimeServiceTestValues.executeRequest(arguments: Array(repeating: String(repeating: "b", count: 1_024), count: 9)),
            RuntimeServiceTestValues.executeRequest(arguments: ["nul\0argument"]),
            RuntimeServiceTestValues.executeRequest(timeoutSeconds: 0),
            RuntimeServiceTestValues.executeRequest(timeoutSeconds: 61),
            RuntimeServiceTestValues.executeRequest(profileID: "profile id"),
            RuntimeServiceTestValues.executeRequest(coordinate: "0/0"),
        ]

        for request in invalidRequests {
            XCTAssertEqual(service.submit(request), .rejectedInvalid)
        }
        XCTAssertTrue(runner.launches.isEmpty)
        XCTAssertThrowsError(try service.listSummaries(limit: 33)) {
            XCTAssertEqual($0 as? RuntimeExecutionServiceError, .invalidSummaryLimit)
        }
        service.stop()
    }

    func testTimeoutAndSpawnFailureRemainDistinctHistoryOutcomes() async throws {
        let runner = RuntimeFakeProcessRunner(termination: .timedOut(143))
        let service = RuntimeExecutionService(runner: runner)

        guard case let .admitted(timedOutID) = service.submit(RuntimeServiceTestValues.executeRequest(timeoutSeconds: 1)) else {
            return XCTFail("expected one-second timeout request admission")
        }
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        let timedOut = await RuntimeServiceTestValues.eventually {
            service.get(id: timedOutID)?.summary.state == .timedOut
        }
        XCTAssertTrue(timedOut)
        XCTAssertEqual(service.get(id: timedOutID)?.summary.exitCode, 143)

        runner.configure(termination: .startFailed)
        guard case let .admitted(failedID) = service.submit(RuntimeServiceTestValues.executeRequest()) else {
            return XCTFail("completed timeout should release the active slot")
        }
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        let failed = await RuntimeServiceTestValues.eventually {
            service.get(id: failedID)?.summary.state == .startFailed
        }
        XCTAssertTrue(failed)
        XCTAssertNil(service.get(id: failedID)?.summary.startedAt)
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testBusyRequestIsRecordedWithoutLeakingItsCommand() async throws {
        let gate = RuntimeServiceTestGate()
        let runner = RuntimeFakeProcessRunner(termination: .exited(0), gate: gate)
        let service = RuntimeExecutionService(runner: runner)
        guard case let .admitted(activeID) = service.submit(RuntimeServiceTestValues.executeRequest()) else {
            return XCTFail("expected first process admission")
        }
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + .seconds(3)), .success)

        let busyCommand = "/private/path/never-run"
        let busyArgument = "secret-argument"
        let second = RuntimeServiceTestValues.executeRequest(executable: busyCommand, arguments: [busyArgument])
        guard case let .rejectedBusy(id) = service.submit(second) else { return XCTFail("expected one-active refusal") }
        let record = try XCTUnwrap(service.get(id: id))
        XCTAssertEqual(record.summary.state, .rejectedBusy)
        XCTAssertEqual(record.standardOutput.totalBytes, 0)
        XCTAssertEqual(record.standardError.totalBytes, 0)
        XCTAssertFalse(String(describing: record).contains(busyCommand))
        XCTAssertFalse(String(describing: record).contains(busyArgument))
        XCTAssertEqual(runner.launches.count, 1)

        for index in 0..<40 {
            guard case .rejectedBusy = service.submit(RuntimeServiceTestValues.executeRequest(
                executable: "/private/path/other-\(index)"
            )) else {
                XCTFail("a busy process must never admit another executable")
                return
            }
        }
        XCTAssertEqual(service.get(id: activeID)?.summary.state, .running)
        XCTAssertEqual(try service.listSummaries(limit: 32).count, 32)

        gate.open()
        let done = await RuntimeServiceTestValues.eventually {
            service.get(id: activeID)?.summary.state == .exited
        }
        XCTAssertTrue(done)
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }

    func testStopCancelsTheActiveProcessAndWaitsForItsReapResult() async throws {
        let gate = RuntimeServiceTestGate()
        let runner = RuntimeFakeProcessRunner(termination: .cancelled(nil), gate: gate)
        let service = RuntimeExecutionService(runner: runner)
        guard case let .admitted(id) = service.submit(RuntimeServiceTestValues.executeRequest()) else {
            return XCTFail("expected process admission")
        }
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + .seconds(3)), .success)

        service.stop()
        XCTAssertEqual(runner.cancellationRequests, [true])
        gate.open()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
        XCTAssertEqual(service.get(id: id)?.summary.state, .cancelled)
        XCTAssertEqual(service.submit(RuntimeServiceTestValues.executeRequest()), .closed)
    }

    func testCleanupUncertaintyClosesAdmissionAndSurvivesStop() async throws {
        let runner = RuntimeFakeProcessRunner(termination: .cleanupUncertain)
        let service = RuntimeExecutionService(runner: runner)
        guard case let .admitted(id) = service.submit(RuntimeServiceTestValues.executeRequest()) else {
            return XCTFail("expected process admission")
        }
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        let finished = await RuntimeServiceTestValues.eventually {
            service.get(id: id)?.summary.state == .cleanupUncertain
        }
        XCTAssertTrue(finished)
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .cleanupUncertain)
        XCTAssertEqual(service.submit(RuntimeServiceTestValues.executeRequest()), .closed)
    }

    func testHistoryRemainsBoundedToNewestThirtyTwoCompletedItems() async throws {
        let runner = RuntimeFakeProcessRunner(termination: .exited(0))
        let service = RuntimeExecutionService(runner: runner)
        var ids = [String]()

        for _ in 0..<35 {
            guard case let .admitted(id) = service.submit(RuntimeServiceTestValues.executeRequest()) else {
                XCTFail("expected sequential request admission")
                return
            }
            ids.append(id)
            XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
            let finished = await RuntimeServiceTestValues.eventually {
                service.get(id: id)?.summary.state == .exited
            }
            XCTAssertTrue(finished)
        }

        let summaries = try service.listSummaries(limit: 32)
        XCTAssertEqual(summaries.count, 32)
        XCTAssertFalse(summaries.contains(where: { $0.id == ids.first }))
        XCTAssertEqual(summaries.first?.id, ids.last)
        service.stop()
        let stopped = await service.waitUntilStopped()
        XCTAssertEqual(stopped, .closed)
    }
}
