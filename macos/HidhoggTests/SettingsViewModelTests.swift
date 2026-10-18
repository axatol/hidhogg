import Darwin
import AppKit
import Foundation
import XCTest
import UniformTypeIdentifiers
import HidhoggCore
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

    func testPositionEditorCanClearLabelButRejectsWhitespace() async throws {
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
        XCTAssertFalse(viewModel.canSavePosition)
        viewModel.editedPositionLabel = ""
        XCTAssertTrue(viewModel.canSavePosition)
        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionPatchCallCount, 1)
        guard let patch = client.lastPositionPatch else {
            return XCTFail("Expected the position patch to be recorded")
        }
        assertSet(patch.label, "")
        assertKeep(patch.background)
        XCTAssertEqual(viewModel.lastMutationSummary, "File committed; runtime reloaded (display)")
    }

    func testPositionEditorLoadsStableChoicesAndSavesAgainstSnapshotDigest() async throws {
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
        XCTAssertTrue(viewModel.canSavePosition)
        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionPatchCallCount, 1)
        XCTAssertEqual(client.lastPositionPatchProfileID, "Work.Profile")
        XCTAssertEqual(client.lastPositionPatchID, "0_0")
        XCTAssertEqual(client.lastPositionPatchDigest, String(repeating: "a", count: 64))
        guard let patch = client.lastPositionPatch else {
            return XCTFail("Expected the position patch to be recorded")
        }
        assertSet(patch.label, "Clock")
        assertKeep(patch.background)
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, String(repeating: "b", count: 64))
        XCTAssertEqual(viewModel.lastMutationSummary, "File committed; runtime reloaded (display)")
        XCTAssertNil(viewModel.selectedEditorProfileID)
    }

    func testPositionDraftBuildsAtomicSixFieldPatchWithOrderedExecuteAction() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(
            instanceID: endpoint.instanceID,
            notificationSources: ["device.power"]
        )
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)

        viewModel.editedPositionLabel = "Clock"
        viewModel.editedPositionBackground = "#1A2B3C80"
        viewModel.editedPositionAlignment = "center"
        viewModel.editedPositionSize = 18
        viewModel.newPositionNotificationSourceID = "button.alerts"
        XCTAssertTrue(viewModel.canAddPositionNotificationSource)
        viewModel.addPositionNotificationSource()
        XCTAssertFalse(viewModel.canAddPositionNotificationSource)
        XCTAssertEqual(viewModel.editedPositionNotificationSources, ["device.power", "button.alerts"])
        viewModel.editedPositionActionKind = .execute
        viewModel.editedPositionActionExecutable = "/usr/bin/printf"
        viewModel.newPositionActionArgument = "%s"
        viewModel.addPositionActionArgument()
        viewModel.newPositionActionArgument = "two words"
        viewModel.addPositionActionArgument()
        viewModel.editedPositionActionTimeoutSeconds = 15
        viewModel.editedPositionActionGesture = .press

        XCTAssertNotNil(viewModel.editedPositionPreviewColor)
        XCTAssertTrue(viewModel.canSavePosition)
        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionPatchCallCount, 1)
        XCTAssertEqual(client.lastPositionPatchProfileID, "Work.Profile")
        XCTAssertEqual(client.lastPositionPatchID, "0_0")
        XCTAssertEqual(client.lastPositionPatchDigest, String(repeating: "a", count: 64))
        guard let patch = client.lastPositionPatch else {
            return XCTFail("Expected the position patch to be recorded")
        }
        assertSet(patch.label, "Clock")
        assertSet(patch.background, "#1A2B3C80")
        assertSet(patch.labelAlignment, "center")
        assertSet(patch.labelSize, 18)
        assertSet(patch.notificationSources, ["device.power", "button.alerts"])
        assertSet(
            patch.action,
            .execute(
                executable: "/usr/bin/printf",
                arguments: ["%s", "two words"],
                timeoutSeconds: 15,
                gesture: .press
            )
        )
        XCTAssertEqual(viewModel.lastMutationSummary, "File committed; runtime reloaded (display)")
    }

    func testPositionDraftBuildsProfileTextAndEnterActions() async throws {
        let scenarios: [(String, SettingsViewModel.PositionActionKind, ButtonGesture)] = [
            ("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", .activateProfile, .press),
            ("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", .typeText, .press),
            ("cccccccc-cccc-4ccc-8ccc-cccccccccccc", .keyPress, .press),
            ("dddddddd-dddd-4ddd-8ddd-dddddddddddd", .typeText, .release)
        ]

        for (instanceID, kind, gesture) in scenarios {
            let endpoint = editorEndpoint(instanceID: instanceID)
            let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
            let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)
            viewModel.editedPositionActionKind = kind
            viewModel.editedPositionActionGesture = gesture

            let expected: ConfiguredAction
            switch kind {
            case .activateProfile:
                viewModel.editedPositionActionProfileID = "Work.Profile"
                expected = .activateProfile(profileID: "Work.Profile", gesture: gesture)
            case .typeText:
                viewModel.editedPositionActionText = "Wake"
                expected = .typeText(text: "Wake", gesture: gesture)
            case .keyPress:
                expected = .keyPress(key: "enter", gesture: gesture)
            case .none, .execute:
                XCTFail("Unexpected scenario")
                continue
            }

            XCTAssertTrue(viewModel.canSavePosition)
            viewModel.saveEditedPosition()
            await viewModel.waitForEditorIdle()
            XCTAssertEqual(client.positionPatchCallCount, 1)
            guard let patch = client.lastPositionPatch else {
                return XCTFail("Expected the position patch to be recorded")
            }
            assertSet(patch.action, expected)
        }
    }

    func testPositionDraftNoOpAndUseDefaultResetsAreDistinct() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)

        XCTAssertFalse(viewModel.canSavePosition)
        viewModel.editedPositionLabel = "Temporary"
        XCTAssertTrue(viewModel.canSavePosition)
        viewModel.editedPositionLabel = "Label 0_0"
        XCTAssertFalse(viewModel.canSavePosition)
        XCTAssertEqual(client.positionPatchCallCount, 0)

        for field in SettingsViewModel.PositionField.allCases {
            viewModel.resetPositionField(field)
        }

        XCTAssertTrue(viewModel.canSavePosition)
        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        guard let patch = client.lastPositionPatch else {
            return XCTFail("Expected the reset patch to be recorded")
        }
        assertReset(patch.label)
        assertReset(patch.background)
        assertReset(patch.labelAlignment)
        assertReset(patch.labelSize)
        assertReset(patch.notificationSources)
        assertReset(patch.action)
    }

    func testRemovingLastNotificationSourceAndClearingActionUseReset() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(
            instanceID: endpoint.instanceID,
            notificationSources: ["device.power"],
            action: .typeText(text: "Wake", gesture: .release)
        )
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)

        viewModel.removePositionNotificationSource("device.power")
        viewModel.editedPositionActionKind = .none
        XCTAssertTrue(viewModel.canSavePosition)
        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        guard let patch = client.lastPositionPatch else {
            return XCTFail("Expected the position patch to be recorded")
        }
        assertReset(patch.notificationSources)
        assertReset(patch.action)
    }

    func testPositionDraftRejectsInvalidBoundsAndIncompleteActions() async throws {
        let existingActionEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let existingActionClient = SettingsConfigEditorTestClient(
            instanceID: existingActionEndpoint.instanceID,
            action: .typeText(text: "Wake", gesture: .release)
        )
        let existingActionViewModel = await makeSelectedPositionEditor(
            client: existingActionClient,
            endpoint: existingActionEndpoint
        )
        existingActionViewModel.editedPositionActionKind = .activateProfile
        XCTAssertFalse(existingActionViewModel.canSavePosition)
        XCTAssertEqual(existingActionViewModel.positionDraftErrorMessage, "Complete the selected action fields.")
        XCTAssertEqual(existingActionClient.positionPatchCallCount, 0)

        let emptyActionEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let emptyActionClient = SettingsConfigEditorTestClient(instanceID: emptyActionEndpoint.instanceID)
        let emptyActionViewModel = await makeSelectedPositionEditor(
            client: emptyActionClient,
            endpoint: emptyActionEndpoint
        )
        emptyActionViewModel.editedPositionActionKind = .activateProfile
        XCTAssertFalse(emptyActionViewModel.canSavePosition)
        XCTAssertEqual(emptyActionViewModel.positionDraftErrorMessage, "Complete the selected action fields.")

        emptyActionViewModel.editedPositionActionProfileID = "Work.Profile"
        emptyActionViewModel.editedPositionBackground = "#fff"
        XCTAssertFalse(emptyActionViewModel.canSavePosition)
        emptyActionViewModel.editedPositionBackground = "#000000"
        emptyActionViewModel.editedPositionSize = 7
        XCTAssertFalse(emptyActionViewModel.canSavePosition)
        emptyActionViewModel.editedPositionSize = 10
        emptyActionViewModel.editedPositionActionKind = .execute
        emptyActionViewModel.editedPositionActionExecutable = "relative/path"
        emptyActionViewModel.editedPositionActionTimeoutSeconds = 0
        XCTAssertFalse(emptyActionViewModel.canSavePosition)
        emptyActionViewModel.editedPositionActionExecutable = "/usr/bin/echo"
        emptyActionViewModel.editedPositionActionTimeoutSeconds = 61
        XCTAssertFalse(emptyActionViewModel.canSavePosition)
        emptyActionViewModel.editedPositionActionTimeoutSeconds = 60
        emptyActionViewModel.editedPositionSize = 33
        XCTAssertFalse(emptyActionViewModel.canSavePosition)
        XCTAssertEqual(emptyActionClient.positionPatchCallCount, 0)
    }

    func testNotificationSourceAndArgumentGuardsRejectDuplicatesAndLimitOverflow() async throws {
        let sourceEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let sourceClient = SettingsConfigEditorTestClient(
            instanceID: sourceEndpoint.instanceID,
            notificationSources: ["device.power"]
        )
        let sourceViewModel = await makeSelectedPositionEditor(client: sourceClient, endpoint: sourceEndpoint)

        sourceViewModel.newPositionNotificationSourceID = "device.power"
        XCTAssertFalse(sourceViewModel.canAddPositionNotificationSource)
        sourceViewModel.addPositionNotificationSource()
        XCTAssertEqual(sourceViewModel.editedPositionNotificationSources, ["device.power"])

        sourceViewModel.newPositionNotificationSourceID = "invalid source"
        XCTAssertFalse(sourceViewModel.canAddPositionNotificationSource)
        sourceViewModel.addPositionNotificationSource()
        XCTAssertEqual(sourceViewModel.editedPositionNotificationSources, ["device.power"])

        sourceViewModel.newPositionNotificationSourceID = "button.alerts"
        XCTAssertTrue(sourceViewModel.canAddPositionNotificationSource)
        sourceViewModel.addPositionNotificationSource()
        XCTAssertEqual(sourceViewModel.editedPositionNotificationSources, ["device.power", "button.alerts"])

        let fullSources = (0..<16).map { "source\($0)" }
        let fullSourcesEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let fullSourcesClient = SettingsConfigEditorTestClient(
            instanceID: fullSourcesEndpoint.instanceID,
            notificationSources: fullSources
        )
        let fullSourcesViewModel = await makeSelectedPositionEditor(
            client: fullSourcesClient,
            endpoint: fullSourcesEndpoint
        )
        fullSourcesViewModel.newPositionNotificationSourceID = "source.extra"
        XCTAssertFalse(fullSourcesViewModel.canAddPositionNotificationSource)
        fullSourcesViewModel.addPositionNotificationSource()
        XCTAssertEqual(fullSourcesViewModel.editedPositionNotificationSources.count, 16)

        let arguments = Array(repeating: "arg", count: 32)
        let argumentEndpoint = editorEndpoint(instanceID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        let argumentClient = SettingsConfigEditorTestClient(
            instanceID: argumentEndpoint.instanceID,
            action: .execute(
                executable: "/usr/bin/echo",
                arguments: arguments,
                timeoutSeconds: 10,
                gesture: .release
            )
        )
        let argumentViewModel = await makeSelectedPositionEditor(
            client: argumentClient,
            endpoint: argumentEndpoint
        )
        argumentViewModel.newPositionActionArgument = "extra"
        XCTAssertFalse(argumentViewModel.canAddPositionActionArgument)
        argumentViewModel.addPositionActionArgument()
        XCTAssertEqual(argumentViewModel.editedPositionActionArguments.count, 32)
    }

    func testUncertainPositionPatchRequiresManualRefreshWithoutRetry() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)
        client.setNextMutationError(.readTimedOut)
        viewModel.editedPositionLabel = "Clock"

        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionPatchCallCount, 1)
        XCTAssertEqual(client.snapshotCallCount, 1)
        XCTAssertTrue(viewModel.requiresSnapshotRefresh)
        XCTAssertTrue(viewModel.editorErrorMessage?.contains("Outcome unknown") == true)

        viewModel.refreshEditorSnapshot()
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(client.positionPatchCallCount, 1)
        XCTAssertEqual(client.snapshotCallCount, 2)
    }

    func testStalePositionPatchRefreshesSnapshotWithoutRetry() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsConfigEditorTestClient(instanceID: endpoint.instanceID)
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)
        client.setNextMutationError(
            .response(.serverError(RuntimeError(
                code: "stale_source",
                message: "configuration source changed; refresh and retry"
            )))
        )
        viewModel.editedPositionLabel = "Clock"

        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionPatchCallCount, 1)
        XCTAssertEqual(client.snapshotCallCount, 2)
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, String(repeating: "b", count: 64))
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertTrue(viewModel.editorNoticeMessage?.contains("edit was not retried") == true)
    }

    func testLatePositionPatchIsDiscardedAfterEndpointReplacement() async throws {
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
        viewModel.selectPositionForEditing("0_0")
        await viewModel.waitForEditorIdle()
        firstClient.blockNextPositionPatch()
        viewModel.editedPositionLabel = "Clock"

        viewModel.saveEditedPosition()
        for _ in 0..<200 where firstClient.positionPatchCallCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(firstClient.positionPatchCallCount, 1)

        endpointBox.endpoint = secondEndpoint
        viewModel.setEditorEndpoint(secondEndpoint)
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.editorSnapshot?.instanceID, secondEndpoint.instanceID)

        firstClient.releasePositionPatch()
        for _ in 0..<200 where firstClient.positionPatchCompletionCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(firstClient.positionPatchCompletionCount, 1)
        XCTAssertEqual(viewModel.editorSnapshot?.instanceID, secondEndpoint.instanceID)
        XCTAssertNil(viewModel.lastMutationSummary)
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertFalse(viewModel.isEditorBusy)
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

    private func makeSelectedPositionEditor(
        client: SettingsConfigEditorTestClient,
        endpoint: RuntimeSessionController.RuntimeEndpoint
    ) async -> SettingsViewModel {
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
        return viewModel
    }

    private func assertSet<Value: Equatable>(
        _ edit: ConfigurationFieldEdit<Value>,
        _ expected: Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .set(let value) = edit else {
            return XCTFail("Expected a set edit", file: file, line: line)
        }
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    private func assertKeep<Value>(
        _ edit: ConfigurationFieldEdit<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .keep = edit else {
            return XCTFail("Expected a keep edit", file: file, line: line)
        }
    }

    private func assertReset<Value>(
        _ edit: ConfigurationFieldEdit<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .reset = edit else {
            return XCTFail("Expected a reset edit", file: file, line: line)
        }
    }

    private func makeSettingsModel() -> HidhoggAppModel {
        HidhoggAppModel(
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
    private let positionPatchRelease = DispatchSemaphore(value: 0)
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
    private var positionNotificationSourcesStorage: [String]
    private var positionActionStorage: ConfiguredAction?
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
    private var positionPatchCallCountStorage = 0
    private var positionPatchCompletionCountStorage = 0
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
    private var lastPositionPatchProfileIDStorage: String?
    private var lastPositionPatchIDStorage: String?
    private var lastPositionPatchDigestStorage: String?
    private var lastPositionPatchStorage: ConfigurationPositionPatch?
    private var nextMutationError: UnixSocketClientError?
    private var nextPositionGetError: UnixSocketClientError?
    private var blocksNextDelete = false
    private var blocksNextPositionGet = false
    private var blocksNextPositionPatch = false

    init(
        instanceID: String,
        blocksFirstSnapshot: Bool = false,
        currentProfileID: String = "Default",
        notificationSources: [String] = [],
        action: ConfiguredAction? = nil
    ) {
        self.instanceID = instanceID
        self.blocksFirstSnapshot = blocksFirstSnapshot
        currentProfileIDStorage = currentProfileID
        positionNotificationSourcesStorage = notificationSources
        positionActionStorage = action
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
    var positionPatchCallCount: Int { read { positionPatchCallCountStorage } }
    var positionPatchCompletionCount: Int { read { positionPatchCompletionCountStorage } }
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
    var lastPositionPatchProfileID: String? { read { lastPositionPatchProfileIDStorage } }
    var lastPositionPatchID: String? { read { lastPositionPatchIDStorage } }
    var lastPositionPatchDigest: String? { read { lastPositionPatchDigestStorage } }
    var lastPositionPatch: ConfigurationPositionPatch? { read { lastPositionPatchStorage } }

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

    func blockNextPositionPatch() {
        lock.lock()
        blocksNextPositionPatch = true
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

    func releasePositionPatch() {
        positionPatchRelease.signal()
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
            label: positionLabelsStorage[positionID] ?? "Label \(positionCoordinates[index])",
            background: "#000000",
            labelAlignment: "bottom",
            labelSize: 10,
            notificationSources: positionNotificationSourcesStorage,
            action: positionActionStorage
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

    func patchConfigEditorPosition(
        profileID: String,
        positionID: String,
        patch: ConfigurationPositionPatch,
        expectedDigest: String,
        requestID: String
    ) throws -> ConfigEditorMutationResponse {
        lock.lock()
        positionPatchCallCountStorage += 1
        lastPositionPatchProfileIDStorage = profileID
        lastPositionPatchIDStorage = positionID
        lastPositionPatchDigestStorage = expectedDigest
        lastPositionPatchStorage = patch
        let shouldBlock = blocksNextPositionPatch
        blocksNextPositionPatch = false
        lock.unlock()

        if shouldBlock {
            positionPatchRelease.wait()
        }

        lock.lock()
        defer { lock.unlock() }
        positionPatchCompletionCountStorage += 1
        try throwPendingMutationError()
        guard digestStorage == expectedDigest,
              labelsStorage[profileID] != nil,
              positionIndex(for: positionID) != nil else {
            throw staleSourceError
        }
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
