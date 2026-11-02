import SwiftUI
import HidhoggDomain

struct WheelSettingsInspector: View {
    @EnvironmentObject private var model: AppModel

    let target: DeviceEditorTarget

    var body: some View {
        let physicalMainWheelOnly = model.selectedMouseSettingsAvailability == .physicalMainWheel
        Form {
            if physicalMainWheelOnly {
                physicalMainWheelSettings
            } else if target == .verticalWheel {
                verticalWheelSettings
            } else {
                thumbWheelSettings
            }

            Section("Device options") {
                Toggle("Restore previous settings on disconnect", isOn: Binding(
                    get: { model.restorePreviousSettingsOnDisconnect },
                    set: { model.setRestorePreviousSettingsOnDisconnect($0) }
                ))
                .disabled(!model.canEditConfiguration)

                Text(physicalMainWheelOnly
                     ? "Restore only main wheel settings changed by Hidhogg."
                     : "This restore policy is shared by both wheels and applies across all app contexts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(target.title)
    }

    private var physicalMainWheelSettings: some View {
        Section("Main wheel · all apps") {
            Picker("Direction", selection: Binding(
                get: { model.wheelPreferenceDraft },
                set: { model.setWheelPreference($0) }
            )) {
                Text("Leave unchanged").tag(Optional<Bool>.none)
                Text("Standard").tag(Optional<Bool>.some(false))
                Text("Natural").tag(Optional<Bool>.some(true))
            }
            .disabled(!model.canEditConfiguration || !model.selectedWheelInversionAvailable)

            Picker("Input resolution", selection: Binding(
                get: { model.wheelHighResolutionDraft },
                set: { model.setWheelHighResolution($0) }
            )) {
                Text("Leave unchanged").tag(Optional<Bool>.none)
                Text("Low").tag(Optional<Bool>.some(false))
                Text("High").tag(Optional<Bool>.some(true))
            }
            .disabled(!model.canEditConfiguration)

            LabeledContent("Observed direction", value: model.observedWheelDirection)
            LabeledContent("Observed resolution", value: model.observedWheelResolution)
            LabeledContent("Hidhogg change", value: model.wheelSessionChange)

            if !model.selectedWheelInversionAvailable {
                Text("Direction inversion was not advertised. Any saved direction preference is preserved but not applied.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Input resolution changes device reporting granularity. Changes save automatically; restoration follows the existing disconnect preference.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = model.selectedMouseStatus.wheel.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.selectedMouseStatus.cleanupUncertain ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var verticalWheelSettings: some View {
        Section("Scroll wheel · all apps") {
            Picker("Direction", selection: Binding(
                get: { model.wheelPreferenceDraft },
                set: { model.setWheelPreference($0) }
            )) {
                Text("Leave unchanged").tag(Optional<Bool>.none)
                Text("Standard").tag(Optional<Bool>.some(false))
                Text("Natural").tag(Optional<Bool>.some(true))
            }
            .disabled(!model.canEditConfiguration)

            Toggle("Custom scroll amount", isOn: Binding(
                get: { model.wheelScrollAmountDraft != nil },
                set: { model.setWheelScrollAmount($0 ? WheelScrollAmount.defaultSelection : nil) }
            ))
            .disabled(!model.canEditConfiguration)

            if let amount = model.wheelScrollAmountDraft {
                Slider(value: Binding(
                    get: { model.wheelScrollAmountDraft ?? WheelScrollAmount.defaultSelection },
                    set: { model.setWheelScrollAmount($0) }
                ), in: WheelScrollAmount.range, step: 0.25)
                .accessibilityLabel("Scroll wheel amount")
                .accessibilityValue(String(format: "%.2f×", amount))
                .disabled(!model.canEditConfiguration)

                LabeledContent("Scroll amount", value: String(format: "%.2f×", amount))
            }

            LabeledContent("Scroll amount state", value: model.scrollAmountStatus)

            if let message = model.selectedMouseStatus.wheel.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.selectedMouseStatus.cleanupUncertain ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Advanced details") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Input resolution", selection: Binding(
                        get: { model.wheelHighResolutionDraft },
                        set: { model.setWheelHighResolution($0) }
                    )) {
                        Text("Leave unchanged").tag(Optional<Bool>.none)
                        Text("Low").tag(Optional<Bool>.some(false))
                        Text("High").tag(Optional<Bool>.some(true))
                    }
                    .disabled(!model.canEditConfiguration)

                    LabeledContent("Observed direction", value: model.observedWheelDirection)
                    if model.selectedMouseStatus.wheel.captureActive {
                        LabeledContent("Effective direction", value: model.effectiveWheelDirection)
                    }
                    LabeledContent("Observed resolution", value: model.observedWheelResolution)
                    LabeledContent("Hidhogg change", value: model.wheelSessionChange)

                    Text("Input resolution changes device reporting granularity. Low resolution does not guarantee whole-line movement or disable application animation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text("Leave unchanged keeps the current value, or restores the previous value when restoration is enabled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }

            Text("Custom amount captures this mouse’s wheel and posts fixed line events. Applications determine how those lines move their content.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thumbWheelSettings: some View {
        Section("Thumb wheel · all apps") {
            Picker("Direction", selection: Binding(
                get: { model.thumbwheelPreferenceDraft },
                set: { model.setThumbwheelPreference($0) }
            )) {
                Text("Leave unchanged").tag(Optional<Bool>.none)
                Text("Standard").tag(Optional<Bool>.some(false))
                Text("Natural").tag(Optional<Bool>.some(true))
            }
            .disabled(!model.canEditConfiguration)

            Toggle("Custom thumb-wheel amount", isOn: Binding(
                get: { model.thumbwheelScrollAmountDraft != nil },
                set: { model.setThumbwheelScrollAmount($0 ? WheelScrollAmount.defaultSelection : nil) }
            ))
            .disabled(!model.canEditConfiguration)

            if let amount = model.thumbwheelScrollAmountDraft {
                Slider(value: Binding(
                    get: { model.thumbwheelScrollAmountDraft ?? WheelScrollAmount.defaultSelection },
                    set: { model.setThumbwheelScrollAmount($0) }
                ), in: WheelScrollAmount.range, step: 0.25)
                .accessibilityLabel("Thumb-wheel amount")
                .accessibilityValue(String(format: "%.2f×", amount))
                .disabled(!model.canEditConfiguration)

                LabeledContent("Thumb-wheel amount", value: String(format: "%.2f×", amount))
            }

            LabeledContent("Thumb-wheel amount state", value: model.thumbwheelScrollAmountStatus)

            if let message = model.selectedMouseStatus.thumbwheel.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.selectedMouseStatus.cleanupUncertain ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Advanced details") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Observed direction", value: model.observedThumbwheelDirection)
                    LabeledContent("Effective direction", value: model.effectiveThumbwheelDirection)
                    LabeledContent("Hidhogg change", value: model.thumbwheelSessionChange)

                    Text("At 1×, each reported thumb-wheel rotation count posts one line. Applications decide how far that line moves.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Text("Changes apply while connected and save automatically. Physical settings remain in place after disconnect unless the restore option above is enabled. Temporary input interception is always released.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
        }
    }
}
