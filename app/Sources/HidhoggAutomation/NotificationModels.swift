import Foundation

public struct NotificationHistoryEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let notificationID: UUID
    public let topic: String
    public let committedAt: Date
    public let expiresAt: Date?
    public let matchedCount: Int
    public let outcome: String
    public let controls: [String]
    public let profile: String?

    public init(
        id: UUID = UUID(),
        notificationID: UUID,
        topic: String,
        committedAt: Date,
        expiresAt: Date?,
        matchedCount: Int,
        outcome: String = "delivered",
        controls: [String] = [],
        profile: String? = nil
    ) {
        self.id = id
        self.notificationID = notificationID
        self.topic = topic
        self.committedAt = committedAt
        self.expiresAt = expiresAt
        self.matchedCount = matchedCount
        self.outcome = outcome
        self.controls = controls
        self.profile = profile
    }
}

public struct PreparedNotificationMutation: Sendable {
    public let labelOverrides: [String: String]
    public let notificationID: UUID?
    public let matchedCount: Int
    public let clearedCount: Int
    public let baseRevision: UInt64

    let storeID: UUID
    let preparedAt: Date
    let candidate: NotificationOverlayCandidate

    init(
        labelOverrides: [String: String],
        notificationID: UUID?,
        matchedCount: Int,
        clearedCount: Int,
        baseRevision: UInt64,
        storeID: UUID,
        preparedAt: Date,
        candidate: NotificationOverlayCandidate
    ) {
        self.labelOverrides = labelOverrides
        self.notificationID = notificationID
        self.matchedCount = matchedCount
        self.clearedCount = clearedCount
        self.baseRevision = baseRevision
        self.storeID = storeID
        self.preparedAt = preparedAt
        self.candidate = candidate
    }
}

struct NotificationOverlay: Sendable {
    let notificationID: UUID
    let text: String
    let expiresAt: Date?
}

struct PendingNotificationEmission: Sendable {
    let notificationID: UUID
    let topic: String
    let text: String
    let targetControls: [String]
    let ttlSeconds: Int?
}

struct NotificationOverlayCandidate: Sendable {
    let overlays: [String: NotificationOverlay]
    let history: [NotificationHistoryEntry]
    let pendingEmission: PendingNotificationEmission?
}

public enum NotificationOverlayStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidTopic
    case blankText
    case multilineText
    case textTooLongByCharacters
    case textTooLongByUTF8Bytes
    case textContainsControlCharacter
    case textContainsDirectionalCharacter
    case invalidTTL
    case tooManySubscribedControls
    case invalidControlKey
    case tooManyOverlays
    case mutationBelongsToAnotherStore
    case staleMutation(expectedRevision: UInt64, actualRevision: UInt64)
    case commitBeforePreparation

    public var errorDescription: String? {
        switch self {
        case .invalidTopic:
            "The notification topic must use 1–64 ASCII letters, digits, dots, underscores, or hyphens and start with a letter or digit."
        case .blankText:
            "Notification text must not be blank."
        case .multilineText:
            "Notification text must contain one line."
        case .textTooLongByCharacters:
            "Notification text must contain at most 64 characters."
        case .textTooLongByUTF8Bytes:
            "Notification text must contain at most 256 UTF-8 bytes."
        case .textContainsControlCharacter:
            "Notification text must not contain control characters."
        case .textContainsDirectionalCharacter:
            "Notification text must not contain bidirectional formatting characters."
        case .invalidTTL:
            "Notification lifetime must be between 1 and 86400 seconds."
        case .tooManySubscribedControls:
            "A notification may match at most 14 controls."
        case .invalidControlKey:
            "A control key must contain 1–128 UTF-8 bytes."
        case .tooManyOverlays:
            "The notification store may contain at most 14 overlays."
        case .mutationBelongsToAnotherStore:
            "The prepared notification mutation belongs to another store."
        case let .staleMutation(expectedRevision, actualRevision):
            "The prepared notification mutation is stale (base revision \(expectedRevision), current revision \(actualRevision))."
        case .commitBeforePreparation:
            "A notification mutation cannot be committed before it was prepared."
        }
    }
}
