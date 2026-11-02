import AppKit
import HidhoggDomain
import SwiftUI

struct D200XAutomationEditorView: View {
    @ObservedObject var model: D200XModel
    @Binding var selectedActionID: String?
    @State private var actionIDDraft = ""
    @State private var executableDraft = ""
    @State private var argumentsDraft = ConfiguredExecutableArgumentsDraft()
    @State private var workingDirectoryDraft = ""
    @State private var timeoutSecondsDraft = 10
    @State private var actionError: String?
    @State private var removalActionID: String?

    private var actionIDs: [String] {
        model.configuration?.actionIDs ?? []
    }

    private var canEditAutomation: Bool {
        model.canEdit && model.isConfigured
    }

    private var actionValidationMessage: String? {
        guard ConfiguredExecutable.isValidIdentifier(actionIDDraft) else {
            return "Use a script ID of at most 64 bytes, beginning with a letter or digit."
        }
        if selectedActionID == nil && model.configuration?.actionDefinition(id: actionIDDraft) != nil {
            return "That ID is already in use."
        }
        if selectedActionID == nil && actionIDs.count >= 64 {
            return "A device can store at most 64 actions."
        }

        let workingDirectory = workingDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = ConfiguredExecutable(
            executable: executableDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: argumentsDraft.arguments,
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            timeoutSeconds: timeoutSecondsDraft
        )
        guard (try? action.validated()) != nil else {
            return "Use absolute paths without NUL bytes, paths and arguments up to 4 KiB, at most 64 arguments totaling 16 KiB, and a 1–60 second timeout."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Script") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(selectedActionID.map { "Editing \($0)" } ?? "New script")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("Script ID", text: $actionIDDraft)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEditAutomation || selectedActionID != nil)

                    TextField("Absolute executable path", text: $executableDraft)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEditAutomation)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Arguments (\(argumentsDraft.rows.count)/\(ConfiguredExecutableArgumentsDraft.maximumArgumentCount))")
                                .font(.callout)
                            Spacer()
                            Button("Add Argument", systemImage: "plus") {
                                _ = argumentsDraft.addArgument()
                                actionError = nil
                            }
                            .disabled(!canEditAutomation || !argumentsDraft.canAddArgument)
                        }
                        Text("Each row is one literal argument; line breaks inside a row are preserved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Executables run directly with literal arguments and an empty environment. Use absolute paths for tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320, alignment: .leading)
                        if argumentsDraft.rows.isEmpty {
                            Text("No arguments")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach($argumentsDraft.rows) { $row in
                            let argumentNumber = (argumentsDraft.rows.firstIndex(where: { $0.id == row.id }) ?? 0) + 1
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Argument \(argumentNumber)")
                                        .font(.caption)
                                    TextEditor(text: $row.value)
                                        .font(.body.monospaced())
                                        .frame(minHeight: 58)
                                        .disabled(!canEditAutomation)
                                        .accessibilityLabel("Argument \(argumentNumber)")
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 5)
                                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                                .allowsHitTesting(false)
                                        }
                                }
                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    argumentsDraft.removeArgument(id: row.id)
                                    actionError = nil
                                }
                                .help("Remove argument \(argumentNumber)")
                                .accessibilityLabel("Remove argument \(argumentNumber)")
                                .disabled(!canEditAutomation)
                            }
                        }
                    }

                    TextField("Working directory (optional)", text: $workingDirectoryDraft)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!canEditAutomation)

                    HStack {
                        Text("Timeout")
                        Spacer()
                        Text("\(timeoutSecondsDraft) sec")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { Double(timeoutSecondsDraft) },
                            set: { timeoutSecondsDraft = Int($0.rounded()) }
                        ),
                        in: 1...60,
                        step: 1
                    )
                    .disabled(!canEditAutomation)
                    .accessibilityLabel("Script timeout in seconds")

                    if let actionError {
                        Text(actionError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let actionValidationMessage {
                        Text(actionValidationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(selectedActionID == nil ? "Add Script" : "Save Script", systemImage: "square.and.arrow.down") {
                            saveAction()
                        }
                        .disabled(!canEditAutomation || actionValidationMessage != nil)

                        if let selectedActionID {
                            Button("Remove…", systemImage: "trash", role: .destructive) {
                                removalActionID = selectedActionID
                            }
                            .disabled(!canEditAutomation)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardContentPadding()
            }

            if let automationMessage = model.automationMessage {
                Text(automationMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: prepareEditor)
        .onChange(of: actionIDDraft) { _, _ in actionError = nil }
        .onChange(of: executableDraft) { _, _ in actionError = nil }
        .onChange(of: argumentsDraft) { _, _ in actionError = nil }
        .onChange(of: workingDirectoryDraft) { _, _ in actionError = nil }
        .onChange(of: selectedActionID) { _, actionID in
            guard let actionID, actionIDs.contains(actionID) else {
                beginNewAction()
                return
            }
            loadAction(actionID)
        }
        .onChange(of: actionIDs) { _, ids in
            guard let selectedActionID, !ids.contains(selectedActionID) else { return }
            self.selectedActionID = nil
            beginNewAction()
        }
        .confirmationDialog(
            "Remove script?",
            isPresented: Binding(
                get: { removalActionID != nil },
                set: { if !$0 { removalActionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let removalActionID {
                Button("Remove \(removalActionID)", role: .destructive) {
                    model.removeAction(id: removalActionID)
                    if selectedActionID == removalActionID { beginNewAction() }
                    self.removalActionID = nil
                }
            }
            Button("Cancel", role: .cancel) { removalActionID = nil }
        } message: {
            Text("Controls assigned to this script will no longer run it.")
        }
    }

    private func prepareEditor() {
        if let selectedActionID, actionIDs.contains(selectedActionID) {
            loadAction(selectedActionID)
        } else {
            beginNewAction()
        }
    }

    private func loadAction(_ actionID: String) {
        guard let action = model.configuration?.actions[actionID] else { return }
        selectedActionID = actionID
        actionIDDraft = actionID
        executableDraft = action.executable
        argumentsDraft = ConfiguredExecutableArgumentsDraft(arguments: action.arguments)
        workingDirectoryDraft = action.workingDirectory ?? ""
        timeoutSecondsDraft = action.timeoutSeconds
        actionError = nil
    }

    private func beginNewAction() {
        selectedActionID = nil
        actionIDDraft = ""
        executableDraft = ""
        argumentsDraft = ConfiguredExecutableArgumentsDraft()
        workingDirectoryDraft = ""
        timeoutSecondsDraft = 10
        actionError = nil
    }

    private func saveAction() {
        guard canEditAutomation, actionValidationMessage == nil else { return }
        let workingDirectory = workingDirectoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = ConfiguredExecutable(
            executable: executableDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: argumentsDraft.arguments,
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            timeoutSeconds: timeoutSecondsDraft
        )

        do {
            try model.saveAction(id: actionIDDraft, action: action)
            selectedActionID = actionIDDraft
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

}
