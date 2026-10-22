import SwiftUI

struct DeviceControlCanvas: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isInspectorPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MX Master 3S")
                    .font(.headline)
                Text("Select a wheel or side button to open its settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MXMasterMousePresentation(
                selectedTarget: model.selectedTarget,
                onSelect: selectTarget
            )
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
