import LogitechBolt

struct BoltPairingChallengePresentationState: Equatable {
    enum CurrentAction: Equatable {
        case click(index: Int)
        case confirmation(direction: BoltPairingClickDirection)
        case waitingForReceiver
    }

    let currentAction: CurrentAction
    let completedDirectionCount: Int

    var isAwaitingConfirmation: Bool {
        if case .confirmation = currentAction { return true }
        return false
    }

    init(challenge: BoltPairingChallenge) {
        let completedClicks = min(max(challenge.completedClicks, 0), challenge.directions.count)
        completedDirectionCount = challenge.entryComplete ? challenge.directions.count : completedClicks

        if challenge.entryComplete {
            currentAction = .waitingForReceiver
        } else if completedClicks < challenge.directions.count {
            currentAction = .click(index: completedClicks)
        } else {
            currentAction = .confirmation(direction: challenge.confirmationDirection)
        }
    }

    func isDirectionComplete(at index: Int) -> Bool {
        index >= 0 && index < completedDirectionCount
    }

    func isCurrentDirection(at index: Int) -> Bool {
        guard case let .click(currentIndex) = currentAction else { return false }
        return currentIndex == index
    }
}
