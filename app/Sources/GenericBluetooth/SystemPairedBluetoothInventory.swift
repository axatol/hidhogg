import CoreBluetooth
import Foundation
import HidhoggDomain
import IOBluetooth

@MainActor
public final class SystemPairedBluetoothInventory: NSObject, PairedBluetoothInventory, CBCentralManagerDelegate {
    private var permissionManager: CBCentralManager?
    private var permissionWaiters: [UUID: CheckedContinuation<BluetoothAccess, Never>] = [:]
    private var connectionNotification: IOBluetoothUserNotification?
    private var disconnectionNotifications: [BluetoothEndpoint: IOBluetoothUserNotification] = [:]
    private var observedEndpoints: Set<BluetoothEndpoint> = []
    private var changed: (@MainActor @Sendable () -> Void)?

    public override init() { super.init() }

    public var access: BluetoothAccess {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    public func requestAccess() async -> BluetoothAccess {
        guard access == .notDetermined else { return access }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: access); return }
                permissionWaiters[id] = continuation
                if permissionManager == nil {
                    permissionManager = CBCentralManager(delegate: self, queue: .main,
                                                        options: [CBCentralManagerOptionShowPowerAlertKey: false])
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionWaiters.removeValue(forKey: id)?.resume(returning: self.access)
            }
        }
    }

    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor [weak self] in
            guard let self, self.access != .notDetermined else { return }
            let waiters = self.permissionWaiters
            self.permissionWaiters.removeAll()
            for waiter in waiters.values { waiter.resume(returning: self.access) }
        }
    }

    public func pairedDevices() throws -> [PairedBluetoothDevice] {
        guard access == .allowed else { throw BluetoothObservationFailure.permissionRequired }
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            throw BluetoothObservationFailure.inventoryUnavailable
        }
        updateDisconnectNotifications(devices)
        var result: [BluetoothEndpoint: PairedBluetoothDevice] = [:]
        var duplicates: Set<BluetoothEndpoint> = []
        for device in devices {
            guard let address = device.addressString, let endpoint = BluetoothEndpoint(address: address) else { continue }
            if result[endpoint] != nil { duplicates.insert(endpoint); continue }
            let name = device.name ?? "Bluetooth Device"
            result[endpoint] = PairedBluetoothDevice(
                endpoint: endpoint,
                name: name,
                isConnected: device.isConnected(),
                reportedKind: BluetoothDeviceKind.reported(
                    majorDeviceClass: device.deviceClassMajor,
                    minorDeviceClass: device.deviceClassMinor
                )
            )
        }
        for endpoint in duplicates { result.removeValue(forKey: endpoint) }
        return result.values.sorted { $0.endpoint.address < $1.endpoint.address }
    }

    public func observeChanges(for endpoints: Set<BluetoothEndpoint>, _ changed: @escaping @MainActor @Sendable () -> Void) {
        stopObserving()
        guard access == .allowed else { return }
        self.changed = changed
        observedEndpoints = endpoints
        connectionNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connectionChanged(_:device:)))
        if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            updateDisconnectNotifications(devices)
        }
    }

    public func stopObserving() {
        connectionNotification?.unregister()
        connectionNotification = nil
        for notification in disconnectionNotifications.values { notification.unregister() }
        disconnectionNotifications.removeAll()
        observedEndpoints.removeAll()
        changed = nil
    }

    private func updateDisconnectNotifications(_ devices: [IOBluetoothDevice]) {
        for device in devices where device.isConnected() {
            guard let address = device.addressString, let endpoint = BluetoothEndpoint(address: address),
                  observedEndpoints.contains(endpoint), disconnectionNotifications[endpoint] == nil else { continue }
            disconnectionNotifications[endpoint] = device.register(forDisconnectNotification: self, selector: #selector(connectionChanged(_:device:)))
        }
    }

    @objc nonisolated private func connectionChanged(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString, let endpoint = BluetoothEndpoint(address: address) else { return }
        let connected = device.isConnected()
        Task { @MainActor [weak self] in
            guard let self, self.observedEndpoints.contains(endpoint) else { return }
            if !connected { self.disconnectionNotifications.removeValue(forKey: endpoint)?.unregister() }
            self.changed?()
        }
    }

    isolated deinit {
        connectionNotification?.unregister()
        for notification in disconnectionNotifications.values { notification.unregister() }
        for waiter in permissionWaiters.values { waiter.resume(returning: .restricted) }
    }
}
