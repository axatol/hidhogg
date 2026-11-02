import HidhoggDomain
import LogitechBolt

extension BoltHardwareSettingsPreferences {
    init(_ preferences: MouseHardwarePreferences) {
        self.init(
            smartShiftMode: preferences.smartShiftMode.flatMap { BoltSmartShiftMode(rawValue: $0.rawValue) },
            smartShiftThreshold: preferences.smartShiftThreshold,
            smartShiftTorque: preferences.smartShiftTorque,
            dpi: preferences.dpi,
            pointerSpeed: preferences.pointerSpeed,
            hapticsEnabled: preferences.hapticsEnabled,
            hapticIntensity: preferences.hapticIntensity,
            hapticPowerSaving: preferences.hapticPowerSaving,
            forceThreshold: preferences.forceThreshold
        )
    }
}
