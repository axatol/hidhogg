import Combine
import Foundation
import UserNotifications

enum LowBatteryNotificationAuthorizationState: Equatable, Sendable {
    case unknown
    case notDetermined
    case denied
    case authorized
    case provisional

    var allowsAlerts: Bool {
        self == .authorized || self == .provisional
    }

    var title: String {
        switch self {
        case .unknown: "Authorization status unknown"
        case .notDetermined: "Permission not requested"
        case .denied: "Notifications disabled"
        case .authorized: "Notifications allowed"
        case .provisional: "Notifications allowed quietly"
        }
    }
}

struct LowBatteryNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}

@MainActor
protocol LowBatteryNotificationCenterAdapter {
    func authorizationStatus() async -> LowBatteryNotificationAuthorizationState
    func requestAlertAuthorization() async throws -> Bool
    func enqueue(_ request: LowBatteryNotificationRequest) async throws
    func removePendingRequest(identifier: String)
}

@MainActor
protocol LowBatteryAlertLatchStore {
    var isLatched: Bool { get }
    func setLatched(_ value: Bool)
}

@MainActor
final class UserDefaultsLowBatteryAlertLatchStore: LowBatteryAlertLatchStore {
    private static let key = "com.hidhogg.app.low-battery-alert-latched.logitech.mx-master-3s"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isLatched: Bool { defaults.bool(forKey: Self.key) }

    func setLatched(_ value: Bool) {
        defaults.set(value, forKey: Self.key)
    }
}

enum LowBatteryAlertPolicy {
    static let alertBelowPercentage = 10
    static let rearmAtPercentage = 20

    static func shouldRearm(percentage: Int?, isFresh: Bool) -> Bool {
        guard isFresh, let percentage, (0...100).contains(percentage) else { return false }
        return percentage >= rearmAtPercentage
    }

    static func isFreshLowBatteryReading(percentage: Int?, charging: Bool?, isFresh: Bool) -> Bool {
        guard isFresh, charging == false, let percentage else { return false }
        return (0..<alertBelowPercentage).contains(percentage)
    }

    static func shouldAlert(
        percentage: Int?,
        charging: Bool?,
        isFresh: Bool,
        isEnabled: Bool,
        authorizationState: LowBatteryNotificationAuthorizationState,
        isLatched: Bool
    ) -> Bool {
        guard isEnabled, isFresh, charging == false,
              isFreshLowBatteryReading(percentage: percentage, charging: charging, isFresh: isFresh),
              authorizationState.allowsAlerts, !isLatched else {
            return false
        }
        return true
    }
}

@MainActor
final class LowBatteryNotificationController: ObservableObject {
    static let notificationIdentifier = "hidhogg.low-battery.logitech.mx-master-3s"

    @Published private(set) var isEnabled = false
    @Published private(set) var authorizationState: LowBatteryNotificationAuthorizationState = .unknown
    @Published private(set) var authorizationError: String?
    @Published private(set) var notificationError: String?

    private let notificationCenter: any LowBatteryNotificationCenterAdapter
    private let latchStore: any LowBatteryAlertLatchStore
    private var preferenceGeneration = 0
    private var isRefreshingAuthorization = false
    private var isRequestingAuthorization = false
    private var isEnqueueing = false
    private var isCurrentEnqueueInvalidated = false
    private var latestObservationIsEligibleLow = false
    private var latestEligibleLowPercentage: Int?

    init(
        notificationCenter: (any LowBatteryNotificationCenterAdapter)? = nil,
        latchStore: (any LowBatteryAlertLatchStore)? = nil
    ) {
        self.notificationCenter = notificationCenter ?? SystemLowBatteryNotificationCenterAdapter()
        self.latchStore = latchStore ?? UserDefaultsLowBatteryAlertLatchStore()
    }

    var statusTitle: String { authorizationState.title }
    var error: String? {
        let messages = [authorizationError, notificationError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func synchronizeEnabled(_ enabled: Bool) {
        guard enabled else {
            if isEnabled { preferenceGeneration += 1 }
            isEnabled = false
            invalidateCurrentEnqueue()
            notificationCenter.removePendingRequest(identifier: Self.notificationIdentifier)
            return
        }

        guard !isEnabled else { return }
        isEnabled = true
        preferenceGeneration += 1
        notificationError = nil
    }

    func setEnabled(_ enabled: Bool) async {
        synchronizeEnabled(enabled)
        guard enabled, !isRequestingAuthorization else { return }

        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }

        var status = await notificationCenter.authorizationStatus()
        updateAuthorizationState(status)
        guard isEnabled, status == .notDetermined else { return }

        do {
            _ = try await notificationCenter.requestAlertAuthorization()
            status = await notificationCenter.authorizationStatus()
            updateAuthorizationState(status)
        } catch {
            authorizationError = "Could not request notification permission: \(error.localizedDescription)"
            authorizationState = await notificationCenter.authorizationStatus()
        }
    }

    func refreshAuthorization() async {
        guard !isRefreshingAuthorization else { return }
        isRefreshingAuthorization = true
        defer { isRefreshingAuthorization = false }

        updateAuthorizationState(await notificationCenter.authorizationStatus())
    }

    func observe(percentage: Int?, charging: Bool?, isFresh: Bool) async {
        latestObservationIsEligibleLow = LowBatteryAlertPolicy.isFreshLowBatteryReading(
            percentage: percentage,
            charging: charging,
            isFresh: isFresh
        )
        latestEligibleLowPercentage = latestObservationIsEligibleLow ? percentage : nil

        if !latestObservationIsEligibleLow, isEnqueueing {
            invalidateCurrentEnqueue()
        }

        guard isFresh, let percentage, (0...100).contains(percentage) else { return }

        if LowBatteryAlertPolicy.shouldRearm(percentage: percentage, isFresh: isFresh) {
            latchStore.setLatched(false)
            notificationError = nil
        }

        guard LowBatteryAlertPolicy.shouldAlert(
                percentage: percentage,
                charging: charging,
                isFresh: isFresh,
                isEnabled: isEnabled,
                authorizationState: authorizationState,
                isLatched: latchStore.isLatched
              ) else {
            return
        }

        guard !isEnqueueing else { return }

        let generation = preferenceGeneration
        isEnqueueing = true
        isCurrentEnqueueInvalidated = false
        notificationError = nil
        defer { isEnqueueing = false }

        do {
            try await notificationCenter.enqueue(notificationRequest(for: percentage))
        } catch {
            guard canContinueWithLatestLow(forGeneration: generation) else { return }
            notificationError = "Could not schedule low battery notification: \(error.localizedDescription)"
            return
        }

        if isCurrentEnqueueInvalidated {
            notificationCenter.removePendingRequest(identifier: Self.notificationIdentifier)
            guard canContinueWithLatestLow(forGeneration: generation),
                  let latestEligibleLowPercentage else {
                return
            }

            isCurrentEnqueueInvalidated = false
            do {
                try await notificationCenter.enqueue(notificationRequest(for: latestEligibleLowPercentage))
            } catch {
                guard canContinueWithLatestLow(forGeneration: generation) else { return }
                notificationError = "Could not schedule low battery notification: \(error.localizedDescription)"
                return
            }
        }

        guard canCompleteCurrentEnqueue(forGeneration: generation) else {
            notificationCenter.removePendingRequest(identifier: Self.notificationIdentifier)
            return
        }
        latchStore.setLatched(true)
    }

    private func notificationRequest(for percentage: Int) -> LowBatteryNotificationRequest {
        LowBatteryNotificationRequest(
            identifier: Self.notificationIdentifier,
            title: "Mouse battery low",
            body: "Battery is at \(percentage)% on your MX Master 3S."
        )
    }

    private func canContinueWithLatestLow(forGeneration generation: Int) -> Bool {
        isEnabled && generation == preferenceGeneration && latestObservationIsEligibleLow &&
            authorizationState.allowsAlerts && !latchStore.isLatched
    }

    private func canCompleteCurrentEnqueue(forGeneration generation: Int) -> Bool {
        !isCurrentEnqueueInvalidated && canContinueWithLatestLow(forGeneration: generation)
    }

    private func invalidateCurrentEnqueue() {
        guard isEnqueueing else { return }
        isCurrentEnqueueInvalidated = true
        notificationCenter.removePendingRequest(identifier: Self.notificationIdentifier)
    }

    private func updateAuthorizationState(_ state: LowBatteryNotificationAuthorizationState) {
        authorizationState = state
        authorizationError = state == .denied
            ? "Notifications are disabled for Hidhogg in System Settings."
            : nil

        guard !state.allowsAlerts, isEnqueueing else { return }
        invalidateCurrentEnqueue()
    }
}

@MainActor
private final class SystemLowBatteryNotificationCenterAdapter: LowBatteryNotificationCenterAdapter {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> LowBatteryNotificationAuthorizationState {
        let settings = await center.notificationSettings()
        let status = settings.authorizationStatus
        return switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        @unknown default: .unknown
        }
    }

    func requestAlertAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func enqueue(_ request: LowBatteryNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: nil
        ))
    }

    func removePendingRequest(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
