import XCTest
@testable import HidhoggAutomation

final class NotificationOverlayTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testPreparedCandidateDoesNotChangeStoreUntilCommitted() throws {
        var store = NotificationOverlayStore()
        let prepared = try store.prepareEmit(
            topic: "battery.low",
            text: "Battery low",
            ttlSeconds: nil,
            subscriptions: ["battery.low": ["tile.battery"]],
            now: start
        )

        XCTAssertEqual(prepared.labelOverrides, ["tile.battery": "Battery low"])
        XCTAssertEqual(prepared.matchedCount, 1)
        XCTAssertTrue(store.labelOverrides(at: start).isEmpty)
        XCTAssertTrue(store.history().isEmpty)

        try store.commit(prepared, committedAt: start)

        XCTAssertEqual(store.labelOverrides(at: start), ["tile.battery": "Battery low"])
        XCTAssertEqual(store.history().count, 1)
        XCTAssertEqual(store.history().first?.outcome, "delivered")
        XCTAssertEqual(store.history().first?.controls, ["tile.battery"])
    }

    func testTopicFiltersMatchAcrossDotsAndDeduplicateControls() throws {
        var store = NotificationOverlayStore()
        let controls = ["tile.all", "tile.build", "tile.shared", "tile.exact"]
        let prepared = try store.prepareEmit(
            topic: "build.project.finished",
            text: "Built",
            ttlSeconds: nil,
            subscriptions: [
                "*": ["tile.all", "tile.shared"],
                "build.*": ["tile.build", "tile.shared"],
                "build.project.finished": ["tile.exact"]
            ],
            now: start
        )

        XCTAssertEqual(prepared.matchedCount, controls.count)
        XCTAssertEqual(Set(prepared.labelOverrides.keys), Set(controls))
        try store.commit(prepared, committedAt: start)

        let entry = try XCTUnwrap(store.history().first)
        XCTAssertEqual(entry.topic, "build.project.finished")
        XCTAssertEqual(entry.matchedCount, controls.count)
        XCTAssertEqual(Set(entry.controls), Set(controls))
    }

    func testRepeatedControlsAcrossMatchingFiltersCountOnce() throws {
        var store = NotificationOverlayStore()
        let repeatedControls = Array(repeating: "tile.shared", count: NotificationOverlayStore.maximumOverlayCount + 1)
        let prepared = try store.prepareEmit(
            topic: "status.ready",
            text: "Ready",
            ttlSeconds: nil,
            subscriptions: ["*": repeatedControls, "status.*": repeatedControls],
            now: start
        )

        XCTAssertEqual(prepared.matchedCount, 1)
        XCTAssertEqual(prepared.labelOverrides, ["tile.shared": "Ready"])
    }

    func testTTLStartsAtCommitAndExpiryRemovesOverlayAtBoundary() throws {
        var store = NotificationOverlayStore()
        let preparedAt = start
        let committedAt = start.addingTimeInterval(20)
        let prepared = try store.prepareEmit(
            topic: "status",
            text: "Ready",
            ttlSeconds: 10,
            subscriptions: ["status": ["tile.status"]],
            now: preparedAt
        )
        try store.commit(prepared, committedAt: committedAt)

        XCTAssertEqual(store.nextExpiration, committedAt.addingTimeInterval(10))
        XCTAssertNotNil(store.notificationID(for: "tile.status", at: committedAt.addingTimeInterval(9.9)))
        XCTAssertNil(store.notificationID(for: "tile.status", at: committedAt.addingTimeInterval(10)))

        let expiry = store.prepareExpiry(now: committedAt.addingTimeInterval(10))
        XCTAssertEqual(expiry.clearedCount, 1)
        XCTAssertTrue(expiry.labelOverrides.isEmpty)
        try store.commit(expiry, committedAt: committedAt.addingTimeInterval(10))
        XCTAssertTrue(store.labelOverrides(at: committedAt.addingTimeInterval(10)).isEmpty)
        XCTAssertNil(store.nextExpiration)
    }

    func testOverlayExpiringDuringSlowDisplayRemainsUntilExplicitExpiryCommit() throws {
        var store = NotificationOverlayStore()
        let first = try store.prepareEmit(
            topic: "first",
            text: "First",
            ttlSeconds: 5,
            subscriptions: ["first": ["tile.a"]],
            now: start
        )
        try store.commit(first, committedAt: start)

        let secondPreparedAt = start.addingTimeInterval(4)
        let second = try store.prepareEmit(
            topic: "second",
            text: "Second",
            ttlSeconds: nil,
            subscriptions: ["second": ["tile.b"]],
            now: secondPreparedAt
        )
        XCTAssertEqual(second.labelOverrides, ["tile.a": "First", "tile.b": "Second"])

        let slowCommitAt = start.addingTimeInterval(6)
        try store.commit(second, committedAt: slowCommitAt)

        XCTAssertEqual(store.nextExpiration, start.addingTimeInterval(5))
        XCTAssertNil(store.notificationID(for: "tile.a", at: slowCommitAt))

        let expiry = store.prepareExpiry(now: slowCommitAt)
        XCTAssertEqual(expiry.clearedCount, 1)
        XCTAssertEqual(expiry.labelOverrides, ["tile.b": "Second"])
        try store.commit(expiry, committedAt: slowCommitAt)

        XCTAssertNil(store.nextExpiration)
        XCTAssertEqual(store.labelOverrides(at: slowCommitAt), ["tile.b": "Second"])
    }

    func testStaleExpiryCannotRemoveReplacement() throws {
        var store = NotificationOverlayStore()
        let original = try store.prepareEmit(
            topic: "temporary",
            text: "Temporary",
            ttlSeconds: 1,
            subscriptions: ["temporary": ["tile"]],
            now: start
        )
        try store.commit(original, committedAt: start)

        let expiryTime = start.addingTimeInterval(1)
        let staleExpiry = store.prepareExpiry(now: expiryTime)
        let replacement = try store.prepareEmit(
            topic: "permanent",
            text: "Permanent",
            ttlSeconds: nil,
            subscriptions: ["permanent": ["tile"]],
            now: expiryTime
        )
        try store.commit(replacement, committedAt: expiryTime)
        XCTAssertThrowsError(try store.commit(staleExpiry, committedAt: expiryTime))

        XCTAssertEqual(store.labelOverrides(at: expiryTime), ["tile": "Permanent"])
        XCTAssertEqual(store.notificationID(for: "tile", at: expiryTime), replacement.notificationID)
    }

    func testReplacementWinsAndStaleClearCannotRemoveReplacement() throws {
        var store = NotificationOverlayStore()
        let first = try store.prepareEmit(
            topic: "first",
            text: "First",
            ttlSeconds: nil,
            subscriptions: ["first": ["tile"]],
            now: start
        )
        try store.commit(first, committedAt: start)
        let firstID = try XCTUnwrap(first.notificationID)

        let staleClear = store.prepareClear(notificationID: firstID, now: start.addingTimeInterval(1))
        let replacementTime = start.addingTimeInterval(2)
        let second = try store.prepareEmit(
            topic: "second",
            text: "Second",
            ttlSeconds: nil,
            subscriptions: ["second": ["tile"]],
            now: replacementTime
        )
        try store.commit(second, committedAt: replacementTime)
        XCTAssertThrowsError(try store.commit(staleClear, committedAt: replacementTime)) {
            XCTAssertEqual(
                $0 as? NotificationOverlayStoreError,
                .staleMutation(expectedRevision: staleClear.baseRevision, actualRevision: staleClear.baseRevision + 1)
            )
        }

        let repeatedClear = store.prepareClear(notificationID: firstID, now: replacementTime)
        XCTAssertEqual(repeatedClear.clearedCount, 0)
        try store.commit(repeatedClear, committedAt: replacementTime)
        XCTAssertEqual(store.labelOverrides(at: replacementTime), ["tile": "Second"])
        XCTAssertEqual(store.notificationID(for: "tile", at: replacementTime), second.notificationID)
    }

    func testClearRemovesEveryRemainingOverlayWithTheNotificationID() throws {
        var store = NotificationOverlayStore()
        let emitted = try store.prepareEmit(
            topic: "alert",
            text: "Alert",
            ttlSeconds: nil,
            subscriptions: ["alert": ["tile.a", "tile.b"]],
            now: start
        )
        try store.commit(emitted, committedAt: start)

        let clear = store.prepareClear(notificationID: try XCTUnwrap(emitted.notificationID), now: start)
        XCTAssertEqual(clear.clearedCount, 2)
        XCTAssertTrue(clear.labelOverrides.isEmpty)
        try store.commit(clear, committedAt: start)

        XCTAssertTrue(store.labelOverrides(at: start).isEmpty)
    }

    func testDismissUsesCapturedIDAndOnlyClearsSelectedControl() throws {
        var store = NotificationOverlayStore()
        let first = try store.prepareEmit(
            topic: "alert",
            text: "Alert",
            ttlSeconds: nil,
            subscriptions: ["alert": ["tile.a", "tile.b"]],
            now: start
        )
        try store.commit(first, committedAt: start)
        let firstID = try XCTUnwrap(first.notificationID)

        let replacementTime = start.addingTimeInterval(1)
        let replacement = try store.prepareEmit(
            topic: "replacement",
            text: "New alert",
            ttlSeconds: nil,
            subscriptions: ["replacement": ["tile.a"]],
            now: replacementTime
        )
        try store.commit(replacement, committedAt: replacementTime)

        let staleDismissal = store.prepareDismiss(
            control: "tile.a",
            capturedID: firstID,
            now: replacementTime
        )
        XCTAssertEqual(staleDismissal.clearedCount, 0)
        try store.commit(staleDismissal, committedAt: replacementTime)
        XCTAssertEqual(store.notificationID(for: "tile.a", at: replacementTime), replacement.notificationID)

        let dismissal = store.prepareDismiss(
            control: "tile.b",
            capturedID: firstID,
            now: replacementTime
        )
        XCTAssertEqual(dismissal.clearedCount, 1)
        try store.commit(dismissal, committedAt: replacementTime)
        XCTAssertNil(store.notificationID(for: "tile.b", at: replacementTime))
        XCTAssertEqual(store.notificationID(for: "tile.a", at: replacementTime), replacement.notificationID)
    }

    func testHistoryIsBoundedAndContainsOnlyNotificationMetadata() throws {
        var store = NotificationOverlayStore()
        for index in 0...NotificationOverlayStore.maximumHistoryCount {
            let emittedAt = start.addingTimeInterval(TimeInterval(index))
            let prepared = try store.prepareEmit(
                topic: "topic\(index)",
                text: "Payload \(index)",
                ttlSeconds: nil,
                subscriptions: ["topic\(index)": ["tile"]],
                now: emittedAt
            )
            try store.commit(prepared, committedAt: emittedAt)
        }

        let entries = store.history()
        XCTAssertEqual(entries.count, NotificationOverlayStore.maximumHistoryCount)
        XCTAssertEqual(entries.first?.topic, "topic1")
        XCTAssertEqual(entries.last?.matchedCount, 1)
        XCTAssertFalse(String(describing: entries).contains("Payload"))
    }

    func testHistoryEntriesUseUniqueEventIDsForTheSameNotification() {
        let notificationID = UUID()
        let delivered = NotificationHistoryEntry(
            notificationID: notificationID,
            topic: "alert",
            committedAt: start,
            expiresAt: nil,
            matchedCount: 1
        )
        let cleared = NotificationHistoryEntry(
            notificationID: notificationID,
            topic: "alert",
            committedAt: start.addingTimeInterval(1),
            expiresAt: nil,
            matchedCount: 1,
            outcome: "cleared",
            controls: ["tile.alert"]
        )

        XCTAssertEqual(delivered.notificationID, cleared.notificationID)
        XCTAssertNotEqual(delivered.id, cleared.id)
        XCTAssertEqual(delivered.outcome, "delivered")
        XCTAssertTrue(delivered.controls.isEmpty)
        XCTAssertEqual(cleared.outcome, "cleared")
        XCTAssertEqual(cleared.controls, ["tile.alert"])
    }

    func testNextExpirationSurvivesEvictionOfItsReceiptFromHistory() throws {
        var store = NotificationOverlayStore()
        let expiration = start.addingTimeInterval(500)
        let longLived = try store.prepareEmit(
            topic: "long",
            text: "Long lived",
            ttlSeconds: 500,
            subscriptions: ["long": ["tile.long"]],
            now: start
        )
        try store.commit(longLived, committedAt: start)

        for index in 0..<NotificationOverlayStore.maximumHistoryCount {
            let emittedAt = start.addingTimeInterval(TimeInterval(index + 1))
            let topic = "event\(index)"
            let event = try store.prepareEmit(
                topic: topic,
                text: "Event \(index)",
                ttlSeconds: nil,
                subscriptions: [topic: ["tile.audit"]],
                now: emittedAt
            )
            try store.commit(event, committedAt: emittedAt)
        }

        XCTAssertEqual(store.history().count, NotificationOverlayStore.maximumHistoryCount)
        XCTAssertFalse(store.history().contains { $0.topic == "long" })
        XCTAssertEqual(store.nextExpiration, expiration)
        XCTAssertEqual(
            store.notificationID(for: "tile.long", at: start.addingTimeInterval(100)),
            longLived.notificationID
        )
    }

    func testUnmatchedEmissionIsNotStoredOrReplayed() throws {
        var store = NotificationOverlayStore()
        let unmatched = try store.prepareEmit(
            topic: "unobserved",
            text: "No replay",
            ttlSeconds: nil,
            subscriptions: [:],
            now: start
        )
        XCTAssertEqual(unmatched.matchedCount, 0)
        XCTAssertNotNil(unmatched.notificationID)
        XCTAssertTrue(unmatched.labelOverrides.isEmpty)
        try store.commit(unmatched, committedAt: start)

        XCTAssertTrue(store.labelOverrides(at: start).isEmpty)
        XCTAssertTrue(store.history().isEmpty)

        let later = try store.prepareEmit(
            topic: "unobserved",
            text: "Current only",
            ttlSeconds: nil,
            subscriptions: ["unobserved": ["tile"]],
            now: start.addingTimeInterval(1)
        )
        XCTAssertEqual(later.labelOverrides, ["tile": "Current only"])
    }

    func testUnmatchedCommitPreservesExpiredRawOverlayUntilExpiryMutation() throws {
        var store = NotificationOverlayStore()
        let delivery = try store.prepareEmit(
            topic: "temporary",
            text: "Temporary",
            ttlSeconds: 1,
            subscriptions: ["temporary": ["tile"]],
            now: start
        )
        try store.commit(delivery, committedAt: start)

        let expiryTime = start.addingTimeInterval(1)
        let unmatched = try store.prepareEmit(
            topic: "unmatched",
            text: "No subscribers",
            ttlSeconds: nil,
            subscriptions: [:],
            now: expiryTime
        )
        XCTAssertEqual(unmatched.matchedCount, 0)
        XCTAssertTrue(unmatched.labelOverrides.isEmpty)
        try store.commit(unmatched, committedAt: expiryTime)

        XCTAssertEqual(store.nextExpiration, expiryTime)
        let expiry = store.prepareExpiry(now: expiryTime)
        XCTAssertEqual(expiry.clearedCount, 1)
        XCTAssertTrue(expiry.labelOverrides.isEmpty)
        try store.commit(expiry, committedAt: expiryTime)
        XCTAssertNil(store.nextExpiration)
    }

    func testExpiredClearAndDismissPreserveRawOverlayForExpiryMutation() throws {
        var store = NotificationOverlayStore()
        let delivery = try store.prepareEmit(
            topic: "temporary",
            text: "Temporary",
            ttlSeconds: 1,
            subscriptions: ["temporary": ["tile"]],
            now: start
        )
        try store.commit(delivery, committedAt: start)
        let notificationID = try XCTUnwrap(delivery.notificationID)
        let expiryTime = start.addingTimeInterval(1)

        let staleClear = store.prepareClear(notificationID: notificationID, now: expiryTime)
        XCTAssertEqual(staleClear.clearedCount, 0)
        XCTAssertTrue(staleClear.labelOverrides.isEmpty)
        try store.commit(staleClear, committedAt: expiryTime)
        XCTAssertEqual(store.nextExpiration, expiryTime)

        let staleDismissal = store.prepareDismiss(control: "tile", capturedID: notificationID, now: expiryTime)
        XCTAssertEqual(staleDismissal.clearedCount, 0)
        XCTAssertTrue(staleDismissal.labelOverrides.isEmpty)
        try store.commit(staleDismissal, committedAt: expiryTime)
        XCTAssertEqual(store.nextExpiration, expiryTime)

        let expiry = store.prepareExpiry(now: expiryTime)
        XCTAssertEqual(expiry.clearedCount, 1)
        XCTAssertTrue(expiry.labelOverrides.isEmpty)
        try store.commit(expiry, committedAt: expiryTime)
        XCTAssertNil(store.nextExpiration)
    }

    func testValidationRejectsInvalidTopicsTextLifetimeAndBounds() throws {
        var store = NotificationOverlayStore()

        for topic in ["", "-invalid", "café", "build.*", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try store.prepareEmit(
                topic: topic,
                text: "Valid",
                ttlSeconds: nil,
                subscriptions: [:],
                now: start
            )) { XCTAssertEqual($0 as? NotificationOverlayStoreError, .invalidTopic) }
        }

        let invalidTexts: [(String, NotificationOverlayStoreError)] = [
            (" \t", .blankText),
            ("first\nsecond", .multilineText),
            ("bad\ttext", .textContainsControlCharacter),
            ("before\u{202E}after", .textContainsDirectionalCharacter),
            (String(repeating: "a", count: 65), .textTooLongByCharacters),
            (String(repeating: "🇦🇺", count: 40), .textTooLongByUTF8Bytes)
        ]
        for (text, expectedError) in invalidTexts {
            XCTAssertThrowsError(try store.prepareEmit(
                topic: "valid",
                text: text,
                ttlSeconds: nil,
                subscriptions: [:],
                now: start
            )) { XCTAssertEqual($0 as? NotificationOverlayStoreError, expectedError) }
        }

        for ttl in [0, 86_401] {
            XCTAssertThrowsError(try store.prepareEmit(
                topic: "valid",
                text: "Valid",
                ttlSeconds: ttl,
                subscriptions: [:],
                now: start
            )) { XCTAssertEqual($0 as? NotificationOverlayStoreError, .invalidTTL) }
        }

        let maximumControls = (0..<NotificationOverlayStore.maximumOverlayCount).map { "tile\($0)" }
        let atCapacity = try store.prepareEmit(
            topic: "valid",
            text: "Valid",
            ttlSeconds: nil,
            subscriptions: ["valid": maximumControls],
            now: start
        )
        XCTAssertEqual(atCapacity.matchedCount, NotificationOverlayStore.maximumOverlayCount)
        try store.commit(atCapacity, committedAt: start)

        XCTAssertThrowsError(try store.prepareEmit(
            topic: "valid",
            text: "Valid",
            ttlSeconds: nil,
            subscriptions: ["valid": ["tile.extra"]],
            now: start.addingTimeInterval(1)
        )) { XCTAssertEqual($0 as? NotificationOverlayStoreError, .tooManyOverlays) }

        XCTAssertThrowsError(try store.prepareEmit(
            topic: "valid",
            text: "Valid",
            ttlSeconds: nil,
            subscriptions: ["valid": (0...NotificationOverlayStore.maximumOverlayCount).map { "tile\($0)" }],
            now: start.addingTimeInterval(1)
        )) { XCTAssertEqual($0 as? NotificationOverlayStoreError, .tooManySubscribedControls) }
    }

    func testResetClearsOverlaysPreservesHistoryAndInvalidatesPreparedMutations() throws {
        var store = NotificationOverlayStore()
        let prepared = try store.prepareEmit(
            topic: "status",
            text: "Ready",
            ttlSeconds: nil,
            subscriptions: ["status": ["tile"]],
            now: start
        )
        try store.commit(prepared, committedAt: start)
        let pending = store.prepareClear(notificationID: try XCTUnwrap(prepared.notificationID), now: start)

        store.reset(now: start.addingTimeInterval(1))

        XCTAssertTrue(store.labelOverrides(at: start).isEmpty)
        XCTAssertEqual(store.history().count, 1)
        XCTAssertEqual(store.history().first?.topic, "status")
        XCTAssertFalse(String(describing: store.history()).contains("Ready"))
        XCTAssertThrowsError(try store.commit(pending, committedAt: start.addingTimeInterval(1)))
    }
}
