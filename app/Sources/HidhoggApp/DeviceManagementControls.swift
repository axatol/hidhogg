import SwiftUI
import HidhoggDomain

struct DeviceManagementControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var isRemovalConfirmationPresented = false
    @State private var pendingRemovalID: UUID?

    let family: DeviceFamily?
    let registrationID: UUID?

    init(family: DeviceFamily) { self.family = family; registrationID = nil }
    init(registrationID: UUID) { family = nil; self.registrationID = registrationID }

    var body: some View {
        if let registration = registrationID.flatMap({ model.registration(id: $0) }) ?? family.flatMap({ model.registration(for: $0) }) {
            controls(for: registration)
        }
    }

    private func controls(for registration: RegisteredDevice) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if !registration.isEnabled {
                    disabledStatus
                }

                Spacer(minLength: 8)

                actionButtons(for: registration)
            }

            VStack(alignment: .leading, spacing: 8) {
                if !registration.isEnabled {
                    disabledStatus
                }

                actionButtons(for: registration)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .disabled(!model.canEditConfiguration)
        .confirmationDialog(
            "Remove device and its settings?",
            isPresented: $isRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove Device", role: .destructive) {
                if let pendingRemovalID { model.removeDevice(pendingRemovalID) }
                pendingRemovalID = nil
            }
            Button("Cancel", role: .cancel) { pendingRemovalID = nil }
        } message: {
            Text("This removes the registration and its saved settings from Hidhogg. macOS pairing is retained. Older configuration files remain on disk for recovery.")
        }
    }

    private var disabledStatus: some View {
        Text("Disabled — settings retained")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func actionButtons(for registration: RegisteredDevice) -> some View {
        HStack(spacing: 8) {
            Button(
                registration.isEnabled ? "Disable" : "Enable",
                systemImage: registration.isEnabled ? "pause.circle" : "play.circle"
            ) {
                model.setDeviceEnabled(registration.id, enabled: !registration.isEnabled)
            }

            Button("Remove", systemImage: "trash", role: .destructive) {
                pendingRemovalID = registration.id
                isRemovalConfirmationPresented = true
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
