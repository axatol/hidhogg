public struct BoltNativeInputDiagnostics: Equatable, Sendable {
    public private(set) var available: Bool
    public private(set) var callbacks: Int
    public private(set) var callbackErrors: Int
    public private(set) var metadataRejected: Int
    public private(set) var reportIDMismatch: Int
    public private(set) var registerReplies: Int
    public private(set) var featureReplies: Int
    public private(set) var receiverNotifications: Int
    public private(set) var unmatchedReports: Int

    public init(available: Bool = false, callbacks: Int = 0, callbackErrors: Int = 0,
                metadataRejected: Int = 0, reportIDMismatch: Int = 0,
                registerReplies: Int = 0, featureReplies: Int = 0,
                receiverNotifications: Int = 0, unmatchedReports: Int = 0) {
        self.available = available
        self.callbacks = max(0, callbacks)
        self.callbackErrors = max(0, callbackErrors)
        self.metadataRejected = max(0, metadataRejected)
        self.reportIDMismatch = max(0, reportIDMismatch)
        self.registerReplies = max(0, registerReplies)
        self.featureReplies = max(0, featureReplies)
        self.receiverNotifications = max(0, receiverNotifications)
        self.unmatchedReports = max(0, unmatchedReports)
    }

    mutating func recordCallback() {
        Self.increment(&callbacks)
    }

    mutating func merge(_ snapshot: Self) {
        available = available || snapshot.available
        callbacks = max(callbacks, snapshot.callbacks)
        callbackErrors = max(callbackErrors, snapshot.callbackErrors)
        metadataRejected = max(metadataRejected, snapshot.metadataRejected)
        reportIDMismatch = max(reportIDMismatch, snapshot.reportIDMismatch)
        registerReplies = max(registerReplies, snapshot.registerReplies)
        featureReplies = max(featureReplies, snapshot.featureReplies)
        receiverNotifications = max(receiverNotifications, snapshot.receiverNotifications)
        unmatchedReports = max(unmatchedReports, snapshot.unmatchedReports)
    }

    mutating func record(_ disposition: BoltNativeInputDisposition) {
        switch disposition {
        case .callbackError: Self.increment(&callbackErrors)
        case .metadataRejected: Self.increment(&metadataRejected)
        case .reportIDMismatch: Self.increment(&reportIDMismatch)
        case .registerReply: Self.increment(&registerReplies)
        case .featureReply: Self.increment(&featureReplies)
        case .receiverNotification: Self.increment(&receiverNotifications)
        case .unmatchedReport: Self.increment(&unmatchedReports)
        }
    }

    private static func increment(_ count: inout Int) {
        guard count < Int.max else { return }
        count += 1
    }
}

enum BoltNativeInputDisposition {
    case callbackError
    case metadataRejected
    case reportIDMismatch
    case registerReply
    case featureReply
    case receiverNotification
    case unmatchedReport
}
