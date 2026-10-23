import SwiftUI

struct D200XDeviceView: View {
    @ObservedObject var model: D200XModel
    @Binding private var isInspectorPresented: Bool

    init(model: D200XModel, isInspectorPresented: Binding<Bool> = .constant(true)) {
        self._model = ObservedObject(wrappedValue: model)
        self._isInspectorPresented = isInspectorPresented
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                deviceHeader

                D200XApplicationSelectorView(model: model)
                deckCanvas

                if let firmware = model.firmware {
                    GroupBox("Firmware") {
                        LabeledContent("Version", value: firmware)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
        .navigationTitle("Ulanzi D200X")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(
                        isInspectorPresented ? "Hide Control Settings" : "Show Control Settings",
                        systemImage: "slider.horizontal.3"
                    )
                }
                .help(isInspectorPresented ? "Hide control settings" : "Show control settings")
            }
        }
    }

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(AppAppearance.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ulanzi D200X")
                        .font(.title2.weight(.semibold))

                    Text(model.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                connectionAction
            }

            LabeledContent("Connection", value: model.connectionTitle)
                .font(.callout)

            if let configurationBlocker = model.configurationBlocker {
                Label(configurationBlocker, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.canEdit {
                Label("D200X configuration cannot be edited right now.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.isConfigured {
                Label("Connect to create this deck's local configuration.", systemImage: "externaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lastActionMessage = model.lastActionMessage {
                Text(lastActionMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var connectionAction: some View {
        if model.isConnected || model.isBusy {
            let actionTitle = model.connectionTitle == "Connecting" ? "Cancel" : "Disconnect"
            Button(actionTitle, systemImage: "xmark.circle") {
                model.disconnect()
            }
            .buttonStyle(.bordered)
            .disabled(model.connectionTitle == "Disconnecting")
        } else {
            Button("Connect", systemImage: "cable.connector") {
                model.connect()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppAppearance.sidebarSelection)
            .disabled(!model.canEdit || model.isBusy)
        }
    }

    private var deckCanvas: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Control deck")
                    .font(.headline)

                Text("Select a key, front button or dial to open its settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            D200XDeckView(model: model) {
                isInspectorPresented = true
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
}
