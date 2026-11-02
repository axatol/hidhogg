import Foundation

public enum BoltFeatureSupport: Equatable, Sendable { case unknown, unsupported, supported }

public enum BoltSmartShiftMode: String, CaseIterable, Sendable { case automatic, ratchet, freeSpin }

public struct BoltHardwareSettingsPreferences: Equatable, Sendable {
    public var smartShiftMode: BoltSmartShiftMode?
    public var smartShiftThreshold: UInt8?
    public var smartShiftTorque: UInt8?
    public var dpi: UInt16?
    public var pointerSpeed: Double?
    public var hapticsEnabled: Bool?
    public var hapticIntensity: UInt8?
    public var hapticPowerSaving: Bool?
    public var forceThreshold: UInt16?

    public init(smartShiftMode: BoltSmartShiftMode? = nil, smartShiftThreshold: UInt8? = nil,
                smartShiftTorque: UInt8? = nil, dpi: UInt16? = nil, pointerSpeed: Double? = nil,
                hapticsEnabled: Bool? = nil, hapticIntensity: UInt8? = nil,
                hapticPowerSaving: Bool? = nil, forceThreshold: UInt16? = nil) {
        self.smartShiftMode = smartShiftMode
        self.smartShiftThreshold = smartShiftThreshold
        self.smartShiftTorque = smartShiftTorque
        self.dpi = dpi
        self.pointerSpeed = pointerSpeed
        self.hapticsEnabled = hapticsEnabled
        self.hapticIntensity = hapticIntensity
        self.hapticPowerSaving = hapticPowerSaving
        self.forceThreshold = forceThreshold
    }
}

public struct BoltSmartShiftStatus: Equatable, Sendable {
    public var support: BoltFeatureSupport = .unknown
    public var mode: BoltSmartShiftMode?
    public var threshold: UInt8?
    public var defaultThreshold: UInt8?
    public var torque: UInt8?
    public var supportsTorque = false
    public var maximumTorque: UInt8?
    public var isOwned = false
    public var message: String?
    public init() {}
}

public struct BoltDPIStatus: Equatable, Sendable {
    public var support: BoltFeatureSupport = .unknown
    public var canWrite = false
    public var sensorCount: UInt8?
    public var sensor: UInt8?
    public var current: UInt16?
    public var defaultDPI: UInt16?
    public var values: [UInt16] = []
    public var isOwned = false
    public var message: String?
    public init() {}
}

public struct BoltPointerSpeedStatus: Equatable, Sendable {
    public var support: BoltFeatureSupport = .unknown
    public var current: Double?
    public var isOwned = false
    public var message: String?
    public init() {}
}

public struct BoltHapticStatus: Equatable, Sendable {
    public var support: BoltFeatureSupport = .unknown
    public var enabled: Bool?
    public var intensity: UInt8?
    public var powerSaving: Bool?
    public var intensityStep: UInt8?
    public var intensityCount: UInt8?
    public var supportedWaveforms: [UInt8] = []
    public var rawEngineStatus: UInt8?
    public var isOwned = false
    public var message: String?
    public init() {}
}

public struct BoltForceButtonStatus: Equatable, Sendable {
    public var support: BoltFeatureSupport = .unknown
    public var threshold: UInt16?
    public var defaultThreshold: UInt16?
    public var minimum: UInt16?
    public var maximum: UInt16?
    public var isOwned = false
    public var message: String?
    public init() {}
}

public struct BoltHardwareSettingsStatus: Equatable, Sendable {
    public var smartShift = BoltSmartShiftStatus()
    public var dpi = BoltDPIStatus()
    public var pointerSpeed = BoltPointerSpeedStatus()
    public var haptics = BoltHapticStatus()
    public var forceButton = BoltForceButtonStatus()
    public var isApplying = false
    public var message: String?
    public init() {}
}
