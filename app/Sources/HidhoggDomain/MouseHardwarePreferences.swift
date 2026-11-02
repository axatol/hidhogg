import Foundation

public enum MouseSmartShiftMode: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case ratchet
    case freeSpin
}

public enum MousePointerSpeed {
    /// Accepted 8.8 client-policy range; actual feature support remains device-specific.
    public static let range = (46.0 / 256.0)...(511.0 / 256.0)

    public static func contains(_ value: Double) -> Bool {
        value.isFinite && range.contains(value)
    }
}

public struct MouseHardwarePreferences: Codable, Equatable, Sendable {
    public var smartShiftMode: MouseSmartShiftMode?
    public var smartShiftThreshold: UInt8?
    public var smartShiftTorque: UInt8?
    public var dpi: UInt16?
    public var pointerSpeed: Double?
    public var hapticsEnabled: Bool?
    public var hapticIntensity: UInt8?
    public var hapticPowerSaving: Bool?
    public var forceThreshold: UInt16?

    public init(
        smartShiftMode: MouseSmartShiftMode? = nil,
        smartShiftThreshold: UInt8? = nil,
        smartShiftTorque: UInt8? = nil,
        dpi: UInt16? = nil,
        pointerSpeed: Double? = nil,
        hapticsEnabled: Bool? = nil,
        hapticIntensity: UInt8? = nil,
        hapticPowerSaving: Bool? = nil,
        forceThreshold: UInt16? = nil
    ) {
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

    public func validated() throws -> Self {
        guard smartShiftThreshold.map({ $0 > 0 }) ?? true,
              smartShiftMode != .automatic || smartShiftThreshold != UInt8.max,
              smartShiftTorque.map({ (1...100).contains($0) }) ?? true,
              dpi.map({ $0 > 0 }) ?? true,
              pointerSpeed.map(MousePointerSpeed.contains) ?? true,
              hapticIntensity.map({ $0 <= 100 }) ?? true else {
            throw ConfigurationValidationError.invalidMouseHardwarePreferences
        }
        return self
    }
}
