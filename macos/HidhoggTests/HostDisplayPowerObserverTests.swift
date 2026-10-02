import Foundation
import XCTest
@testable import Hidhogg

@MainActor
final class HostDisplayPowerObserverTests: XCTestCase {
    func testDisplayAggregationTreatsEmptyAndAllSleepingListsAsDark() {
        XCTAssertFalse(CoreGraphicsHostDisplayPowerQuery.displayAwake(displaySleepStates: []))
        XCTAssertFalse(CoreGraphicsHostDisplayPowerQuery.displayAwake(displaySleepStates: [true, true]))
        XCTAssertTrue(CoreGraphicsHostDisplayPowerQuery.displayAwake(displaySleepStates: [true, false]))
    }

    func testWorkspaceTransitionPrecedesAStaleInitialQuery() {
        let source = FakeHostDisplayPowerEventSource(queryResults: [.success(true)])
        source.transitionDuringObservation = .sleep
        let observer = HostDisplayPowerObserver(source: source)
        var received: [Bool] = []

        observer.start(
            stateHandler: { received.append($0) },
            errorHandler: { _ in }
        )

        XCTAssertEqual(received, [false])
        XCTAssertEqual(source.queryCount, 0)

        source.emitWake()
        XCTAssertEqual(received, [false, true])
        XCTAssertEqual(source.queryCount, 0)
        observer.stop()
    }

    func testQueryFailureRemainsUnknownAndCanBeReconciledLater() {
        let source = FakeHostDisplayPowerEventSource(queryResults: [
            .failure(.activeDisplayCount(code: 5)),
            .success(false)
        ])
        let observer = HostDisplayPowerObserver(source: source)
        var received: [Bool] = []
        var errors: [String?] = []

        observer.start(
            stateHandler: { received.append($0) },
            errorHandler: { errors.append($0) }
        )

        XCTAssertNil(observer.lastKnownDisplayAwake)
        XCTAssertEqual(received, [])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0]?.contains("Core Graphics error 5") == true)

        observer.reconcileIfUnknown()

        XCTAssertEqual(observer.lastKnownDisplayAwake, false)
        XCTAssertEqual(received, [false])
        XCTAssertEqual(errors.count, 2)
        XCTAssertNil(errors[1])
        observer.stop()
    }

    func testDuplicateTransitionDoesNotEmitRedundantStateOrErrorCallback() {
        let source = FakeHostDisplayPowerEventSource(queryResults: [.success(true)])
        let observer = HostDisplayPowerObserver(source: source)
        var received: [Bool] = []
        var errors: [String?] = []

        observer.start(
            stateHandler: { received.append($0) },
            errorHandler: { errors.append($0) }
        )
        source.emitWake()

        XCTAssertEqual(received, [true])
        XCTAssertEqual(errors.count, 1)
        XCTAssertNil(errors[0])
        observer.stop()
    }

    func testRestartRequeriesInsteadOfKeepingAStaleObserverState() {
        let source = FakeHostDisplayPowerEventSource(queryResults: [
            .success(true),
            .success(false)
        ])
        let observer = HostDisplayPowerObserver(source: source)
        var received: [Bool] = []
        let handler: HostDisplayPowerStateHandler = { received.append($0) }
        let errorHandler: HostDisplayPowerErrorHandler = { _ in }

        observer.start(stateHandler: handler, errorHandler: errorHandler)
        observer.stop()
        observer.start(stateHandler: handler, errorHandler: errorHandler)

        XCTAssertEqual(received, [true, false])
        XCTAssertEqual(source.queryCount, 2)
        observer.stop()
    }
}

@MainActor
private final class FakeHostDisplayPowerEventSource: HostDisplayPowerEventSource {
    enum TransitionDuringObservation {
        case sleep
        case wake
    }

    private var queryResults: [Result<Bool, HostDisplayPowerQueryError>]
    private var onSleep: HostDisplayPowerTransitionHandler?
    private var onWake: HostDisplayPowerTransitionHandler?
    var queryCount = 0
    var transitionDuringObservation: TransitionDuringObservation?

    init(queryResults: [Result<Bool, HostDisplayPowerQueryError>]) {
        self.queryResults = queryResults
    }

    func currentDisplayAwake() throws -> Bool {
        queryCount += 1
        guard !queryResults.isEmpty else {
            throw HostDisplayPowerQueryError.activeDisplayCount(code: -1)
        }
        return try queryResults.removeFirst().get()
    }

    func observePowerChanges(
        onSleep: @escaping HostDisplayPowerTransitionHandler,
        onWake: @escaping HostDisplayPowerTransitionHandler
    ) -> any HostDisplayPowerEventObservation {
        self.onSleep = onSleep
        self.onWake = onWake
        switch transitionDuringObservation {
        case .sleep:
            onSleep()
        case .wake:
            onWake()
        case nil:
            break
        }
        return FakeHostDisplayPowerEventObservation { [weak self] in
            self?.onSleep = nil
            self?.onWake = nil
        }
    }

    func emitSleep() {
        onSleep?()
    }

    func emitWake() {
        onWake?()
    }
}

@MainActor
private final class FakeHostDisplayPowerEventObservation: HostDisplayPowerEventObservation {
    private let cancellation: @MainActor () -> Void
    private var isCancelled = false

    init(cancellation: @escaping @MainActor () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancellation()
    }
}
