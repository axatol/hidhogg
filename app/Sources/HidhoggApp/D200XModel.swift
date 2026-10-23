import AppKit
import Combine
import Foundation
import HidhoggDomain
import MacOSActions
import UlanziD200X

@MainActor
final class D200XModel: ObservableObject {
    @Published private(set) var configuration: D200XConfiguration?
    @Published private(set) var status: D200XStatus = .disconnected
    @Published private(set) var canEdit = false
    @Published private(set) var configurationBlocker: String?
    @Published private(set) var message = "Disconnected. Connect to discover D200X."
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastActionMessage: String?
    @Published var selectedControl: D200XControl = .key0
    @Published var applicationID: String?

    var onEdit: ((D200XConfiguration) -> Void)?
    var onDiagnostic: ((DiagnosticEvent) -> Void)?
    private let session: (any D200XSessionProtocol)?
    private let sender: ShortcutSender
    private let frontmostApplication: @MainActor () -> String?
    private let delay: @Sendable (Duration) async throws -> Void
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var wanted = false
    private var suspended = false
    private var generation: UInt64 = 0
    private var epoch: UInt64 = 0
    private var renderRevision: UInt64 = 0
    private var retryCount = 0
    private var pressed: Set<UInt8> = []
    private var lastPage: D200XPage?

    init(session: (any D200XSessionProtocol)? = nil, sender: ShortcutSender,
         frontmostApplication: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.session = session
        self.sender = sender
        self.frontmostApplication = frontmostApplication
        self.delay = delay
        if let session {
            eventTask = Task { [weak self] in
                for await event in session.events {
                    guard let self, !Task.isCancelled else { return }
                    self.receive(event)
                }
            }
        }
    }

    isolated deinit {
        eventTask?.cancel()
        connectionTask?.cancel()
        renderTask?.cancel()
        stopTask?.cancel()
    }

    var isConfigured: Bool { configuration != nil }
    var isConnected: Bool { if case .connected = status { true } else { false } }
    var isBusy: Bool { if case .connecting = status { true } else if case .disconnecting = status { true } else { false } }
    var connectionTitle: String {
        switch status {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting"
        case .failed: "Failed"
        }
    }
    var applications: [String] { configuration?.applications.keys.sorted() ?? [] }
    var binding: ControlBinding { configuration?.binding(for: selectedControl, application: applicationID) ?? .disabled }
    var isInherited: Bool { applicationID.map { configuration?.applications[$0]?[selectedControl.rawValue] == nil } ?? false }
    var appearance: D200XTileAppearance {
        configuration?.tiles[selectedControl.rawValue] ?? D200XTileAppearance(label: selectedControl.title, backgroundHex: "30343B")
    }
    var firmware: String? { if case .connected(let identity) = status { identity.firmware } else { nil } }

    func synchronize(_ configuration: D200XConfiguration?, canEdit: Bool, blocker: String? = nil) {
        let visualsChanged = self.configuration?.tiles != configuration?.tiles
        self.configuration = configuration
        self.canEdit = canEdit
        configurationBlocker = blocker ?? (canEdit ? nil : "D200X configuration cannot be edited right now.")
        if configuration == nil, wanted { disconnect() }
        if visualsChanged, isConnected, canEdit { scheduleRender() }
    }

    func enableConfiguration() {
        guard canEdit, configuration == nil else { return }
        onEdit?(.empty)
    }

    func setBinding(_ binding: ControlBinding?) {
        guard canEdit, var next = configuration else { return }
        if let applicationID {
            var overrides = next.applications[applicationID] ?? [:]
            overrides[selectedControl.rawValue] = binding
            next.applications[applicationID] = overrides
        } else {
            next.defaults[selectedControl.rawValue] = binding ?? .disabled
        }
        onEdit?(next)
    }

    func setAppearance(label: String, backgroundHex: String) {
        guard canEdit, selectedControl.rawValue.hasPrefix("key"), var next = configuration else { return }
        next.tiles[selectedControl.rawValue] = D200XTileAppearance(label: label, backgroundHex: backgroundHex)
        onEdit?(next)
    }

    func addApplication(_ identifier: String) {
        guard canEdit, var next = configuration else { return }
        next.applications[identifier] = next.applications[identifier] ?? [:]
        guard (try? next.validated()) != nil else { return }
        onEdit?(next)
        applicationID = identifier
    }

    func removeSelectedApplication() {
        guard canEdit, let applicationID, var next = configuration else { return }
        guard next.applications.removeValue(forKey: applicationID) != nil else {
            self.applicationID = nil
            return
        }
        onEdit?(next)
        self.applicationID = nil
    }

    func connect(configureIfNeeded: Bool = true) {
        guard session != nil, !suspended, !isConnected, !isBusy else { return }
        if configuration == nil, !configureIfNeeded { return }
        guard canEdit else {
            blockConnection(configurationBlocker ?? "D200X configuration cannot be edited right now.")
            return
        }
        if let configurationBlocker {
            blockConnection(configurationBlocker)
            return
        }
        if configuration == nil {
            onEdit?(.empty)
            guard canEdit else {
                blockConnection(configurationBlocker ?? "D200X configuration cannot be edited right now.")
                return
            }
            if let configurationBlocker {
                blockConnection(configurationBlocker)
                return
            }
            guard configuration != nil else {
                blockConnection("D200X configuration is unavailable. Resolve the configuration issue before connecting.")
                return
            }
        }
        wanted = true
        retryCount = 0
        errorMessage = nil
        beginConnection()
    }

    func disconnect() {
        wanted = false
        epoch &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        renderTask?.cancel()
        renderTask = nil
        pressed.removeAll()
        lastPage = nil
        guard let session else { return }
        status = .disconnecting
        let previous = stopTask
        stopTask = Task { [weak self] in
            if let previous { await previous.value }
            await session.disconnect()
            guard let self else { return }
            self.status = .disconnected
            self.message = "Disconnected."
        }
    }

    func sleep() {
        let reconnect = wanted
        disconnect()
        wanted = reconnect
        suspended = true
    }

    func wake() {
        guard suspended else { return }
        suspended = false
        guard wanted, isConfigured, canEdit else { return }
        retryCount = 0
        beginConnection()
    }

    func suspendDelivery(_ suspended: Bool) {
        self.suspended = suspended
        if suspended { pressed.removeAll() }
    }

    func stop() async {
        disconnect()
        if let stopTask { await stopTask.value }
    }

    private func beginConnection(retry: Bool = false) {
        guard let session, wanted, !suspended, connectionTask == nil else { return }
        epoch &+= 1
        renderTask?.cancel()
        renderTask = nil
        lastPage = nil
        let intent = epoch
        status = .connecting
        message = retry ? "Reconnecting to D200X…" : "Discovering D200X…"
        let wait = retry ? [1, 2, 5][min(retryCount - 1, 2)] : 0
        let pendingStop = stopTask
        connectionTask = Task { [weak self, delay] in
            do {
                if let pendingStop { await pendingStop.value }
                if wait > 0 { try await delay(.seconds(wait)) }
                try Task.checkCancellation()
                guard let self, self.epoch == intent, self.wanted, !self.suspended else { return }
                try await session.connect()
                guard !Task.isCancelled, self.epoch == intent, self.wanted, !self.suspended else { return }
                self.connectionTask = nil
                self.lastPage = nil
                self.scheduleRender()
            } catch {
                guard let self, self.epoch == intent, !Task.isCancelled else { return }
                self.connectionTask = nil
                let failure = error as? D200XFailure ?? .transport
                self.status = .failed(failure)
                self.fail(failure.userMessage)
                self.retryConnection()
            }
        }
    }

    private func retryConnection() {
        guard wanted, !suspended, canEdit, retryCount < 3, connectionTask == nil else { return }
        retryCount += 1
        beginConnection(retry: true)
    }

    private func receive(_ event: D200XSessionEvent) {
        switch event {
        case .status(let next, let eventGeneration):
            guard eventGeneration >= generation else { return }
            if eventGeneration != generation { pressed.removeAll(); lastPage = nil }
            generation = eventGeneration
            if case .connected = next, (!wanted || suspended) { return }
            status = next
            switch next {
            case .connected:
                message = "Connected to Ulanzi D200X."
                errorMessage = nil
                diagnostic(.d200xStatus, message)
            case .failed(let failure):
                lastPage = nil
                fail(failure.userMessage)
                retryConnection()
            case .disconnected:
                message = "Disconnected."
            default: break
            }
        case .input(let input, let eventGeneration):
            guard eventGeneration == generation, isConnected, wanted, !suspended, canEdit else { return }
            if input.gesture == .release { pressed.remove(input.index); return }
            guard let control = mappedControl(input) else { return }
            if input.gesture == .press, !pressed.insert(input.index).inserted { return }
            guard let shortcut = configuration?.binding(for: control, application: frontmostApplication()).shortcut else { return }
            do {
                try sender.send(shortcut)
                lastActionMessage = "Posted \(ShortcutSender.label(for: shortcut)) from \(control.title)."
            } catch {
                lastActionMessage = "Shortcut delivery failed. Check input permissions in Settings."
                diagnostic(.d200xActionFailed, "D200X shortcut delivery failed.", error: true)
            }
        }
    }

    private func mappedControl(_ input: D200XInput) -> D200XControl? {
        guard input.prefix == 1 else { return nil }
        if input.family == 1, input.gesture == .press {
            return D200XControl.allCases.first { $0.wireIndex == Int(input.index) && $0.gesture == nil }
        }
        guard input.family == 2, input.gesture != .unknown, input.gesture != .release else { return nil }
        return D200XControl.allCases.first { $0.wireIndex == Int(input.index) && $0.gesture?.rawValue == input.state }
    }

    private func scheduleRender() {
        guard configuration != nil, let session, wanted, !suspended, canEdit else { return }
        renderRevision &+= 1
        guard renderTask == nil else { return }
        let intent = epoch
        renderTask = Task { [weak self] in
            do {
                while let self, self.epoch == intent, self.wanted, !self.suspended, self.canEdit,
                      let configuration = self.configuration {
                    try Task.checkCancellation()
                    let revision = self.renderRevision
                    try await Task.sleep(for: .milliseconds(150))
                    if revision != self.renderRevision { continue }
                    let page = try await Task.detached(priority: .utility) {
                        try D200XPageRenderer.page(configuration: configuration)
                    }.value
                    guard !Task.isCancelled, self.epoch == intent else { return }
                    if revision != self.renderRevision { continue }
                    let previous = self.lastPage
                    let changed = page.slots.filter { previous?.slots[$0.key] != $0.value }
                    if !changed.isEmpty {
                        try await session.applyPage(D200XPage(slots: changed), update: previous == nil ? .replace : .incremental)
                        guard !Task.isCancelled, self.epoch == intent else { return }
                        self.lastPage = page
                        self.retryCount = 0
                        self.message = "Page sent to D200X."
                        self.diagnostic(.d200xPageSent, "D200X page transfer completed; appearance requires physical verification.")
                    }
                    if revision == self.renderRevision {
                        self.renderTask = nil
                        return
                    }
                }
                if let self, self.epoch == intent { self.renderTask = nil }
            } catch {
                guard let self, !Task.isCancelled, self.epoch == intent else { return }
                self.renderTask = nil
                self.lastPage = nil
                self.fail("Could not send the D200X page.")
            }
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        self.message = message
        diagnostic(.d200xFailure, message, error: true)
    }

    private func blockConnection(_ reason: String) {
        errorMessage = reason
        message = reason
    }

    private func diagnostic(_ code: DiagnosticCode, _ message: String, error: Bool = false) {
        onDiagnostic?(DiagnosticEvent(code: code, message: message, isError: error))
    }
}
