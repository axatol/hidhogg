import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DeviceApplicationSelector: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPopoverPresented = false
    @State private var isApplicationPickerPresented = false
    @State private var isPickerWaitingForPopoverDismissal = false
    @State private var isRemovalConfirmationPresented = false
    @State private var searchText = ""
    @State private var applicationPendingRemoval: String?
    @State private var metadataByBundleIdentifier: [String: ApplicationMetadata] = [:]

    var isDeviceWide: Bool = false

    private struct ApplicationMetadata {
        let displayName: String
        let icon: NSImage?
    }

    private var filteredApplicationIDs: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.applicationIDs }

        return model.applicationIDs.filter { identifier in
            identifier.localizedStandardContains(query) ||
                metadataByBundleIdentifier[identifier]?.displayName.localizedStandardContains(query) == true
        }
    }

    private var selectedApplicationName: String {
        guard let identifier = model.selectedApplicationID else { return "All apps" }
        return metadataByBundleIdentifier[identifier]?.displayName ?? identifier
    }

    private var removalTitle: String {
        guard let applicationPendingRemoval else { return "Remove application context?" }
        return "Remove \(metadataByBundleIdentifier[applicationPendingRemoval]?.displayName ?? applicationPendingRemoval)?"
    }

    private var removalMessage: String {
        guard let identifier = applicationPendingRemoval else { return "This removes the configured application context." }
        let assignmentCount = model.document.draft.mouse?.applications[identifier]?.count ?? 0
        guard assignmentCount > 0 else {
            return "Bundle ID: \(identifier). This removes the configured application context."
        }
        let assignmentLabel = assignmentCount == 1 ? "assignment" : "assignments"
        return "Bundle ID: \(identifier). This removes \(assignmentCount) explicit \(assignmentLabel) for this application."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isDeviceWide ? "Retained button app context" : "Application editing scope")
                .font(.headline)

            Button {
                isPopoverPresented.toggle()
            } label: {
                HStack(spacing: 12) {
                    selectedApplicationIcon
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedApplicationName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(model.selectedApplicationID ?? "Default assignment for all apps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Application editing scope: \(selectedApplicationName)")
            .accessibilityHint("Choose All apps or a configured application. This does not activate the application.")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                applicationPopover
            }

            Text(isDeviceWide
                 ? "Wheel settings apply across all apps. This context is retained for Back and Forward."
                 : "Selecting an app changes which button assignment you edit. Button delivery still follows the foreground app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: model.applicationIDs) {
            metadataByBundleIdentifier = Self.loadMetadata(for: model.applicationIDs)
        }
        .onChange(of: isPopoverPresented) { _, isPresented in
            guard !isPresented, isPickerWaitingForPopoverDismissal else { return }
            isPickerWaitingForPopoverDismissal = false
            isApplicationPickerPresented = true
        }
        .confirmationDialog(
            removalTitle,
            isPresented: $isRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Application", role: .destructive) {
                guard let applicationPendingRemoval,
                      model.selectedApplicationID == applicationPendingRemoval else { return }
                model.removeSelectedApplication()
                self.applicationPendingRemoval = nil
                isPopoverPresented = false
            }
            .disabled(!model.canEditConfiguration)

            Button("Cancel", role: .cancel) {
                applicationPendingRemoval = nil
            }
        } message: {
            Text(removalMessage)
        }
        .fileImporter(
            isPresented: $isApplicationPickerPresented,
            allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.addApplication(at: url) }
            case .failure(let error):
                model.reportError(error.localizedDescription)
            }
        }
    }

    private var applicationPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search configured applications", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search configured applications")

            ScrollView {
                VStack(spacing: 4) {
                    applicationRow(identifier: nil)

                    if filteredApplicationIDs.isEmpty {
                        ContentUnavailableView(
                            "No matching apps",
                            systemImage: "magnifyingglass",
                            description: Text("Search configured apps by name or bundle ID.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        ForEach(filteredApplicationIDs, id: \.self) { identifier in
                            applicationRow(identifier: identifier)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            if let selectedApplicationID = model.selectedApplicationID {
                Button(
                    "Remove \(metadataByBundleIdentifier[selectedApplicationID]?.displayName ?? selectedApplicationID)…",
                    systemImage: "minus.circle",
                    role: .destructive
                ) {
                    applicationPendingRemoval = selectedApplicationID
                    isRemovalConfirmationPresented = true
                }
                .disabled(!model.canEditConfiguration)
            }

            Button("Add Application…", systemImage: "plus.app") {
                isPickerWaitingForPopoverDismissal = true
                isPopoverPresented = false
            }
            .disabled(!model.canEditConfiguration)
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private var selectedApplicationIcon: some View {
        if let identifier = model.selectedApplicationID {
            applicationIcon(for: identifier, size: 32)
        } else {
            Image(systemName: "square.stack.3d.up")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func applicationRow(identifier: String?) -> some View {
        let isSelected = model.selectedApplicationID == identifier

        return Button {
            model.selectApplication(identifier)
            searchText = ""
            isPopoverPresented = false
        } label: {
            HStack(spacing: 10) {
                if let identifier {
                    applicationIcon(for: identifier, size: 28)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "square.stack.3d.up")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(identifier.map { metadataByBundleIdentifier[$0]?.displayName ?? $0 } ?? "All apps")
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(identifier.map(assignmentSummary(for:)) ?? "Default assignments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(AppAppearance.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? AppAppearance.accent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(identifier.map {
            "\(metadataByBundleIdentifier[$0]?.displayName ?? $0), \($0)"
        } ?? "All apps")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func applicationIcon(for identifier: String, size: CGFloat) -> some View {
        if let icon = metadataByBundleIdentifier[identifier]?.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .font(.system(size: size * 0.78))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private func assignmentSummary(for identifier: String) -> String {
        guard let overrides = model.document.draft.mouse?.applications[identifier], !overrides.isEmpty else {
            return "Inherits All apps · \(identifier)"
        }
        return identifier
    }

    @MainActor
    private static func loadMetadata(for identifiers: [String]) -> [String: ApplicationMetadata] {
        Dictionary(uniqueKeysWithValues: identifiers.map { identifier in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                return (identifier, ApplicationMetadata(displayName: identifier, icon: nil))
            }

            let bundle = Bundle(url: applicationURL)
            let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? applicationURL.deletingPathExtension().lastPathComponent

            return (
                identifier,
                ApplicationMetadata(
                    displayName: displayName.isEmpty ? identifier : displayName,
                    icon: NSWorkspace.shared.icon(forFile: applicationURL.path)
                )
            )
        })
    }
}
