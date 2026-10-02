import Foundation
import XCTest
@testable import Hidhogg

@MainActor
final class ForegroundApplicationObserverTests: XCTestCase {
    func testStartSeedsFrontmostApplicationBeforeLaterActivations() {
        let source = TestForegroundApplicationEventSource(initialBundleIdentifier: "com.example.initial")
        let observer = ForegroundApplicationObserver(source: source)
        var observed: [String?] = []

        observer.start { observed.append($0) }
        source.emit("com.example.next")

        XCTAssertEqual(observed, ["com.example.initial", "com.example.next"])
        XCTAssertEqual(source.observeCount, 1)
    }

    func testNilAndEmptyBundleIdentifiersAreIgnored() {
        let source = TestForegroundApplicationEventSource(initialBundleIdentifier: nil)
        let observer = ForegroundApplicationObserver(source: source)
        var observed: [String?] = []

        observer.start { observed.append($0) }
        source.emit(nil)
        source.emit("")
        source.emit("com.example.valid")

        XCTAssertEqual(observed, ["com.example.valid"])
    }

    func testRepeatedActivationEventsRemainObservableForCoordinatorPolicy() {
        let source = TestForegroundApplicationEventSource(initialBundleIdentifier: "com.example.app")
        let observer = ForegroundApplicationObserver(source: source)
        var observed: [String?] = []

        observer.start { observed.append($0) }
        source.emit("com.example.app")
        source.emit("com.example.app")

        XCTAssertEqual(
            observed,
            ["com.example.app", "com.example.app", "com.example.app"]
        )
    }

    func testRestartCancelsPreviousSubscriptionAndSeedsAgain() {
        let source = TestForegroundApplicationEventSource(initialBundleIdentifier: "com.example.first")
        let observer = ForegroundApplicationObserver(source: source)
        var firstObserved: [String?] = []
        var secondObserved: [String?] = []

        observer.start { firstObserved.append($0) }
        observer.start { secondObserved.append($0) }
        source.emit("com.example.second")

        XCTAssertEqual(firstObserved, ["com.example.first"])
        XCTAssertEqual(secondObserved, ["com.example.first", "com.example.second"])
        XCTAssertEqual(source.observeCount, 2)
        XCTAssertEqual(source.cancelCount, 1)
    }

    func testStopCancelsSubscriptionAndPreventsFurtherEvents() {
        let source = TestForegroundApplicationEventSource(initialBundleIdentifier: "com.example.app")
        let observer = ForegroundApplicationObserver(source: source)
        var observed: [String?] = []

        observer.start { observed.append($0) }
        observer.stop()
        source.emit("com.example.other")

        XCTAssertEqual(observed, ["com.example.app"])
        XCTAssertEqual(source.cancelCount, 1)
    }

    func testQueuedActivationFromPreviousStartIsDroppedAfterRestart() {
        let source = TestForegroundApplicationEventSource(initialBundleIdentifier: "com.example.first")
        let observer = ForegroundApplicationObserver(source: source)
        var firstObserved: [String?] = []
        var secondObserved: [String?] = []

        observer.start { firstObserved.append($0) }
        source.queue("com.example.stale")
        observer.start { secondObserved.append($0) }
        source.deliverQueued()
        source.emit("com.example.second")

        XCTAssertEqual(firstObserved, ["com.example.first"])
        XCTAssertEqual(
            secondObserved,
            ["com.example.first", "com.example.second"]
        )
    }

    func testQueuedActivationIsDroppedAfterStop() {
        let source = TestForegroundApplicationEventSource(initialBundleIdentifier: "com.example.app")
        let observer = ForegroundApplicationObserver(source: source)
        var observed: [String?] = []

        observer.start { observed.append($0) }
        source.queue("com.example.stale")
        observer.stop()
        source.deliverQueued()

        XCTAssertEqual(observed, ["com.example.app"])
    }
}

@MainActor
private final class TestForegroundApplicationEventSource: ForegroundApplicationEventSource {
    private(set) var observeCount = 0
    private(set) var cancelCount = 0
    private var initialBundleIdentifier: String?
    private var handler: ForegroundApplicationHandler?
    private var queuedEvents: [() -> Void] = []

    init(initialBundleIdentifier: String?) {
        self.initialBundleIdentifier = initialBundleIdentifier
    }

    func frontmostBundleIdentifier() -> String? {
        initialBundleIdentifier
    }

    func observeActivations(
        _ handler: @escaping ForegroundApplicationHandler
    ) -> any ForegroundApplicationObservation {
        observeCount += 1
        self.handler = handler
        return TestForegroundApplicationObservation { [weak self] in
            self?.handler = nil
            self?.cancelCount += 1
        }
    }

    func emit(_ bundleIdentifier: String?) {
        handler?(bundleIdentifier)
    }

    func queue(_ bundleIdentifier: String?) {
        guard let handler else { return }
        queuedEvents.append { handler(bundleIdentifier) }
    }

    func deliverQueued() {
        let queuedEvents = queuedEvents
        self.queuedEvents.removeAll()
        queuedEvents.forEach { $0() }
    }
}

@MainActor
private final class TestForegroundApplicationObservation: ForegroundApplicationObservation {
    private let onCancel: @MainActor () -> Void
    private var isCancelled = false

    init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel()
    }
}
