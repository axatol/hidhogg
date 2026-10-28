import Foundation
import HidhoggDomain

public struct NotificationOverlayStore: Sendable {
    public static let maximumOverlayCount = 14
    public static let maximumHistoryCount = 100

    private static let maximumTextCharacterCount = 64
    private static let maximumTextUTF8ByteCount = 256
    private static let maximumControlKeyUTF8ByteCount = 128

    private let id: UUID
    private var revision: UInt64
    private var overlays: [String: NotificationOverlay]
    private var historyEntries: [NotificationHistoryEntry]

    public init() {
        id = UUID()
        revision = 0
        overlays = [:]
        historyEntries = []
    }

    public func prepareEmit(
        topic: String,
        text: String? = nil,
        appID: String? = nil,
        ttlSeconds: Int?,
        subscriptions: [String: [String]],
        now: Date
    ) throws -> PreparedNotificationMutation {
        try Self.validate(topic: topic, text: text, appID: appID, ttlSeconds: ttlSeconds)

        var seenControls = Set<String>()
        var controls = [String]()
        for filter in subscriptions.keys.sorted() where NotificationTopic.matches(topic, filter: filter) {
            for control in subscriptions[filter] ?? [] {
                guard !control.isEmpty, control.utf8.count <= Self.maximumControlKeyUTF8ByteCount else {
                    throw NotificationOverlayStoreError.invalidControlKey
                }
                guard seenControls.insert(control).inserted else { continue }
                guard controls.count < Self.maximumOverlayCount else {
                    throw NotificationOverlayStoreError.tooManySubscribedControls
                }
                controls.append(control)
            }
        }

        var candidateOverlays = overlays
        let notificationID = nextNotificationID()
        let pendingEmission: PendingNotificationEmission?

        if controls.isEmpty {
            pendingEmission = nil
        } else {
            guard Set(candidateOverlays.keys).union(controls).count <= Self.maximumOverlayCount else {
                throw NotificationOverlayStoreError.tooManyOverlays
            }

            pendingEmission = PendingNotificationEmission(
                notificationID: notificationID,
                topic: topic,
                text: text,
                appID: appID,
                targetControls: controls,
                ttlSeconds: ttlSeconds
            )
            for control in controls {
                candidateOverlays[control] = NotificationOverlay(
                    notificationID: notificationID,
                    text: text,
                    appID: appID,
                    expiresAt: nil
                )
            }
        }

        let candidate = NotificationOverlayCandidate(
            overlays: candidateOverlays,
            history: historyEntries,
            pendingEmission: pendingEmission
        )
        return preparedMutation(
            candidate: candidate,
            notificationID: notificationID,
            matchedCount: controls.count,
            clearedCount: 0,
            at: now
        )
    }

    public func prepareClear(notificationID: UUID, now: Date) -> PreparedNotificationMutation {
        var candidateOverlays = overlays
        let controlsToClear = candidateOverlays.compactMap { control, overlay in
            overlay.notificationID == notificationID && Self.isActive(overlay, at: now) ? control : nil
        }
        for control in controlsToClear {
            candidateOverlays.removeValue(forKey: control)
        }

        return preparedMutation(
            candidate: NotificationOverlayCandidate(
                overlays: candidateOverlays,
                history: historyEntries,
                pendingEmission: nil
            ),
            notificationID: nil,
            matchedCount: 0,
            clearedCount: controlsToClear.count,
            at: now
        )
    }

    public func prepareClearAll(now: Date) -> PreparedNotificationMutation {
        preparedMutation(candidate: NotificationOverlayCandidate(overlays: [:], history: historyEntries,
            pendingEmission: nil), notificationID: nil, matchedCount: 0, clearedCount: overlays.count, at: now)
    }

    public func prepareDismiss(
        control: String,
        capturedID: UUID?,
        now: Date
    ) -> PreparedNotificationMutation {
        var candidateOverlays = overlays
        let shouldClear: Bool
        if let capturedID, let overlay = candidateOverlays[control] {
            shouldClear = overlay.notificationID == capturedID && Self.isActive(overlay, at: now)
        } else {
            shouldClear = false
        }
        if shouldClear {
            candidateOverlays.removeValue(forKey: control)
        }

        return preparedMutation(
            candidate: NotificationOverlayCandidate(
                overlays: candidateOverlays,
                history: historyEntries,
                pendingEmission: nil
            ),
            notificationID: nil,
            matchedCount: 0,
            clearedCount: shouldClear ? 1 : 0,
            at: now
        )
    }

    public func prepareExpiry(now: Date) -> PreparedNotificationMutation {
        var candidateOverlays = overlays
        let expiredControls = candidateOverlays.compactMap { control, overlay in
            overlay.expiresAt.map { $0 <= now } == true ? control : nil
        }
        for control in expiredControls {
            candidateOverlays.removeValue(forKey: control)
        }

        return preparedMutation(
            candidate: NotificationOverlayCandidate(
                overlays: candidateOverlays,
                history: historyEntries,
                pendingEmission: nil
            ),
            notificationID: nil,
            matchedCount: 0,
            clearedCount: expiredControls.count,
            at: now
        )
    }

    public mutating func commit(_ mutation: PreparedNotificationMutation, committedAt: Date) throws {
        guard mutation.storeID == id else {
            throw NotificationOverlayStoreError.mutationBelongsToAnotherStore
        }
        guard mutation.baseRevision == revision else {
            throw NotificationOverlayStoreError.staleMutation(
                expectedRevision: mutation.baseRevision,
                actualRevision: revision
            )
        }
        guard committedAt >= mutation.preparedAt else {
            throw NotificationOverlayStoreError.commitBeforePreparation
        }

        var committedOverlays = mutation.candidate.overlays
        var committedHistory = mutation.candidate.history

        if let pendingEmission = mutation.candidate.pendingEmission {
            let expiresAt = pendingEmission.ttlSeconds.map {
                committedAt.addingTimeInterval(TimeInterval($0))
            }
            for control in pendingEmission.targetControls {
                committedOverlays[control] = NotificationOverlay(
                    notificationID: pendingEmission.notificationID,
                    text: pendingEmission.text,
                    appID: pendingEmission.appID,
                    expiresAt: expiresAt
                )
            }

            if !pendingEmission.targetControls.isEmpty {
                if committedHistory.count == Self.maximumHistoryCount {
                    committedHistory.removeFirst()
                }
                committedHistory.append(NotificationHistoryEntry(
                    notificationID: pendingEmission.notificationID,
                    topic: pendingEmission.topic,
                    appID: pendingEmission.appID,
                    committedAt: committedAt,
                    expiresAt: expiresAt,
                    matchedCount: pendingEmission.targetControls.count,
                    controls: pendingEmission.targetControls
                ))
            }
        }

        guard committedOverlays.count <= Self.maximumOverlayCount else {
            throw NotificationOverlayStoreError.tooManyOverlays
        }

        overlays = committedOverlays
        historyEntries = committedHistory
        revision &+= 1
    }

    public func labelOverrides(at date: Date) -> [String: String] {
        Self.labelOverrides(in: overlays, at: date)
    }

    public func notificationAppIDs(at date: Date) -> [String: String] {
        Self.notificationAppIDs(in: overlays, at: date)
    }

    public func notificationID(for control: String, at date: Date) -> UUID? {
        guard let overlay = overlays[control], Self.isActive(overlay, at: date) else { return nil }
        return overlay.notificationID
    }

    public func history() -> [NotificationHistoryEntry] {
        historyEntries
    }

    public var nextExpiration: Date? {
        overlays.values.compactMap(\.expiresAt).min()
    }

    public mutating func reset(now _: Date) {
        overlays.removeAll(keepingCapacity: false)
        revision &+= 1
    }

    private func preparedMutation(
        candidate: NotificationOverlayCandidate,
        notificationID: UUID?,
        matchedCount: Int,
        clearedCount: Int,
        at date: Date
    ) -> PreparedNotificationMutation {
        PreparedNotificationMutation(
            labelOverrides: Self.labelOverrides(in: candidate.overlays, at: date),
            notificationAppIDs: Self.notificationAppIDs(in: candidate.overlays, at: date),
            notificationID: notificationID,
            matchedCount: matchedCount,
            clearedCount: clearedCount,
            baseRevision: revision,
            storeID: id,
            preparedAt: date,
            candidate: candidate
        )
    }

    private func nextNotificationID() -> UUID {
        var candidate = UUID()
        let activeIDs = Set(overlays.values.map(\.notificationID))
        let historicalIDs = Set(historyEntries.map(\.notificationID))
        while activeIDs.contains(candidate) || historicalIDs.contains(candidate) {
            candidate = UUID()
        }
        return candidate
    }

    private static func validate(topic: String, text: String?, appID: String?, ttlSeconds: Int?) throws {
        guard NotificationTopic.isValidTopic(topic) else { throw NotificationOverlayStoreError.invalidTopic }
        guard text != nil || appID != nil else { throw NotificationOverlayStoreError.missingContent }
        if let text { try validate(text: text) }
        if let appID, !NativeAction.isValidBundleIdentifier(appID) {
            throw NotificationOverlayStoreError.invalidAppID
        }
        if let ttlSeconds, !(1...86_400).contains(ttlSeconds) {
            throw NotificationOverlayStoreError.invalidTTL
        }
    }

    private static func validate(text: String) throws {
        guard text.utf8.count <= maximumTextUTF8ByteCount else {
            throw NotificationOverlayStoreError.textTooLongByUTF8Bytes
        }
        guard text.count <= maximumTextCharacterCount else {
            throw NotificationOverlayStoreError.textTooLongByCharacters
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotificationOverlayStoreError.blankText
        }

        for scalar in text.unicodeScalars {
            if isLineBreak(scalar) {
                throw NotificationOverlayStoreError.multilineText
            }
            if scalar.properties.generalCategory == .control {
                throw NotificationOverlayStoreError.textContainsControlCharacter
            }
            if isDirectionalControl(scalar) {
                throw NotificationOverlayStoreError.textContainsDirectionalCharacter
            }
        }
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
            true
        default:
            false
        }
    }

    private static func isDirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x206F:
            true
        default:
            false
        }
    }

    private static func labelOverrides(in overlays: [String: NotificationOverlay], at date: Date) -> [String: String] {
        overlays.compactMapValues { overlay in
            isActive(overlay, at: date) ? overlay.displayLabel : nil
        }
    }

    private static func notificationAppIDs(in overlays: [String: NotificationOverlay], at date: Date) -> [String: String] {
        overlays.compactMapValues { overlay in
            guard isActive(overlay, at: date) else { return nil }
            return overlay.appID
        }
    }

    private static func isActive(_ overlay: NotificationOverlay, at date: Date) -> Bool {
        overlay.expiresAt.map { $0 > date } ?? true
    }
}
