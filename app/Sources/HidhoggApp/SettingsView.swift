import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var diagnostics: DiagnosticsStore
    @EnvironmentObject private var restartCoordinator: RestartCoordinator
    @EnvironmentObject private var loginItemController: LoginItemController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Attempt connection on launch", isOn: Binding(
                    get: { model.document.draft.connectOnLaunch },
                    set: { model.setConnectOnLaunch($0) }
                ))
                .disabled(model.isLoading || model.isRestarting)
                Text("Attempts one connection each time Hidhogg launches, including after Restart. Changing this setting does not connect immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItemController.isLaunchAtLoginRequested },
                    set: { enabled in
                        Task { @MainActor in
                            guard !model.isRestarting else { return }
                            await loginItemController.setLaunchAtLogin(enabled)
                        }
                    }
                ))
                .disabled(!loginItemController.canChangeRegistration || model.isRestarting)
                LabeledContent("macOS status", value: loginItemController.statusTitle)
                if loginItemController.statusRequiresAttention {
                    Label(loginItemController.statusDetail, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if loginItemController.status != .enabled {
                    Text(loginItemController.statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = loginItemController.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Open Login Items Settings", systemImage: "arrow.up.forward.app") {
                    loginItemController.openLoginItemsSettings()
                }
                .disabled(model.isRestarting)
            }

            Section("Input Permission") {
                LabeledContent("Accessibility trust", value: model.permissionChecks.accessibilityTrusted ? "Granted" : "Not granted")
                LabeledContent("Post input events", value: model.permission == .granted ? "Granted" : "Not granted")
                if model.permissionChecks.accessibilityTrusted && !model.permissionChecks.eventPostingAllowed {
                    Text("Accessibility is trusted, but macOS still reports event posting as denied for this process. Refresh or restart Hidhogg. If this persists, remove and re-add this copy in System Settings.")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Text("Hidhogg posts shortcuts and custom wheel or thumb-wheel scroll events only while their connected session and input permission are active.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(model.permission == .granted ? "Refresh Permission" : "Request Permission", systemImage: "hand.raised") {
                    if model.permission == .granted {
                        _ = model.refreshPermission(retryScrollCapture: true)
                    } else {
                        _ = model.requestPermission()
                        openPermissionSettings()
                    }
                }
                Button("Open Accessibility Settings", systemImage: "arrow.up.forward.app") {
                    openPermissionSettings()
                }
                HStack(spacing: 8) {
                    Image(nsImage: AppAppearance.icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text("Drag Hidhogg into the permission list")
                }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .onDrag {
                        NSItemProvider(object: ApplicationIdentity.current.bundleURL as NSURL)
                    } preview: {
                        Image(nsImage: AppAppearance.icon).resizable().frame(width: 64, height: 64)
                    }
                    .help("Adds the running app’s file URL to the drag. Enable its switch in System Settings afterward.")
                Button("Restart Hidhogg", systemImage: "arrow.clockwise") {
                    restart()
                }
                .disabled(restartCoordinator.inProgress || model.isLoading || model.isSaving)
            }

            Section("Configuration File") {
                Text(model.configurationURL.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                LabeledContent("Document", value: model.configurationStatus)
                if let error = model.configurationSaveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry Saving", systemImage: "arrow.clockwise") {
                        Task { await model.flushPendingSave() }
                    }
                    .disabled(model.isSaving || model.configurationLoadFailed)
                }
                Button("Reload from File…", systemImage: "arrow.clockwise") { model.requestReload() }
                    .disabled(!model.canReloadConfiguration)
            }
            Section("Diagnostics") {
                LabeledContent("Process", value: String(ApplicationIdentity.current.processID))
                LabeledContent("Build", value: String(ApplicationIdentity.current.buildID.prefix(12)))
                Text(ApplicationIdentity.current.bundleURL.path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                DisclosureGroup("Recent activity (up to 100 entries)") {
                    ForEach(diagnostics.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.date, style: .time)
                                    .foregroundStyle(.secondary)
                                Text(entry.code.rawValue)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                            }
                            Text(entry.message)
                                .foregroundStyle(entry.isError ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            DisclosureGroup("Details") {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("ID  \(entry.id.uuidString)")
                                    Text("Build  \(entry.buildID)")
                                    Text("Source  \(entry.source.description)")
                                }
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                    }
                }
                Button("Clear Recent Activity") { diagnostics.clear() }
                    .disabled(diagnostics.entries.isEmpty)
                Text("Persistent diagnostics are available in Console under com.hidhogg.app. macOS manages log retention. Shortcut contents are not logged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            loginItemController.refreshStatus()
            _ = model.refreshPermission()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loginItemController.refreshStatus() }
        }
    }

    private func restart() {
        restartCoordinator.requestRestart()
    }

    private func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
              NSWorkspace.shared.open(url) else {
            model.reportError("Open System Settings → Privacy & Security → Accessibility, then add Hidhogg and enable it.")
            return
        }
    }
}
