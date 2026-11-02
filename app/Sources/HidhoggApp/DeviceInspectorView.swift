import SwiftUI

struct DeviceInspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.selectedMouseSettingsAvailability {
            case .managed:
                if model.selectedTarget.control != nil {
                    ControlBindingInspector(control: model.selectedControl)
                } else {
                    WheelSettingsInspector(target: model.selectedTarget)
                }
            case .physicalMainWheel:
                WheelSettingsInspector(target: .verticalWheel)
            case .informationOnly:
                ContentUnavailableView(
                    "Settings unavailable",
                    systemImage: "computermouse",
                    description: Text("\(model.selectedDeviceCapabilitySummary). Device information remains available in the workspace.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}
