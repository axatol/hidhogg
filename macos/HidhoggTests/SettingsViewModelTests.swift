import Darwin
import AppKit
import Foundation
import XCTest
import UniformTypeIdentifiers
@testable import Hidhogg

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testProfileStatusPrioritizesStateOverCachedCurrentProfile() {
        let cases: [(ProfileSwitchCoordinatorState, String)] = [
            (.invalidMapping(bundleIdentifier: "com.example.editor", profileID: "Missing.Profile"), "Profile: stale mapping (Missing.Profile)"),
            (.unavailable, "Profile: runtime unavailable"),
            (.waitingForRuntime, "Profile: waiting for runtime"),
            (.stopped, "Profile: stopped"),
            (.outcomeUnknown(profileID: "Work.Profile"), "Profile: switch to Work.Profile is unconfirmed"),
            (.switching(profileID: "Work.Profile"), "Profile: switching to Work.Profile…")
        ]

        for (state, expected) in cases {
            XCTAssertEqual(
                HidhoggAppModel.profileStatusText(
                    state: state,
                    currentProfileID: "Cached.Profile"
                ),
                expected
            )
        }
    }

    func testProfileStatusShowsHealthyCurrentOnlyForCurrentOrUnmatchedState() {
        XCTAssertEqual(
            HidhoggAppModel.profileStatusText(
                state: .current(profileID: "Work.Profile"),
                currentProfileID: "Cached.Profile"
            ),
            "Profile: Work.Profile"
        )
        XCTAssertEqual(
            HidhoggAppModel.profileStatusText(
                state: .unmatched(bundleIdentifier: "com.example.editor"),
                currentProfileID: "Cached.Profile"
            ),
            "Profile: Cached.Profile"
        )
        XCTAssertEqual(
            HidhoggAppModel.profileStatusText(
                state: .unmatched(bundleIdentifier: "com.example.editor"),
                currentProfileID: nil
            ),
            "Profile: unchanged"
        )
    }

    func testMappingRowsMarkProfilesMissingFromTheLiveCatalogAsStale() {
        let preferences = ProfileMappingPreferences(mappings: [
            "com.example.editor": "Removed.Profile",
            "com.example.terminal": "Default"
        ])
        let catalog = ProfileListResponse(
            requestID: "request",
            instanceID: "instance",
            profiles: [
                ProfileSummary(id: "Default", label: "Default", isDefault: true, isCurrent: true)
            ]
        )

        let rows = SettingsViewModel.makeMappingRows(
            preferences: preferences,
            catalog: catalog
        )

        XCTAssertEqual(rows.map(\.bundleIdentifier), [
            "com.example.editor",
            "com.example.terminal"
        ])
        XCTAssertEqual(rows[0].status, .stale)
        XCTAssertEqual(rows[1].status, .valid)
    }

    func testMappingRowsKeepStoredInvalidEntriesVisible() {
        let preferences = ProfileMappingPreferences(mappings: [
            "": "Default",
            "com.example.editor": ""
        ])

        let rows = SettingsViewModel.makeMappingRows(
            preferences: preferences,
            catalog: nil
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy {
            if case .invalid = $0.status { return true }
            return false
        })
    }

    func testModelMappingEditsPersistTheCompleteSnapshot() throws {
        let store = TestSettingsMappingStore()
        let model = HidhoggAppModel(
            executablePath: "/tmp/hidhogg-runtime",
            preferencesStore: TestAppPreferencesStore(),
            profileMappingStore: store
        )

        try model.setMapping(
            profileID: "Work.Profile",
            forBundleIdentifier: "com.example.editor"
        )

        XCTAssertEqual(store.values, ["com.example.editor": "Work.Profile"])
        XCTAssertEqual(model.mappings.profileID(for: "com.example.editor"), "Work.Profile")
    }

    func testPendingApplicationMappingPersistsSelectedLiveProfile() async throws {
        let initialMappings = ["com.example.editor": "Default"]
        let store = TestSettingsMappingStore(values: initialMappings)
        let (model, _) = try await makeConfiguredModel(
            store: store,
            mappings: initialMappings
        )
        let viewModel = SettingsViewModel(
            model: model,
            applicationSelector: { .selected("com.example.terminal") }
        )

        viewModel.beginApplicationSelection()
        XCTAssertEqual(viewModel.pendingBundleIdentifier, "com.example.terminal")
        XCTAssertEqual(viewModel.pendingProfileID, "Default")
        XCTAssertEqual(viewModel.pendingPickerProfileID, "Default")

        viewModel.selectPendingProfile("Work.Profile")
        viewModel.commitPendingMapping()
        await model.profileCoordinator.waitForIdle()

        XCTAssertNil(viewModel.pendingBundleIdentifier)
        XCTAssertNil(viewModel.pendingProfileID)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            store.values,
            [
                "com.example.editor": "Default",
                "com.example.terminal": "Work.Profile"
            ]
        )
        XCTAssertEqual(model.mappings.profileID(for: "com.example.terminal"), "Work.Profile")
        await model.profileCoordinator.shutdown()
    }

    func testPendingApplicationMappingRejectsProfileMissingFromLiveCatalog() async throws {
        let initialMappings = ["com.example.editor": "Default"]
        let store = TestSettingsMappingStore(values: initialMappings)
        let (model, client) = try await makeConfiguredModel(
            store: store,
            mappings: initialMappings
        )
        let viewModel = SettingsViewModel(
            model: model,
            applicationSelector: { .selected("com.example.terminal") }
        )

        viewModel.beginApplicationSelection()
        viewModel.selectPendingProfile("Work.Profile")
        client.setProfileIDs(["Default"])
        model.retryProfileSwitch()
        await model.profileCoordinator.waitForIdle()
        try model.setMapping(
            profileID: "Default",
            forBundleIdentifier: "com.example.editor"
        )
        await model.profileCoordinator.waitForIdle()

        XCTAssertEqual(viewModel.availableProfiles.map(\.id), ["Default"])
        XCTAssertNil(viewModel.pendingPickerProfileID)
        viewModel.commitPendingMapping()

        XCTAssertEqual(viewModel.errorMessage, "Choose a profile from the live runtime catalog.")
        XCTAssertEqual(viewModel.pendingBundleIdentifier, "com.example.terminal")
        XCTAssertEqual(viewModel.pendingProfileID, "Work.Profile")
        XCTAssertEqual(store.values, initialMappings)
        await model.profileCoordinator.shutdown()
    }

    func testUpdateMappingPersistsSelectedLiveProfile() async throws {
        let initialMappings = ["com.example.editor": "Default"]
        let store = TestSettingsMappingStore(values: initialMappings)
        let (model, _) = try await makeConfiguredModel(
            store: store,
            mappings: initialMappings
        )
        let viewModel = SettingsViewModel(model: model)

        viewModel.updateMapping(
            bundleIdentifier: "com.example.editor",
            profileID: "Work.Profile"
        )
        await model.profileCoordinator.waitForIdle()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(store.values, ["com.example.editor": "Work.Profile"])
        XCTAssertEqual(model.mappings.profileID(for: "com.example.editor"), "Work.Profile")
        await model.profileCoordinator.shutdown()
    }

    func testRemoveMappingPersistsRemainingMappings() async throws {
        let initialMappings = [
            "com.example.editor": "Default",
            "com.example.terminal": "Work.Profile"
        ]
        let store = TestSettingsMappingStore(values: initialMappings)
        let (model, _) = try await makeConfiguredModel(
            store: store,
            mappings: initialMappings
        )
        let viewModel = SettingsViewModel(model: model)

        viewModel.removeMapping(bundleIdentifier: "com.example.terminal")
        await model.profileCoordinator.waitForIdle()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(store.values, ["com.example.editor": "Default"])
        XCTAssertNil(model.mappings.profileID(for: "com.example.terminal"))
        await model.profileCoordinator.shutdown()
    }

    func testApplicationBundleIdentifierReadsOnlyTheBundleIdentifier() throws {
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: applicationURL) }
        let info = ["CFBundleIdentifier": "com.example.editor"]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        XCTAssertEqual(
            ApplicationBundlePicker.bundleIdentifier(at: applicationURL),
            "com.example.editor"
        )
    }

    func testApplicationBundleIdentifierRejectsNonApplications() {
        XCTAssertNil(
            ApplicationBundlePicker.bundleIdentifier(
                at: URL(fileURLWithPath: "/Applications/Editor.txt")
            )
        )
        XCTAssertNil(
            ApplicationBundlePicker.bundleIdentifier(
                at: URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true)
            )
        )
    }

    func testApplicationBundlePickerAllowsSelectingApplicationPackages() {
        let panel = NSOpenPanel()

        ApplicationBundlePicker.configure(panel)

        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.resolvesAliases)
        XCTAssertEqual(panel.allowedContentTypes, [.applicationBundle])
    }

    func testEditorEndpointReplacementDropsLateSnapshotAndClearsEditor() async throws {
        let firstEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let firstClient = SettingsConfigEditorTestClient(
            instanceID: firstEndpoint.instanceID,
            blocksFirstSnapshot: true
        )
        let secondClient = SettingsConfigEditorTestClient(instanceID: secondEndpoint.instanceID)
        let factory = SettingsConfigEditorTestClientFactory(clients: [
            firstEndpoint.instanceID: firstClient,
            secondEndpoint.instanceID: secondClient
        ])
        let endpointBox = SettingsEditorEndpointBox(endpoint: firstEndpoint)
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            editorClientFactory: factory,
            runtimeEndpointProvider: { endpointBox.endpoint }
        )

        for _ in 0..<200 where firstClient.snapshotCallCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(firstClient.snapshotCallCount, 1)

        endpointBox.endpoint = secondEndpoint
        viewModel.setEditorEndpoint(secondEndpoint)
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.editorSnapshot?.instanceID, secondEndpoint.instanceID)
        XCTAssertEqual(factory.socketPaths, [firstEndpoint.socketPath, secondEndpoint.socketPath])
        XCTAssertEqual(factory.instanceIDs, [firstEndpoint.instanceID, secondEndpoint.instanceID])

        firstClient.releaseFirstSnapshot()
        for _ in 0..<200 where firstClient.snapshotCompletionCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await Task.yield()
        XCTAssertEqual(viewModel.editorSnapshot?.instanceID, secondEndpoint.instanceID)

        endpointBox.endpoint = nil
        viewModel.setEditorEndpoint(nil)
        XCTAssertNil(viewModel.editorSnapshot)
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertNil(viewModel.lastMutationSummary)
        XCTAssertFalse(viewModel.hasEditorEndpoint)
    }

    func testLateDeleteMutationResultIsDiscardedAfterEndpointReplacement() async throws {
        let firstEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let firstClient = SettingsConfigEditorTestClient(instanceID: firstEndpoint.instanceID)
        let secondClient = SettingsConfigEditorTestClient(instanceID: secondEndpoint.instanceID)
        let endpointBox = SettingsEditorEndpointBox(endpoint: firstEndpoint)
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            editorClientFactory: SettingsConfigEditorTestClientFactory(clients: [
                firstEndpoint.instanceID: firstClient,
                secondEndpoint.instanceID: secondClient
            ]),
            runtimeEndpointProvider: { endpointBox.endpoint }
        )
        await viewModel.waitForEditorIdle()

        firstClient.blockNextDelete()
        defer { firstClient.releaseDelete() }
        viewModel.requestDeleteProfile("Work.Profile")
        viewModel.confirmPendingProfileChange()
        for _ in 0..<200 where firstClient.deleteCallCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(firstClient.deleteCallCount, 1)

        endpointBox.endpoint = secondEndpoint
        viewModel.setEditorEndpoint(secondEndpoint)
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.editorSnapshot?.instanceID, secondEndpoint.instanceID)
        XCTAssertNil(viewModel.lastMutationSummary)

        firstClient.releaseDelete()
        for _ in 0..<200 where firstClient.deleteCompletionCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(firstClient.deleteCompletionCount, 1)
        XCTAssertEqual(viewModel.editorSnapshot?.instanceID, secondEndpoint.instanceID)
        XCTAssertNil(viewModel.lastMutationSummary)
        XCTAssertFalse(viewModel.isEditorBusy)
    }

    func testCloneRequiresConfirmedIDAndLabelAndStaleDigestRefreshesWithoutRetry() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        client.setNextMutationError(
            .response(.serverError(RuntimeError(
                code: "stale_source",
                message: "configuration source changed; refresh and retry"
            )))
        )
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            editorClientFactory: SettingsConfigEditorTestClientFactory(clients: [
                endpoint.instanceID: client
            ]),
            runtimeEndpointProvider: { endpoint }
        )
        await viewModel.waitForEditorIdle()

        XCTAssertFalse(viewModel.canCloneProfile)
        viewModel.newProfileID = "Copy.Profile"
        viewModel.newProfileLabel = "Copy"
        XCTAssertTrue(viewModel.canCloneProfile)
        viewModel.requestCloneProfile()
        guard case .clone(let request) = viewModel.pendingConfirmation else {
            return XCTFail("clone requires a confirmation")
        }
        XCTAssertEqual(request.profileID, "Copy.Profile")
        XCTAssertEqual(request.label, "Copy")
        XCTAssertNil(request.sourceProfileID)

        viewModel.confirmPendingProfileChange()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.createCallCount, 1)
        XCTAssertEqual(client.lastCreateProfileID, "Copy.Profile")
        XCTAssertEqual(client.lastCreateLabel, "Copy")
        XCTAssertNil(client.lastCreateSourceProfileID)
        XCTAssertEqual(client.snapshotCallCount, 2)
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, String(repeating: "b", count: 64))
        XCTAssertTrue(viewModel.editorNoticeMessage?.contains("was not retried") == true)

    }

    func testMutationTimeoutIsOutcomeUnknownAndNotRetried() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        client.setNextMutationError(.readTimedOut)
        let viewModel = makeEditorViewModel(
            client: client,
            endpoint: endpoint,
            model: makeSettingsModel()
        )
        await viewModel.waitForEditorIdle()
        viewModel.newProfileID = "Copy.Profile"
        viewModel.newProfileLabel = "Copy"
        viewModel.requestCloneProfile()
        viewModel.confirmPendingProfileChange()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.createCallCount, 1)
        XCTAssertEqual(client.snapshotCallCount, 1)
        XCTAssertTrue(viewModel.requiresSnapshotRefresh)
        XCTAssertTrue(viewModel.editorErrorMessage?.contains("Outcome unknown") == true)

        viewModel.refreshEditorSnapshot()
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(client.snapshotCallCount, 2)
        XCTAssertEqual(client.createCallCount, 1)
    }

    func testDeleteAdvisoryLeavesRacedMappingVisibleAsStaleAndRefreshesCatalogOnly() async throws {
        let initialMappings = ["com.example.editor": "Default"]
        let store = TestSettingsMappingStore(values: initialMappings)
        let (model, profileClient) = try await makeConfiguredModel(
            store: store,
            mappings: initialMappings
        )
        let endpoint = editorEndpoint(instanceID: "settings-test")
        let editorClient = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        let viewModel = makeEditorViewModel(client: editorClient, endpoint: endpoint, model: model)
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(viewModel.profileDeletionBlockReason("Default"), "The default profile cannot be deleted.")
        XCTAssertNil(viewModel.profileDeletionBlockReason("Work.Profile"))
        viewModel.requestDeleteProfile("Default")
        XCTAssertNil(viewModel.pendingConfirmation)

        editorClient.blockNextDelete()
        viewModel.requestDeleteProfile("Work.Profile")
        viewModel.confirmPendingProfileChange()
        for _ in 0..<200 where editorClient.deleteCallCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(editorClient.deleteCallCount, 1)

        try model.setMapping(
            profileID: "Work.Profile",
            forBundleIdentifier: "com.example.terminal"
        )
        await model.profileCoordinator.waitForIdle()
        profileClient.setProfileIDs(["Default"])
        editorClient.releaseDelete()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(editorClient.deleteCallCount, 1)
        XCTAssertEqual(profileClient.activationCount, 0)
        XCTAssertGreaterThan(profileClient.listCount, 1)
        XCTAssertEqual(model.mappings.profileID(for: "com.example.terminal"), "Work.Profile")
        XCTAssertEqual(viewModel.lastMutationSummary, "File committed; runtime reloaded (catalog)")
        let staleMapping = try XCTUnwrap(
            viewModel.mappingRows.first(where: { $0.bundleIdentifier == "com.example.terminal" })
        )
        XCTAssertEqual(staleMapping.status, .stale)
        await model.profileCoordinator.shutdown()
    }

    func testCurrentProfileDeletionIsRejectedSeparatelyFromDefault() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(
            instanceID: endpoint.instanceID,
            currentProfileID: "Work.Profile"
        )
        let viewModel = makeEditorViewModel(
            client: client,
            endpoint: endpoint,
            model: makeSettingsModel()
        )
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(viewModel.editorSnapshot?.defaultProfileID, "Default")
        XCTAssertEqual(viewModel.editorSnapshot?.currentProfileID, "Work.Profile")
        XCTAssertEqual(
            viewModel.profileDeletionBlockReason("Work.Profile"),
            "The current profile cannot be deleted."
        )
        XCTAssertEqual(
            viewModel.profileDeletionBlockReason("Default"),
            "The default profile cannot be deleted."
        )

        viewModel.requestDeleteProfile("Work.Profile")

        XCTAssertNil(viewModel.pendingConfirmation)
        XCTAssertEqual(client.deleteCallCount, 0)
    }

    func testPositionLabelEditorCanClearLabelButRejectsWhitespace() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        let viewModel = makeEditorViewModel(
            client: client,
            endpoint: endpoint,
            model: makeSettingsModel()
        )
        await viewModel.waitForEditorIdle()
        viewModel.selectProfileForEditing("Work.Profile")
        await viewModel.waitForEditorIdle()
        viewModel.selectPositionForEditing("0_0")
        await viewModel.waitForEditorIdle()

        viewModel.editedPositionLabel = " "
        XCTAssertFalse(viewModel.canSavePositionLabel)
        viewModel.editedPositionLabel = ""
        XCTAssertTrue(viewModel.canSavePositionLabel)
        viewModel.saveEditedPositionLabel()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionLabelSetCallCount, 1)
        XCTAssertEqual(client.lastPositionSetLabel, "")
        XCTAssertEqual(viewModel.lastMutationSummary, "File committed; runtime reloaded (display)")
    }

    func testPositionLabelEditorLoadsStableChoicesAndSavesAgainstSnapshotDigest() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        let viewModel = makeEditorViewModel(
            client: client,
            endpoint: endpoint,
            model: makeSettingsModel()
        )
        await viewModel.waitForEditorIdle()

        viewModel.selectProfileForEditing("Work.Profile")
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(viewModel.editorPositions.count, 14)
        XCTAssertEqual(viewModel.editorPositions.first?.positionID, "0_0")
        XCTAssertEqual(viewModel.editorPositions.first?.position, "0_0")
        XCTAssertEqual(client.lastPositionsProfileID, "Work.Profile")
        XCTAssertEqual(client.lastPositionsSourceDigest, String(repeating: "a", count: 64))

        viewModel.selectPositionForEditing("0_0")
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(viewModel.editedPosition?.positionID, "0_0")
        XCTAssertEqual(viewModel.editedPositionLabel, "Label 0_0")
        XCTAssertEqual(client.lastPositionGetID, "0_0")
        XCTAssertEqual(client.lastPositionGetProfileID, "Work.Profile")
        XCTAssertEqual(client.lastPositionGetDigest, String(repeating: "a", count: 64))

        viewModel.editedPositionLabel = "Clock"
        XCTAssertTrue(viewModel.canSavePositionLabel)
        viewModel.saveEditedPositionLabel()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionLabelSetCallCount, 1)
        XCTAssertEqual(client.lastPositionSetProfileID, "Work.Profile")
        XCTAssertEqual(client.lastPositionSetID, "0_0")
        XCTAssertEqual(client.lastPositionSetLabel, "Clock")
        XCTAssertEqual(client.lastPositionSetDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, String(repeating: "b", count: 64))
        XCTAssertEqual(viewModel.lastMutationSummary, "File committed; runtime reloaded (display)")
        XCTAssertNil(viewModel.selectedEditorProfileID)
    }

    func testPositionSelectionAndDraftResetWhenProfileChanges() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        let viewModel = makeEditorViewModel(
            client: client,
            endpoint: endpoint,
            model: makeSettingsModel()
        )
        await viewModel.waitForEditorIdle()

        viewModel.selectProfileForEditing("Work.Profile")
        await viewModel.waitForEditorIdle()
        viewModel.selectPositionForEditing("0_0")
        await viewModel.waitForEditorIdle()
        viewModel.editedPositionLabel = "Unsaved"

        viewModel.selectProfileForEditing("Default")

        XCTAssertEqual(viewModel.selectedEditorProfileID, "Default")
        XCTAssertTrue(viewModel.editorPositions.isEmpty)
        XCTAssertNil(viewModel.selectedEditorPositionID)
        XCTAssertNil(viewModel.editedPosition)
        XCTAssertEqual(viewModel.editedPositionLabel, "")
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.editorPositions.count, 14)
        XCTAssertNil(viewModel.selectedEditorPositionID)
        XCTAssertNil(viewModel.editedPosition)
        XCTAssertEqual(viewModel.editedPositionLabel, "")
    }

    func testLatePositionDetailIsDiscardedAfterEndpointReplacement() async throws {
        let firstEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let firstClient = SettingsConfigEditorTestClient(instanceID: firstEndpoint.instanceID)
        let secondClient = SettingsConfigEditorTestClient(instanceID: secondEndpoint.instanceID)
        let endpointBox = SettingsEditorEndpointBox(endpoint: firstEndpoint)
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            editorClientFactory: SettingsConfigEditorTestClientFactory(clients: [
                firstEndpoint.instanceID: firstClient,
                secondEndpoint.instanceID: secondClient
            ]),
            runtimeEndpointProvider: { endpointBox.endpoint }
        )
        await viewModel.waitForEditorIdle()
        viewModel.selectProfileForEditing("Work.Profile")
        await viewModel.waitForEditorIdle()

        firstClient.blockNextPositionGet()
        defer { firstClient.releasePositionGet() }
        viewModel.selectPositionForEditing("0_0")
        for _ in 0..<200 where firstClient.positionGetCallCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(firstClient.positionGetCallCount, 1)

        endpointBox.endpoint = secondEndpoint
        viewModel.setEditorEndpoint(secondEndpoint)
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(viewModel.editorSnapshot?.instanceID, secondEndpoint.instanceID)
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertTrue(viewModel.editorPositions.isEmpty)
        XCTAssertNil(viewModel.selectedEditorPositionID)
        XCTAssertNil(viewModel.editedPosition)
        XCTAssertEqual(viewModel.editedPositionLabel, "")

        firstClient.releasePositionGet()
        for _ in 0..<200 where firstClient.positionGetCompletionCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(firstClient.positionGetCompletionCount, 1)
        XCTAssertEqual(viewModel.editorSnapshot?.instanceID, secondEndpoint.instanceID)
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertTrue(viewModel.editorPositions.isEmpty)
        XCTAssertNil(viewModel.selectedEditorPositionID)
        XCTAssertNil(viewModel.editedPosition)
        XCTAssertEqual(viewModel.editedPositionLabel, "")
        XCTAssertFalse(viewModel.isEditorBusy)
    }

    func testStalePositionDetailRefreshesSnapshotWithoutRetryingRead() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        client.setNextPositionGetError(
            .response(.serverError(RuntimeError(
                code: "stale_source",
                message: "configuration source changed; refresh and retry"
            )))
        )
        let viewModel = makeEditorViewModel(
            client: client,
            endpoint: endpoint,
            model: makeSettingsModel()
        )
        await viewModel.waitForEditorIdle()
        viewModel.selectProfileForEditing("Work.Profile")
        await viewModel.waitForEditorIdle()

        viewModel.selectPositionForEditing("0_0")
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionGetCallCount, 1)
        XCTAssertEqual(client.snapshotCallCount, 2)
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, String(repeating: "b", count: 64))
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertTrue(viewModel.editorNoticeMessage?.contains("read was not retried") == true)
    }

    func testSuccessfulLabelMutationRefreshesSnapshotDigestAndReportsOutcomes() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        let viewModel = makeEditorViewModel(
            client: client,
            endpoint: endpoint,
            model: makeSettingsModel()
        )
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, String(repeating: "a", count: 64))

        viewModel.selectProfileForEditing("Work.Profile")
        await viewModel.waitForEditorIdle()
        viewModel.editedProfileLabel = "Work renamed"
        viewModel.saveEditedProfileLabel()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.labelSetCallCount, 1)
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, String(repeating: "b", count: 64))
        XCTAssertEqual(viewModel.lastMutationSummary, "File committed; runtime reloaded (catalog)")
    }

    func testSettingsEditorFactoryUsesTenSecondTimeoutForSlowSnapshot() throws {
        let instanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let requestID = "11111111-1111-4111-8111-111111111111"
        let transport = DelayedConfigEditorSnapshotTransport(instanceID: instanceID, delay: 1.1)
        let factory = SettingsConfigEditorClientFactory(transportFactory: { transport })
        let endpoint = try makeEditorSocketEndpoint()
        defer { endpoint.cleanup() }
        let client = try factory.make(socketPath: endpoint.socket.path, instanceID: instanceID)

        let start = Date()
        let snapshot = try client.configEditorSnapshot(requestID: requestID)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(snapshot.instanceID, instanceID)
        XCTAssertGreaterThan(elapsed, 1.0)
        XCTAssertEqual(
            transport.timeouts,
            [SettingsConfigEditorClientFactory.phaseTimeoutNanoseconds]
        )
        XCTAssertEqual(SettingsConfigEditorClientFactory.phaseTimeoutNanoseconds, 10_000_000_000)
    }

    private func makeConfiguredModel(
        store: TestSettingsMappingStore,
        mappings: [String: String]
    ) async throws -> (HidhoggAppModel, SettingsProfileClient) {
        let client = SettingsProfileClient()
        let coordinator = ProfileSwitchCoordinator(
            mappings: ProfileMappingPreferences(mappings: mappings),
            client: client
        )
        await coordinator.setRuntimeEndpoint(
            RuntimeSessionController.RuntimeEndpoint(
                instanceID: "settings-test",
                socketPath: "/private/tmp/settings-test.sock"
            )
        )
        coordinator.startObserving(
            SettingsForegroundObserver(initialBundleIdentifier: "com.example.editor")
        )
        await coordinator.waitForIdle()

        let model = HidhoggAppModel(
            executablePath: "/tmp/hidhogg-runtime",
            preferencesStore: TestAppPreferencesStore(),
            profileMappingStore: store,
            profileCoordinator: coordinator
        )
        guard let initialMapping = coordinator.mappings.sortedMappings.first else {
            throw SettingsViewModelTestError.missingInitialMapping
        }
        try model.setMapping(
            profileID: initialMapping.profileID,
            forBundleIdentifier: initialMapping.bundleIdentifier
        )
        await coordinator.waitForIdle()
        return (model, client)
    }

    private func makeEditorViewModel(
        client: SettingsConfigEditorTestClient,
        endpoint: RuntimeSessionController.RuntimeEndpoint,
        model: HidhoggAppModel
    ) -> SettingsViewModel {
        SettingsViewModel(
            model: model,
            applicationSelector: { .cancelled },
            editorClientFactory: SettingsConfigEditorTestClientFactory(clients: [
                endpoint.instanceID: client
            ]),
            runtimeEndpointProvider: { endpoint }
        )
    }

    private func makeSettingsModel() -> HidhoggAppModel {
        HidhoggAppModel(
            executablePath: "/tmp/hidhogg-runtime",
            preferencesStore: TestAppPreferencesStore(),
            profileMappingStore: TestSettingsMappingStore()
        )
    }

    private func editorEndpoint(instanceID: String) -> RuntimeSessionController.RuntimeEndpoint {
        RuntimeSessionController.RuntimeEndpoint(
            instanceID: instanceID,
            socketPath: "/private/tmp/\(instanceID).sock"
        )
    }

    private func makeEditorSocketEndpoint() throws -> SettingsEditorSocketEndpoint {
        let directory = URL(
            fileURLWithPath: "/private/tmp/hidhogg-settings-editor-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let socket = directory.appendingPathComponent("runtime.sock")
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw UnixSocketClientError.systemCall("socket", errno)
        }

        do {
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socket.path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                for offset in 0..<rawBuffer.count {
                    rawBuffer[offset] = 0
                }
                for (offset, byte) in pathBytes.enumerated() where offset < rawBuffer.count - 1 {
                    rawBuffer[offset] = byte
                }
            }
            let bindResult = withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0, Darwin.chmod(socket.path, mode_t(0o600)) == 0 else {
                throw UnixSocketClientError.systemCall("bind", errno)
            }
        } catch {
            _ = Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return SettingsEditorSocketEndpoint(directory: directory, socket: socket, descriptor: descriptor)
    }

}

private enum SettingsViewModelTestError: Error {
    case missingInitialMapping
}

private final class TestAppPreferencesStore: @unchecked Sendable, AppPreferencesStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

private final class TestSettingsMappingStore: @unchecked Sendable, ProfileMappingPreferencesStore {
    private(set) var values: [String: String]?

    init(values: [String: String]? = nil) {
        self.values = values
    }

    func dictionary(forKey key: String) -> [String: String]? {
        values
    }

    func set(_ value: [String: String]?, forKey key: String) {
        values = value
    }
}

private final class SettingsProfileClient: @unchecked Sendable, RuntimeProfileChecking {
    private let lock = NSLock()
    private var currentProfileID = "Default"
    private var profileIDs = ["Default", "Work.Profile"]
    private var activationCountStorage = 0
    private var listCountStorage = 0

    var activationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activationCountStorage
    }

    var listCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return listCountStorage
    }

    func setProfileIDs(_ profileIDs: [String]) {
        lock.lock()
        self.profileIDs = profileIDs
        lock.unlock()
    }

    func listProfiles(requestID: String) throws -> ProfileListResponse {
        lock.lock()
        listCountStorage += 1
        let currentProfileID = self.currentProfileID
        let profileIDs = self.profileIDs
        lock.unlock()
        return ProfileListResponse(
            requestID: requestID,
            instanceID: "settings-test",
            profiles: profileIDs.map { profileID in
                ProfileSummary(
                    id: profileID,
                    label: profileID,
                    isDefault: profileID == "Default",
                    isCurrent: profileID == currentProfileID
                )
            }
        )
    }

    func activateProfile(profileID: String, requestID: String) throws -> ProfileActivationResponse {
        lock.lock()
        defer { lock.unlock() }
        activationCountStorage += 1
        guard profileIDs.contains(profileID) else {
            throw SettingsProfileClientError.profileMissing
        }
        currentProfileID = profileID
        return ProfileActivationResponse(
            requestID: requestID,
            profileID: profileID,
            changed: true
        )
    }
}

private enum SettingsConfigEditorTestFailure: Error, Sendable {
    case missingClient
}

@MainActor
private final class SettingsEditorEndpointBox {
    var endpoint: RuntimeSessionController.RuntimeEndpoint?

    init(endpoint: RuntimeSessionController.RuntimeEndpoint?) {
        self.endpoint = endpoint
    }
}

private struct SettingsEditorSocketEndpoint {
    let directory: URL
    let socket: URL
    let descriptor: Int32

    func cleanup() {
        _ = Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SettingsConfigEditorTestClientFactory: @unchecked Sendable, RuntimeConfigEditorClientCreating {
    private let lock = NSLock()
    private let clients: [String: SettingsConfigEditorTestClient]
    private var socketPathsStorage: [String] = []
    private var instanceIDsStorage: [String] = []

    var socketPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return socketPathsStorage
    }

    var instanceIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return instanceIDsStorage
    }

    init(clients: [String: SettingsConfigEditorTestClient]) {
        self.clients = clients
    }

    func make(socketPath: String, instanceID: String) throws -> any RuntimeConfigEditorChecking {
        lock.lock()
        socketPathsStorage.append(socketPath)
        instanceIDsStorage.append(instanceID)
        let client = clients[instanceID]
        lock.unlock()
        guard let client else { throw SettingsConfigEditorTestFailure.missingClient }
        return client
    }
}

private final class SettingsConfigEditorTestClient: @unchecked Sendable, RuntimeConfigEditorChecking {
    private let lock = NSLock()
    private let instanceID: String
    private let blocksFirstSnapshot: Bool
    private let firstSnapshotRelease = DispatchSemaphore(value: 0)
    private let deleteRelease = DispatchSemaphore(value: 0)
    private let positionGetRelease = DispatchSemaphore(value: 0)
    private var revisionStorage: UInt64 = 1
    private var digestStorage = String(repeating: "a", count: 64)
    private var profileIDsStorage = ["Default", "Work.Profile"]
    private var labelsStorage = ["Default": "Default", "Work.Profile": "Work"]
    private let positionCoordinates = [
        "0_0", "1_0", "2_0", "3_0", "4_0",
        "0_1", "1_1", "2_1", "3_1", "4_1",
        "0_2", "1_2", "2_2", "3_2"
    ]
    private var positionLabelsStorage: [String: String] = [:]
    private var currentProfileIDStorage = "Default"
    private var snapshotCallCountStorage = 0
    private var snapshotCompletionCountStorage = 0
    private var createCallCountStorage = 0
    private var deleteCallCountStorage = 0
    private var deleteCompletionCountStorage = 0
    private var labelSetCallCountStorage = 0
    private var positionsListCallCountStorage = 0
    private var positionGetCallCountStorage = 0
    private var positionGetCompletionCountStorage = 0
    private var positionLabelSetCallCountStorage = 0
    private var lastCreateProfileIDStorage: String?
    private var lastCreateLabelStorage: String?
    private var lastCreateSourceProfileIDStorage: String?
    private var lastPositionsProfileIDStorage: String?
    private var lastPositionsSourceDigestStorage: String?
    private var lastPositionGetProfileIDStorage: String?
    private var lastPositionGetIDStorage: String?
    private var lastPositionGetDigestStorage: String?
    private var lastPositionSetProfileIDStorage: String?
    private var lastPositionSetIDStorage: String?
    private var lastPositionSetLabelStorage: String?
    private var lastPositionSetDigestStorage: String?
    private var nextMutationError: UnixSocketClientError?
    private var nextPositionGetError: UnixSocketClientError?
    private var blocksNextDelete = false
    private var blocksNextPositionGet = false

    init(
        instanceID: String,
        blocksFirstSnapshot: Bool = false,
        currentProfileID: String = "Default"
    ) {
        self.instanceID = instanceID
        self.blocksFirstSnapshot = blocksFirstSnapshot
        currentProfileIDStorage = currentProfileID
    }

    var snapshotCallCount: Int { read { snapshotCallCountStorage } }
    var snapshotCompletionCount: Int { read { snapshotCompletionCountStorage } }
    var createCallCount: Int { read { createCallCountStorage } }
    var deleteCallCount: Int { read { deleteCallCountStorage } }
    var deleteCompletionCount: Int { read { deleteCompletionCountStorage } }
    var labelSetCallCount: Int { read { labelSetCallCountStorage } }
    var positionsListCallCount: Int { read { positionsListCallCountStorage } }
    var positionGetCallCount: Int { read { positionGetCallCountStorage } }
    var positionGetCompletionCount: Int { read { positionGetCompletionCountStorage } }
    var positionLabelSetCallCount: Int { read { positionLabelSetCallCountStorage } }
    var lastCreateProfileID: String? { read { lastCreateProfileIDStorage } }
    var lastCreateLabel: String? { read { lastCreateLabelStorage } }
    var lastCreateSourceProfileID: String? { read { lastCreateSourceProfileIDStorage } }
    var lastPositionsProfileID: String? { read { lastPositionsProfileIDStorage } }
    var lastPositionsSourceDigest: String? { read { lastPositionsSourceDigestStorage } }
    var lastPositionGetProfileID: String? { read { lastPositionGetProfileIDStorage } }
    var lastPositionGetID: String? { read { lastPositionGetIDStorage } }
    var lastPositionGetDigest: String? { read { lastPositionGetDigestStorage } }
    var lastPositionSetProfileID: String? { read { lastPositionSetProfileIDStorage } }
    var lastPositionSetID: String? { read { lastPositionSetIDStorage } }
    var lastPositionSetLabel: String? { read { lastPositionSetLabelStorage } }
    var lastPositionSetDigest: String? { read { lastPositionSetDigestStorage } }

    func setNextMutationError(_ error: UnixSocketClientError) {
        lock.lock()
        nextMutationError = error
        lock.unlock()
    }

    func setNextPositionGetError(_ error: UnixSocketClientError) {
        lock.lock()
        nextPositionGetError = error
        lock.unlock()
    }

    func blockNextDelete() {
        lock.lock()
        blocksNextDelete = true
        lock.unlock()
    }

    func blockNextPositionGet() {
        lock.lock()
        blocksNextPositionGet = true
        lock.unlock()
    }

    func releaseFirstSnapshot() {
        firstSnapshotRelease.signal()
    }

    func releaseDelete() {
        deleteRelease.signal()
    }

    func releasePositionGet() {
        positionGetRelease.signal()
    }

    func configEditorSnapshot(requestID: String) throws -> ConfigEditorSnapshotResponse {
        lock.lock()
        snapshotCallCountStorage += 1
        let shouldBlock = blocksFirstSnapshot && snapshotCallCountStorage == 1
        lock.unlock()

        if shouldBlock {
            firstSnapshotRelease.wait()
        }

        lock.lock()
        snapshotCompletionCountStorage += 1
        let snapshot = makeSnapshot(requestID: requestID)
        lock.unlock()
        return snapshot
    }

    func configEditorProfile(
        profileID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorProfileResponse {
        lock.lock()
        defer { lock.unlock() }
        guard digestStorage == sourceDigest,
              let label = labelsStorage[profileID] else {
            throw staleSourceError
        }
        return ConfigEditorProfileResponse(
            requestID: requestID,
            instanceID: instanceID,
            sourceDigest: sourceDigest,
            profileID: profileID,
            label: label
        )
    }

    func configEditorPositions(
        profileID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorPositionsResponse {
        lock.lock()
        defer { lock.unlock() }
        positionsListCallCountStorage += 1
        lastPositionsProfileIDStorage = profileID
        lastPositionsSourceDigestStorage = sourceDigest
        guard digestStorage == sourceDigest,
              labelsStorage[profileID] != nil else {
            throw staleSourceError
        }
        let positions = positionCoordinates.map { coordinate in
            ConfigEditorPositionSummary(positionID: coordinate, position: coordinate)
        }
        return ConfigEditorPositionsResponse(
            requestID: requestID,
            instanceID: instanceID,
            sourceDigest: sourceDigest,
            profileID: profileID,
            positions: positions
        )
    }

    func configEditorPosition(
        profileID: String,
        positionID: String,
        sourceDigest: String,
        requestID: String
    ) throws -> ConfigEditorPositionResponse {
        lock.lock()
        positionGetCallCountStorage += 1
        lastPositionGetProfileIDStorage = profileID
        lastPositionGetIDStorage = positionID
        lastPositionGetDigestStorage = sourceDigest
        let shouldBlock = blocksNextPositionGet
        blocksNextPositionGet = false
        let configuredError = nextPositionGetError
        nextPositionGetError = nil
        lock.unlock()

        if shouldBlock {
            positionGetRelease.wait()
        }

        lock.lock()
        defer { lock.unlock() }
        positionGetCompletionCountStorage += 1
        if let configuredError {
            if case .response(.serverError(let runtimeError)) = configuredError,
               runtimeError.code == "stale_source" {
                advanceSnapshot()
            }
            throw configuredError
        }
        guard digestStorage == sourceDigest,
              labelsStorage[profileID] != nil,
              let index = positionIndex(for: positionID) else {
            throw staleSourceError
        }
        return ConfigEditorPositionResponse(
            requestID: requestID,
            instanceID: instanceID,
            sourceDigest: sourceDigest,
            profileID: profileID,
            positionID: positionID,
            label: positionLabelsStorage[positionID] ?? "Label \(positionCoordinates[index])"
        )
    }

    func setConfigEditorProfileLabel(
        profileID: String,
        label: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        lock.lock()
        defer { lock.unlock() }
        labelSetCallCountStorage += 1
        try throwPendingMutationError()
        guard digestStorage == expectedDigest,
              labelsStorage[profileID] != nil else {
            throw staleSourceError
        }
        labelsStorage[profileID] = label
        advanceSnapshot()
        return mutationResponse(requestID: requestID)
    }

    func createConfigEditorProfile(
        profileID: String,
        label: String,
        expectedDigest: String,
        sourceProfileID: String?,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        lock.lock()
        defer { lock.unlock() }
        createCallCountStorage += 1
        lastCreateProfileIDStorage = profileID
        lastCreateLabelStorage = label
        lastCreateSourceProfileIDStorage = sourceProfileID
        try throwPendingMutationError()
        guard digestStorage == expectedDigest,
              !profileIDsStorage.contains(profileID),
              sourceProfileID.map({ profileIDsStorage.contains($0) }) ?? true else {
            throw staleSourceError
        }
        profileIDsStorage.append(profileID)
        labelsStorage[profileID] = label
        advanceSnapshot()
        return mutationResponse(requestID: requestID)
    }

    func deleteConfigEditorProfile(
        profileID: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        lock.lock()
        deleteCallCountStorage += 1
        let shouldBlock = blocksNextDelete
        blocksNextDelete = false
        lock.unlock()

        if shouldBlock {
            deleteRelease.wait()
        }

        lock.lock()
        defer { lock.unlock() }
        try throwPendingMutationError()
        guard digestStorage == expectedDigest,
              profileIDsStorage.contains(profileID),
              profileID != "Default",
              profileID != currentProfileIDStorage else {
            throw staleSourceError
        }
        profileIDsStorage.removeAll { $0 == profileID }
        labelsStorage.removeValue(forKey: profileID)
        advanceSnapshot()
        deleteCompletionCountStorage += 1
        return mutationResponse(requestID: requestID)
    }

    func setConfigEditorPositionLabel(
        profileID: String,
        positionID: String,
        label: String,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        lock.lock()
        defer { lock.unlock() }
        positionLabelSetCallCountStorage += 1
        lastPositionSetProfileIDStorage = profileID
        lastPositionSetIDStorage = positionID
        lastPositionSetLabelStorage = label
        lastPositionSetDigestStorage = expectedDigest
        try throwPendingMutationError()
        guard digestStorage == expectedDigest,
              labelsStorage[profileID] != nil,
              positionIndex(for: positionID) != nil else {
            throw staleSourceError
        }
        positionLabelsStorage[positionID] = label
        advanceSnapshot()
        return mutationResponse(requestID: requestID, effect: .display)
    }

    private var staleSourceError: UnixSocketClientError {
        .response(.serverError(RuntimeError(
            code: "stale_source",
            message: "configuration source changed; refresh and retry"
        )))
    }

    private func throwPendingMutationError() throws {
        guard let error = nextMutationError else { return }
        nextMutationError = nil
        if case .response(.serverError(let runtimeError)) = error,
           runtimeError.code == "stale_source" {
            advanceSnapshot()
        }
        throw error
    }

    private func advanceSnapshot() {
        revisionStorage += 1
        digestStorage = digestStorage == String(repeating: "a", count: 64)
            ? String(repeating: "b", count: 64)
            : String(repeating: "a", count: 64)
    }

    private func positionIndex(for positionID: String) -> Int? {
        positionCoordinates.firstIndex(of: positionID)
    }

    private func makeSnapshot(requestID: String) -> ConfigEditorSnapshotResponse {
        ConfigEditorSnapshotResponse(
            requestID: requestID,
            instanceID: instanceID,
            sourceDigest: digestStorage,
            revision: revisionStorage,
            defaultProfileID: "Default",
            currentProfileID: currentProfileIDStorage,
            profileIDs: profileIDsStorage
        )
    }

    private func mutationResponse(
        requestID: String,
        effect: ConfigEditorEffect = .catalog
    ) -> ConfigEditorMutationResponse {
        ConfigEditorMutationResponse(
            requestID: requestID,
            instanceID: instanceID,
            sourceDigest: digestStorage,
            fileCommit: .committed,
            reloadOutcome: .changed,
            revision: revisionStorage,
            effect: effect,
            reason: .none
        )
    }

    private func read<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class DelayedConfigEditorSnapshotTransport: @unchecked Sendable, SocketTransport {
    private let instanceID: String
    private let delay: TimeInterval
    private let lock = NSLock()
    private var timeoutsStorage: [UInt64] = []

    var timeouts: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return timeoutsStorage
    }

    init(instanceID: String, delay: TimeInterval) {
        self.instanceID = instanceID
        self.delay = delay
    }

    func exchange(request: Data, socketPath: String, timeoutNanoseconds: UInt64) throws -> Data {
        lock.lock()
        timeoutsStorage.append(timeoutNanoseconds)
        lock.unlock()

        guard let envelope = try JSONSerialization.jsonObject(
            with: Data(request.dropLast())
        ) as? [String: Any],
              let requestID = envelope["request_id"] as? String else {
            throw UnixSocketClientError.malformedResponse
        }

        Thread.sleep(forTimeInterval: delay)
        let response: [String: Any] = [
            "protocol_version": 1,
            "request_id": requestID,
            "result": [
                "instance_id": instanceID,
                "source_digest": String(repeating: "a", count: 64),
                "revision": 1,
                "default_profile_id": "Default",
                "current_profile_id": "Default",
                "profile_ids": ["Default"]
            ],
            "error": NSNull()
        ]
        var frame = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        frame.append(0x0a)
        return frame
    }
}

private enum SettingsProfileClientError: Error {
    case profileMissing
}

@MainActor
private final class SettingsForegroundObserver: ForegroundApplicationObserving {
    private let initialBundleIdentifier: String?
    private var handler: ForegroundApplicationHandler?

    init(initialBundleIdentifier: String?) {
        self.initialBundleIdentifier = initialBundleIdentifier
    }

    func start(handler: @escaping ForegroundApplicationHandler) {
        self.handler = handler
        handler(initialBundleIdentifier)
    }

    func stop() {
        handler = nil
    }
}
