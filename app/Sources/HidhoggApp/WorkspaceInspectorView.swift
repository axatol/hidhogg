import SwiftUI

struct WorkspaceInspectorView: View {
    let route: WorkspaceRoute
    @ObservedObject var d200xModel: D200XModel

    var body: some View {
        Group {
            switch route {
            case .devices, .mouse:
                DeviceInspectorView()
            case .d200x:
                ScrollView {
                    D200XControlInspectorView(model: d200xModel)
                }
            case .logitechSetup, .flowLite, .genericBluetooth, .actions, .notifications, .tilePresets, .settings:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}
