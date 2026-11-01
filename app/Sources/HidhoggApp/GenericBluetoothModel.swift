import Combine
import Foundation
import GenericBluetooth
import HidhoggDomain

struct GenericBluetoothStatus: Equatable {
    enum Connection: String {
        case connected = "Connected", disconnected = "Disconnected", notPaired = "Not listed by macOS"
        case unavailable = "Unavailable", disabled = "Disabled", suspended = "Suspended"
    }
    var connection: Connection = .unavailable
    var battery: BluetoothBattery?
    var observedAt: Date?
    var failure: BluetoothObservationFailure?
    var reportedKind: BluetoothDeviceKind?
    var sampleID: UUID?

    var batteryText: String {
        guard let battery else { return "Battery unavailable" }
        let components = [("Battery", battery.main), ("Left", battery.left), ("Right", battery.right), ("Case", battery.caseLevel)]
        return components.compactMap { label, level in level.map { "\(label) \($0)%" } }.joined(separator: " · ")
    }

    var summary: String {
        let summary = connection == .connected ? "Connected · \(batteryText)" : connection.rawValue
        return failure != nil && observedAt != nil ? "\(summary) · Earlier observation" : summary
    }
}

@MainActor
protocol BluetoothCheckScheduling: AnyObject {
    func start(every interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor
final class BluetoothCheckScheduler: BluetoothCheckScheduling {
    private var task: Task<Void, Never>?

    func start(every interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void) {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
    isolated deinit { task?.cancel() }
}

@MainActor
final class GenericBluetoothModel: ObservableObject {
    @Published private(set) var devices: [PairedBluetoothDevice] = []
    @Published private(set) var statuses: [UUID: GenericBluetoothStatus] = [:] {
        didSet { updateScheduledChecks(); onStateChange?() }
    }
    @Published private(set) var access: BluetoothAccess
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var discoveryFailure: BluetoothObservationFailure?
    private let inventory: any PairedBluetoothInventory
    private let report: any BluetoothReportReading
    private let registryReport: (any BluetoothReportReading)?
    private let now: () -> Date
    private let scheduler: (any BluetoothCheckScheduling)?
    private var scheduling = false
    private var alertEnabled: Set<UUID> = []
    private var stopped = false
    var onStateChange: (@MainActor () -> Void)?
    var isSuspended: Bool { suspended || stopped }
    private var registrations: [UUID: BluetoothEndpoint] = [:]
    private var enabled: Set<UUID> = []
    private var registrationTokens: [UUID: UUID] = [:]
    private var suspended = false
    private var observing = false
    private var refreshTask: Task<Void, Never>?
    private var previousTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var refreshAgain = false
    private var refreshAllAgain = false
    private var discoverAgain = false
    private var discoveryPresented = false
    private var authorizationTask: Task<Void, Never>?
    private var authorizationID: UUID?

    init(inventory: any PairedBluetoothInventory = InertBluetoothInventory(),
         report: any BluetoothReportReading = SystemBluetoothReport(),
         registryReport: (any BluetoothReportReading)? = nil,
         scheduler: (any BluetoothCheckScheduling)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.inventory = inventory
        self.report = report
        self.registryReport = registryReport
        self.now = now
        self.scheduler = scheduler
        self.access = inventory.access
    }

    func status(for id: UUID) -> GenericBluetoothStatus { statuses[id] ?? GenericBluetoothStatus() }

    func canRegister(_ endpoint: BluetoothEndpoint) -> Bool {
        !suspended && inventory.access == .allowed && discoveryFailure == nil && devices.contains { $0.endpoint == endpoint }
    }

    func synchronize(_ devices: [RegisteredDevice], suspended: Bool) {
        var next: [UUID: BluetoothEndpoint] = [:]
        var nextEnabled: Set<UUID> = []
        var nextAlerts: Set<UUID> = []
        for device in devices {
            guard let configuration = device.bluetoothConfiguration else { continue }
            next[device.id] = configuration.endpoint
            if device.isEnabled { nextEnabled.insert(device.id) }
            if device.isEnabled && configuration.lowBatteryAlertsEnabled { nextAlerts.insert(device.id) }
        }
        let changed = registrations != next || enabled != nextEnabled || self.suspended != suspended
        registrationTokens = next.reduce(into: [:]) { tokens, entry in
            let unchanged = registrations[entry.key] == entry.value && enabled.contains(entry.key) == nextEnabled.contains(entry.key)
            tokens[entry.key] = unchanged ? (registrationTokens[entry.key] ?? UUID()) : UUID()
        }
        registrations = next
        enabled = nextEnabled
        alertEnabled = nextAlerts
        stopped = false
        self.suspended = suspended
        statuses = statuses.filter { next[$0.key] != nil }
        for id in next.keys {
            if !nextEnabled.contains(id) { statuses[id] = GenericBluetoothStatus(connection: .disabled) }
            else if suspended { statuses[id] = GenericBluetoothStatus(connection: .suspended) }
            else if statuses[id] == nil || statuses[id]?.connection == .disabled || statuses[id]?.connection == .suspended { statuses[id] = GenericBluetoothStatus() }
        }
        guard !suspended, !enabled.isEmpty else {
            stop()
            return
        }
        access = inventory.access
        updateScheduledChecks()
        onStateChange?()
        if changed, observing {
            inventory.stopObserving()
            observing = false
            beginObservation()
        }
        if changed, access == .allowed { refresh() }
    }

    func discover() {
        guard !suspended else { return }
        stopped = false
        requestRefresh(discover: true)
    }

    func beginDiscovery() {
        discoveryPresented = true
        if inventory.access == .allowed { discover() }
    }

    func endDiscovery() {
        discoveryPresented = false
        devices = []
        if enabled.isEmpty { stop() }
    }

    func refresh() {
        guard !suspended, !enabled.isEmpty else { return }
        requestRefresh(discover: false)
    }

    func recheckAccess() {
        let current = inventory.access
        guard access != current else { return }
        access = current
        if current == .allowed {
            stopped = false
            refresh()
            return
        }
        stop()
        devices = []
        discoveryFailure = .permissionRequired
        for key in enabled { statuses[key] = GenericBluetoothStatus(failure: .permissionRequired) }
    }

    func requestAuthorization() {
        guard !suspended, authorizationTask == nil else { return }
        let id = UUID()
        authorizationID = id
        isRequestingAccess = true
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.inventory.requestAccess()
            guard self.authorizationID == id, !Task.isCancelled, !self.suspended else { return }
            self.authorizationTask = nil
            self.authorizationID = nil
            self.isRequestingAccess = false
            self.recheckAccess()
        }
    }

    func stop() {
        stopped = true
        scheduler?.stop()
        scheduling = false
        onStateChange?()
        authorizationID = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        isRequestingAccess = false
        refreshID = nil
        refreshAgain = false
        refreshAllAgain = false
        discoverAgain = false
        refreshTask?.cancel()
        if let refreshTask { previousTask = refreshTask }
        refreshTask = nil
        isRefreshing = false
        if observing { inventory.stopObserving(); observing = false }
    }

    private func requestRefresh(discover: Bool, scheduledOnly: Bool = false) {
        if refreshTask != nil {
            refreshAgain = true
            refreshAllAgain = refreshAllAgain || !scheduledOnly
            discoverAgain = discoverAgain || discover
            return
        }
        let id = UUID()
        refreshID = id
        isRefreshing = true
        let previous = previousTask
        previousTask = nil
        refreshTask = Task { [weak self] in
            if let previous { await previous.value }
            guard let self, !Task.isCancelled, self.refreshID == id else { return }
            await self.performRefresh(discover: discover, scheduledOnly: scheduledOnly, id: id)
            guard self.refreshID == id else { return }
            self.refreshTask = nil
            self.isRefreshing = false
            if self.refreshAgain {
                let discover = self.discoverAgain
                let scheduledOnly = !self.refreshAllAgain
                self.refreshAgain = false
                self.refreshAllAgain = false
                self.discoverAgain = false
                self.requestRefresh(discover: discover, scheduledOnly: scheduledOnly)
            }
        }
    }

    private func performRefresh(discover: Bool, scheduledOnly: Bool, id: UUID) async {
        var currentAccess = inventory.access
        if discover, currentAccess == .notDetermined { currentAccess = await inventory.requestAccess() }
        guard refreshID == id, !suspended, !Task.isCancelled else { return }
        access = currentAccess
        guard access == .allowed else {
            discoveryFailure = .permissionRequired
            devices = []
            for key in enabled { statuses[key] = GenericBluetoothStatus(failure: .permissionRequired) }
            if observing { inventory.stopObserving(); observing = false }
            return
        }
        let requestedIDs = scheduledOnly ? scheduledCheckIDs : enabled
        let requested = registrations.filter { requestedIDs.contains($0.key) }
        let requestedTokens = registrationTokens
        guard !scheduledOnly || !requested.isEmpty else { return }
        let paired: [PairedBluetoothDevice]
        do { paired = try inventory.pairedDevices() }
        catch {
            discoveryFailure = .inventoryUnavailable
            for key in requested.keys {
                var status = statuses[key] ?? GenericBluetoothStatus()
                status.failure = .inventoryUnavailable
                statuses[key] = status
            }
            return
        }
        if !scheduledOnly { devices = discoveryPresented ? paired : [] }
        discoveryFailure = nil
        beginObservation()
        guard !requested.isEmpty else { return }
        let pairedByEndpoint = Dictionary(paired.map { ($0.endpoint, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, endpoint) in activeRequestedEntries(requested, tokens: requestedTokens) {
            var status = statuses[key] ?? GenericBluetoothStatus()
            let paired = pairedByEndpoint[endpoint]
            status.connection = paired.map { $0.isConnected ? .connected : .disconnected } ?? .notPaired
            status.reportedKind = paired?.reportedKind
            statuses[key] = status
        }
        guard !activeRequestedEntries(requested, tokens: requestedTokens, scheduledOnly: scheduledOnly).isEmpty else { return }
        var batteries: [BluetoothEndpoint: BluetoothBattery] = [:]
        var primaryFailure: BluetoothObservationFailure?
        do {
            let data = try await report.read()
            let active = activeRequestedEntries(requested, tokens: requestedTokens, scheduledOnly: scheduledOnly)
            batteries = try BluetoothReportParser.batteries(in: data, pairedEndpoints: Set(active.values).intersection(pairedByEndpoint.keys))
        } catch let error as BluetoothObservationFailure { primaryFailure = error }
        catch { primaryFailure = .reportFailed }
        guard refreshID == id, !suspended, !Task.isCancelled else { return }
        guard inventory.access == .allowed else {
            access = inventory.access
            devices = []
            for key in enabled { statuses[key] = GenericBluetoothStatus(failure: .permissionRequired) }
            inventory.stopObserving()
            observing = false
            return
        }
        let activeBeforeFallback = activeRequestedEntries(requested, tokens: requestedTokens, scheduledOnly: scheduledOnly)
        let fallbackEndpoints = Set(activeBeforeFallback.values)
            .intersection(Set(pairedByEndpoint.keys))
            .subtracting(Set(batteries.keys))
        var registryBatteries: [BluetoothEndpoint: BluetoothBattery] = [:]
        var registryFailure: BluetoothObservationFailure?
        if let registryReport, !fallbackEndpoints.isEmpty {
            do {
                let data = try await registryReport.read()
                let active = activeRequestedEntries(requested, tokens: requestedTokens, scheduledOnly: scheduledOnly)
                registryBatteries = try BluetoothRegistryBatteryParser.batteries(in: data,
                    pairedEndpoints: fallbackEndpoints.intersection(active.values))
            } catch let error as BluetoothObservationFailure { registryFailure = error }
            catch { registryFailure = .reportFailed }
        }
        guard refreshID == id, !suspended, !Task.isCancelled else { return }
        guard inventory.access == .allowed else {
            access = inventory.access
            devices = []
            for key in enabled { statuses[key] = GenericBluetoothStatus(failure: .permissionRequired) }
            inventory.stopObserving()
            observing = false
            return
        }
        let observedAt = now()
        for (key, endpoint) in activeRequestedEntries(requested, tokens: requestedTokens, scheduledOnly: scheduledOnly) {
            let paired = pairedByEndpoint[endpoint]
            let previous = statuses[key]
            let battery = batteries[endpoint] ?? registryBatteries[endpoint]
            let failure = battery == nil ? primaryFailure ?? registryFailure ?? .batteryUnavailable : nil
            statuses[key] = GenericBluetoothStatus(connection: paired.map { $0.isConnected ? .connected : .disconnected } ?? .notPaired,
                                                   battery: battery ?? previous?.battery,
                                                   observedAt: battery == nil ? previous?.observedAt : observedAt,
                                                   failure: failure,
                                                   reportedKind: paired?.reportedKind,
                                                   sampleID: battery == nil ? previous?.sampleID : UUID())
        }
    }

    private func activeRequestedEntries(_ requested: [UUID: BluetoothEndpoint], tokens: [UUID: UUID],
                                        scheduledOnly: Bool = false) -> [UUID: BluetoothEndpoint] {
        requested.filter { key, endpoint in
            registrations[key] == endpoint && enabled.contains(key) && registrationTokens[key] == tokens[key] &&
                (!scheduledOnly || (alertEnabled.contains(key) && statuses[key]?.connection == .connected))
        }
    }

    private func beginObservation() {
        guard !suspended, !enabled.isEmpty, !observing, inventory.access == .allowed else { return }
        observing = true
        let endpoints = Set(registrations.filter { enabled.contains($0.key) }.values)
        inventory.observeChanges(for: endpoints) { [weak self] in self?.refresh() }
    }

    private var scheduledCheckIDs: Set<UUID> {
        guard !isSuspended, inventory.access == .allowed else { return [] }
        return Set(alertEnabled.filter { id in
            enabled.contains(id) && statuses[id]?.connection == .connected && statuses[id]?.failure != .inventoryUnavailable
        })
    }

    private func updateScheduledChecks() {
        let eligible = !scheduledCheckIDs.isEmpty
        guard eligible != scheduling else { return }
        scheduling = eligible
        guard eligible else { scheduler?.stop(); return }
        scheduler?.start(every: 600) { [weak self] in
            guard let self else { return }
            self.recheckAccess()
            self.updateScheduledChecks()
            guard self.scheduling else { return }
            self.requestRefresh(discover: false, scheduledOnly: true)
        }
    }

    isolated deinit { scheduler?.stop(); authorizationTask?.cancel(); refreshTask?.cancel(); previousTask?.cancel(); inventory.stopObserving() }
}

@MainActor
private final class InertBluetoothInventory: PairedBluetoothInventory {
    var access: BluetoothAccess { .notDetermined }
    func requestAccess() async -> BluetoothAccess { .notDetermined }
    func pairedDevices() throws -> [PairedBluetoothDevice] { [] }
    func observeChanges(for endpoints: Set<BluetoothEndpoint>, _ changed: @escaping @MainActor @Sendable () -> Void) { }
    func stopObserving() { }
}
