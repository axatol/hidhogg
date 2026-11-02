import Foundation

public enum DeviceFamily: String, Codable, CaseIterable, Sendable {
    case mxMaster3S = "logitech.mx-master-3s"
    case mxMaster4 = "logitech.mx-master-4"
    case d200x = "ulanzi.d200x"
    case flowLite84 = "lofree.flow-lite84"
    case genericBluetooth = "bluetooth.generic"

    public var title: String {
        switch self {
        case .mxMaster3S: "MX Master 3S"
        case .mxMaster4: "MX Master 4"
        case .d200x: "D200X"
        case .flowLite84: "Flow Lite84"
        case .genericBluetooth: "Bluetooth Device"
        }
    }

    public var isLogitechMouse: Bool {
        self == .mxMaster3S || self == .mxMaster4
    }
}

public enum RegisteredDeviceConfiguration: Equatable, Sendable {
    case mouse(DeviceBindings)
    case d200x(D200XConfiguration?)
    case flowLite84
    case genericBluetooth(GenericBluetoothConfiguration)

    public static func genericBluetooth(_ endpoint: BluetoothEndpoint) -> Self {
        .genericBluetooth(GenericBluetoothConfiguration(endpoint: endpoint))
    }

    public var family: DeviceFamily {
        switch self {
        case .mouse: .mxMaster3S
        case .d200x: .d200x
        case .flowLite84: .flowLite84
        case .genericBluetooth: .genericBluetooth
        }
    }
}

public struct RegisteredDevice: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var isEnabled: Bool
    public var configuration: RegisteredDeviceConfiguration
    public var mouseModel: LogitechMouseModel?
    public var logitechAssociation: LogitechAssociation?
    public var family: DeviceFamily {
        guard case .mouse = configuration else { return configuration.family }
        return mouseModel?.family ?? .mxMaster3S
    }
    public var bluetoothConfiguration: GenericBluetoothConfiguration? {
        guard case .genericBluetooth(let configuration) = configuration else { return nil }
        return configuration
    }

    public init(id: UUID = UUID(), displayName: String? = nil, isEnabled: Bool = true,
                configuration: RegisteredDeviceConfiguration, mouseModel: LogitechMouseModel? = nil,
                logitechAssociation: LogitechAssociation? = nil) {
        let resolvedMouseModel: LogitechMouseModel?
        if case .mouse = configuration {
            resolvedMouseModel = mouseModel ?? .mxMaster3S
        } else {
            resolvedMouseModel = mouseModel
        }
        self.id = id
        self.displayName = displayName ?? (resolvedMouseModel?.family ?? configuration.family).title
        self.isEnabled = isEnabled
        self.configuration = configuration
        self.mouseModel = resolvedMouseModel
        self.logitechAssociation = logitechAssociation
    }

    public static func make(family: DeviceFamily) -> Self? {
        let configuration: RegisteredDeviceConfiguration? = switch family {
        case .mxMaster3S: .mouse(AppConfiguration.defaultConfiguration.devices[0])
        case .mxMaster4: .mouse(AppConfiguration.defaultConfiguration.devices[0])
        case .d200x: .d200x(nil)
        case .flowLite84: .flowLite84
        case .genericBluetooth: nil
        }
        guard let configuration else { return nil }
        let mouseModel: LogitechMouseModel? = switch family {
        case .mxMaster3S: .mxMaster3S
        case .mxMaster4: .mxMaster4
        case .d200x, .flowLite84, .genericBluetooth: nil
        }
        return Self(configuration: configuration, mouseModel: mouseModel)
    }
}

public struct WorkspaceConfiguration: Equatable, Sendable {
    public static let currentVersion = 2
    public var connectOnLaunch: Bool
    public var devices: [RegisteredDevice]
    public var preferredMouseID: UUID?

    public init(connectOnLaunch: Bool = true, devices: [RegisteredDevice], preferredMouseID: UUID? = nil) {
        self.connectOnLaunch = connectOnLaunch
        self.devices = devices
        self.preferredMouseID = preferredMouseID
    }

    public init(legacy: AppConfiguration) {
        connectOnLaunch = legacy.connectOnLaunch
        preferredMouseID = nil
        devices = [
            RegisteredDevice(configuration: .mouse(legacy.mouse ?? AppConfiguration.empty.devices[0])),
            RegisteredDevice(configuration: .d200x(legacy.d200x)),
            RegisteredDevice(configuration: .flowLite84)
        ]
    }

    public var configuration: AppConfiguration {
        let mouseRegistrations = devices.compactMap { device -> RegisteredDevice? in
            guard case .mouse = device.configuration else { return nil }
            return device
        }
        let mouse: DeviceBindings?
        switch mouseRegistrations.count {
        case 0: mouse = AppConfiguration.defaultConfiguration.mouse
        case 1: mouse = configuration(forMouseID: preferredMouseID ?? mouseRegistrations[0].id).mouse
        default: mouse = preferredMouseID.flatMap { configuration(forMouseID: $0).mouse }
        }

        return projectedConfiguration(mouse: mouse)
    }

    public func configuration(forMouseID mouseID: UUID?) -> AppConfiguration {
        let mouse: DeviceBindings? = mouseID.flatMap { id -> DeviceBindings? in
            guard let index = uniqueRegistrationIndex(for: id),
                  case .mouse(let mouse) = devices[index].configuration else {
                return nil
            }
            return mouse
        }
        return projectedConfiguration(mouse: mouse)
    }

    public func applying(_ configuration: AppConfiguration) -> Self {
        let mouseRegistrations = devices.filter { device in
            if case .mouse = device.configuration { return true }
            return false
        }
        let mouseID = preferredMouseID ?? (mouseRegistrations.count == 1 ? mouseRegistrations[0].id : nil)
        return applying(configuration, mouseID: mouseID)
    }

    public func applying(_ configuration: AppConfiguration, mouseID: UUID?) -> Self {
        var next = self
        next.connectOnLaunch = configuration.connectOnLaunch
        for index in next.devices.indices {
            switch next.devices[index].configuration {
            case .d200x: next.devices[index].configuration = .d200x(configuration.d200x)
            case .mouse, .flowLite84, .genericBluetooth: break
            }
        }

        if let mouseID,
           let index = next.uniqueRegistrationIndex(for: mouseID),
           case .mouse = next.devices[index].configuration,
           let mouse = configuration.mouse {
            next.devices[index].configuration = .mouse(mouse)
        }

        return next
    }

    public func validated() throws -> Self {
        let singletonNativeFamilies = devices.map(\.family).filter { !$0.isLogitechMouse && $0 != .genericBluetooth }
        let endpoints = devices.compactMap { device -> BluetoothEndpoint? in
            if case .genericBluetooth(let configuration) = device.configuration { return configuration.endpoint }
            return nil
        }
        guard devices.count <= 256,
              Set(devices.map(\.id)).count == devices.count,
              Set(singletonNativeFamilies).count == singletonNativeFamilies.count,
              Set(endpoints).count == endpoints.count else {
            throw ConfigurationValidationError.invalidRegistry
        }
        if let preferredMouseID {
            guard let index = uniqueRegistrationIndex(for: preferredMouseID),
                  case .mouse = devices[index].configuration else {
                throw ConfigurationValidationError.invalidRegistry
            }
        }
        var enabledMouseIdentities: [LogitechIdentity] = []
        for device in devices {
            guard !device.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  device.displayName.utf8.count <= 128,
                  !device.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ConfigurationValidationError.invalidRegistry
            }
            switch device.configuration {
            case .mouse(let mouse):
                _ = try AppConfiguration(devices: [mouse]).validated()
                if let association = device.logitechAssociation {
                    _ = try association.validated()
                    if device.isEnabled {
                        guard !enabledMouseIdentities.contains(association.identity) else {
                            throw ConfigurationValidationError.invalidRegistry
                        }
                        enabledMouseIdentities.append(association.identity)
                    }
                }
            case .d200x(let deck): _ = try deck?.validated()
            case .genericBluetooth(let configuration):
                guard (1...100).contains(configuration.lowBatteryThreshold) else {
                    throw ConfigurationValidationError.invalidRegistry
                }
            case .flowLite84: break
            }
            if case .mouse = device.configuration {
                continue
            }
            guard device.mouseModel == nil, device.logitechAssociation == nil else {
                throw ConfigurationValidationError.invalidRegistry
            }
        }
        return self
    }

    private func projectedConfiguration(mouse: DeviceBindings?) -> AppConfiguration {
        var projection = AppConfiguration(devices: mouse.map { [$0] } ?? [], connectOnLaunch: connectOnLaunch)
        for device in devices {
            if case .d200x(let deck) = device.configuration {
                projection.d200x = deck
            }
        }
        return projection
    }

    private func uniqueRegistrationIndex(for id: UUID) -> Int? {
        let indices = devices.indices.filter { devices[$0].id == id }
        guard indices.count == 1 else { return nil }
        return indices[0]
    }
}
