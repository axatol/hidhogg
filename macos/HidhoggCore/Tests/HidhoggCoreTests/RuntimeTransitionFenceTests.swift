import Dispatch
import Foundation
import XCTest
@testable import HidhoggCore

final class RuntimeTransitionFenceTests: XCTestCase {
    func testReceiptStampsAreInvalidatedAcrossTransitionBoundaries() {
        let fence = RuntimeTransitionFence()
        let before = fence.stampAtReceipt()
        XCTAssertTrue(fence.accepts(before))

        XCTAssertTrue(fence.beginTransition())
        let during = fence.stampAtReceipt()
        XCTAssertTrue(during.active)
        XCTAssertFalse(fence.accepts(before))
        XCTAssertFalse(fence.accepts(during))

        XCTAssertTrue(fence.endTransition())
        let after = fence.stampAtReceipt()
        XCTAssertFalse(after.active)
        XCTAssertFalse(fence.accepts(before))
        XCTAssertFalse(fence.accepts(during))
        XCTAssertTrue(fence.accepts(after))
    }

    func testRepeatedBeginAndEndRejectWithoutChangingFenceState() {
        let fence = RuntimeTransitionFence()
        let initial = fence.stampAtReceipt()

        XCTAssertFalse(fence.endTransition())
        XCTAssertEqual(fence.stampAtReceipt(), initial)
        XCTAssertTrue(fence.accepts(initial))

        XCTAssertTrue(fence.beginTransition())
        let active = fence.stampAtReceipt()
        XCTAssertFalse(fence.beginTransition())
        XCTAssertEqual(fence.stampAtReceipt(), active)

        XCTAssertTrue(fence.endTransition())
        let completed = fence.stampAtReceipt()
        XCTAssertFalse(fence.endTransition())
        XCTAssertEqual(fence.stampAtReceipt(), completed)
        XCTAssertTrue(fence.accepts(completed))
    }

    func testConcurrentReceiptReadsNeverObserveTornPhaseAndGeneration() {
        let fence = RuntimeTransitionFence()
        let stamps = RuntimeTransitionStampRecorder()
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        finished.enter()

        DispatchQueue.global().async {
            start.wait()
            DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
                stamps.append(fence.stampAtReceipt())
            }
            finished.leave()
        }

        start.signal()
        for _ in 0..<500 {
            XCTAssertTrue(fence.beginTransition())
            XCTAssertTrue(fence.endTransition())
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)

        let receipts = stamps.snapshot()
        XCTAssertEqual(receipts.count, 2_000)
        XCTAssertTrue(receipts.allSatisfy { $0.active == ($0.generation.isMultiple(of: 2) == false) })
        XCTAssertEqual(fence.stampAtReceipt().generation, 1_000)
    }
}

private final class RuntimeTransitionStampRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [RuntimeTransitionStamp] = []

    func append(_ stamp: RuntimeTransitionStamp) {
        lock.lock()
        stamps.append(stamp)
        lock.unlock()
    }

    func snapshot() -> [RuntimeTransitionStamp] {
        lock.lock()
        defer { lock.unlock() }
        return stamps
    }
}
