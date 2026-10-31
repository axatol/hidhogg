import Foundation

public enum DeviceFamily: String, Codable, CaseIterable, Sendable {
    case mxMaster3S = "logitech.mx-master-3s"
    case d200x = "ulanzi.d200x"
    case flowLite84 = "lofree.flow-lite84"

    public var title: String {
        switch self {
        case .mxMaster3S: "MX Master 3S"
        case .d200x: "D200X"
        case .flowLite84: "Flow Lite84"
        }
    }
}

public enum RegisteredDeviceConfiguration: Equatable, Sendable {
    case mouse(DeviceBindings)
    case d200x(D200XConfiguration?)
    case flowLite84

    public var family: DeviceFamily {
        switch self {
        case .mouse: .mxMaster3S
        case .d200x: .d200x
        case .flowLite84: .flowLite84
        }
    }
}

public struct RegisteredDevice: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var isEnabled: Bool
    public var configuration: RegisteredDeviceConfiguration
    public var family: DeviceFamily { configuration.family }

    public init(id: UUID = UUID(), displayName: String? = nil, isEnabled: Bool = true,
                configuration: RegisteredDeviceConfiguration) {
        self.id = id
        self.displayName = displayName ?? configuration.family.title
        self.isEnabled = isEnabled
        self.configuration = configuration
    }

    public static func make(family: DeviceFamily) -> Self {
        let configuration: RegisteredDeviceConfiguration = switch family {
        case .mxMaster3S: .mouse(AppConfiguration.defaultConfiguration.devices[0])
        case .d200x: .d200x(nil)
        case .flowLite84: .flowLite84
        }
        return Self(configuration: configuration)
    }
}

public struct WorkspaceConfiguration: Equatable, Sendable {
    public static let currentVersion = 2
    public var connectOnLaunch: Bool
    public var devices: [RegisteredDevice]

    public init(connectOnLaunch: Bool = true, devices: [RegisteredDevice]) {
        self.connectOnLaunch = connectOnLaunch
        self.devices = devices
    }

    public init(legacy: AppConfiguration) {
        connectOnLaunch = legacy.connectOnLaunch
        devices = [
            RegisteredDevice(configuration: .mouse(legacy.mouse ?? AppConfiguration.empty.devices[0])),
            RegisteredDevice(configuration: .d200x(legacy.d200x)),
            RegisteredDevice(configuration: .flowLite84)
        ]
    }

    public var configuration: AppConfiguration {
        var projection = AppConfiguration.defaultConfiguration
        projection.connectOnLaunch = connectOnLaunch
        for device in devices {
            switch device.configuration {
            case .mouse(let mouse): projection.devices = [mouse]
            case .d200x(let deck): projection.d200x = deck
            case .flowLite84: break
            }
        }
        return projection
    }

    public func applying(_ configuration: AppConfiguration) -> Self {
        var next = self
        next.connectOnLaunch = configuration.connectOnLaunch
        for index in next.devices.indices {
            switch next.devices[index].configuration {
            case .mouse:
                if let mouse = configuration.mouse { next.devices[index].configuration = .mouse(mouse) }
            case .d200x: next.devices[index].configuration = .d200x(configuration.d200x)
            case .flowLite84: break
            }
        }
        return next
    }

    public func validated() throws -> Self {
        guard devices.count <= DeviceFamily.allCases.count,
              Set(devices.map(\.id)).count == devices.count,
              Set(devices.map(\.family)).count == devices.count else {
            throw ConfigurationValidationError.invalidRegistry
        }
        for device in devices {
            guard !device.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  device.displayName.utf8.count <= 128,
                  !device.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ConfigurationValidationError.invalidRegistry
            }
            switch device.configuration {
            case .mouse(let mouse): _ = try AppConfiguration(devices: [mouse]).validated()
            case .d200x(let deck): _ = try deck?.validated()
            case .flowLite84: break
            }
        }
        return self
    }
}
