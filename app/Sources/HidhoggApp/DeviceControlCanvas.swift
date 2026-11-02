import SwiftUI
import HidhoggDomain

struct DeviceControlCanvas: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isInspectorPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedMouseName)
                    .font(.headline)
                Text("Select a wheel or side button to open its settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.selectedMouseID.flatMap({ model.registration(id: $0)?.mouseModel }) != .mxMaster4 {
                MXMasterMousePresentation(
                    selectedTarget: model.selectedTarget,
                    onSelect: selectTarget
                )
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 10) {
                if model.selectedMouseID.flatMap({ model.registration(id: $0)?.mouseModel }) == .mxMaster4 {
                    Button("Scroll wheel") { selectTarget(.verticalWheel) }
                    Button("Thumbwheel") { selectTarget(.thumbWheel) }
                        .disabled(!model.selectedMouseStatus.supportsThumbwheelManagement)
                }
                ForEach(MouseControl.allCases, id: \.self) { control in
                    if control != .back && control != .forward || model.selectedMouseID.flatMap({ model.registration(id: $0)?.mouseModel }) == .mxMaster4 {
                        Button(control.title) { selectTarget(DeviceEditorTarget(rawValue: control.rawValue) ?? .back) }
                            .disabled(!model.selectedMouseStatus.availableControls.contains(control))
                    }
                }
            }

        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func selectTarget(_ target: DeviceEditorTarget) {
        model.selectTarget(target)
        isInspectorPresented = true
    }
}
