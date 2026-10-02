import Darwin
import XCTest
@testable import HidhoggCore

final class RuntimePosixProcessRunnerTests: XCTestCase {
    func testContinuouslyReadablePipeReturnsAfterEachStreamDrainQuantum() {
        var stdout = RuntimeProcessDrainBudget(limit: 65_536, maximumReadAttempts: 64)
        var stderr = RuntimeProcessDrainBudget(limit: 65_536, maximumReadAttempts: 64)
        var stdoutReads = 0
        var stderrReads = 0

        while stdout.canRead {
            stdoutReads += 1
            stdout.recordReadAttempt()
            stdout.recordRead(min(8_192, stdout.remaining))
        }
        while stderr.canRead {
            stderrReads += 1
            stderr.recordReadAttempt()
            stderr.recordRead(min(8_192, stderr.remaining))
        }

        XCTAssertEqual(stdoutReads, 8)
        XCTAssertEqual(stderrReads, 8)
        XCTAssertEqual(stdout.bytesRead, 65_536)
        XCTAssertEqual(stderr.bytesRead, 65_536)
    }

    func testSmallAlwaysReadableChunksAlsoYieldWithinTheReadAttemptBound() {
        var budget = RuntimeProcessDrainBudget(limit: 65_536, maximumReadAttempts: 64)
        while budget.canRead {
            budget.recordReadAttempt()
            budget.recordRead(1)
        }

        XCTAssertEqual(budget.readAttempts, 64)
        XCTAssertEqual(budget.bytesRead, 64)
    }

    func testInterruptedReadReturnsToSupervisionInsteadOfRetryingInPlace() {
        XCTAssertTrue(RuntimeProcessDrainBudget.shouldReturnToSupervisor(afterReadError: EINTR))
        XCTAssertTrue(RuntimeProcessDrainBudget.shouldReturnToSupervisor(afterReadError: EAGAIN))
    }
}
