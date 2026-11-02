import SwiftUI

struct DeviceInspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !model.selectedMouseSupportsManagement {
                ContentUnavailableView("Controls unsupported", systemImage: "computermouse",
                                       description: Text("Basic device information is available in the device workspace."))
            } else if model.selectedTarget.control != nil {
                ControlBindingInspector(control: model.selectedControl)
            } else {
                WheelSettingsInspector(target: model.selectedTarget)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}
