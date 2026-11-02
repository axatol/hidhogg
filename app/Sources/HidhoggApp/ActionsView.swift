import HidhoggDomain
import SwiftUI

struct ActionsView: View {
    @ObservedObject var model: D200XModel
    let onOpenTile: (String?, String) -> Void
    @State private var selectedActionID: String?
    @State private var newDraftID = UUID()

    private var scriptIDs: [String] {
        model.configuration?.actions.keys.sorted() ?? []
    }

    private var editorIdentity: AnyHashable {
        selectedActionID.map { AnyHashable($0) } ?? AnyHashable(newDraftID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scripts")
                        .font(.title2.weight(.semibold))
                    Text("Create reusable executable scripts here, then assign them to controls in the D200X inspector.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.isConfigured {
                    GroupBox("Deck configuration") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Create a local configuration before adding scripts. You can edit it while disconnected.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Set Up Deck Configuration", systemImage: "plus.square") {
                                model.enableConfiguration()
                            }
                            .disabled(!model.canEdit)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                }

                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Scripts")
                                .font(.headline)
                            Spacer()
                            Button("New Script", systemImage: "plus", action: beginNewScript)
                                .disabled(!model.canEdit || !model.isConfigured)
                        }
                        .padding(.horizontal, 8)

                        List(selection: $selectedActionID) {
                            ForEach(scriptIDs, id: \.self) { scriptID in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scriptID)
                                    Text("Executable script")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(scriptID)
                            }
                        }
                        .listStyle(.inset)
                    }
                    .frame(minWidth: 150, idealWidth: 190, maxWidth: 260, maxHeight: .infinity)

                    ScrollView {
                        D200XAutomationEditorView(model: model, selectedActionID: $selectedActionID)
                            .id(editorIdentity)
                            .padding(18)
                    }
                    .frame(minWidth: 320, minHeight: 400, maxHeight: .infinity)
                }
                .frame(minHeight: 420)

                D200XAutomationHistoryView(
                    model: model,
                    showNotifications: false,
                    onOpenTile: onOpenTile
                )
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(24)
        }
        .navigationTitle("Scripts")
        .onAppear(perform: selectInitialScript)
        .onChange(of: scriptIDs) { _, ids in
            guard let selectedActionID, !ids.contains(selectedActionID) else { return }
            self.selectedActionID = nil
            newDraftID = UUID()
        }
    }

    private func beginNewScript() {
        selectedActionID = nil
        newDraftID = UUID()
    }

    private func selectInitialScript() {
        guard selectedActionID == nil, let firstScriptID = scriptIDs.first else { return }
        selectedActionID = firstScriptID
    }
}
