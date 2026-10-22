import Foundation

public struct BoltDeviceInformation: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case unknown, loading, available, unsupported, unavailable
    }

    public enum Charging: Equatable, Sendable {
        case discharging, charging, slowCharging, complete, error
        case unknown(UInt8)
    }

    public struct Battery: Equatable, Sendable {
        public let percentage: Int?
        public let charging: Charging
        public let observedAt: Date

        public init(percentage: Int?, charging: Charging, observedAt: Date) {
            self.percentage = percentage
            self.charging = charging
            self.observedAt = observedAt
        }
    }

    public struct FirmwareEntity: Equatable, Sendable {
        public let type: UInt8
        public let prefix: String
        public let rawVersion: UInt16
        public let rawBuild: UInt16
        public let flags: UInt8
        public let hardwareRevision: UInt8?

        public init(type: UInt8, prefix: String, rawVersion: UInt16, rawBuild: UInt16, flags: UInt8,
                    hardwareRevision: UInt8? = nil) {
            self.type = type
            self.prefix = prefix
            self.rawVersion = rawVersion
            self.rawBuild = rawBuild
            self.flags = flags
            self.hardwareRevision = hardwareRevision
        }
    }

    public var batteryState: State
    public var firmwareState: State
    public var battery: Battery?
    public var firmware: [FirmwareEntity]
    public var isRefreshing: Bool

    public init(batteryState: State = .unknown, firmwareState: State = .unknown,
                battery: Battery? = nil, firmware: [FirmwareEntity] = [], isRefreshing: Bool = false) {
        self.batteryState = batteryState
        self.firmwareState = firmwareState
        self.battery = battery
        self.firmware = firmware
        self.isRefreshing = isRefreshing
    }
}

enum BoltDeviceInformationRequestError: Error {
    case protocolRejected
}

enum BoltDeviceInformationReader {
    struct BatteryCapabilities: Equatable, Sendable {
        let supportsPercentage: Bool

        init(_ payload: [UInt8]) throws {
            guard payload.count >= 2 else { throw BoltFailure.malformed }
            supportsPercentage = payload[1] & 0x02 != 0
        }
    }

    static func featureIndex(_ payload: [UInt8]) throws -> UInt8 {
        guard payload.count >= 3 else { throw BoltFailure.malformed }
        guard payload[0] != 0 else { throw BoltFailure.unsupported }
        return payload[0]
    }

    static func battery(_ payload: [UInt8], capabilities: BatteryCapabilities,
                        observedAt: Date = .now) throws -> BoltDeviceInformation.Battery {
        guard payload.count >= 4 else { throw BoltFailure.malformed }
        guard !capabilities.supportsPercentage || payload[0] <= 100 else { throw BoltFailure.malformed }
        let charging: BoltDeviceInformation.Charging = switch payload[2] {
        case 0: .discharging
        case 1: .charging
        case 2: .slowCharging
        case 3: .complete
        case 4: .error
        case let value: .unknown(value)
        }
        return .init(percentage: capabilities.supportsPercentage ? Int(payload[0]) : nil,
                     charging: charging, observedAt: observedAt)
    }

    static func firmwareCount(_ payload: [UInt8]) throws -> UInt8 {
        guard payload.count >= 15, payload[0] <= 8 else { throw BoltFailure.malformed }
        return payload[0]
    }

    static func firmwareEntity(_ payload: [UInt8]) throws -> BoltDeviceInformation.FirmwareEntity {
        guard payload.count >= 16 else { throw BoltFailure.malformed }
        let type = payload[0]
        let prefix = String(decoding: payload[1...3].map { (0x20...0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self)
        let hardwareRevision = type & 0x0F == 2 ? payload[1] : nil
        return .init(type: type, prefix: prefix, rawVersion: BoltWire.word(payload, 4),
                     rawBuild: BoltWire.word(payload, 6), flags: payload[8], hardwareRevision: hardwareRevision)
    }
}
