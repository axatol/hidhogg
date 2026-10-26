import Combine
import Foundation
import HidhoggAutomation
import HidhoggDomain

struct LiveNotificationEvent: Identifiable, Equatable {
    let id: UUID
    let topic: String
    let text: String
    let receivedAt: Date
    let profile: String
    var notificationID: UUID?
    var controls: [String]
    var outcome: String
}

@MainActor
final class D200XAutomationCoordinator: ObservableObject {
    @Published private(set) var notificationHistory: [NotificationHistoryEntry] = []
    @Published private(set) var actionHistory: [ConfiguredActionRecord] = []
    @Published private(set) var message: String?
    @Published private(set) var isListening = false
    @Published private(set) var liveNotifications: [LiveNotificationEvent] = []
    private weak var model: D200XModel?
    private let runner: ConfiguredActionRunner
    private let server = LocalAutomationServer()
    private var store = NotificationOverlayStore()
    private var operation: Task<AutomationResponse, Never>?
    private var operationID: UUID?
    private var pendingCount = 0
    private var revision: UInt64 = 0
    private var expiryTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var isStopping = false
    private var historyReadRevision: UInt64 = 0
    private let clockOrigin = ContinuousClock.now
    private let dateOrigin = Date.now

    init(model: D200XModel, runner: ConfiguredActionRunner) {
        self.model = model
        self.runner = runner
        historyTask = Task { [weak self, events = runner.events] in
            for await _ in events {
                guard let self, !Task.isCancelled else { return }
                await self.refreshHistory()
            }
        }
    }

    isolated deinit {
        expiryTask?.cancel()
        historyTask?.cancel()
        startupTask?.cancel()
        operation?.cancel()
    }

    private var clockDate: Date {
        let elapsed = clockOrigin.duration(to: .now).components
        return dateOrigin.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    var labels: [String: String] { store.labelOverrides(at: clockDate) }
    var isStopped: Bool { isStopping }

    func start() {
        guard startupTask == nil, !isStopping else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.server.start { [weak self] request in
                    guard let self else {
                        return .failure(requestID: request.requestID, code: "unavailable", message: "Hidhogg is unavailable.")
                    }
                    return await self.handle(request)
                }
                self.message = "Local automation is available."
            } catch {
                self.message = "Local automation could not start. Another endpoint may already exist."
            }
        }
    }

    func reset() {
        revision &+= 1
        expiryTask?.cancel()
        expiryTask = nil
        store.reset(now: clockDate)
    }

    func refreshHistory() async {
        historyReadRevision &+= 1
        let revision = historyReadRevision
        let records = await runner.history()
        guard revision == historyReadRevision else { return }
        actionHistory = records
    }
    func clearActionHistory() async {
        historyReadRevision &+= 1
        await runner.clearHistory()
        await refreshHistory()
    }

    func clearActiveNotifications() async {
        var ids: Set<UUID> = []
        let response = await enqueue(requestID: UUID().uuidString) { [weak self] store in
            ids = Set(D200XControl.allCases.compactMap { self?.captureNotificationID(control: $0) })
            return store.prepareClearAll(now: self?.clockDate ?? .now)
        }
        if response.succeeded {
            for index in liveNotifications.indices where liveNotifications[index].notificationID.map(ids.contains) == true {
                liveNotifications[index].outcome = "cleared"
            }
        }
    }

    func setListening(_ enabled: Bool) {
        isListening = enabled
        if !enabled { liveNotifications.removeAll() }
    }

    func stop() async {
        isStopping = true
        setListening(false)
        reset()
        await startupTask?.value
        await server.stop()
        _ = await operation?.value
        await runner.stop()
        historyTask?.cancel()
    }

    func invoke(id: String) async throws -> UUID {
        guard !isStopping, let model, model.canRunConfiguredActions,
              let action = model.configuration?.actionDefinition(id: id) else { throw AutomationUnavailable() }
        return try await invokeCaptured(id: id, definition: action, trigger: .init(kind: .localAPI))
    }

    func invokeCaptured(id: String, action: ConfiguredExecutable, trigger: ConfiguredActionTrigger? = nil) async throws -> UUID {
        try await invokeCaptured(id: id, definition: .executable(action), trigger: trigger)
    }

    func invokeCaptured(id: String, definition: ConfiguredActionDefinition, trigger: ConfiguredActionTrigger? = nil) async throws -> UUID {
        guard !isStopping, model?.canRunConfiguredActions == true else { throw AutomationUnavailable() }
        let executionID: UUID
        switch definition {
        case .executable(let action): executionID = try await runner.invoke(id: id, action: action, trigger: trigger)
        case .native(let action): executionID = try await runner.invoke(id: id, nativeAction: action, trigger: trigger)
        }
        await refreshHistory()
        return executionID
    }

    func captureNotificationID(control: D200XControl) -> UUID? {
        store.notificationID(for: control.rawValue, at: clockDate)
    }

    func dismiss(control: D200XControl, capturedID: UUID?) async -> Bool {
        guard let capturedID else { return true }
        let result = await enqueue(requestID: UUID().uuidString, topic: "device", outcome: "dismissed", notificationID: capturedID,
                                   authorize: { [weak self] in
            guard let self else { return false }
            return self.store.notificationID(for: control.rawValue, at: self.clockDate) == capturedID
        }) { [weak self] store in
            guard let self, store.notificationID(for: control.rawValue, at: self.clockDate) == capturedID else {
                throw AutomationUnavailable()
            }
            return store.prepareDismiss(control: control.rawValue, capturedID: capturedID, now: self.clockDate)
        }
        guard result.succeeded, case .object(let values)? = result.result else { return false }
        return values["cleared_count"] == .integer(1)
    }

    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        do {
            try request.validated()
            guard !isStopping else { throw AutomationUnavailable() }
            switch request.method {
            case .status:
                return .success(requestID: request.requestID, result: .object([
                    "connected": .bool(model?.isConnected == true),
                    "actions": .array((model?.configuration?.actionIDs ?? []).map(AutomationValue.string))
                ]))
            case .actionsInvoke:
                let id = try await invoke(id: request.params?.actionID ?? "")
                return .success(requestID: request.requestID, result: .object(["execution_id": .string(id.uuidString)]))
            case .actionsHistory:
                return .success(requestID: request.requestID, result: try .encoding(Array(await runner.history().suffix(40))))
            case .notificationsHistory:
                return .success(requestID: request.requestID, result: .array(notificationHistory.suffix(40).map { entry in
                    .object(["event_id": .string(entry.id.uuidString), "notification_id": .string(entry.notificationID.uuidString), "topic": .string(entry.topic),
                             "profile": .string(entry.profile ?? "Default"),
                             "outcome": .string(entry.outcome), "controls": .array(entry.controls.map(AutomationValue.string)),
                             "matched_count": .integer(entry.matchedCount), "committed_at": .string(entry.committedAt.ISO8601Format())])
                }))
            case .notificationsEmit:
                guard let params = request.params, let topic = params.topic, let text = params.text else {
                    throw AutomationUnavailable()
                }
                model?.refreshActiveApplication()
                let capturedTopics = model?.runtimeConfiguration?.notificationTopics ?? [:]
                let eventID = UUID()
                let recipients = capturedTopics.filter {
                    $0.value.contains { NotificationTopic.matches(topic, filter: $0) }
                }.keys.sorted()
                if isListening {
                    liveNotifications.append(LiveNotificationEvent(id: eventID, topic: topic, text: text,
                        receivedAt: .now, profile: model?.activeProfileName ?? "Default", notificationID: nil, controls: recipients, outcome: "received"))
                    if liveNotifications.count > 100 { liveNotifications.removeFirst(liveNotifications.count - 100) }
                }
                let response = await enqueue(requestID: request.requestID, topic: topic, outcome: "delivered") { [weak self] store in
                    var subscriptions: [String: [String]] = [:]
                    for (control, topics) in capturedTopics {
                        for topic in topics { subscriptions[topic, default: []].append(control) }
                    }
                    return try store.prepareEmit(topic: topic, text: text, ttlSeconds: params.ttlSeconds,
                                          subscriptions: subscriptions, now: self?.clockDate ?? .now)
                }
                if let index = liveNotifications.firstIndex(where: { $0.id == eventID }) {
                    liveNotifications[index].outcome = response.succeeded ? (recipients.isEmpty ? "unhandled" : "delivered") : "failed"
                    if case .object(let result)? = response.result, case .string(let id)? = result["notification_id"] {
                        liveNotifications[index].notificationID = UUID(uuidString: id)
                    }
                }
                return response
            case .notificationsClear:
                guard let id = request.params?.notificationID else { throw AutomationUnavailable() }
                return await enqueue(requestID: request.requestID, notificationID: id) { [weak self] store in store.prepareClear(notificationID: id, now: self?.clockDate ?? .now) }
            }
        } catch {
            return .failure(requestID: request.requestID, code: "unavailable", message: "The request is invalid or its configured action is unavailable.")
        }
    }

    private func enqueue(requestID: String, topic: String = "local", outcome: String = "cleared", notificationID: UUID? = nil,
                         authorize: (@MainActor () -> Bool)? = nil,
                         prepare: @escaping @MainActor (NotificationOverlayStore) throws -> PreparedNotificationMutation) async -> AutomationResponse {
        guard !isStopping, pendingCount < 8 else {
            return .failure(requestID: requestID, code: "busy", message: "The notification queue is unavailable or full.")
        }
        pendingCount += 1
        let previous = operation
        let intent = revision
        let profile = model?.activeProfileName ?? "Default"
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            guard let self, !self.isStopping, !Task.isCancelled, self.revision == intent else {
                return AutomationResponse.failure(requestID: requestID, code: "cancelled", message: "The device context changed.")
            }
            do {
                let previousControls = Set(self.store.labelOverrides(at: .distantPast).keys)
                let mutation = try prepare(self.store)
                if mutation.matchedCount > 0 || mutation.clearedCount > 0 {
                    guard let model = self.model, model.canDeliverNotification else { throw AutomationUnavailable() }
                    try await model.applyNotificationLabels(mutation.labelOverrides, authorize: { [weak self] in
                        self?.revision == intent && (authorize?() ?? true)
                    })
                }
                guard !self.isStopping, self.revision == intent, !Task.isCancelled else { throw AutomationUnavailable() }
                try self.store.commit(mutation, committedAt: self.clockDate)
                let controls = outcome == "delivered"
                    ? (self.model?.runtimeConfiguration?.notificationTopics.filter { $0.value.contains { NotificationTopic.matches(topic, filter: $0) } }.keys.sorted() ?? [])
                    : previousControls.subtracting(mutation.labelOverrides.keys).sorted()
                self.recordNotification(topic: topic, outcome: outcome == "delivered" && mutation.matchedCount == 0 ? "unhandled" : outcome,
                                        notificationID: mutation.notificationID ?? notificationID,
                                        count: max(mutation.matchedCount, mutation.clearedCount), controls: controls, profile: profile)
                var result: [String: AutomationValue] = ["matched_count": .integer(mutation.matchedCount), "cleared_count": .integer(mutation.clearedCount)]
                if let id = mutation.notificationID { result["notification_id"] = .string(id.uuidString) }
                return .success(requestID: requestID, result: .object(result))
            } catch {
                self.message = "The notification was not delivered. Check the device connection and request."
                self.model?.reportAutomationFailure("A tile notification could not be committed to the device.")
                self.recordNotification(topic: topic, outcome: "failed", notificationID: notificationID, count: 0, controls: [], profile: profile)
                return .failure(requestID: requestID, code: "not_delivered", message: "The notification could not be committed to the device.")
            }
        }
        operation = task
        operationID = id
        let response = await task.value
        pendingCount -= 1
        if operationID == id { operation = nil; operationID = nil }
        scheduleExpiry(afterFailure: !response.succeeded)
        return response
    }

    private func scheduleExpiry(afterFailure: Bool = false) {
        expiryTask?.cancel()
        guard !isStopping, model?.canDeliverNotification == true, let deadline = store.nextExpiration else { return }
        let wait = max(afterFailure ? 0.25 : 0, deadline.timeIntervalSince(clockDate))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            _ = await self.enqueue(requestID: UUID().uuidString, topic: "timer", outcome: "expired") { $0.prepareExpiry(now: self.clockDate) }
        }
    }

    private func recordNotification(topic: String, outcome: String, notificationID: UUID?, count: Int, controls: [String], profile: String) {
        if let notificationID, let index = liveNotifications.firstIndex(where: { $0.notificationID == notificationID }) {
            liveNotifications[index].outcome = outcome
        }
        notificationHistory.append(NotificationHistoryEntry(notificationID: notificationID ?? UUID(), topic: topic,
                                                            committedAt: clockDate, expiresAt: nil, matchedCount: count,
                                                            outcome: outcome, controls: controls, profile: profile))
        if notificationHistory.count > 100 { notificationHistory.removeFirst(notificationHistory.count - 100) }
    }
}

private struct AutomationUnavailable: Error {}

private extension AutomationResponse {
    var succeeded: Bool { error == nil }
}
