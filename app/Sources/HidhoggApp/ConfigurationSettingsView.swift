import SwiftUI

struct ConfigurationSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Configuration File") {
            Text(model.configurationURL.path)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            LabeledContent("Document", value: model.configurationStatus)

            if model.configurationLoadFailed {
                if let error = model.configurationLoadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label("Configuration editing is unavailable until the file reloads successfully.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.configurationSaveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            recoveryActions
        }
    }

    @ViewBuilder
    private var recoveryActions: some View {
        switch model.configurationFailureKind {
        case .some(.save):
            retrySavingButton
            reloadButton
        case .some(.conflict), .some(.load):
            reloadButton
        case .none:
            if model.configurationSaveError != nil {
                retrySavingButton
            }
            reloadButton
        }
    }

    private var retrySavingButton: some View {
        Button("Retry Saving", systemImage: "arrow.clockwise") {
            Task { await model.flushPendingSave() }
        }
        .disabled(model.isSaving || !model.canEditConfiguration)
    }

    private var reloadButton: some View {
        Button("Reload from File…", systemImage: "arrow.clockwise") {
            model.requestReload()
        }
        .disabled(!model.canReloadConfiguration)
    }
}
