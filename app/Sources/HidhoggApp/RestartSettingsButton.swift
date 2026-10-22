import SwiftUI

struct RestartSettingsButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var restartCoordinator: RestartCoordinator

    var body: some View {
        Button("Restart Hidhogg", systemImage: "arrow.clockwise") {
            restartCoordinator.requestRestart()
        }
        .disabled(restartCoordinator.inProgress || model.isLoading || model.isSaving)
    }
}
