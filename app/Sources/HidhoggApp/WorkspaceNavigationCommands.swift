import SwiftUI

struct WorkspaceNavigationCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.navigation.canGoBack)

            Button("Forward") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.navigation.canGoForward)
        }
    }
}
