import Foundation
import GenericBluetooth
import HidhoggDomain

enum BluetoothBatteryComponent: String, CaseIterable {
    case main, left, right, caseLevel

    var title: String {
        switch self {
        case .main: "Battery"
        case .left: "Left"
        case .right: "Right"
        case .caseLevel: "Case"
        }
    }

    func percentage(in battery: BluetoothBattery) -> Int? {
        switch self {
        case .main: battery.main
        case .left: battery.left
        case .right: battery.right
        case .caseLevel: battery.caseLevel
        }
    }
}

@MainActor
protocol GenericBluetoothAlertLatchStore {
    func isLatched(device: UUID, component: BluetoothBatteryComponent) -> Bool
    func setLatched(_ latched: Bool, device: UUID, component: BluetoothBatteryComponent)
}

@MainActor
final class UserDefaultsGenericBluetoothAlertLatchStore: GenericBluetoothAlertLatchStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isLatched(device: UUID, component: BluetoothBatteryComponent) -> Bool {
        defaults.bool(forKey: key(device, component))
    }

    func setLatched(_ latched: Bool, device: UUID, component: BluetoothBatteryComponent) {
        defaults.set(latched, forKey: key(device, component))
    }

    private func key(_ device: UUID, _ component: BluetoothBatteryComponent) -> String {
        "com.hidhogg.app.low-battery-alert-latched.bluetooth.\(device.uuidString).\(component.rawValue)"
    }
}

@MainActor
final class GenericBluetoothAlertCoordinator {
    private struct Entry: Equatable {
        let endpoint: BluetoothEndpoint
        let alertsEnabled: Bool
        let threshold: Int
        let eligible: Bool
    }

    private let notificationCenter: any LowBatteryNotificationCenterAdapter
    private let latchStore: any GenericBluetoothAlertLatchStore
    private var entries: [UUID: Entry] = [:]
    private var generations: [UUID: UUID] = [:]
    private var samples: [UUID: UUID] = [:]
    private var pending: [UUID: Set<BluetoothBatteryComponent>] = [:]
    private var inFlight: Set<UUID> = []
    private(set) var notificationError: String?

    init(notificationCenter: any LowBatteryNotificationCenterAdapter,
         latchStore: (any GenericBluetoothAlertLatchStore)? = nil) {
        self.notificationCenter = notificationCenter
        self.latchStore = latchStore ?? UserDefaultsGenericBluetoothAlertLatchStore()
    }

    static func identifier(for device: UUID) -> String { "hidhogg.low-battery.bluetooth.\(device.uuidString)" }

    func synchronize(devices: [RegisteredDevice], statuses: [UUID: GenericBluetoothStatus],
                     authorization: LowBatteryNotificationAuthorizationState, suspended: Bool,
                     bluetoothAllowed: Bool) {
        let registrations = devices.filter { $0.bluetoothConfiguration != nil }
        let ids = Set(registrations.map(\.id))
        for id in Set(entries.keys).subtracting(ids) {
            invalidate(id)
            entries[id] = nil
            generations[id] = nil
            samples[id] = nil
        }
        for device in registrations {
            guard let configuration = device.bluetoothConfiguration else { continue }
            let status = statuses[device.id]
            let active = device.isEnabled && !suspended && bluetoothAllowed &&
                status?.connection == .connected && status?.failure == nil
            let entry = Entry(endpoint: configuration.endpoint, alertsEnabled: configuration.lowBatteryAlertsEnabled,
                              threshold: configuration.lowBatteryThreshold,
                              eligible: active && configuration.lowBatteryAlertsEnabled && authorization.allowsAlerts)
            if entries[device.id] != entry {
                invalidate(device.id)
                generations[device.id] = UUID()
                entries[device.id] = entry
            }
            guard let status, let sample = status.sampleID, samples[device.id] != sample else { continue }
            samples[device.id] = sample
            guard active, let battery = status.battery else { continue }
            let threshold = configuration.lowBatteryThreshold
            guard (1...100).contains(threshold) else { continue }
            var low: [BluetoothBatteryComponent: Int] = [:]
            for component in BluetoothBatteryComponent.allCases {
                guard let percentage = component.percentage(in: battery), (0...100).contains(percentage) else { continue }
                if percentage > threshold && percentage >= min(100, threshold + 5) {
                    latchStore.setLatched(false, device: device.id, component: component)
                }
                if percentage <= threshold { low[component] = percentage }
            }
            if let pendingComponents = pending[device.id], !pendingComponents.isSubset(of: Set(low.keys)) {
                invalidate(device.id)
                generations[device.id] = UUID()
            }
            guard entry.eligible, !inFlight.contains(device.id) else { continue }
            let newlyLow = low.filter { !latchStore.isLatched(device: device.id, component: $0.key) }
            guard !newlyLow.isEmpty, let generation = generations[device.id] else { continue }
            enqueue(device: device, low: newlyLow, generation: generation)
        }
    }

    func stop() {
        for id in entries.keys { invalidate(id); generations[id] = UUID() }
        entries = [:]
    }

    private func invalidate(_ id: UUID) {
        pending[id] = nil
        notificationCenter.removePendingRequest(identifier: Self.identifier(for: id))
    }

    private func enqueue(device: RegisteredDevice, low: [BluetoothBatteryComponent: Int], generation: UUID) {
        let id = device.id
        let components = Set(low.keys)
        pending[id] = components
        inFlight.insert(id)
        notificationError = nil
        let levels = BluetoothBatteryComponent.allCases.compactMap { component in
            low[component].map { "\(component.title) \($0)%" }
        }.joined(separator: ", ")
        let request = LowBatteryNotificationRequest(identifier: Self.identifier(for: id),
            title: "Bluetooth device battery low", body: "\(device.displayName): \(levels).")
        Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight.remove(id) }
            guard self.canComplete(id, generation: generation, components: components) else { return }
            do { try await self.notificationCenter.enqueue(request) }
            catch {
                guard self.canComplete(id, generation: generation, components: components) else { return }
                self.pending[id] = nil
                self.notificationError = "Could not schedule Bluetooth low battery notification."
                return
            }
            guard self.canComplete(id, generation: generation, components: components) else {
                self.notificationCenter.removePendingRequest(identifier: Self.identifier(for: id))
                return
            }
            for component in components { self.latchStore.setLatched(true, device: id, component: component) }
            self.pending[id] = nil
        }
    }

    private func canComplete(_ id: UUID, generation: UUID, components: Set<BluetoothBatteryComponent>) -> Bool {
        generations[id] == generation && entries[id]?.eligible == true && pending[id] == components
    }
}
