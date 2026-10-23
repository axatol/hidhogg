import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct D200XApplicationSelectorView: View {
    @ObservedObject var model: D200XModel
    @State private var isPopoverPresented = false
    @State private var isApplicationPickerPresented = false
    @State private var isPickerWaitingForPopoverDismissal = false
    @State private var isRemovalConfirmationPresented = false
    @State private var isRemovalWaitingForPopoverDismissal = false
    @State private var searchText = ""
    @State private var metadataByBundleIdentifier: [String: ApplicationMetadata] = [:]
    @State private var selectionError: String?
    @State private var pendingApplicationRemoval: PendingApplicationRemoval?

    private struct ApplicationMetadata {
        let displayName: String
        let icon: NSImage?
    }

    private struct PendingApplicationRemoval {
        let applicationID: String
        let displayName: String
        let overrideCount: Int
    }

    private var filteredApplicationIDs: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.applications }

        return model.applications.filter { identifier in
            identifier.localizedStandardContains(query) ||
                metadataByBundleIdentifier[identifier]?.displayName.localizedStandardContains(query) == true
        }
    }

    private var selectedApplicationName: String {
        guard let identifier = model.applicationID else { return "All apps" }
        return metadataByBundleIdentifier[identifier]?.displayName ?? identifier
    }

    private var removalTitle: String {
        guard let pendingApplicationRemoval else { return "Remove application overrides?" }
        return "Remove overrides for \(pendingApplicationRemoval.displayName)?"
    }

    private var removalMessage: String {
        guard let pendingApplicationRemoval else {
            return "This removes only this device's application overrides. The installed application remains unchanged."
        }
        let applicationID = pendingApplicationRemoval.applicationID
        let overrideCount = pendingApplicationRemoval.overrideCount
        guard overrideCount > 0 else {
            return "Bundle ID: \(applicationID). This removes only this device's application context. The installed application remains unchanged."
        }
        let overrideLabel = overrideCount == 1 ? "override" : "overrides"
        return "Bundle ID: \(applicationID). This removes \(overrideCount) explicit \(overrideLabel) from this device. The installed application remains unchanged."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Application editing scope")
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
                        Text(model.applicationID ?? "Default assignments for all apps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
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
            .accessibilityHint("Choose All apps or a configured application. Button delivery still follows the foreground app.")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                applicationPopover
            }

            if let selectionError {
                Label(selectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: model.applications) {
            metadataByBundleIdentifier = Self.loadMetadata(for: model.applications)
        }
        .onChange(of: isPopoverPresented) { _, isPresented in
            guard !isPresented else { return }
            if isPickerWaitingForPopoverDismissal {
                isPickerWaitingForPopoverDismissal = false
                isApplicationPickerPresented = true
                return
            }

            if isRemovalWaitingForPopoverDismissal {
                isRemovalWaitingForPopoverDismissal = false
                isRemovalConfirmationPresented = true
            }
        }
        .onChange(of: isRemovalConfirmationPresented) { _, isPresented in
            guard !isPresented else { return }
            pendingApplicationRemoval = nil
        }
        .confirmationDialog(
            removalTitle,
            isPresented: $isRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Application", role: .destructive) {
                guard let pendingApplicationRemoval,
                      model.applications.contains(pendingApplicationRemoval.applicationID),
                      model.canEdit else {
                    self.pendingApplicationRemoval = nil
                    return
                }
                model.applicationID = pendingApplicationRemoval.applicationID
                guard model.applicationID == pendingApplicationRemoval.applicationID,
                      model.canEdit else {
                    self.pendingApplicationRemoval = nil
                    return
                }
                model.removeSelectedApplication()
                self.pendingApplicationRemoval = nil
            }
            .disabled(!model.canEdit)

            Button("Cancel", role: .cancel) {
                pendingApplicationRemoval = nil
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
                guard let url = urls.first else { return }
                addApplication(at: url)
            case .failure(let error):
                selectionError = error.localizedDescription
            }
        }
    }

    private func beginRemovalConfirmation(for applicationID: String) {
        guard model.canEdit,
              model.isConfigured,
              model.applications.contains(applicationID),
              let configuration = model.configuration else { return }

        pendingApplicationRemoval = PendingApplicationRemoval(
            applicationID: applicationID,
            displayName: metadataByBundleIdentifier[applicationID]?.displayName ?? applicationID,
            overrideCount: configuration.applications[applicationID]?.count ?? 0
        )
        guard isPopoverPresented else {
            isRemovalConfirmationPresented = true
            return
        }

        isRemovalWaitingForPopoverDismissal = true
        isPopoverPresented = false
    }

    private var applicationPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search configured applications", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search configured applications by name or bundle identifier")

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

            Button("Add Application…", systemImage: "plus.app") {
                selectionError = nil
                isPickerWaitingForPopoverDismissal = true
                isPopoverPresented = false
            }
            .disabled(!model.canEdit || !model.isConfigured)
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder
    private var selectedApplicationIcon: some View {
        if let identifier = model.applicationID {
            applicationIcon(for: identifier, size: 32)
        } else {
            Image(systemName: "square.stack.3d.up")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func applicationRow(identifier: String?) -> some View {
        let isSelected = model.applicationID == identifier

        return HStack(spacing: 4) {
            Button {
                model.applicationID = identifier
                searchText = ""
                selectionError = nil
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
                        Text(identifier ?? "Default assignments for all apps")
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

            if let identifier {
                Button("Remove Application", systemImage: "minus.circle") {
                    beginRemovalConfirmation(for: identifier)
                }
                .labelStyle(.iconOnly)
                .help("Remove application overrides")
                .accessibilityLabel("Remove overrides for \(metadataByBundleIdentifier[identifier]?.displayName ?? identifier)")
                .disabled(!model.canEdit || !model.isConfigured)
            }
        }
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

    private func addApplication(at url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let identifier = Bundle(url: url)?.bundleIdentifier, !identifier.isEmpty else {
            selectionError = "The selected application does not have a bundle identifier."
            return
        }

        guard model.canEdit, model.isConfigured else { return }
        model.addApplication(identifier)
        model.applicationID = identifier
        selectionError = nil
    }

    @MainActor
    private static func loadMetadata(for identifiers: [String]) -> [String: ApplicationMetadata] {
        var metadata: [String: ApplicationMetadata] = [:]

        for identifier in identifiers {
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                metadata[identifier] = ApplicationMetadata(displayName: identifier, icon: nil)
                continue
            }

            let bundle = Bundle(url: applicationURL)
            let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? applicationURL.deletingPathExtension().lastPathComponent

            metadata[identifier] = ApplicationMetadata(
                displayName: displayName.isEmpty ? identifier : displayName,
                icon: NSWorkspace.shared.icon(forFile: applicationURL.path)
            )
        }

        return metadata
    }
}
