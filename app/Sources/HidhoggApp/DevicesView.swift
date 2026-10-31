import SwiftUI
import HidhoggDomain

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding private var isInspectorPresented: Bool

    init(isInspectorPresented: Binding<Bool> = .constant(true)) {
        self._isInspectorPresented = isInspectorPresented
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                deviceHeader

                DeviceApplicationSelector(isDeviceWide: model.selectedTarget.control == nil)

                DeviceControlCanvas(isInspectorPresented: $isInspectorPresented)

                configurationStatus

                DeviceInformationView()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(
                        isInspectorPresented ? "Hide Inspector" : "Show Inspector",
                        systemImage: "sidebar.trailing"
                    )
                }
                .help(isInspectorPresented ? "Hide device settings" : "Show device settings")
            }
        }
        .onChange(of: isInspectorPresented) { _, isPresented in
            if !isPresented { model.cancelRecording() }
        }
        .onDisappear {
            model.cancelRecording()
        }
    }

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image("DeviceMouse")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(AppAppearance.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("MX Master 3S")
                        .font(.title2.weight(.semibold))
                    Text(model.connectionMessage)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                connectionAction
            }

            DeviceManagementControls(family: .mxMaster3S)

            DeviceBatteryOverviewView()

            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: model.connectionColor))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(model.connectionTitle)
                }
                LabeledContent("Button handling", value: model.buttonReadiness)
            }
            .font(.callout)

            if model.boltStatus.cleanupUncertain && !model.isBackgroundRecovery {
                Label(
                    model.connectionRequested
                        ? "Mouse settings could not be verified. Reconnecting automatically."
                        : "Mouse settings could not be verified. Connect to check them again.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if model.permission != .granted {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(
                        "Input posting permission is required for shortcuts and custom scroll amounts.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    Button("Open Permissions", systemImage: "gearshape") {
                        model.openPermissions()
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var connectionAction: some View {
        if model.isBackgroundRecovery {
            Button("Cancel", systemImage: "xmark.circle", role: .destructive) { model.disconnect() }
                .help("Stop automatic connection recovery")
        } else if model.boltStatus.phase == .discovering || model.boltStatus.phase == .enabling {
            Button("Cancel", systemImage: "xmark.circle") { model.disconnect() }
        } else if [.ready, .enabled, .stopping].contains(model.boltStatus.phase) {
            Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                model.disconnect()
            }
            .disabled(model.boltStatus.phase == .stopping)
        } else if model.connectionRequested {
            Button(model.isReconnectPending ? "Cancel Reconnect" : "Cancel", systemImage: "xmark.circle", role: .destructive) {
                model.disconnect()
            }
        } else {
            Button("Connect", systemImage: "cable.connector") {
                model.connect()
            }
            .disabled(!model.canDiscover)
        }
    }

    private var configurationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                LabeledContent("Saved on this Mac", value: model.configurationStatus)
                Spacer()
            }

            if model.configurationFailureKind == .save, let error = model.configurationSaveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.configurationFailureKind == .conflict {
                Label(
                    model.configurationSaveError ?? "The configuration file changed outside Hidhogg.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                Text("Your draft remains editable but cannot be saved against the changed file. Reload from File… offers confirmation before discarding unsaved edits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.configurationLoadFailed {
                Label(
                    model.configurationLoadError ?? "The configuration file could not be loaded.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                Label("Configuration editing is unavailable until the file reloads successfully.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("Edits apply immediately and save one second after the last change. Offline edits are saved and applied after connection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if model.configurationFailureKind == .save {
                    Button("Retry Saving", systemImage: "arrow.clockwise") {
                        Task { await model.flushPendingSave() }
                    }
                    .disabled(model.isSaving || !model.canEditConfiguration)
                }

                Button("Reload from File…", systemImage: "arrow.clockwise") {
                    model.requestReload()
                }
                .disabled(!model.canReloadConfiguration)
            }

            if let lastActionMessage = model.lastActionMessage {
                Text(lastActionMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}
