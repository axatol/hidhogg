import AppKit
import Foundation
import HidhoggAutomation
import HidhoggDomain
import SwiftUI

struct NotificationsView: View {
    @ObservedObject var model: D200XModel
    let onOpenTile: (String?, String) -> Void
    @State private var topicFilter = "*"
    @State private var testTopic = "hidhogg.test"
    @State private var testText = "Test notification"
    @State private var testAppID = ""
    @State private var isTestPublisherPresented = false
    @State private var isPublishing = false
    @State private var publishFeedback: String?
    @State private var publishSucceeded = false

    private var listeningBinding: Binding<Bool> {
        Binding(get: { model.isListening }, set: model.setListening)
    }

    private var topicFilterError: String? {
        guard NotificationTopic.isValidFilter(topicFilter) else {
            return "Use a 1–64 character ASCII filter such as build.*, *.finished or *."
        }
        return nil
    }

    private var filteredHistory: [NotificationHistoryRow] {
        guard topicFilterError == nil else { return [] }

        let liveByNotificationID = Dictionary(grouping: model.liveNotifications.compactMap { event in
            event.notificationID.map { ($0, event) }
        }, by: { $0.0 })
        let metadataRows = model.notificationHistory.map { entry in
            let liveEvent = liveByNotificationID[entry.notificationID]?.max {
                $0.1.receivedAt < $1.1.receivedAt
            }?.1
            return NotificationHistoryRow(
                id: entry.id,
                notificationID: entry.notificationID,
                topic: entry.topic,
                appID: entry.appID,
                receivedAt: entry.committedAt,
                profile: entry.profile,
                controls: entry.controls,
                outcome: entry.outcome,
                matchedCount: entry.matchedCount,
                text: liveEvent?.text
            )
        }
        let recordedNotificationIDs = Set(model.notificationHistory.map(\.notificationID))
        let liveOnlyRows = model.liveNotifications.compactMap { event -> NotificationHistoryRow? in
            if let notificationID = event.notificationID, recordedNotificationIDs.contains(notificationID) {
                return nil
            }
            return NotificationHistoryRow(
                id: event.id,
                notificationID: event.notificationID,
                topic: event.topic,
                appID: event.appID,
                receivedAt: event.receivedAt,
                profile: event.profile,
                controls: event.controls,
                outcome: event.outcome,
                matchedCount: nil,
                text: event.text
            )
        }

        return (metadataRows + liveOnlyRows)
            .filter { NotificationTopic.matches($0.topic, filter: topicFilter) }
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(100)
            .map { $0 }
    }

    private var testPublisherError: String? {
        guard NotificationTopic.isValidTopic(testTopic) else {
            return "Use a concrete topic of up to 64 ASCII characters; published topics cannot contain *."
        }
        let hasText = !testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let appID = testAppID.isEmpty ? nil : testAppID
        guard hasText || appID != nil else {
            return "Enter notification text or an application bundle ID."
        }
        if let appID, !NativeAction.isValidBundleIdentifier(appID) {
            return "Enter a valid application bundle ID."
        }
        if hasText, (testText.unicodeScalars.count > 64 || testText.utf8.count > 256
            || testText.unicodeScalars.contains(where: Self.isForbiddenNotificationTextScalar)) {
            return "Use one line of at most 64 characters and 256 UTF-8 bytes without control characters."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("Listen", isOn: listeningBinding)
                    .fixedSize()
                    .help("Keep recent notification details in memory while listening is on")

                TextField("Filter", text: $topicFilter)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Notification topic filter")
                    .help("Use an exact topic or '*' wildcards; wildcards can match dots")
                    .frame(maxWidth: 190)

                Button("Clear", systemImage: "xmark.circle") {
                    Task { await model.clearActiveNotifications() }
                }
                .help("Clear active notifications from the deck")
                .accessibilityLabel("Clear active notifications")

                Button("Test", systemImage: "paperplane") {
                    isTestPublisherPresented = true
                }
                .help("Publish a test notification")
                .popover(isPresented: $isTestPublisherPresented, arrowEdge: .bottom) {
                    testPublisherPopover
                }
            }

            Text("Notification text stays in memory while Listen is on. History keeps metadata and an optional app bundle ID.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let topicFilterError {
                Text(topicFilterError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            List {
                if filteredHistory.isEmpty {
                    ContentUnavailableView(
                        topicFilterError == nil ? "No matching notifications" : "Invalid topic filter",
                        systemImage: "bell",
                        description: Text(topicFilterError == nil
                            ? "Receipts and outcomes will appear here."
                            : "Enter a valid exact topic or wildcard filter.")
                    )
                } else {
                    ForEach(filteredHistory) { row in
                        notificationRow(row)
                            .listRowSeparator(.visible)
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Notifications")
    }

    private var testPublisherPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Test publisher")
                .font(.headline)

            TextField("Concrete topic", text: $testTopic)
                .textFieldStyle(.roundedBorder)
                .disabled(isPublishing)
            TextField("Application bundle ID (optional)", text: $testAppID)
                .textFieldStyle(.roundedBorder)
                .disabled(isPublishing)
            TextField("Notification text (optional)", text: $testText)
                .textFieldStyle(.roundedBorder)
                .disabled(isPublishing)

            if !model.isListening {
                Text("Turn on Listen before publishing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let testPublisherError {
                Text(testPublisherError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let publishFeedback {
                Text(publishFeedback)
                    .font(.callout)
                    .foregroundStyle(publishSucceeded ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Expires after 10 seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Publish") { publishTestNotification() }
                    .disabled(!model.isListening || isPublishing || testPublisherError != nil)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func notificationRow(_ row: NotificationHistoryRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    copyTopic(row.topic)
                } label: {
                    HStack(spacing: 4) {
                        Text(row.topic)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .help("Copy topic")
                .accessibilityLabel("Copy topic \(row.topic)")

                if let text = row.text {
                    Text(text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(text)
                        .textSelection(.enabled)
                }

                if let appID = row.appID {
                    Text(appID)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Application bundle ID: \(appID)")
                }

                Spacer(minLength: 4)
                Text(row.receivedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(row.receivedAt.formatted(date: .complete, time: .complete))

                if let notificationID = row.notificationID {
                    Button(role: .destructive) {
                        Task { await model.clearNotification(id: notificationID) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss this notification")
                    .accessibilityLabel("Dismiss notification for \(row.topic)")
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    profileNavigationLink(row.profile, controlIdentifier: firstValidControlIdentifier(row.controls))
                    Text("·")
                    controlLinks(row.controls, profile: row.profile)
                    if let matchedCount = row.matchedCount {
                        Text("· \(matchedCount) matched")
                    }
                    Text("· \(outcomeTitle(row.outcome))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 3)
    }

    private func publishTestNotification() {
        guard model.isListening, testPublisherError == nil, !isPublishing else { return }
        let topic = testTopic
        let text = testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : testText
        let appID = testAppID.isEmpty ? nil : testAppID
        isPublishing = true
        publishFeedback = nil

        Task { @MainActor in
            let response = await model.publishNotification(topic: topic, text: text, ttlSeconds: 10, appID: appID)
            isPublishing = false
            if let error = response.error {
                publishSucceeded = false
                publishFeedback = error.message
            } else {
                publishSucceeded = true
                publishFeedback = "Test notification submitted."
            }
        }
    }

    private func outcomeTitle(_ outcome: String) -> String {
        outcome.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func copyTopic(_ topic: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(topic, forType: .string)
    }

    private func firstValidControlIdentifier(_ identifiers: [String]) -> String? {
        identifiers.first { D200XControl(rawValue: $0) != nil }
    }

    private static func isForbiddenNotificationTextScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || [0x85, 0x2028, 0x2029, 0x061C, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(scalar.value)
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
            Text("No controls matched")
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

private struct NotificationHistoryRow: Identifiable {
    let id: UUID
    let notificationID: UUID?
    let topic: String
    let appID: String?
    let receivedAt: Date
    let profile: String?
    let controls: [String]
    let outcome: String
    let matchedCount: Int?
    let text: String?
}
