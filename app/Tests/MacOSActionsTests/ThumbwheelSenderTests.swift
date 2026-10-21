import MacOSActions
import Testing

@MainActor
struct ThumbwheelSenderTests {
    @Test func horizontalAmountScalesOnlyHorizontalAxisAndRetainsFractions() throws {
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        var observedAt = clock.now

        try sender.send(vertical: 0.25, horizontal: 0.4, amount: 1.25, amountAxis: .horizontal,
                        generation: 4, observedAt: observedAt)
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0.25, horizontal: 0.4, amount: 1.25, amountAxis: .horizontal,
                        generation: 4, observedAt: observedAt)

        #expect(posted == [.init(vertical: 0, horizontal: 1)])

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0.5, horizontal: 0, amount: 1.25, amountAxis: .horizontal,
                        generation: 4, observedAt: observedAt)
        #expect(posted == [.init(vertical: 0, horizontal: 1), .init(vertical: 1, horizontal: 0)])
    }

    @Test func selectedAxisAcceptsRawInt16MagnitudeBeforeApplyingAmount() throws {
        var posted = [PostedLines]()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) }
        )

        try sender.send(vertical: 0, horizontal: -32_768, amount: 10, amountAxis: .horizontal,
                        generation: 1, observedAt: .now)

        #expect(posted == [.init(vertical: 0, horizontal: -327_680)])
    }

    @Test func changingAmountAxisClearsPriorFractionalState() throws {
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        var observedAt = clock.now

        try sender.send(vertical: 0.75, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0, horizontal: 0.25, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0.25, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)

        #expect(posted.isEmpty)
    }

    @Test func invalidRawInputNeverReachesPostAfterScalingIsSelected() {
        var posted = [PostedLines]()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) }
        )

        #expect(throws: ScrollDeliveryError.invalidDelta) {
            try sender.send(vertical: 0, horizontal: 32_768.1, amount: 10, amountAxis: .horizontal,
                            generation: 1, observedAt: .now)
        }
        #expect(posted.isEmpty)
    }

    @Test func stateOneStartsFreshFractionAndStateThreeZeroStopsClearIt() throws {
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        var observedAt = clock.now

        try sender.send(vertical: 0, horizontal: 0.75, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0, horizontal: 0.25, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt, resetFractionsBefore: true)
        #expect(posted.isEmpty)

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0, horizontal: 0.75, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        #expect(posted == [.init(vertical: 0, horizontal: 1)])

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0, horizontal: 0.75, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0, horizontal: 0, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt, resetFractionsAfter: true)
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0, horizontal: 0.25, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        #expect(posted == [.init(vertical: 0, horizontal: 1)])

        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0, horizontal: 0.75, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        #expect(posted == [.init(vertical: 0, horizontal: 1), .init(vertical: 0, horizontal: 1)])
    }

    @Test func duplicateStartTimestampCannotBeAcceptedByAStateBoundaryReset() throws {
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        let observedAt = clock.now

        try sender.send(vertical: 0, horizontal: 0.5, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        #expect(throws: ScrollDeliveryError.staleTimestamp) {
            try sender.send(vertical: 0, horizontal: 1, amount: 1, amountAxis: .horizontal,
                            generation: 1, observedAt: observedAt, resetFractionsBefore: true)
        }
        #expect(posted.isEmpty)
    }

    @Test func permissionRevocationAfterSuccessfulThumbwheelSendStopsFurtherPosts() throws {
        var allowed = true
        var preflightCalls = 0
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { preflightCalls += 1; return allowed },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        var observedAt = clock.now

        try sender.send(vertical: 0, horizontal: 1.75, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        #expect(posted == [.init(vertical: 0, horizontal: 1)])

        allowed = false
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        #expect(throws: ScrollDeliveryError.permissionDenied) {
            try sender.send(vertical: 0, horizontal: 0.5, amount: 1, amountAxis: .horizontal,
                            generation: 1, observedAt: observedAt)
        }

        allowed = true
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0, horizontal: 0.25, amount: 1, amountAxis: .horizontal,
                        generation: 1, observedAt: observedAt)
        #expect(posted == [.init(vertical: 0, horizontal: 1)])
        #expect(preflightCalls == 3)
    }
}

@MainActor
private final class SenderTestClock {
    var now = ContinuousClock.now
}

private struct PostedLines: Equatable {
    let vertical: Int32
    let horizontal: Int32
}
