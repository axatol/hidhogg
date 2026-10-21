import HidhoggDomain
import MacOSActions
import Testing

@MainActor
struct ScrollSenderTests {
    @Test func initializerStoresFakesWithoutCallingThem() {
        var preflightCalls = 0
        var nowCalls = 0
        var posted = [PostedLines]()
        let sender = ScrollSender(
            preflight: { preflightCalls += 1; return true },
            post: { posted.append(PostedLines(vertical: $0, horizontal: $1)) },
            now: { nowCalls += 1; return ContinuousClock.now }
        )

        #expect(preflightCalls == 0)
        #expect(nowCalls == 0)
        #expect(posted.isEmpty)
        #expect(sender.canPostEvents())
        #expect(preflightCalls == 1)
        #expect(nowCalls == 0)
    }

    @Test func fractionalReportsProduceWholeLineUnitsWithoutDirectionBias() throws {
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        var observedAt = clock.now

        for _ in 0..<15 {
            observedAt = observedAt.advanced(by: .milliseconds(1))
            clock.now = observedAt
            try sender.send(vertical: 1.0 / 15.0, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        }

        sender.reset()
        for _ in 0..<15 {
            observedAt = observedAt.advanced(by: .milliseconds(1))
            clock.now = observedAt
            try sender.send(vertical: -1.0 / 15.0, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        }

        #expect(posted == [
            .init(vertical: 1, horizontal: 0),
            .init(vertical: -1, horizontal: 0)
        ])
    }

    @Test func amountOnlyScalesVerticalAndKeepsHorizontalAtOneTimes() throws {
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        let observedAt = clock.now

        try sender.send(vertical: 0.5, horizontal: 0.5, amount: 2, generation: 1, observedAt: observedAt)
        let nextObservedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = nextObservedAt
        try sender.send(vertical: 0, horizontal: 0.5, amount: 2, generation: 1, observedAt: nextObservedAt)

        #expect(posted == [
            .init(vertical: 1, horizontal: 0),
            .init(vertical: 0, horizontal: 1)
        ])
    }

    @Test func generationAmountAndLongReportGapResetFractionalState() throws {
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
        try sender.send(vertical: 0.25, horizontal: 0, amount: 1, generation: 2, observedAt: observedAt)
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0.25, horizontal: 0, amount: 2, generation: 2, observedAt: observedAt)
        observedAt = observedAt.advanced(by: .milliseconds(260))
        clock.now = observedAt
        try sender.send(vertical: 0.25, horizontal: 0, amount: 2, generation: 2, observedAt: observedAt)
        observedAt = observedAt.advanced(by: .milliseconds(1))
        clock.now = observedAt
        try sender.send(vertical: 0.5, horizontal: 0, amount: 2, generation: 2, observedAt: observedAt)

        #expect(posted == [.init(vertical: 1, horizontal: 0)])
    }

    @Test func invalidReportsAndTimesNeverReachPostClosure() throws {
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        let observedAt = clock.now

        #expect(throws: ScrollDeliveryError.invalidAmount) {
            try sender.send(vertical: 1, horizontal: 0, amount: .nan, generation: 1, observedAt: observedAt)
        }
        #expect(throws: ScrollDeliveryError.invalidAmount) {
            try sender.send(vertical: 1, horizontal: 0, amount: 10.1, generation: 1, observedAt: observedAt)
        }
        #expect(throws: ScrollDeliveryError.invalidDelta) {
            try sender.send(vertical: .infinity, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        }
        #expect(throws: ScrollDeliveryError.invalidDelta) {
            try sender.send(vertical: 32_769, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        }
        #expect(throws: ScrollDeliveryError.futureTimestamp) {
            try sender.send(
                vertical: 1,
                horizontal: 0,
                amount: 1,
                generation: 1,
                observedAt: observedAt.advanced(by: .seconds(1))
            )
        }
        #expect(throws: ScrollDeliveryError.staleTimestamp) {
            try sender.send(
                vertical: 1,
                horizontal: 0,
                amount: 1,
                generation: 1,
                observedAt: observedAt.advanced(by: .milliseconds(-300))
            )
        }

        try sender.send(vertical: 0, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        #expect(throws: ScrollDeliveryError.staleTimestamp) {
            try sender.send(vertical: 1, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        }
        #expect(posted.isEmpty)
    }

    @Test func deniedOrFailedDeliveryClearsFractionsAndConsumesAttemptTimestamp() throws {
        var allowed = false
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { allowed },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )
        let firstObservedAt = clock.now

        #expect(throws: ScrollDeliveryError.permissionDenied) {
            try sender.send(vertical: 0.75, horizontal: 0, amount: 1, generation: 1, observedAt: firstObservedAt)
        }
        allowed = true
        #expect(throws: ScrollDeliveryError.staleTimestamp) {
            try sender.send(vertical: 1, horizontal: 0, amount: 1, generation: 1, observedAt: firstObservedAt)
        }

        let retryObservedAt = firstObservedAt.advanced(by: .milliseconds(1))
        clock.now = retryObservedAt
        try sender.send(
            vertical: 0.25,
            horizontal: 0,
            amount: 1,
            generation: 1,
            observedAt: retryObservedAt
        )
        #expect(posted.isEmpty)
    }

    @Test func permissionRevocationAfterSuccessfulSendPreventsPostingAndClearsFractions() throws {
        var allowed = true
        var preflightCalls = 0
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { preflightCalls += 1; return allowed },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )

        try sender.send(vertical: 1.75, horizontal: 0.75, amount: 1, generation: 1, observedAt: clock.now)
        #expect(posted == [.init(vertical: 1, horizontal: 0)])

        allowed = false
        clock.now = clock.now.advanced(by: .milliseconds(1))
        #expect(throws: ScrollDeliveryError.permissionDenied) {
            try sender.send(vertical: 0.25, horizontal: 0.25, amount: 1, generation: 1, observedAt: clock.now)
        }
        #expect(posted.count == 1)
        #expect(preflightCalls == 2)

        allowed = true
        clock.now = clock.now.advanced(by: .milliseconds(1))
        try sender.send(vertical: 0.25, horizontal: 0.25, amount: 1, generation: 1, observedAt: clock.now)
        #expect(posted == [.init(vertical: 1, horizontal: 0)])
        #expect(preflightCalls == 3)
    }

    @Test func postFailureDoesNotPermitSameReportToBePostedAgain() throws {
        var shouldFail = true
        var attempts = 0
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { _, _ in
                attempts += 1
                if shouldFail { throw FakePostError.failed }
            },
            now: { clock.now }
        )
        let observedAt = clock.now

        #expect(throws: FakePostError.self) {
            try sender.send(vertical: 1, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        }
        shouldFail = false
        #expect(throws: ScrollDeliveryError.staleTimestamp) {
            try sender.send(vertical: 1, horizontal: 0, amount: 1, generation: 1, observedAt: observedAt)
        }
        #expect(attempts == 1)
    }

    @Test func maximumSupportedNormalizedInputRemainsInInt32Range() throws {
        var posted = [PostedLines]()
        let clock = SenderTestClock()
        let sender = ScrollSender(
            preflight: { true },
            post: { posted.append(.init(vertical: $0, horizontal: $1)) },
            now: { clock.now }
        )

        try sender.send(
            vertical: 32_768,
            horizontal: -32_768,
            amount: 10,
            generation: 1,
            observedAt: clock.now
        )

        #expect(posted == [.init(vertical: 327_680, horizontal: -32_768)])
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

private enum FakePostError: Error {
    case failed
}
