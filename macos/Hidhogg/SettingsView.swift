import AppKit
import Combine
import SwiftUI

struct SettingsConfigEditorClientFactory: RuntimeConfigEditorClientCreating, Sendable {
    static let phaseTimeoutNanoseconds: UInt64 = 10_000_000_000

    private let transportFactory: @Sendable () -> any SocketTransport

    init(transportFactory: @escaping @Sendable () -> any SocketTransport = { DarwinSocketTransport() }) {
        self.transportFactory = transportFactory
    }

    func make(socketPath: String, instanceID: String) throws -> any RuntimeConfigEditorChecking {
        try ConfigEditorClient(
            socketPath: socketPath,
            instanceID: instanceID,
            transport: transportFactory(),
            phaseTimeoutNanoseconds: Self.phaseTimeoutNanoseconds
        )
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    enum MappingStatus: Equatable {
        case valid
        case stale
        case catalogUnavailable
        case invalid(String)
    }

    struct MappingRow: Identifiable, Equatable {
        let bundleIdentifier: String
        let profileID: String
        let status: MappingStatus

        var id: String {
            "\(bundleIdentifier)\u{0}\(profileID)"
        }
    }

    typealias ApplicationSelector = @MainActor () -> ApplicationBundleSelection
    typealias RuntimeEndpointProvider = @MainActor () -> RuntimeSessionController.RuntimeEndpoint?

    struct CloneRequest: Equatable, Sendable {
        let profileID: String
        let label: String
        let sourceProfileID: String?
        let sourceDigest: String
    }

    struct DeleteRequest: Equatable, Sendable {
        let profileID: String
        let sourceDigest: String
    }

    enum PendingConfirmation: Equatable {
        case clone(CloneRequest)
        case delete(DeleteRequest)
    }

    @Published private(set) var pendingBundleIdentifier: String?
    @Published private(set) var pendingProfileID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var editorSnapshot: ConfigEditorSnapshotResponse?
    @Published private(set) var editedProfile: ConfigEditorProfileResponse?
    @Published private(set) var editorPositions: [ConfigEditorPositionSummary] = []
    @Published private(set) var editedPosition: ConfigEditorPositionResponse?
    @Published private(set) var selectedEditorProfileID: String?
    @Published private(set) var selectedEditorPositionID: String?
    @Published private(set) var pendingConfirmation: PendingConfirmation?
    @Published private(set) var editorErrorMessage: String?
    @Published private(set) var editorNoticeMessage: String?
    @Published private(set) var lastMutationSummary: String?
    @Published private(set) var isEditorBusy = false
    @Published private(set) var requiresSnapshotRefresh = false
    @Published var newProfileID = ""
    @Published var newProfileLabel = ""
    @Published var newProfileSourceID: String?
    @Published var editedProfileLabel = ""
    @Published var editedPositionLabel = ""

    private let model: HidhoggAppModel
    private let applicationSelector: ApplicationSelector
    private let editorClientFactory: any RuntimeConfigEditorClientCreating
    private let runtimeEndpointProvider: RuntimeEndpointProvider
    private var boundEndpoint: RuntimeSessionController.RuntimeEndpoint?
    private var editorSession: EditorSession?
    private var editorRequestGeneration: UInt64 = 0
    private var profileSelectionGeneration: UInt64 = 0
    private var positionSelectionGeneration: UInt64 = 0
    private var editorRequestTask: Task<Void, Never>?
    private var catalogRefreshTask: Task<Void, Never>?

    private struct EditorSession: Sendable {
        let endpoint: RuntimeSessionController.RuntimeEndpoint
        let generation: UInt64
        let client: any RuntimeConfigEditorChecking
    }

    convenience init(model: HidhoggAppModel) {
        self.init(
            model: model,
            applicationSelector: { ApplicationBundlePicker.choose() }
        )
    }

    init(
        model: HidhoggAppModel,
        applicationSelector: @escaping ApplicationSelector,
        editorClientFactory: any RuntimeConfigEditorClientCreating = SettingsConfigEditorClientFactory(),
        runtimeEndpointProvider: RuntimeEndpointProvider? = nil
    ) {
        self.model = model
        self.applicationSelector = applicationSelector
        self.editorClientFactory = editorClientFactory
        self.runtimeEndpointProvider = runtimeEndpointProvider ?? { [weak model] in
            model?.runtimeSession.endpoint
        }
        setEditorEndpoint(self.runtimeEndpointProvider())
    }

    var availableProfiles: [ProfileSummary] {
        model.profileCatalog?.profiles ?? []
    }

    var hasEditorEndpoint: Bool {
        editorSession != nil
    }

    var canRefreshEditorSnapshot: Bool {
        editorSession != nil && !isEditorBusy
    }

    var canCloneProfile: Bool {
        guard !isEditorBusy,
              !requiresSnapshotRefresh,
              let editorSnapshot,
              editorSnapshot.profileIDs.count < 31,
              ProfileValidation.isValidID(newProfileID),
              ProfileValidation.isValidLabel(newProfileLabel),
              !editorSnapshot.profileIDs.contains(newProfileID) else {
            return false
        }
        guard let newProfileSourceID else { return true }
        return editorSnapshot.profileIDs.contains(newProfileSourceID)
    }

    var canSaveProfileLabel: Bool {
        guard !isEditorBusy,
              !requiresSnapshotRefresh,
              let editedProfile,
              editedProfile.sourceDigest == editorSnapshot?.sourceDigest,
              ProfileValidation.isValidLabel(editedProfileLabel) else {
            return false
        }
        return editedProfileLabel != editedProfile.label
    }

    var canSavePositionLabel: Bool {
        guard !isEditorBusy,
              !requiresSnapshotRefresh,
              let editorSnapshot,
              let editedPosition,
              editedPosition.sourceDigest == editorSnapshot.sourceDigest,
              editedPosition.profileID == selectedEditorProfileID,
              editedPosition.positionID == selectedEditorPositionID,
              ProfileValidation.isValidPositionLabel(editedPositionLabel) else {
            return false
        }
        return editedPositionLabel != editedPosition.label
    }

    var editorSnapshotDigest: String? {
        editorSnapshot?.sourceDigest
    }

    func waitForEditorIdle() async {
        while true {
            if let editorRequestTask {
                await editorRequestTask.value
                continue
            }
            if let catalogRefreshTask {
                await catalogRefreshTask.value
                continue
            }
            return
        }
    }

    private func clearProfileEditingState() {
        profileSelectionGeneration &+= 1
        selectedEditorProfileID = nil
        editedProfile = nil
        editedProfileLabel = ""
        clearPositionEditingState()
    }

    private func clearPositionEditingState() {
        editorPositions = []
        clearSelectedPositionEditingState()
    }

    private func clearSelectedPositionEditingState() {
        positionSelectionGeneration &+= 1
        selectedEditorPositionID = nil
        editedPosition = nil
        editedPositionLabel = ""
    }

    func setEditorEndpoint(_ endpoint: RuntimeSessionController.RuntimeEndpoint?) {
        if endpoint == boundEndpoint, editorSession != nil { return }
        if endpoint == nil, boundEndpoint == nil, editorSession == nil { return }

        editorRequestGeneration &+= 1
        editorRequestTask = nil
        editorSession = nil
        boundEndpoint = endpoint
        editorSnapshot = nil
        clearProfileEditingState()
        pendingConfirmation = nil
        editorErrorMessage = nil
        editorNoticeMessage = nil
        lastMutationSummary = nil
        isEditorBusy = false
        requiresSnapshotRefresh = false
        newProfileID = ""
        newProfileLabel = ""
        newProfileSourceID = nil

        guard let endpoint else { return }
        do {
            editorSession = EditorSession(
                endpoint: endpoint,
                generation: editorRequestGeneration,
                client: try editorClientFactory.make(
                    socketPath: endpoint.socketPath,
                    instanceID: endpoint.instanceID
                )
            )
            refreshEditorSnapshot()
        } catch {
            editorErrorMessage = "The profile editor could not connect to the current runtime."
        }
    }

    func refreshEditorSnapshot() {
        guard let session = currentEditorSession() else { return }
        guard !isEditorBusy else { return }

        clearProfileEditingState()
        editorErrorMessage = nil
        isEditorBusy = true
        let client = session.client
        let requestID = UUID().uuidString.lowercased()
        let operation = Task.detached(priority: .userInitiated) {
            Result {
                try client.configEditorSnapshot(requestID: requestID)
            }
        }
        editorRequestTask = Task { @MainActor [weak self] in
            let result = await operation.value
            guard let self else { return }
            guard self.editorRequestGeneration == session.generation else { return }
            guard self.isCurrent(session) else {
                self.setEditorEndpoint(self.runtimeEndpointProvider())
                return
            }

            self.editorRequestTask = nil
            self.isEditorBusy = false
            switch result {
            case .success(let snapshot):
                guard snapshot.instanceID == session.endpoint.instanceID else {
                    self.editorErrorMessage = "The editor response did not match the current runtime."
                    return
                }
                self.editorSnapshot = snapshot
                if let newProfileSourceID = self.newProfileSourceID,
                   !snapshot.profileIDs.contains(newProfileSourceID) {
                    self.newProfileSourceID = nil
                }
                self.requiresSnapshotRefresh = false
            case .failure:
                self.requiresSnapshotRefresh = true
                self.editorErrorMessage = "The profile editor snapshot could not be loaded. Refresh before editing."
            }
        }
    }

    func selectProfileForEditing(_ profileID: String?) {
        guard !isEditorBusy else { return }
        guard let profileID else {
            clearProfileEditingState()
            editorErrorMessage = nil
            return
        }
        guard let session = currentEditorSession(),
              !requiresSnapshotRefresh,
              let snapshot = editorSnapshot,
              snapshot.profileIDs.contains(profileID) else {
            editorErrorMessage = "Choose a profile from the current editor snapshot."
            return
        }

        profileSelectionGeneration &+= 1
        let selectionGeneration = profileSelectionGeneration
        clearPositionEditingState()
        selectedEditorProfileID = profileID
        editedProfile = nil
        editedProfileLabel = ""
        editorErrorMessage = nil
        isEditorBusy = true
        let client = session.client
        let requestID = UUID().uuidString.lowercased()
        let sourceDigest = snapshot.sourceDigest
        let operation = Task.detached(priority: .userInitiated) {
            Result {
                try client.configEditorProfile(
                    profileID: profileID,
                    sourceDigest: sourceDigest,
                    requestID: requestID
                )
            }
        }
        editorRequestTask = Task { @MainActor [weak self] in
            let result = await operation.value
            guard let self else { return }
            guard self.editorRequestGeneration == session.generation else { return }
            guard self.profileSelectionGeneration == selectionGeneration,
                  self.selectedEditorProfileID == profileID else { return }
            guard self.isCurrent(session) else {
                self.setEditorEndpoint(self.runtimeEndpointProvider())
                return
            }

            self.editorRequestTask = nil
            self.isEditorBusy = false
            switch result {
            case .success(let profile):
                guard profile.instanceID == session.endpoint.instanceID,
                      profile.sourceDigest == sourceDigest,
                      profile.profileID == profileID else {
                    self.editorErrorMessage = "The editor response did not match the current profile snapshot."
                    return
                }
                self.editedProfile = profile
                self.editedProfileLabel = profile.label
                self.loadEditorPositions(
                    session: session,
                    profileID: profileID,
                    sourceDigest: sourceDigest,
                    selectionGeneration: selectionGeneration
                )
            case .failure(let error):
                self.handleReadFailure(error, message: "Profile details could not be loaded from the current runtime.")
            }
        }
    }

    private func loadEditorPositions(
        session: EditorSession,
        profileID: String,
        sourceDigest: String,
        selectionGeneration: UInt64
    ) {
        guard !isEditorBusy,
              profileSelectionGeneration == selectionGeneration,
              selectedEditorProfileID == profileID,
              editorSnapshot?.sourceDigest == sourceDigest else {
            return
        }
        guard isCurrent(session) else {
            setEditorEndpoint(runtimeEndpointProvider())
            return
        }

        isEditorBusy = true
        let client = session.client
        let requestID = UUID().uuidString.lowercased()
        let operation = Task.detached(priority: .userInitiated) {
            Result {
                try client.configEditorPositions(
                    profileID: profileID,
                    sourceDigest: sourceDigest,
                    requestID: requestID
                )
            }
        }
        editorRequestTask = Task { @MainActor [weak self] in
            let result = await operation.value
            guard let self else { return }
            guard self.editorRequestGeneration == session.generation,
                  self.profileSelectionGeneration == selectionGeneration,
                  self.selectedEditorProfileID == profileID else { return }
            guard self.isCurrent(session) else {
                self.setEditorEndpoint(self.runtimeEndpointProvider())
                return
            }

            self.editorRequestTask = nil
            self.isEditorBusy = false
            switch result {
            case .success(let response):
                guard response.instanceID == session.endpoint.instanceID,
                      response.sourceDigest == sourceDigest,
                      response.profileID == profileID else {
                    self.editorErrorMessage = "Position choices did not match the current profile snapshot."
                    return
                }
                self.editorPositions = response.positions
            case .failure(let error):
                self.handleReadFailure(
                    error,
                    message: "Position choices could not be loaded from the current runtime."
                )
            }
        }
    }

    func selectPositionForEditing(_ positionID: String?) {
        guard !isEditorBusy else { return }
        guard let positionID else {
            clearSelectedPositionEditingState()
            editorErrorMessage = nil
            return
        }
        guard let session = currentEditorSession(),
              !requiresSnapshotRefresh,
              let snapshot = editorSnapshot,
              let profileID = selectedEditorProfileID,
              editorPositions.contains(where: { $0.positionID == positionID }) else {
            editorErrorMessage = "Choose a position from the current profile snapshot."
            return
        }

        positionSelectionGeneration &+= 1
        let selectionGeneration = positionSelectionGeneration
        let profileGeneration = profileSelectionGeneration
        selectedEditorPositionID = positionID
        editedPosition = nil
        editedPositionLabel = ""
        editorErrorMessage = nil
        isEditorBusy = true
        let client = session.client
        let requestID = UUID().uuidString.lowercased()
        let sourceDigest = snapshot.sourceDigest
        let operation = Task.detached(priority: .userInitiated) {
            Result {
                try client.configEditorPosition(
                    profileID: profileID,
                    positionID: positionID,
                    sourceDigest: sourceDigest,
                    requestID: requestID
                )
            }
        }
        editorRequestTask = Task { @MainActor [weak self] in
            let result = await operation.value
            guard let self else { return }
            guard self.editorRequestGeneration == session.generation,
                  self.profileSelectionGeneration == profileGeneration,
                  self.positionSelectionGeneration == selectionGeneration,
                  self.selectedEditorProfileID == profileID,
                  self.selectedEditorPositionID == positionID else { return }
            guard self.isCurrent(session) else {
                self.setEditorEndpoint(self.runtimeEndpointProvider())
                return
            }

            self.editorRequestTask = nil
            self.isEditorBusy = false
            switch result {
            case .success(let response):
                guard response.instanceID == session.endpoint.instanceID,
                      response.sourceDigest == sourceDigest,
                      response.profileID == profileID,
                      response.positionID == positionID else {
                    self.editorErrorMessage = "The position label did not match the current profile snapshot."
                    return
                }
                self.editedPosition = response
                self.editedPositionLabel = response.label
            case .failure(let error):
                self.handleReadFailure(
                    error,
                    message: "The position label could not be loaded from the current runtime."
                )
            }
        }
    }

    func requestCloneProfile() {
        guard canCloneProfile, let snapshot = editorSnapshot else {
            editorErrorMessage = "Enter a valid new profile ID and label, and choose a valid source."
            return
        }
        pendingConfirmation = .clone(
            CloneRequest(
                profileID: newProfileID,
                label: newProfileLabel,
                sourceProfileID: newProfileSourceID,
                sourceDigest: snapshot.sourceDigest
            )
        )
        editorErrorMessage = nil
    }

    func requestDeleteProfile(_ profileID: String) {
        guard let snapshot = editorSnapshot else {
            editorErrorMessage = "Refresh the editor snapshot before deleting a profile."
            return
        }
        guard let reason = profileDeletionBlockReason(profileID) else {
            pendingConfirmation = .delete(
                DeleteRequest(profileID: profileID, sourceDigest: snapshot.sourceDigest)
            )
            editorErrorMessage = nil
            return
        }
        editorErrorMessage = reason
    }

    func confirmPendingProfileChange() {
        guard !isEditorBusy, !requiresSnapshotRefresh else { return }
        guard let session = currentEditorSession(),
              let snapshot = editorSnapshot,
              let pendingConfirmation else {
            return
        }
        self.pendingConfirmation = nil

        switch pendingConfirmation {
        case .clone(let request):
            guard request.sourceDigest == snapshot.sourceDigest,
                  canCloneProfile,
                  request.profileID == newProfileID,
                  request.label == newProfileLabel,
                  request.sourceProfileID == newProfileSourceID else {
                editorErrorMessage = "The clone details changed. Review them and confirm again."
                return
            }
            performMutation(session: session) { client in
                try client.createConfigEditorProfile(
                    profileID: request.profileID,
                    label: request.label,
                    expectedDigest: request.sourceDigest,
                    sourceProfileID: request.sourceProfileID,
                    requestID: UUID().uuidString.lowercased()
                )
            }
        case .delete(let request):
            guard request.sourceDigest == snapshot.sourceDigest,
                  profileDeletionBlockReason(request.profileID) == nil else {
                editorErrorMessage = profileDeletionBlockReason(request.profileID)
                    ?? "The editor snapshot changed. Refresh before deleting."
                return
            }
            performMutation(session: session) { client in
                try client.deleteConfigEditorProfile(
                    profileID: request.profileID,
                    expectedDigest: request.sourceDigest,
                    requestID: UUID().uuidString.lowercased()
                )
            }
        }
    }

    func dismissPendingConfirmation() {
        pendingConfirmation = nil
    }

    func saveEditedProfileLabel() {
        guard canSaveProfileLabel,
              let session = currentEditorSession(),
              let editedProfile,
              let snapshot = editorSnapshot else {
            editorErrorMessage = "Choose a profile and enter a valid label before saving."
            return
        }
        let profileID = editedProfile.profileID
        let label = editedProfileLabel
        let expectedDigest = snapshot.sourceDigest
        performMutation(session: session) { client in
            try client.setConfigEditorProfileLabel(
                profileID: profileID,
                label: label,
                expectedDigest: expectedDigest,
                requestID: UUID().uuidString.lowercased()
            )
        }
    }

    func saveEditedPositionLabel() {
        guard canSavePositionLabel,
              let session = currentEditorSession(),
              let editedPosition,
              let snapshot = editorSnapshot else {
            editorErrorMessage = "Choose a position and enter a valid label before saving."
            return
        }
        let profileID = editedPosition.profileID
        let positionID = editedPosition.positionID
        let label = editedPositionLabel
        let expectedDigest = snapshot.sourceDigest
        performMutation(session: session) { client in
            try client.setConfigEditorPositionLabel(
                profileID: profileID,
                positionID: positionID,
                label: label,
                expectedDigest: expectedDigest,
                requestID: UUID().uuidString.lowercased()
            )
        }
    }

    func profileDeletionBlockReason(_ profileID: String) -> String? {
        guard let snapshot = editorSnapshot,
              snapshot.profileIDs.contains(profileID) else {
            return "The profile is not in the current editor snapshot."
        }
        if profileID == snapshot.defaultProfileID {
            return "The default profile cannot be deleted."
        }
        if profileID == snapshot.currentProfileID {
            return "The current profile cannot be deleted."
        }
        if model.mappings.sortedMappings.contains(where: { $0.profileID == profileID }) ||
            model.mappings.invalidMappings.contains(where: { $0.mapping.profileID == profileID }) {
            return "A saved application mapping refers to this profile."
        }
        return nil
    }

    private func performMutation(
        session: EditorSession,
        operation: @escaping @Sendable (any RuntimeConfigEditorChecking) throws -> ConfigEditorMutationResponse
    ) {
        guard !isEditorBusy,
              !requiresSnapshotRefresh,
              isCurrent(session) else {
            editorErrorMessage = "The runtime changed. Refresh the editor before making another change."
            return
        }

        isEditorBusy = true
        editorErrorMessage = nil
        let request = Task.detached(priority: .userInitiated) {
            Result {
                try operation(session.client)
            }
        }
        editorRequestTask = Task { @MainActor [weak self] in
            let result = await request.value
            guard let self else { return }
            guard self.editorRequestGeneration == session.generation else { return }
            guard self.isCurrent(session) else {
                self.setEditorEndpoint(self.runtimeEndpointProvider())
                return
            }

            self.editorRequestTask = nil
            self.isEditorBusy = false
            switch result {
            case .success(let response):
                guard response.instanceID == session.endpoint.instanceID else {
                    self.requiresSnapshotRefresh = true
                    self.editorErrorMessage = "The editor response did not match the current runtime."
                    return
                }
                self.lastMutationSummary = Self.mutationSummary(response)
                self.editorNoticeMessage = nil
                self.requiresSnapshotRefresh = true
                self.refreshCatalogAfterMutation()
                self.refreshEditorSnapshot()
            case .failure(let error):
                if Self.isStaleSourceError(error) {
                    self.editorNoticeMessage = "The configuration changed. This edit was not retried; refreshing the snapshot."
                    self.requiresSnapshotRefresh = true
                    self.refreshEditorSnapshot()
                } else if Self.isUncertainMutationError(error) {
                    self.requiresSnapshotRefresh = true
                    self.editorErrorMessage = "Outcome unknown: the runtime may have committed this edit. Refresh the snapshot before editing again."
                } else {
                    self.editorErrorMessage = "The runtime rejected the profile edit. Review the snapshot and try again."
                }
            }
        }
    }

    private func refreshCatalogAfterMutation() {
        let model = self.model
        catalogRefreshTask = Task { @MainActor [weak self] in
            await model.refreshProfileCatalog()
            self?.catalogRefreshTask = nil
        }
    }

    private func currentEditorSession() -> EditorSession? {
        guard runtimeEndpointProvider() == boundEndpoint else {
            setEditorEndpoint(runtimeEndpointProvider())
            return nil
        }
        return editorSession
    }

    private func isCurrent(_ session: EditorSession) -> Bool {
        editorRequestGeneration == session.generation &&
            boundEndpoint == session.endpoint &&
            runtimeEndpointProvider() == session.endpoint
    }

    private func handleReadFailure(
        _ error: Error,
        message: String = "Profile details could not be loaded from the current runtime."
    ) {
        if Self.isStaleSourceError(error) {
            editorNoticeMessage = "The configuration changed. This read was not retried; refreshing the snapshot."
            requiresSnapshotRefresh = true
            refreshEditorSnapshot()
        } else {
            editorErrorMessage = message
        }
    }

    private static func isStaleSourceError(_ error: Error) -> Bool {
        guard case UnixSocketClientError.response(.serverError(let runtimeError)) = error else {
            return false
        }
        return runtimeError.code == "stale_source"
    }

    private static func isUncertainMutationError(_ error: Error) -> Bool {
        guard let error = error as? UnixSocketClientError else { return true }
        switch error {
        case .response(.serverError):
            return false
        default:
            return true
        }
    }

    private static func mutationSummary(_ response: ConfigEditorMutationResponse) -> String {
        let file = switch response.fileCommit {
        case .unchanged: "File unchanged"
        case .committed: "File committed"
        case .uncertain: "File outcome uncertain"
        }
        let reload = switch response.reloadOutcome {
        case .unchanged: "runtime unchanged"
        case .changed: "runtime reloaded"
        case .rejected: "runtime rejected reload"
        case .uncertain: "runtime outcome uncertain"
        case .notAttempted: "runtime reload not attempted"
        }
        let effect = response.effect == .unchanged ? "" : " (\(response.effect.rawValue))"
        let reason = response.reason == .none ? "" : " — \(response.reason.rawValue)"
        return "\(file); \(reload)\(effect)\(reason)"
    }

    var pendingPickerProfileID: String? {
        guard let pendingProfileID,
              availableProfiles.contains(where: { $0.id == pendingProfileID }) else {
            return nil
        }
        return pendingProfileID
    }

    var mappingRows: [MappingRow] {
        Self.makeMappingRows(preferences: model.mappings, catalog: model.profileCatalog)
    }

    var canAddApplication: Bool {
        !availableProfiles.isEmpty
    }

    func beginApplicationSelection() {
        guard canAddApplication else {
            errorMessage = "Profiles are unavailable until the runtime is ready."
            return
        }
        switch applicationSelector() {
        case .cancelled:
            return
        case .invalid:
            errorMessage = "The selected application has no valid bundle identifier."
            return
        case .selected(let bundleIdentifier):
            pendingProfileID = model.mappingProfileID(for: bundleIdentifier)
                .flatMap { profileID in
                    availableProfiles.contains(where: { $0.id == profileID }) ? profileID : nil
                }
                ?? availableProfiles.first?.id
            pendingBundleIdentifier = bundleIdentifier
            errorMessage = nil
        }
    }

    func selectPendingProfile(_ profileID: String) {
        guard availableProfiles.contains(where: { $0.id == profileID }) else { return }
        pendingProfileID = profileID
    }

    func commitPendingMapping() {
        guard let bundleIdentifier = pendingBundleIdentifier,
              let profileID = pendingProfileID else {
            errorMessage = "Choose a profile before adding the mapping."
            return
        }
        guard availableProfiles.contains(where: { $0.id == profileID }) else {
            errorMessage = "Choose a profile from the live runtime catalog."
            return
        }
        do {
            try model.setMapping(
                profileID: profileID,
                forBundleIdentifier: bundleIdentifier
            )
            cancelPendingMapping()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func cancelPendingMapping() {
        pendingBundleIdentifier = nil
        pendingProfileID = nil
        errorMessage = nil
    }

    func updateMapping(bundleIdentifier: String, profileID: String) {
        guard availableProfiles.contains(where: { $0.id == profileID }) else {
            errorMessage = "Choose a profile from the live runtime catalog."
            return
        }
        do {
            try model.setMapping(
                profileID: profileID,
                forBundleIdentifier: bundleIdentifier
            )
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func removeMapping(bundleIdentifier: String) {
        model.removeMapping(forBundleIdentifier: bundleIdentifier)
        errorMessage = nil
    }

    static func makeMappingRows(
        preferences: ProfileMappingPreferences,
        catalog: ProfileListResponse?
    ) -> [MappingRow] {
        let availableProfileIDs = Set(catalog?.profiles.map(\.id) ?? [])
        let validRows = preferences.sortedMappings.map { mapping in
            MappingRow(
                bundleIdentifier: mapping.bundleIdentifier,
                profileID: mapping.profileID,
                status: catalog == nil
                    ? .catalogUnavailable
                    : availableProfileIDs.contains(mapping.profileID) ? .valid : .stale
            )
        }
        let invalidRows = preferences.invalidMappings.map { invalidMapping in
            MappingRow(
                bundleIdentifier: invalidMapping.mapping.bundleIdentifier,
                profileID: invalidMapping.mapping.profileID,
                status: .invalid(Self.message(for: invalidMapping.reason))
            )
        }
        return (validRows + invalidRows).sorted {
            if $0.bundleIdentifier == $1.bundleIdentifier {
                return $0.profileID < $1.profileID
            }
            return $0.bundleIdentifier < $1.bundleIdentifier
        }
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? ProfileMappingPreferencesError else {
            return "The mapping could not be saved."
        }
        return message(for: error)
    }

    private static func message(for reason: ProfileMappingInvalidReason) -> String {
        switch reason {
        case .invalidBundleIdentifier:
            return "Invalid bundle identifier"
        case .invalidProfileIdentifier:
            return "Invalid profile identifier"
        case .mappingLimitExceeded:
            return "Mapping limit exceeded"
        }
    }

    private static func message(for error: ProfileMappingPreferencesError) -> String {
        switch error {
        case .invalidBundleIdentifier:
            return "The application bundle identifier is invalid."
        case .invalidProfileIdentifier:
            return "The profile identifier is invalid."
        case .mappingLimitExceeded:
            return "The maximum number of mappings has been reached."
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject private var model: HidhoggAppModel
    @StateObject private var viewModel: SettingsViewModel

    init(model: HidhoggAppModel) {
        self.model = model
        _viewModel = StateObject(wrappedValue: SettingsViewModel(model: model))
    }

    var body: some View {
        Form {
            Section("Configuration") {
                LabeledContent("TOML file") {
                    Text(model.selectedConfigurationPath ?? "Not selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(model.selectedConfigurationPath == nil ? .secondary : .primary)
                }
                Button("Choose…") {
                    model.chooseConfiguration()
                }
                Text(model.healthText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Application mappings") {
                if viewModel.mappingRows.isEmpty {
                    Text("No application mappings")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.mappingRows) { row in
                        SettingsMappingRowView(
                            row: row,
                            model: model,
                            viewModel: viewModel
                        )
                    }
                }

                if let pendingBundleIdentifier = viewModel.pendingBundleIdentifier {
                    PendingMappingView(
                        bundleIdentifier: pendingBundleIdentifier,
                        viewModel: viewModel
                    )
                }

                Button("Add Application…") {
                    viewModel.beginApplicationSelection()
                }
                .disabled(!viewModel.canAddApplication || viewModel.pendingBundleIdentifier != nil)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section("Profiles") {
                if !viewModel.hasEditorEndpoint {
                    Text("Profile editing is available when the runtime is ready.")
                        .foregroundStyle(.secondary)
                } else if let snapshot = viewModel.editorSnapshot {
                    HStack {
                        Text("Source SHA-256")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(snapshot.sourceDigest)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    LabeledContent("Default", value: snapshot.defaultProfileID)
                    LabeledContent("Current", value: snapshot.currentProfileID)

                    HStack {
                        Button("Refresh snapshot") {
                            viewModel.refreshEditorSnapshot()
                        }
                        .disabled(!viewModel.canRefreshEditorSnapshot)
                        if viewModel.isEditorBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    Picker(
                        "Edit profile",
                        selection: Binding(
                            get: { viewModel.selectedEditorProfileID },
                            set: { viewModel.selectProfileForEditing($0) }
                        )
                    ) {
                        Text("Choose a profile").tag(nil as String?)
                        ForEach(snapshot.profileIDs, id: \.self) { profileID in
                            Text(profileID).tag(profileID as String?)
                        }
                    }

                    if viewModel.editedProfile != nil {
                        TextField("Profile label", text: $viewModel.editedProfileLabel)
                        Button("Save label") {
                            viewModel.saveEditedProfileLabel()
                        }
                        .disabled(!viewModel.canSaveProfileLabel)

                        let deleteReason = viewModel.selectedEditorProfileID
                            .flatMap(viewModel.profileDeletionBlockReason)
                        Button("Delete profile…", role: .destructive) {
                            if let profileID = viewModel.selectedEditorProfileID {
                                viewModel.requestDeleteProfile(profileID)
                            }
                        }
                        .disabled(
                            viewModel.isEditorBusy ||
                                viewModel.requiresSnapshotRefresh ||
                                deleteReason != nil
                        )
                        if let deleteReason {
                            Text(deleteReason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                        Text("Edit position label")
                            .font(.headline)
                        Picker(
                            "Position",
                            selection: Binding(
                                get: { viewModel.selectedEditorPositionID },
                                set: { viewModel.selectPositionForEditing($0) }
                            )
                        ) {
                            Text("Choose a position").tag(nil as String?)
                            ForEach(viewModel.editorPositions, id: \.positionID) { position in
                                Text(position.position)
                                    .tag(position.positionID as String?)
                            }
                        }
                        .disabled(
                            viewModel.isEditorBusy ||
                                viewModel.requiresSnapshotRefresh ||
                                viewModel.editorPositions.count != 14
                        )
                        if viewModel.editorPositions.count != 14 {
                            Text(viewModel.isEditorBusy
                                 ? "Loading position choices…"
                                 : "Position choices are unavailable for this snapshot.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if viewModel.editedPosition != nil {
                            TextField("Position label", text: $viewModel.editedPositionLabel)
                            Button("Save position label") {
                                viewModel.saveEditedPositionLabel()
                            }
                            .disabled(!viewModel.canSavePositionLabel)
                        }
                    }

                    Divider()
                    Text("Clone a profile")
                        .font(.headline)
                    TextField("New stable profile ID", text: $viewModel.newProfileID)
                    TextField("New profile label", text: $viewModel.newProfileLabel)
                    Picker("Clone from", selection: $viewModel.newProfileSourceID) {
                        Text("Current when created (\(snapshot.currentProfileID))")
                            .tag(nil as String?)
                        ForEach(snapshot.profileIDs, id: \.self) { profileID in
                            Text(profileID).tag(profileID as String?)
                        }
                    }
                    Button("Review clone…") {
                        viewModel.requestCloneProfile()
                    }
                    .disabled(!viewModel.canCloneProfile)

                    if viewModel.requiresSnapshotRefresh {
                        Text("Refresh the snapshot before making another change.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let lastMutationSummary = viewModel.lastMutationSummary {
                        Text(lastMutationSummary)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    if let editorNoticeMessage = viewModel.editorNoticeMessage {
                        Text(editorNoticeMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let editorErrorMessage = viewModel.editorErrorMessage {
                        Text(editorErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text(viewModel.editorErrorMessage ?? "Loading the profile editor snapshot…")
                        .foregroundStyle(.secondary)
                    Button("Refresh snapshot") {
                        viewModel.refreshEditorSnapshot()
                    }
                    .disabled(!viewModel.canRefreshEditorSnapshot)
                }
            }

            Section("Runtime") {
                Text(model.profileStatusText)
                    .foregroundStyle(.secondary)
                if viewModel.availableProfiles.isEmpty {
                    Text("Profile choices appear when the Go runtime is ready.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 420)
        .padding()
        .onReceive(model.runtimeSession.$endpoint) { endpoint in
            viewModel.setEditorEndpoint(endpoint)
        }
        .confirmationDialog(
            "Confirm profile change",
            isPresented: Binding(
                get: { viewModel.pendingConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissPendingConfirmation()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            switch viewModel.pendingConfirmation {
            case .clone(let request):
                Button("Create \(request.profileID)") {
                    viewModel.confirmPendingProfileChange()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.dismissPendingConfirmation()
                }
            case .delete(let request):
                Button("Delete \(request.profileID)", role: .destructive) {
                    viewModel.confirmPendingProfileChange()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.dismissPendingConfirmation()
                }
            case nil:
                EmptyView()
            }
        } message: {
            switch viewModel.pendingConfirmation {
            case .clone(let request):
                let source = request.sourceProfileID ?? "the current profile when the change is committed"
                Text("Clone \(source) as \(request.profileID) with label “\(request.label)”?")
            case .delete(let request):
                Text("Delete \(request.profileID)? Go will also refuse deletion if the profile is referenced by a TOML action.")
            case nil:
                EmptyView()
            }
        }
    }
}

@MainActor
private struct SettingsMappingRowView: View {
    let row: SettingsViewModel.MappingRow
    @ObservedObject var model: HidhoggAppModel
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.bundleIdentifier.isEmpty ? "Invalid bundle identifier" : row.bundleIdentifier)
                statusView
            }
            Spacer(minLength: 12)
            if case .invalid = row.status {
                EmptyView()
            } else if model.profileCatalog == nil {
                Text("Catalog unavailable")
                    .foregroundStyle(.secondary)
            } else {
                Picker(
                    "Profile",
                    selection: Binding(
                        get: { row.profileID },
                        set: { viewModel.updateMapping(bundleIdentifier: row.bundleIdentifier, profileID: $0) }
                    )
                ) {
                    if !model.profileCatalog!.profiles.contains(where: { $0.id == row.profileID }) {
                        Text("Missing: \(row.profileID)").tag(row.profileID)
                    }
                    ForEach(model.profileCatalog!.profiles, id: \.id) { profile in
                        Text("\(profile.label) (\(profile.id))").tag(profile.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
            }
            Button("Remove", role: .destructive) {
                viewModel.removeMapping(bundleIdentifier: row.bundleIdentifier)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusView: some View {
        switch row.status {
        case .valid:
            Text("Active mapping")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .stale:
            Label("Stale profile: \(row.profileID)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        case .catalogUnavailable:
            Text("Profile validity unknown until runtime is ready")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .invalid(let reason):
            Text(reason)
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}

@MainActor
private struct PendingMappingView: View {
    let bundleIdentifier: String
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New mapping")
                .font(.headline)
            Text(bundleIdentifier)
                .font(.caption)
            Picker(
                "Profile",
                selection: Binding(
                    get: { viewModel.pendingPickerProfileID },
                    set: { profileID in
                        if let profileID {
                            viewModel.selectPendingProfile(profileID)
                        }
                    }
                )
            ) {
                if viewModel.pendingPickerProfileID == nil {
                    Text("Choose a profile")
                        .tag(nil as String?)
                }
                ForEach(viewModel.availableProfiles, id: \.id) { profile in
                    Text("\(profile.label) (\(profile.id))").tag(profile.id as String?)
                }
            }
            HStack {
                Button("Add Mapping") {
                    viewModel.commitPendingMapping()
                }
                .disabled(viewModel.pendingProfileID == nil)
                Button("Cancel") {
                    viewModel.cancelPendingMapping()
                }
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
