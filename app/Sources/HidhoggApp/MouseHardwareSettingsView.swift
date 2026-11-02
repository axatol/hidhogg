import SwiftUI
import HidhoggDomain
import LogitechBolt

struct MouseHardwareSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var status: BoltHardwareSettingsStatus { model.mouseHardwareStatus }
    private var preferences: MouseHardwarePreferences { model.mouseHardwarePreferences }

    private var isMX4: Bool {
        guard let id = model.selectedMouseID else { return false }
        return model.registration(id: id)?.mouseModel == .mxMaster4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Mouse settings").font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshMouseHardwareSettings() }
                    .disabled(!model.canChangeMouseHardware || status.isApplying)
            }
            pointerSettings
            scrollSettings
            smartShiftSettings
            if isMX4 {
                hapticSettings
                forceSettings
            }
            GroupBox("On disconnect") {
                Toggle("Restore previous mouse settings", isOn: Binding(
                    get: { model.restorePreviousSettingsOnDisconnect },
                    set: { model.setRestorePreviousSettingsOnDisconnect($0) }
                ))
                .disabled(!model.canEditConfiguration)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardContentPadding()
            }
            if let message = status.message {
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Settings apply after a brief pause and save automatically. Each control uses the capabilities reported by this mouse.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedDPI: UInt16 {
        if let saved = preferences.dpi, status.dpi.values.contains(saved) { return saved }
        return status.dpi.current ?? status.dpi.values.first ?? 0
    }

    private func setDPIIndex(_ value: Double) {
        let values = status.dpi.values
        guard model.canChangeMouseHardware, value.isFinite, !values.isEmpty else { return }
        let index = Int(min(Double(values.count - 1), max(0, value)).rounded())
        model.setMouseHardwarePreference(\.dpi, Optional(values[index]))
    }

    private var pointerSettings: some View {
        GroupBox("Point") {
            VStack(alignment: .leading, spacing: 14) {
                if status.pointerSpeed.support == .supported {
                    speedSlider
                } else {
                    availability("Pointer speed", support: status.pointerSpeed.support, message: "Not available yet")
                }
                if status.dpi.support == .supported, !status.dpi.values.isEmpty {
                    LabeledContent("Sensor DPI", value: selectedDPI.formatted())
                    if status.dpi.values.count > 1 {
                        Slider(value: Binding(
                            get: { Double(status.dpi.values.firstIndex(of: selectedDPI) ?? 0) },
                            set: setDPIIndex
                        ), in: 0...Double(status.dpi.values.count - 1), step: 1) {
                            Text("Sensor DPI")
                        } minimumValueLabel: { Text(status.dpi.values[0].formatted()) }
                          maximumValueLabel: { Text(status.dpi.values[status.dpi.values.count - 1].formatted()) }
                        .labelsHidden()
                        .accessibilityLabel("Sensor DPI")
                        .accessibilityValue("\(selectedDPI) DPI")
                        .disabled(!model.canChangeMouseHardware || !status.dpi.canWrite)
                    }
                    featureMessage(status.dpi.message)
                    if let saved = preferences.dpi, !status.dpi.values.contains(saved) {
                        Text("Saved DPI \(saved) is unavailable on this connection. Choose a supported value.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let current = status.dpi.current, preferences.dpi != nil, preferences.dpi != current {
                        LabeledContent("Current DPI", value: current.formatted())
                    }
                    Text("DPI controls sensor resolution. Pointer speed is adjusted independently.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    availability("Sensor DPI", support: status.dpi.support, message: status.dpi.message)
                }
            }
            .cardContentPadding()
        }
    }

    private var speedSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Pointer speed", value: ((preferences.pointerSpeed ?? status.pointerSpeed.current ?? 1) * 100).formatted(.number.precision(.fractionLength(0))) + "%")
            Slider(value: Binding(
                get: { min(MousePointerSpeed.range.upperBound, max(MousePointerSpeed.range.lowerBound, preferences.pointerSpeed ?? status.pointerSpeed.current ?? 1)) },
                set: { model.setMouseHardwarePreference(\.pointerSpeed, Optional($0)) }
            ), in: MousePointerSpeed.range, step: 1.0 / 256) {
                Text("Pointer speed")
            } minimumValueLabel: { Text("Slower") } maximumValueLabel: { Text("Faster") }
            .labelsHidden()
            .accessibilityLabel("Pointer speed")
            .disabled(!model.canChangeMouseHardware)
            featureMessage(status.pointerSpeed.message)
        }
    }

    private var scrollSettings: some View {
        GroupBox("Scroll") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Vertical direction", selection: Binding(
                    get: { model.wheelPreferenceDraft ?? false }, set: { model.setWheelPreference($0) }
                )) {
                    Text("Standard").tag(false)
                    Text("Natural").tag(true)
                }
                .disabled(!model.canEditConfiguration || !model.selectedWheelInversionAvailable)
                Picker("Thumbwheel direction", selection: Binding(
                    get: { model.thumbwheelPreferenceDraft ?? true }, set: { model.setThumbwheelPreference($0) }
                )) {
                    Text("Standard").tag(false)
                    Text("Natural").tag(true)
                }
                .disabled(!model.canEditConfiguration || model.selectedMouseStatus.thumbwheel.support != .supported)
                Text("Directions always follow these settings when connected. Scroll speed and advanced reporting options are in the wheel inspector.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .cardContentPadding()
        }
    }

    private var smartShiftSettings: some View {
        GroupBox("Wheel feel") {
            VStack(alignment: .leading, spacing: 14) {
                if status.smartShift.support == .supported {
                    Picker("Wheel mode", selection: Binding(
                        get: { preferences.smartShiftMode ?? MouseSmartShiftMode(rawValue: status.smartShift.mode?.rawValue ?? "ratchet") ?? .ratchet },
                        set: { model.setSmartShiftMode($0) }
                    )) {
                        Text("SmartShift").tag(MouseSmartShiftMode.automatic)
                        Text("Ratchet").tag(MouseSmartShiftMode.ratchet)
                        Text("Free-spin").tag(MouseSmartShiftMode.freeSpin)
                    }
                    .disabled(!model.canChangeMouseHardware)
                    if (preferences.smartShiftMode?.rawValue ?? status.smartShift.mode?.rawValue) == "automatic" {
                        Slider(value: Binding(
                            get: { Double(min(254, max(1, preferences.smartShiftThreshold ?? status.smartShift.threshold ?? 10))) },
                            set: { model.setMouseHardwarePreference(\.smartShiftThreshold, Optional(UInt8($0.rounded()))) }
                        ), in: 1...254, step: 1) {
                            Text("Switching speed")
                        } minimumValueLabel: { Text("Lower") } maximumValueLabel: { Text("Higher") }
                        .disabled(!model.canChangeMouseHardware)
                        Text("Lower switching speeds enter free-spin more easily.").font(.callout).foregroundStyle(.secondary)
                    }
                    if status.smartShift.supportsTorque, let maximum = status.smartShift.maximumTorque, maximum > 1 {
                        Slider(value: Binding(
                            get: { Double(min(maximum, max(1, preferences.smartShiftTorque ?? status.smartShift.torque ?? 1))) },
                            set: { model.setMouseHardwarePreference(\.smartShiftTorque, Optional(UInt8($0.rounded()))) }
                        ), in: 1...Double(maximum), step: 1) {
                            Text("Scroll force")
                        } minimumValueLabel: { Text("Lighter") } maximumValueLabel: { Text("Firmer") }
                        .disabled(!model.canChangeMouseHardware)
                    }
                    if let saved = preferences.smartShiftTorque, let maximum = status.smartShift.maximumTorque, saved > maximum {
                        Text("Saved scroll force exceeds this mouse’s range.").font(.callout).foregroundStyle(.secondary)
                    }
                    featureMessage(status.smartShift.message)
                } else {
                    availability("SmartShift", support: status.smartShift.support, message: status.smartShift.message)
                }
            }
            .cardContentPadding()
        }
    }

    private var hapticSettings: some View {
        GroupBox("Haptic feedback") {
            VStack(alignment: .leading, spacing: 14) {
                if status.haptics.support == .supported {
                    Toggle("Haptic feedback", isOn: Binding(
                        get: { preferences.hapticsEnabled ?? status.haptics.enabled ?? false },
                        set: { model.setMouseHardwarePreference(\.hapticsEnabled, Optional($0)) }
                    ))
                    .disabled(!model.canChangeMouseHardware)
                    Slider(value: Binding(
                        get: { Double(preferences.hapticIntensity ?? status.haptics.intensity ?? 0) },
                        set: { model.setMouseHardwarePreference(\.hapticIntensity, Optional(UInt8($0.rounded()))) }
                    ), in: 0...100, step: Double(max(1, status.haptics.intensityStep ?? 1))) {
                        Text("Intensity")
                    } minimumValueLabel: { Text("Gentler") } maximumValueLabel: { Text("Stronger") }
                    .disabled(!model.canChangeMouseHardware)
                    Toggle("Reduce feedback at low battery", isOn: Binding(
                        get: { preferences.hapticPowerSaving ?? status.haptics.powerSaving ?? false },
                        set: { model.setMouseHardwarePreference(\.hapticPowerSaving, Optional($0)) }
                    ))
                    .disabled(!model.canChangeMouseHardware)
                    if let intensity = status.haptics.intensity {
                        LabeledContent("Current intensity", value: "\(intensity)%")
                    }
                    Button("Test feedback", systemImage: "waveform") { model.testMouseHaptics() }
                        .disabled(!model.canChangeMouseHardware || status.isApplying || status.haptics.enabled != true || status.haptics.rawEngineStatus != 0 || status.haptics.supportedWaveforms.isEmpty)
                    featureMessage(status.haptics.message)
                } else {
                    availability("Haptic feedback", support: status.haptics.support, message: status.haptics.message)
                }
            }
            .cardContentPadding()
        }
    }

    private var forceSettings: some View {
        GroupBox("Thumb panel") {
            VStack(alignment: .leading, spacing: 14) {
                if status.forceButton.support == .supported,
                   let minimum = status.forceButton.minimum, let maximum = status.forceButton.maximum, minimum < maximum {
                    Slider(value: Binding(
                        get: { Double(min(maximum, max(minimum, preferences.forceThreshold ?? status.forceButton.threshold ?? minimum))) },
                        set: { model.setMouseHardwarePreference(\.forceThreshold, Optional(UInt16($0.rounded()))) }
                    ), in: Double(minimum)...Double(maximum)) {
                        Text("Press pressure")
                    } minimumValueLabel: { Text("Lighter") } maximumValueLabel: { Text("Firmer") }
                    .disabled(!model.canChangeMouseHardware)
                    Text("Adjust the pressure required to activate the panel. This is separate from haptic intensity.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let saved = preferences.forceThreshold, !(minimum...maximum).contains(saved) {
                        Text("Saved press pressure is outside this mouse’s range.").font(.callout).foregroundStyle(.secondary)
                    }
                    featureMessage(status.forceButton.message)
                } else {
                    availability("Press pressure", support: status.forceButton.support, message: status.forceButton.message)
                }
            }
            .cardContentPadding()
        }
    }

    private func availability(_ title: String, support: BoltFeatureSupport, message: String?) -> some View {
        LabeledContent(title) {
            Text(message ?? (support == .unsupported ? "Not supported by this mouse" : "Connect or refresh to check availability"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func featureMessage(_ message: String?) -> some View {
        if let message {
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
