import LogitechBolt
import XCTest
@testable import HidhoggApp

final class BoltPairingChallengePresentationTests: XCTestCase {
    func testFirstClickIsCurrentAndUnconfirmed() {
        let state = makeState(completedClicks: 0)

        XCTAssertEqual(state.currentAction, .click(index: 0))
        XCTAssertEqual(state.completedDirectionCount, 0)
        XCTAssertTrue(state.isCurrentDirection(at: 0))
        XCTAssertFalse(state.isDirectionComplete(at: 0))
    }

    func testMiddleProgressHighlightsNextDirection() {
        let state = makeState(completedClicks: 4)

        XCTAssertEqual(state.currentAction, .click(index: 4))
        XCTAssertTrue(state.isDirectionComplete(at: 3))
        XCTAssertTrue(state.isCurrentDirection(at: 4))
        XCTAssertFalse(state.isDirectionComplete(at: 4))
    }

    func testTenClicksAdvanceToSeparateBothButtonConfirmation() {
        let state = makeState(completedClicks: 10)

        XCTAssertEqual(state.currentAction, .confirmation(direction: .both))
        XCTAssertTrue(state.isAwaitingConfirmation)
        XCTAssertEqual(state.completedDirectionCount, 10)
    }

    func testEntryCompleteWaitsForReceiverWithoutAnotherClick() {
        let state = makeState(completedClicks: 10, entryComplete: true)

        XCTAssertEqual(state.currentAction, .waitingForReceiver)
        XCTAssertFalse(state.isAwaitingConfirmation)
        XCTAssertEqual(state.completedDirectionCount, 10)
        XCTAssertFalse(state.isCurrentDirection(at: 9))
    }

    func testRewoundProgressMovesCurrentDirectionBackward() {
        let beforeRewind = makeState(completedClicks: 7)
        let afterRewind = makeState(completedClicks: 6)

        XCTAssertEqual(beforeRewind.currentAction, .click(index: 7))
        XCTAssertEqual(afterRewind.currentAction, .click(index: 6))
        XCTAssertTrue(beforeRewind.isDirectionComplete(at: 6))
        XCTAssertFalse(afterRewind.isDirectionComplete(at: 6))
        XCTAssertTrue(afterRewind.isCurrentDirection(at: 6))
    }

    private func makeState(completedClicks: Int, entryComplete: Bool = false) -> BoltPairingChallengePresentationState {
        let directions: [BoltPairingClickDirection] = (0..<10).map { index in
            index.isMultiple(of: 2) ? .left : .right
        }
        let challenge = BoltPairingChallenge(directions: directions,
                                             confirmationDirection: .both,
                                             completedClicks: completedClicks,
                                             requiredClicks: 10,
                                             entryComplete: entryComplete)
        return BoltPairingChallengePresentationState(challenge: challenge)
    }
}
