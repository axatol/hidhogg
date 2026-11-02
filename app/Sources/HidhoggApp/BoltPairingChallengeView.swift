import LogitechBolt
import SwiftUI

struct BoltPairingChallengeView: View {
    let challenge: BoltPairingChallenge

    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: 5)
    private let highlightColor = Color(red: 0.78, green: 0.55, blue: 0.12)

    private var presentation: BoltPairingChallengePresentationState {
        BoltPairingChallengePresentationState(challenge: challenge)
    }

    var body: some View {
        let progressTotal = Double(max(1, challenge.requiredClicks))
        let progressValue = Double(min(max(challenge.completedClicks, 0), Int(progressTotal)))

        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm on the mouse")
                .font(.headline)
            Text("Click the mouse buttons in this order:")
                .font(.callout)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(challenge.directions.indices, id: \.self) { index in
                    let direction = challenge.directions[index]
                    let isComplete = presentation.isDirectionComplete(at: index)
                    let isCurrent = presentation.isCurrentDirection(at: index)

                    HStack(spacing: 3) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                        Text(direction.compactTitle)
                            .font(.callout.weight(.semibold))
                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(isCurrent ? highlightColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isCurrent ? highlightColor : Color.clear,
                                          lineWidth: isCurrent ? 2 : 0)
                    }
                    .opacity(isComplete && !isCurrent ? 0.5 : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(index + 1), \(direction.accessibilityTitle)")
                    .accessibilityValue(isComplete ? "Confirmed" : isCurrent ? "Current" : "Up next")
                }
            }

            Group {
                switch presentation.currentAction {
                case let .click(index):
                    Label("Current: Step \(index + 1), \(challenge.directions[index].accessibilityTitle)",
                          systemImage: "arrow.right.circle.fill")
                case let .confirmation(direction):
                    Label("Press \(direction.actionTitle) now to confirm.", systemImage: "hand.tap.fill")
                case .waitingForReceiver:
                    Label("Confirmation received. Waiting for the receiver to finish pairing…",
                          systemImage: "hourglass")
                }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(presentation.isAwaitingConfirmation ? highlightColor : Color.primary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(presentation.isAwaitingConfirmation ? highlightColor : Color.clear,
                                  lineWidth: presentation.isAwaitingConfirmation ? 2 : 0)
            }

            ProgressView(value: progressValue, total: progressTotal) {
                Text("\(challenge.completedClicks) of \(challenge.requiredClicks) clicks confirmed")
            }
        }
    }
}

private extension BoltPairingClickDirection {
    var compactTitle: String {
        switch self {
        case .left: "L"
        case .right: "R"
        case .both: "B"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .left: "Left button"
        case .right: "Right button"
        case .both: "Both buttons together"
        }
    }

    var actionTitle: String {
        switch self {
        case .left: "the left button"
        case .right: "the right button"
        case .both: "both buttons together"
        }
    }
}
