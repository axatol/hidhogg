import SwiftUI
import HidhoggDomain

struct WheelSettingsInspector: View {
    @EnvironmentObject private var model: AppModel

    let target: DeviceEditorTarget

    var body: some View {
        Form {
            if target == .verticalWheel {
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

                Text("This restore policy is shared by both wheels and applies across all app contexts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(target.title)
    }

    private var verticalWheelSettings: some View {
        Section("Vertical wheel · all apps") {
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
                .accessibilityLabel("Vertical wheel amount")
                .accessibilityValue(String(format: "%.2f×", amount))
                .disabled(!model.canEditConfiguration)

                LabeledContent("Vertical amount", value: String(format: "%.2f×", amount))
            }

            LabeledContent("Scroll amount state", value: model.scrollAmountStatus)

            if let message = model.boltStatus.wheel.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.boltStatus.cleanupUncertain ? .orange : .secondary)
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
                    if model.boltStatus.wheel.captureActive {
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

            if let message = model.boltStatus.thumbwheel.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.boltStatus.cleanupUncertain ? .orange : .secondary)
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
