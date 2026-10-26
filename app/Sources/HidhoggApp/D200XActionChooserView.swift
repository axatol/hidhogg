import HidhoggDomain
import SwiftUI

struct D200XActionChooserView: View {
    @ObservedObject var model: D200XModel
    let onChoose: (String) -> Void
    @State private var searchText = ""

    private var actionIDs: [String] {
        model.configuration?.actionIDs ?? []
    }

    private var filteredActionIDs: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return actionIDs }
        return actionIDs.filter { actionID in
            actionID.localizedStandardContains(query) || actionKindTitle(actionID).localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose Action")
                .font(.headline)

            TextField("Search actions", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search actions")
                .accessibilityIdentifier("d200x-action-search")
                .help("Filter actions by ID or type.")

            List {
                if filteredActionIDs.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No actions" : "No matching actions",
                        systemImage: "bolt",
                        description: Text(searchText.isEmpty
                            ? "Create an action on the Actions page before assigning one."
                            : "Try a different action name or type.")
                    )
                } else {
                    ForEach(filteredActionIDs, id: \.self) { actionID in
                        Button {
                            onChoose(actionID)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(actionID)
                                    .font(.body.weight(.medium))
                                Text(actionKindTitle(actionID))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(actionID), \(actionKindTitle(actionID))")
                        .accessibilityHint("Assigns this action to the selected control without running it.")
                        .help("Assign \(actionID) without running it")
                    }
                }
            }
            .listStyle(.plain)
        }
        .padding(12)
        .frame(width: 340, height: 340)
    }

    private func actionKindTitle(_ actionID: String) -> String {
        switch model.configuration?.actionDefinition(id: actionID) {
        case .some(.executable(_)):
            "Custom executable"
        case .some(.native(let action)):
            switch action.kind {
            case .media: "Media"
            case .volume: "Volume"
            case .bell: "Bell"
            case .playSound: "Play Sound"
            case .openApplication: "Open Application"
            case .openFile: "Open File"
            case .openURL: "Open URL"
            case .deckNotification: "Deck Notification"
            case .shortcut: "Keyboard Shortcut"
            }
        case .none:
            "Unavailable"
        }
    }
}
