import SwiftUI

struct DeviceBatteryOverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let presentation = DeviceInformationPresentation(status: model.boltStatus)

        VStack(alignment: .leading, spacing: 10) {
            if model.lowBatteryNotifications != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        batteryContent(presentation)
                            .fixedSize(horizontal: true, vertical: false)
                        lowBatteryNotificationToggle
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        batteryContent(presentation)
                        lowBatteryNotificationToggle
                    }
                }
            } else {
                batteryContent(presentation)
            }

            if presentation.isConnected, let battery = model.boltStatus.deviceInformation.battery,
               model.boltStatus.deviceInformation.batteryState == .available {
                Text("Battery read \(battery.observedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batteryContent(_ presentation: DeviceInformationPresentation) -> some View {
        LabeledContent {
            Label(presentation.batteryText, systemImage: presentation.batterySymbol)
        } label: {
            Text("Battery")
        }
        .font(.callout)
    }

    private var lowBatteryNotificationToggle: some View {
        Toggle("Notify below 10%", isOn: Binding(
            get: { model.document.draft.mouse?.lowBatteryNotificationsEnabled == true },
            set: { model.setLowBatteryNotificationsEnabled($0) }
        ))
        .toggleStyle(.checkbox)
        .font(.callout)
        .disabled(!model.canEditConfiguration || model.isRestarting)
        .help("Show a notification when the battery falls below 10%. Alerts rearm when the battery reaches 20% and are suppressed while charging.")
        .accessibilityLabel("Notify when the battery falls below 10 percent")
        .accessibilityHint("Alerts rearm when the battery reaches 20 percent and are suppressed while charging.")
    }
}
