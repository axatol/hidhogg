import Foundation
import HidhoggAutomation
import HidhoggDomain
import SwiftUI

struct D200XAutomationHistoryView: View {
    @ObservedObject var model: D200XModel
    var showNotifications = true
    var showActions = true
    let onOpenTile: (String?, String) -> Void
    @State private var isExpanded = false

    private var recentNotifications: [NotificationHistoryEntry] {
        showNotifications ? Array(model.notificationHistory.suffix(10).reversed()) : []
    }

    private var recentActions: [ConfiguredActionRecord] {
        showActions ? Array(model.actionHistory.suffix(10).reversed()) : []
    }

    var body: some View {
        DisclosureGroup("Recent automation history", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Metadata only; notification content and custom executable arguments are not shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if showActions {
                        Button("Clear action history", systemImage: "trash") {
                            Task { await model.clearActionHistory() }
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Clear action history")
                        .disabled(model.actionHistory.isEmpty)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refreshAutomationHistory() }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Refresh automation history")
                }

                if recentNotifications.isEmpty && recentActions.isEmpty {
                    Text("No automation activity has been recorded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !recentNotifications.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications")
                            .font(.callout.weight(.semibold))
                        ForEach(recentNotifications) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.topic)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                Text("\(outcomeTitle(entry.outcome)) · Count \(entry.matchedCount) · \(entry.committedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal) {
                                    HStack(spacing: 6) {
                                        profileNavigationLink(
                                            entry.profile,
                                            controlIdentifier: firstValidControlIdentifier(entry.controls)
                                        )
                                        Text("·")
                                        controlLinks(entry.controls, profile: entry.profile)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: true, vertical: false)
                                }
                                .scrollIndicators(.hidden)
                                Text("Event ID: \(entry.id.uuidString)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: 320, alignment: .leading)
                            }
                        }
                    }
                }

                if !recentActions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Actions")
                            .font(.callout.weight(.semibold))
                        ForEach(recentActions, id: \.executionID) { record in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.actionID)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                    Text(record.admittedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    actionOrigin(record.trigger)
                                    Text("Execution ID: \(record.executionID.uuidString)\(record.exitCode.map { " · Exit code: \($0)" } ?? "")")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: 320, alignment: .leading)
                                    if let failureMessage = record.failureMessage {
                                        Text(failureMessage)
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                                Text(record.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded else { return }
            Task { await model.refreshAutomationHistory() }
        }
    }

    private func outcomeTitle(_ outcome: String) -> String {
        outcome.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @ViewBuilder
    private func actionOrigin(_ trigger: ConfiguredActionTrigger?) -> some View {
        if let trigger {
            switch trigger.kind {
            case .device:
                HStack(spacing: 4) {
                    Text("Device ·")
                    if let identifier = trigger.control, let control = D200XControl(rawValue: identifier) {
                        profileNavigationLink(trigger.profile, controlIdentifier: identifier)
                        Text("·")
                        Button(control.title) {
                            onOpenTile(trigger.profile == "Default" ? nil : trigger.profile, identifier)
                        }
                        .buttonStyle(.link)
                        .help("Open \(control.title) in the D200X")
                    } else {
                        Text("Profile: \(trigger.profile ?? "Default") · \(trigger.control ?? "Unknown control")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .localAPI:
                Text("CLI / local API")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Unknown origin")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func firstValidControlIdentifier(_ identifiers: [String]) -> String? {
        identifiers.first { D200XControl(rawValue: $0) != nil }
    }

    @ViewBuilder
    private func profileNavigationLink(_ profile: String?, controlIdentifier: String?) -> some View {
        let profileName = profile ?? "Default"
        if let controlIdentifier, D200XControl(rawValue: controlIdentifier) != nil {
            Button("Profile: \(profileName)") {
                onOpenTile(profileName == "Default" ? nil : profile, controlIdentifier)
            }
            .buttonStyle(.link)
        } else {
            Text("Profile: \(profileName)")
        }
    }

    @ViewBuilder
    private func controlLinks(_ identifiers: [String], profile: String?) -> some View {
        if identifiers.isEmpty {
            Text("No controls recorded")
        } else {
            ForEach(Array(identifiers.enumerated()), id: \.offset) { index, identifier in
                if index > 0 { Text(",") }
                if let control = D200XControl(rawValue: identifier) {
                    Button(control.title) {
                        onOpenTile(profile == "Default" ? nil : profile, identifier)
                    }
                    .buttonStyle(.link)
                    .help("Open \(control.title) in the D200X")
                } else {
                    Text(identifier)
                }
            }
        }
    }
}
