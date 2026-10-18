import AppKit
import Foundation
import XCTest
import UniformTypeIdentifiers
import HidhoggCore
@testable import Hidhogg

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testPermissionStatusRefreshReadsTheCurrentKeyboardInputAccess() {
        var status = false
        var refreshCount = 0
        let viewModel = PermissionSettingsViewModel(
            checkKeyboardInputAccess: {
                refreshCount += 1
                return status
            }
        )

        XCTAssertEqual(viewModel.keyboardInputStatusText, "Checking…")

        viewModel.refresh()
        XCTAssertEqual(viewModel.keyboardInputAllowed, false)
        XCTAssertEqual(viewModel.keyboardInputStatusText, "Not allowed")

        status = true
        viewModel.refresh()
        XCTAssertEqual(viewModel.keyboardInputAllowed, true)
        XCTAssertEqual(viewModel.keyboardInputStatusText, "Allowed")
        XCTAssertEqual(refreshCount, 2)
    }

    func testPermissionSettingsOpenTargetsAccessibilityAndReportsFailure() {
        var openedURL: URL?
        var openingSucceeds = false
        let viewModel = PermissionSettingsViewModel(
            openURL: { url in
                openedURL = url
                return openingSucceeds
            }
        )

        viewModel.openAccessibilitySettings()

        XCTAssertEqual(
            openedURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(
            viewModel.openSettingsErrorMessage,
            "Could not open Permission Settings. Open System Settings > Privacy & Security > Device Control and Data Access (Accessibility on earlier macOS versions) and enable Hidhogg."
        )

        openingSucceeds = true
        viewModel.openAccessibilitySettings()
        XCTAssertNil(viewModel.openSettingsErrorMessage)
    }

    func testShowApplicationInFinderUsesTheExactRunningBundleURL() {
        let bundleURL = URL(fileURLWithPath: "/tmp/permission-test/Hidhogg.app", isDirectory: true)
        var revealedURL: URL?
        let viewModel = PermissionSettingsViewModel(
            applicationBundleURL: bundleURL,
            showInFinder: { url in revealedURL = url }
        )

        viewModel.showApplicationInFinder()

        XCTAssertEqual(viewModel.applicationBundleURL, bundleURL)
        XCTAssertEqual(revealedURL, bundleURL)
    }

    func testPermissionSettingsDefaultsToTheRunningApplicationBundle() {
        let viewModel = PermissionSettingsViewModel()

        XCTAssertEqual(viewModel.applicationBundleURL, Bundle.main.bundleURL)
    }

    func testApplicationBundleDragProviderOffersURLRepresentation() {
        let bundleURL = URL(fileURLWithPath: "/tmp/permission-test/Hidhogg.app", isDirectory: true)
        let viewModel = PermissionSettingsViewModel(applicationBundleURL: bundleURL)

        let provider = viewModel.applicationBundleItemProvider()

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.url.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertEqual(UTType.url.identifier, "public.url")
        XCTAssertEqual(UTType.fileURL.identifier, "public.file-url")
    }

    func testApplicationBundleDragProviderLoadsTheExactBundleURL() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("permission-test-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = fixtureRoot.appendingPathComponent("Hidhogg.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let provider = PermissionSettingsViewModel(
            applicationBundleURL: bundleURL
        ).applicationBundleItemProvider()

        let loadedURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                continuation.resume(returning: url)
            }
        }

        XCTAssertEqual(loadedURL, bundleURL)
    }

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
        let catalog = [
            RuntimeOperationProfile(id: "Default", label: "Default", isDefault: true, isCurrent: true)
        ]

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

    func testEditorRuntimeReplacementDropsLateSnapshotAndClearsEditor() async throws {
        let firstEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let firstClient = SettingsEditorOperationsFake(
            instanceID: firstEndpoint.instanceID,
            blocksFirstSnapshot: true
        )
        let secondClient = SettingsEditorOperationsFake(
            instanceID: secondEndpoint.instanceID,
            digest: String(repeating: "b", count: 64)
        )
        let firstHandle = RuntimeOperationsHandle(identity: firstEndpoint.instanceID, operations: firstClient)
        let secondHandle = RuntimeOperationsHandle(identity: secondEndpoint.instanceID, operations: secondClient)
        let runtimeBox = SettingsEditorOperationsBox(handle: firstHandle)
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            runtimeOperationsProvider: { runtimeBox.handle }
        )

        for _ in 0..<200 where firstClient.snapshotCallCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(firstClient.snapshotCallCount, 1)

        runtimeBox.handle = secondHandle
        viewModel.setRuntimeOperations(secondHandle)
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, secondClient.sourceDigest)
        XCTAssertEqual(secondClient.snapshotCallCount, 1)

        firstClient.releaseFirstSnapshot()
        for _ in 0..<200 where firstClient.snapshotCompletionCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await Task.yield()
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, secondClient.sourceDigest)

        runtimeBox.handle = nil
        viewModel.setRuntimeOperations(nil)
        XCTAssertNil(viewModel.editorSnapshot)
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertNil(viewModel.lastMutationSummary)
        XCTAssertFalse(viewModel.hasEditorRuntime)
    }

    func testLateDeleteMutationResultIsDiscardedAfterRuntimeReplacement() async throws {
        let firstEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let firstClient = SettingsEditorOperationsFake(instanceID: firstEndpoint.instanceID)
        let secondClient = SettingsEditorOperationsFake(
            instanceID: secondEndpoint.instanceID,
            digest: String(repeating: "b", count: 64)
        )
        let firstHandle = RuntimeOperationsHandle(identity: firstEndpoint.instanceID, operations: firstClient)
        let secondHandle = RuntimeOperationsHandle(identity: secondEndpoint.instanceID, operations: secondClient)
        let runtimeBox = SettingsEditorOperationsBox(handle: firstHandle)
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            runtimeOperationsProvider: { runtimeBox.handle }
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

        runtimeBox.handle = secondHandle
        viewModel.setRuntimeOperations(secondHandle)
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, secondClient.sourceDigest)
        XCTAssertNil(viewModel.lastMutationSummary)

        firstClient.releaseDelete()
        for _ in 0..<200 where firstClient.deleteCompletionCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(firstClient.deleteCompletionCount, 1)
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, secondClient.sourceDigest)
        XCTAssertNil(viewModel.lastMutationSummary)
        XCTAssertFalse(viewModel.isEditorBusy)
    }

    func testCloneRequiresConfirmedIDAndLabelAndStaleDigestRefreshesWithoutRetry() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
        client.setNextMutationError(.staleSource)
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            runtimeOperationsProvider: {
                RuntimeOperationsHandle(identity: endpoint.instanceID, operations: client)
            }
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

    func testUncertainFileCommitIsOutcomeUnknownAndNotRetried() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
        client.setNextMutationError(.fileCommitFailed(uncertain: true))
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
        let editorClient = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
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
        let client = SettingsEditorOperationsFake(
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
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
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
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
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
        let client = SettingsEditorOperationsFake(
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

    func testExecuteArgumentRowsKeepStableIdentityThroughRemovalAndSerializeInOrder() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsEditorOperationsFake(
            instanceID: endpoint.instanceID,
            action: .execute(
                executable: "/usr/bin/printf",
                arguments: ["first", "middle", "last"],
                timeoutSeconds: 10,
                gesture: .release
            )
        )
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)
        let originalRows = viewModel.editedPositionActionArgumentRows
        let firstID = try XCTUnwrap(originalRows.first?.id)
        let middleID = try XCTUnwrap(originalRows.dropFirst().first?.id)
        let lastID = try XCTUnwrap(originalRows.last?.id)

        XCTAssertEqual(viewModel.positionActionArgumentValue(id: middleID), "middle")
        viewModel.setPositionActionArgument(id: middleID, value: "edited middle")
        viewModel.removePositionActionArgument(id: firstID)
        viewModel.setPositionActionArgument(id: lastID, value: "edited last")

        XCTAssertEqual(viewModel.editedPositionActionArgumentRows.map(\.id), [middleID, lastID])
        XCTAssertEqual(viewModel.editedPositionActionArguments, ["edited middle", "edited last"])
        XCTAssertNil(viewModel.positionActionArgumentValue(id: firstID))

        viewModel.setPositionActionArgument(id: firstID, value: "stale edit")
        viewModel.removePositionActionArgument(id: firstID)
        XCTAssertEqual(viewModel.editedPositionActionArguments, ["edited middle", "edited last"])

        XCTAssertTrue(viewModel.canSavePosition)
        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        guard let patch = client.lastPositionPatch else {
            return XCTFail("Expected the position patch to be recorded")
        }
        assertSet(
            patch.action,
            .execute(
                executable: "/usr/bin/printf",
                arguments: ["edited middle", "edited last"],
                timeoutSeconds: 10,
                gesture: .release
            )
        )
    }

    func testExecuteArgumentIDsExpireWhenActionOrPositionChanges() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsEditorOperationsFake(
            instanceID: endpoint.instanceID,
            action: .execute(
                executable: "/usr/bin/printf",
                arguments: ["first", "second"],
                timeoutSeconds: 10,
                gesture: .release
            )
        )
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)
        let firstID = try XCTUnwrap(viewModel.editedPositionActionArgumentRows.first?.id)

        viewModel.setPositionActionArgument(id: firstID, value: "kept edit")
        viewModel.editedPositionActionKind = .typeText
        XCTAssertNil(viewModel.positionActionArgumentValue(id: firstID))
        viewModel.setPositionActionArgument(id: firstID, value: "stale action edit")

        viewModel.editedPositionActionKind = .execute
        let afterActionSwitch = viewModel.editedPositionActionArgumentRows
        XCTAssertFalse(afterActionSwitch.contains { $0.id == firstID })
        XCTAssertEqual(viewModel.editedPositionActionArguments, ["kept edit", "second"])
        viewModel.setPositionActionArgument(id: firstID, value: "stale action edit")
        XCTAssertEqual(viewModel.editedPositionActionArguments, ["kept edit", "second"])

        viewModel.selectPositionForEditing("0_1")
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.selectedEditorPositionID, "0_1")
        XCTAssertFalse(viewModel.editedPositionActionArgumentRows.contains { $0.id == afterActionSwitch[0].id })
        viewModel.setPositionActionArgument(id: afterActionSwitch[0].id, value: "stale position edit")
        XCTAssertEqual(viewModel.editedPositionActionArguments, ["first", "second"])
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
            let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
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
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
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
        let client = SettingsEditorOperationsFake(
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
        let existingActionClient = SettingsEditorOperationsFake(
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
        let emptyActionClient = SettingsEditorOperationsFake(instanceID: emptyActionEndpoint.instanceID)
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
        let sourceClient = SettingsEditorOperationsFake(
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
        let fullSourcesClient = SettingsEditorOperationsFake(
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
        let argumentClient = SettingsEditorOperationsFake(
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
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)
        client.setNextMutationError(.deviceWriteFailed)
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
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
        let viewModel = await makeSelectedPositionEditor(client: client, endpoint: endpoint)
        client.setNextMutationError(.staleSource)
        viewModel.editedPositionLabel = "Clock"

        viewModel.saveEditedPosition()
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(client.positionPatchCallCount, 1)
        XCTAssertEqual(client.snapshotCallCount, 2)
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, String(repeating: "b", count: 64))
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertTrue(viewModel.editorNoticeMessage?.contains("edit was not retried") == true)
    }

    func testLatePositionPatchIsDiscardedAfterRuntimeReplacement() async throws {
        let firstEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let firstClient = SettingsEditorOperationsFake(instanceID: firstEndpoint.instanceID)
        let secondClient = SettingsEditorOperationsFake(instanceID: secondEndpoint.instanceID, digest: String(repeating: "b", count: 64))
        let firstHandle = RuntimeOperationsHandle(identity: firstEndpoint.instanceID, operations: firstClient)
        let secondHandle = RuntimeOperationsHandle(identity: secondEndpoint.instanceID, operations: secondClient)
        let runtimeBox = SettingsEditorOperationsBox(handle: firstHandle)
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            runtimeOperationsProvider: { runtimeBox.handle }
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

        runtimeBox.handle = secondHandle
        viewModel.setRuntimeOperations(secondHandle)
        await viewModel.waitForEditorIdle()
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, secondClient.sourceDigest)

        firstClient.releasePositionPatch()
        for _ in 0..<200 where firstClient.positionPatchCompletionCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertEqual(firstClient.positionPatchCompletionCount, 1)
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, secondClient.sourceDigest)
        XCTAssertNil(viewModel.lastMutationSummary)
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertFalse(viewModel.isEditorBusy)
    }

    func testPositionSelectionAndDraftResetWhenProfileChanges() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
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

    func testLatePositionDetailIsDiscardedAfterRuntimeReplacement() async throws {
        let firstEndpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let secondEndpoint = editorEndpoint(instanceID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        let firstClient = SettingsEditorOperationsFake(instanceID: firstEndpoint.instanceID)
        let secondClient = SettingsEditorOperationsFake(instanceID: secondEndpoint.instanceID, digest: String(repeating: "b", count: 64))
        let firstHandle = RuntimeOperationsHandle(identity: firstEndpoint.instanceID, operations: firstClient)
        let secondHandle = RuntimeOperationsHandle(identity: secondEndpoint.instanceID, operations: secondClient)
        let runtimeBox = SettingsEditorOperationsBox(handle: firstHandle)
        let viewModel = SettingsViewModel(
            model: makeSettingsModel(),
            applicationSelector: { .cancelled },
            runtimeOperationsProvider: { runtimeBox.handle }
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

        runtimeBox.handle = secondHandle
        viewModel.setRuntimeOperations(secondHandle)
        await viewModel.waitForEditorIdle()

        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, secondClient.sourceDigest)
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
        XCTAssertEqual(viewModel.editorSnapshot?.sourceDigest, secondClient.sourceDigest)
        XCTAssertNil(viewModel.selectedEditorProfileID)
        XCTAssertTrue(viewModel.editorPositions.isEmpty)
        XCTAssertNil(viewModel.selectedEditorPositionID)
        XCTAssertNil(viewModel.editedPosition)
        XCTAssertEqual(viewModel.editedPositionLabel, "")
        XCTAssertFalse(viewModel.isEditorBusy)
    }

    func testStalePositionDetailRefreshesSnapshotWithoutRetryingRead() async throws {
        let endpoint = editorEndpoint(instanceID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
        client.setNextPositionGetError(.staleSource)
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
        let client = SettingsEditorOperationsFake(instanceID: endpoint.instanceID)
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

    private func makeConfiguredModel(
        store: TestSettingsMappingStore,
        mappings: [String: String]
    ) async throws -> (HidhoggAppModel, SettingsProfileClient) {
        let client = SettingsProfileClient()
        let coordinator = ProfileSwitchCoordinator(mappings: ProfileMappingPreferences(mappings: mappings))
        await coordinator.setRuntimeOperations(
            RuntimeOperationsHandle(identity: "settings-test", operations: client)
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
        client: SettingsEditorOperationsFake,
        endpoint: RuntimeSessionController.RuntimeEndpoint,
        model: HidhoggAppModel
    ) -> SettingsViewModel {
        SettingsViewModel(
            model: model,
            applicationSelector: { .cancelled },
            runtimeOperationsProvider: {
                RuntimeOperationsHandle(identity: endpoint.instanceID, operations: client)
            }
        )
    }

    private func makeSelectedPositionEditor(
        client: SettingsEditorOperationsFake,
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

private final class SettingsProfileClient: @unchecked Sendable, HidhoggAppRuntimeOperations {
    private let lock = NSLock()
    private var currentProfileID = "Default"
    private var profileIDs = ["Default", "Work.Profile"]
    private var activationCountStorage = 0
    private var listCountStorage = 0
    private let digest = String(repeating: "a", count: 64)

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

    func profiles() async throws -> [RuntimeOperationProfile] {
        let (currentProfileID, profileIDs) = lock.withLock {
            listCountStorage += 1
            return (self.currentProfileID, self.profileIDs)
        }
        return profileIDs.map { profileID in
            RuntimeOperationProfile(
                id: profileID,
                label: profileID,
                isDefault: profileID == "Default",
                isCurrent: profileID == currentProfileID
            )
        }
    }

    func activateProfile(_ profileID: String) async throws -> RuntimeActivationResult {
        try lock.withLock {
            activationCountStorage += 1
            guard profileIDs.contains(profileID) else {
                throw RuntimeOperationError.profileNotFound
            }
            currentProfileID = profileID
            return RuntimeActivationResult(profileID: profileID, changed: true, revision: 1)
        }
    }

    func setHostDisplayAwake(_ awake: Bool) async throws -> RuntimeOperationDisplayResult {
        RuntimeOperationDisplayResult(displayAwake: awake, changed: false)
    }

    func editorSnapshot() async throws -> RuntimeOperationEditorSnapshot {
        let profileIDs = lock.withLock { self.profileIDs }
        return RuntimeOperationEditorSnapshot(
            sourceDigest: digest,
            revision: 1,
            defaultProfileID: "Default",
            currentProfileID: lock.withLock { currentProfileID },
            profileIDs: profileIDs
        )
    }

    func editorProfile(sourceDigest: String, profileID: String) async throws -> RuntimeOperationEditorProfile {
        guard sourceDigest == digest,
              lock.withLock({ profileIDs.contains(profileID) }) else {
            throw RuntimeOperationError.profileNotFound
        }
        return RuntimeOperationEditorProfile(sourceDigest: digest, profileID: profileID, label: profileID)
    }

    func editorPositions(sourceDigest: String, profileID: String) async throws -> RuntimeOperationEditorPositions {
        guard sourceDigest == digest,
              lock.withLock({ profileIDs.contains(profileID) }) else {
            throw RuntimeOperationError.profileNotFound
        }
        return RuntimeOperationEditorPositions(sourceDigest: digest, profileID: profileID, positions: [])
    }

    func editorPosition(
        sourceDigest: String,
        profileID: String,
        positionID: String
    ) async throws -> RuntimeOperationEditorPosition {
        throw RuntimeOperationError.profileNotFound
    }

    func edit(expectedDigest: String, edit: RuntimeConfigurationEdit) async throws -> RuntimeOperationEditResult {
        throw RuntimeOperationError.editInvalid
    }

    func cloneProfile(
        expectedDigest: String,
        sourceProfileID: String?,
        profileID: String,
        label: String
    ) async throws -> RuntimeOperationEditResult {
        throw RuntimeOperationError.editInvalid
    }

    func reloadConfiguration() async throws -> RuntimeOperationReloadResult {
        RuntimeOperationReloadResult(
            revision: 1,
            changed: false,
            effects: RuntimeOperationReloadEffects(
                catalogChanged: false,
                defaultChanged: false,
                currentProfileChanged: false,
                currentProfileFallback: false,
                actionChanged: false,
                displayChanged: false,
                brightnessChanged: false,
                idleChanged: false,
                effect: .unchanged
            ),
            displayUpdated: false
        )
    }

    func configurationStatus() async throws -> RuntimeOperationConfigurationStatus {
        RuntimeOperationConfigurationStatus(
            revision: 1,
            active: true,
            state: .idle,
            outcome: .ready,
            reason: .none,
            diagnostic: nil
        )
    }

    func retire() async {}
}

private final class SettingsEditorOperationsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandle: RuntimeOperationsHandle?

    init(handle: RuntimeOperationsHandle?) {
        storedHandle = handle
    }

    var handle: RuntimeOperationsHandle? {
        get { lock.withLock { storedHandle } }
        set { lock.withLock { storedHandle = newValue } }
    }
}

private final class SettingsAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                guard !isOpen else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            let waiting = waiters
            waiters.removeAll()
            return waiting
        }
        waiting.forEach { $0.resume() }
    }
}

private final class SettingsEditorOperationsFake: HidhoggAppRuntimeOperations, @unchecked Sendable {
    private let lock = NSLock()
    private let instanceID: String
    private let blocksFirstSnapshot: Bool
    private let firstSnapshotRelease = SettingsAsyncGate()
    private let deleteRelease = SettingsAsyncGate()
    private let positionGetRelease = SettingsAsyncGate()
    private let positionPatchRelease = SettingsAsyncGate()
    private var revisionStorage: UInt64 = 1
    private var digestStorage: String
    private var profileIDsStorage = ["Default", "Work.Profile"]
    private var labelsStorage = ["Default": "Default", "Work.Profile": "Work"]
    private let positionCoordinates = [
        "0_0", "1_0", "2_0", "3_0", "4_0",
        "0_1", "1_1", "2_1", "3_1", "4_1",
        "0_2", "1_2", "2_2", "3_2"
    ]
    private var positionLabelsStorage: [String: String] = [:]
    private var positionBackgroundStorage: [String: String] = [:]
    private var positionAlignmentStorage: [String: String] = [:]
    private var positionSizeStorage: [String: Int] = [:]
    private var positionNotificationSourcesStorage: [String]
    private var positionActionStorage: ConfiguredAction?
    private var currentProfileIDStorage: String
    private var snapshotCallCountStorage = 0
    private var snapshotCompletionCountStorage = 0
    private var createCallCountStorage = 0
    private var deleteCallCountStorage = 0
    private var deleteCompletionCountStorage = 0
    private var labelSetCallCountStorage = 0
    private var positionsListCallCountStorage = 0
    private var positionGetCallCountStorage = 0
    private var positionGetCompletionCountStorage = 0
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
    private var lastPositionPatchProfileIDStorage: String?
    private var lastPositionPatchIDStorage: String?
    private var lastPositionPatchDigestStorage: String?
    private var lastPositionPatchStorage: ConfigurationPositionPatch?
    private var nextMutationError: RuntimeOperationError?
    private var nextPositionGetError: RuntimeOperationError?
    private var blocksNextDelete = false
    private var blocksNextPositionGet = false
    private var blocksNextPositionPatch = false

    init(
        instanceID: String,
        digest: String = String(repeating: "a", count: 64),
        blocksFirstSnapshot: Bool = false,
        currentProfileID: String = "Default",
        notificationSources: [String] = [],
        action: ConfiguredAction? = nil
    ) {
        self.instanceID = instanceID
        digestStorage = digest
        self.blocksFirstSnapshot = blocksFirstSnapshot
        currentProfileIDStorage = currentProfileID
        positionNotificationSourcesStorage = notificationSources
        positionActionStorage = action
    }

    var sourceDigest: String { read { digestStorage } }
    var snapshotCallCount: Int { read { snapshotCallCountStorage } }
    var snapshotCompletionCount: Int { read { snapshotCompletionCountStorage } }
    var createCallCount: Int { read { createCallCountStorage } }
    var deleteCallCount: Int { read { deleteCallCountStorage } }
    var deleteCompletionCount: Int { read { deleteCompletionCountStorage } }
    var labelSetCallCount: Int { read { labelSetCallCountStorage } }
    var positionsListCallCount: Int { read { positionsListCallCountStorage } }
    var positionGetCallCount: Int { read { positionGetCallCountStorage } }
    var positionGetCompletionCount: Int { read { positionGetCompletionCountStorage } }
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
    var lastPositionPatchProfileID: String? { read { lastPositionPatchProfileIDStorage } }
    var lastPositionPatchID: String? { read { lastPositionPatchIDStorage } }
    var lastPositionPatchDigest: String? { read { lastPositionPatchDigestStorage } }
    var lastPositionPatch: ConfigurationPositionPatch? { read { lastPositionPatchStorage } }

    func setNextMutationError(_ error: RuntimeOperationError) {
        lock.withLock { nextMutationError = error }
    }

    func setNextPositionGetError(_ error: RuntimeOperationError) {
        lock.withLock { nextPositionGetError = error }
    }

    func setProfileIDs(_ profileIDs: [String]) {
        lock.withLock { profileIDsStorage = profileIDs }
    }

    func blockNextDelete() {
        lock.withLock { blocksNextDelete = true }
    }

    func blockNextPositionGet() {
        lock.withLock { blocksNextPositionGet = true }
    }

    func blockNextPositionPatch() {
        lock.withLock { blocksNextPositionPatch = true }
    }

    func releaseFirstSnapshot() { firstSnapshotRelease.open() }
    func releaseDelete() { deleteRelease.open() }
    func releasePositionGet() { positionGetRelease.open() }
    func releasePositionPatch() { positionPatchRelease.open() }

    func profiles() async throws -> [RuntimeOperationProfile] {
        lock.withLock {
            profileIDsStorage.map { profileID in
                RuntimeOperationProfile(
                    id: profileID,
                    label: labelsStorage[profileID] ?? profileID,
                    isDefault: profileID == "Default",
                    isCurrent: profileID == currentProfileIDStorage
                )
            }
        }
    }

    func activateProfile(_ profileID: String) async throws -> RuntimeActivationResult {
        try lock.withLock {
            guard profileIDsStorage.contains(profileID) else {
                throw RuntimeOperationError.profileNotFound
            }
            let changed = currentProfileIDStorage != profileID
            currentProfileIDStorage = profileID
            return RuntimeActivationResult(
                profileID: profileID,
                changed: changed,
                revision: revisionStorage
            )
        }
    }

    func setHostDisplayAwake(_ awake: Bool) async throws -> RuntimeOperationDisplayResult {
        RuntimeOperationDisplayResult(displayAwake: awake, changed: false)
    }

    func editorSnapshot() async throws -> RuntimeOperationEditorSnapshot {
        let shouldBlock = lock.withLock {
            snapshotCallCountStorage += 1
            return blocksFirstSnapshot && snapshotCallCountStorage == 1
        }
        if shouldBlock {
            await firstSnapshotRelease.wait()
        }
        return lock.withLock {
            snapshotCompletionCountStorage += 1
            return makeSnapshot()
        }
    }

    func editorProfile(
        sourceDigest: String,
        profileID: String
    ) async throws -> RuntimeOperationEditorProfile {
        try lock.withLock {
            guard digestStorage == sourceDigest,
                  let label = labelsStorage[profileID] else {
                throw RuntimeOperationError.staleSource
            }
            return RuntimeOperationEditorProfile(
                sourceDigest: digestStorage,
                profileID: profileID,
                label: label
            )
        }
    }

    func editorPositions(
        sourceDigest: String,
        profileID: String
    ) async throws -> RuntimeOperationEditorPositions {
        try lock.withLock {
            positionsListCallCountStorage += 1
            lastPositionsProfileIDStorage = profileID
            lastPositionsSourceDigestStorage = sourceDigest
            guard digestStorage == sourceDigest,
                  labelsStorage[profileID] != nil else {
                throw RuntimeOperationError.staleSource
            }
            return RuntimeOperationEditorPositions(
                sourceDigest: digestStorage,
                profileID: profileID,
                positions: positionCoordinates.map {
                    RuntimeOperationPositionSummary(positionID: $0, position: $0)
                }
            )
        }
    }

    func editorPosition(
        sourceDigest: String,
        profileID: String,
        positionID: String
    ) async throws -> RuntimeOperationEditorPosition {
        let gate = lock.withLock {
            positionGetCallCountStorage += 1
            lastPositionGetProfileIDStorage = profileID
            lastPositionGetIDStorage = positionID
            lastPositionGetDigestStorage = sourceDigest
            let shouldBlock = blocksNextPositionGet
            blocksNextPositionGet = false
            let error = nextPositionGetError
            nextPositionGetError = nil
            return (shouldBlock, error)
        }
        if gate.0 {
            await positionGetRelease.wait()
        }

        return try lock.withLock {
            positionGetCompletionCountStorage += 1
            if let error = gate.1 {
                if error == .staleSource { advanceSnapshot() }
                throw error
            }
            guard digestStorage == sourceDigest,
                  labelsStorage[profileID] != nil,
                  positionIndex(for: positionID) != nil else {
                advanceSnapshot()
                throw RuntimeOperationError.staleSource
            }
            return makePosition(profileID: profileID, positionID: positionID)
        }
    }

    func edit(
        expectedDigest: String,
        edit: RuntimeConfigurationEdit
    ) async throws -> RuntimeOperationEditResult {
        switch edit {
        case .setProfileLabel(let profileID, let label):
            return try lock.withLock {
                labelSetCallCountStorage += 1
                try throwPendingMutationError()
                guard digestStorage == expectedDigest,
                      labelsStorage[profileID] != nil else {
                    advanceSnapshot()
                    throw RuntimeOperationError.staleSource
                }
                labelsStorage[profileID] = label
                advanceSnapshot()
                return mutationResult(effect: .catalog)
            }
        case .cloneProfile(let sourceID, let newID, let label):
            return try await cloneProfile(
                expectedDigest: expectedDigest,
                sourceProfileID: sourceID,
                profileID: newID,
                label: label
            )
        case .deleteProfile(let profileID):
            return try await deleteProfile(profileID, expectedDigest: expectedDigest)
        case .patchPosition(let profileID, let coordinate, let patch):
            return try await patchPosition(
                profileID: profileID,
                positionID: coordinate,
                patch: patch,
                expectedDigest: expectedDigest
            )
        }
    }

    func cloneProfile(
        expectedDigest: String,
        sourceProfileID: String?,
        profileID: String,
        label: String
    ) async throws -> RuntimeOperationEditResult {
        try lock.withLock {
            createCallCountStorage += 1
            lastCreateProfileIDStorage = profileID
            lastCreateLabelStorage = label
            lastCreateSourceProfileIDStorage = sourceProfileID
            try throwPendingMutationError()
            let resolvedSource = sourceProfileID ?? "Default"
            guard digestStorage == expectedDigest,
                  !profileIDsStorage.contains(profileID),
                  profileIDsStorage.contains(resolvedSource) else {
                advanceSnapshot()
                throw RuntimeOperationError.staleSource
            }
            profileIDsStorage.append(profileID)
            labelsStorage[profileID] = label
            advanceSnapshot()
            return mutationResult(effect: .catalog)
        }
    }

    func reloadConfiguration() async throws -> RuntimeOperationReloadResult {
        let effects = RuntimeOperationReloadEffects(
            catalogChanged: false,
            defaultChanged: false,
            currentProfileChanged: false,
            currentProfileFallback: false,
            actionChanged: false,
            displayChanged: false,
            brightnessChanged: false,
            idleChanged: false,
            effect: .unchanged
        )
        return RuntimeOperationReloadResult(
            revision: read { revisionStorage },
            changed: false,
            effects: effects,
            displayUpdated: false
        )
    }

    func configurationStatus() async throws -> RuntimeOperationConfigurationStatus {
        RuntimeOperationConfigurationStatus(
            revision: read { revisionStorage },
            active: true,
            state: .idle,
            outcome: .ready,
            reason: .none,
            diagnostic: nil
        )
    }

    func retire() async {}

    private func deleteProfile(
        _ profileID: String,
        expectedDigest: String
    ) async throws -> RuntimeOperationEditResult {
        let shouldBlock = lock.withLock {
            deleteCallCountStorage += 1
            let shouldBlock = blocksNextDelete
            blocksNextDelete = false
            return shouldBlock
        }
        if shouldBlock {
            await deleteRelease.wait()
        }

        return try lock.withLock {
            try throwPendingMutationError()
            guard digestStorage == expectedDigest,
                  profileIDsStorage.contains(profileID),
                  profileID != "Default",
                  profileID != currentProfileIDStorage else {
                advanceSnapshot()
                throw RuntimeOperationError.staleSource
            }
            profileIDsStorage.removeAll { $0 == profileID }
            labelsStorage.removeValue(forKey: profileID)
            advanceSnapshot()
            deleteCompletionCountStorage += 1
            return mutationResult(effect: .catalog)
        }
    }

    private func patchPosition(
        profileID: String,
        positionID: String,
        patch: ConfigurationPositionPatch,
        expectedDigest: String
    ) async throws -> RuntimeOperationEditResult {
        let shouldBlock = lock.withLock {
            positionPatchCallCountStorage += 1
            lastPositionPatchProfileIDStorage = profileID
            lastPositionPatchIDStorage = positionID
            lastPositionPatchDigestStorage = expectedDigest
            lastPositionPatchStorage = patch
            let shouldBlock = blocksNextPositionPatch
            blocksNextPositionPatch = false
            return shouldBlock
        }
        if shouldBlock {
            await positionPatchRelease.wait()
        }

        return try lock.withLock {
            positionPatchCompletionCountStorage += 1
            try throwPendingMutationError()
            guard digestStorage == expectedDigest,
                  labelsStorage[profileID] != nil,
                  positionIndex(for: positionID) != nil else {
                advanceSnapshot()
                throw RuntimeOperationError.staleSource
            }
            apply(patch, to: positionID)
            advanceSnapshot()
            return mutationResult(effect: .display)
        }
    }

    private func apply(_ patch: ConfigurationPositionPatch, to positionID: String) {
        switch patch.label {
        case .keep: break
        case .set(let value): positionLabelsStorage[positionID] = value
        case .reset: positionLabelsStorage.removeValue(forKey: positionID)
        }
        switch patch.background {
        case .keep: break
        case .set(let value): positionBackgroundStorage[positionID] = value
        case .reset: positionBackgroundStorage.removeValue(forKey: positionID)
        }
        switch patch.labelAlignment {
        case .keep: break
        case .set(let value): positionAlignmentStorage[positionID] = value
        case .reset: positionAlignmentStorage.removeValue(forKey: positionID)
        }
        switch patch.labelSize {
        case .keep: break
        case .set(let value): positionSizeStorage[positionID] = value
        case .reset: positionSizeStorage.removeValue(forKey: positionID)
        }
        switch patch.notificationSources {
        case .keep: break
        case .set(let value): positionNotificationSourcesStorage = value
        case .reset: positionNotificationSourcesStorage = []
        }
        switch patch.action {
        case .keep: break
        case .set(let value): positionActionStorage = value
        case .reset: positionActionStorage = nil
        }
    }

    private func makeSnapshot() -> RuntimeOperationEditorSnapshot {
        RuntimeOperationEditorSnapshot(
            sourceDigest: digestStorage,
            revision: revisionStorage,
            defaultProfileID: "Default",
            currentProfileID: currentProfileIDStorage,
            profileIDs: profileIDsStorage
        )
    }

    private func makePosition(profileID: String, positionID: String) -> RuntimeOperationEditorPosition {
        RuntimeOperationEditorPosition(
            sourceDigest: digestStorage,
            profileID: profileID,
            positionID: positionID,
            label: positionLabelsStorage[positionID] ?? "Label \(positionID)",
            background: positionBackgroundStorage[positionID] ?? "#000000",
            labelAlignment: positionAlignmentStorage[positionID] ?? "bottom",
            labelSize: positionSizeStorage[positionID] ?? 10,
            notificationSources: positionNotificationSourcesStorage,
            action: positionActionStorage
        )
    }

    private func mutationResult(effect: RuntimeOperationEffect) -> RuntimeOperationEditResult {
        RuntimeOperationEditResult(
            sourceDigest: digestStorage,
            fileCommit: .committed,
            reloadOutcome: .reloaded,
            revision: revisionStorage,
            effect: effect,
            reason: .none
        )
    }

    private func throwPendingMutationError() throws {
        guard let error = nextMutationError else { return }
        nextMutationError = nil
        if error == .staleSource { advanceSnapshot() }
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

    private func read<Value>(_ body: () -> Value) -> Value {
        lock.withLock(body)
    }
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
