import Foundation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class UIAlignmentTests: XCTestCase {
    func testWheelTargetHistoryPreservesSelectedApplication() throws {
        let model = makeModel(configurationURL: temporaryConfigurationURL())
        let applicationID = "com.example.editor"
        var configuration = AppConfiguration.empty
        configuration.devices[0].applications[applicationID] = ["back": .key(KeyboardShortcut(keyCode: 12))]
        model.updateDraft(configuration)

        model.selectApplication(applicationID)
        model.beginRecording(for: .back, applicationID: applicationID)
        XCTAssertNotNil(model.captureSessionID)
        model.selectTarget(.verticalWheel)
        XCTAssertNil(model.captureSessionID)
        XCTAssertEqual(model.selectedApplicationID, applicationID)
        XCTAssertEqual(model.selectedTarget, .verticalWheel)

        model.selectTarget(.thumbWheel)
        XCTAssertEqual(model.selectedApplicationID, applicationID)
        XCTAssertEqual(model.selectedTarget, .thumbWheel)

        model.goBack()
        XCTAssertEqual(model.selectedApplicationID, applicationID)
        XCTAssertEqual(model.selectedTarget, .verticalWheel)

        model.goForward()
        XCTAssertEqual(model.selectedApplicationID, applicationID)
        XCTAssertEqual(model.selectedTarget, .thumbWheel)
    }

    func testInheritRetainsApplicationAfterConfigurationStoreRoundTrip() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let model = makeModel(configurationURL: url, store: store)
        let applicationID = "com.example.browser"
        var configuration = AppConfiguration.empty
        configuration.devices[0].applications[applicationID] = ["back": .key(KeyboardShortcut(keyCode: 12))]
        model.updateDraft(configuration)
        model.selectApplication(applicationID)

        model.setBindingMode(.inherit, for: .back)
        XCTAssertEqual(model.selectedApplicationID, applicationID)
        XCTAssertEqual(model.bindingMode(for: .back), .inherit)
        XCTAssertTrue(model.document.draft.mouse?.applications[applicationID]?.isEmpty == true)

        await model.save()

        let reloaded = try await store.load()
        XCTAssertTrue(reloaded.configuration.mouse?.applications[applicationID]?.isEmpty == true)
        XCTAssertFalse(model.isDirty)
    }

    func testStaleCaptureCompletionAndCancellationCannotAffectCurrentSession() throws {
        let model = makeModel(configurationURL: temporaryConfigurationURL())
        model.beginRecording(for: .back)
        let staleSessionID = try XCTUnwrap(model.captureSessionID)

        model.beginRecording(for: .forward)
        let currentSessionID = try XCTUnwrap(model.captureSessionID)
        XCTAssertNotEqual(staleSessionID, currentSessionID)
        let currentTarget = model.recordingTarget
        let currentDraft = model.document.draft

        model.completeRecording(KeyboardShortcut(keyCode: 13), sessionID: staleSessionID)
        model.cancelRecording(sessionID: staleSessionID)

        XCTAssertEqual(model.captureSessionID, currentSessionID)
        XCTAssertEqual(model.recordingTarget, currentTarget)
        XCTAssertEqual(model.document.draft, currentDraft)

        model.completeRecording(KeyboardShortcut(keyCode: 14), sessionID: currentSessionID)
        XCTAssertEqual(model.document.draft.mouse?.binding(for: .forward, application: nil), .key(KeyboardShortcut(keyCode: 14)))
        XCTAssertNil(model.captureSessionID)
    }

    func testRepeatedPermissionNavigationRequestsRemainObservable() {
        let model = makeModel(configurationURL: temporaryConfigurationURL())
        model.openPermissions()
        let firstRequest = model.settingsScrollRequestID

        model.openPermissions()

        XCTAssertNotEqual(model.settingsScrollRequestID, firstRequest)
        XCTAssertEqual(model.selectedSettingsCategory, .permissions)
        XCTAssertEqual(model.navigation.current.route, .settings)
    }

    func testRouteAndHistoryNavigationCancelActiveRecording() throws {
        let model = makeModel(configurationURL: temporaryConfigurationURL())

        model.beginRecording(for: .back)
        XCTAssertNotNil(model.captureSessionID)
        model.openPermissions()
        XCTAssertEqual(model.selectedSettingsCategory, .permissions)
        XCTAssertEqual(model.navigation.current.route, .settings)
        XCTAssertNil(model.captureSessionID)
        XCTAssertNil(model.recordingTarget)

        model.navigate(to: .devices)
        model.selectTarget(.forward)
        model.beginRecording(for: .forward)
        XCTAssertNotNil(model.captureSessionID)
        model.goBack()
        XCTAssertNil(model.captureSessionID)
        XCTAssertNil(model.recordingTarget)

        model.beginRecording(for: .back)
        XCTAssertNotNil(model.captureSessionID)
        model.goForward()
        XCTAssertNil(model.captureSessionID)
        XCTAssertNil(model.recordingTarget)
    }

    func testSettingsCategoryIsRememberedAndPermissionsLinkSelectsItWithoutHistoryEntry() {
        let model = makeModel(configurationURL: temporaryConfigurationURL())
        model.selectedSettingsCategory = .diagnostics
        model.navigate(to: .settings)
        XCTAssertEqual(model.selectedSettingsCategory, .diagnostics)

        let historyAfterSettings = model.navigation.backRoutes.count
        model.selectedSettingsCategory = .configuration
        XCTAssertEqual(model.navigation.backRoutes.count, historyAfterSettings)

        model.navigate(to: .devices)
        model.navigate(to: .settings)
        XCTAssertEqual(model.selectedSettingsCategory, .configuration)

        model.navigate(to: .devices)
        let historyBeforePermissions = model.navigation.backRoutes.count
        model.openPermissions()
        XCTAssertEqual(model.navigation.current.route, .settings)
        XCTAssertEqual(model.selectedSettingsCategory, .permissions)
        XCTAssertEqual(model.navigation.backRoutes.count, historyBeforePermissions + 1)

        let historyAfterPermissions = model.navigation.backRoutes.count
        model.selectedSettingsCategory = .general
        XCTAssertEqual(model.navigation.backRoutes.count, historyAfterPermissions)
    }

    func testOfflineCaptureCompletesWithoutInputPermission() throws {
        let model = makeModel(
            configurationURL: temporaryConfigurationURL(),
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
                XCTFail("Configuration capture must not post keyboard events")
            })
        )
        let shortcut = KeyboardShortcut(keyCode: 12)
        XCTAssertFalse(model.permissionChecks.eventPostingAllowed)

        model.beginRecording(for: .back)
        let sessionID = try XCTUnwrap(model.captureSessionID)
        model.completeRecording(shortcut, sessionID: sessionID)

        XCTAssertEqual(model.document.draft.mouse?.binding(for: .back, application: nil), .key(shortcut))
        XCTAssertNil(model.captureSessionID)
    }

    func testRevisionConflictPreservesEditableDraftAndReloadsExternalConfiguration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let model = makeModel(configurationURL: url, store: store)
        await model.save()
        let initial = try await store.load()

        var external = AppConfiguration.empty
        external.devices[0].defaults["forward"] = .key(KeyboardShortcut(keyCode: 13))
        _ = try await store.save(external, expecting: initial.revision)

        var local = AppConfiguration.empty
        local.devices[0].defaults["back"] = .key(KeyboardShortcut(keyCode: 12))
        model.updateDraft(local)
        let localSaveSucceeded = await model.flushPendingSave()
        XCTAssertFalse(localSaveSucceeded)

        XCTAssertEqual(model.configurationFailureKind, .conflict)
        XCTAssertTrue(model.canEditConfiguration)
        XCTAssertTrue(model.canReloadConfiguration)
        XCTAssertEqual(model.document.draft, local)
        let afterConflict = try await store.load()
        XCTAssertEqual(afterConflict.configuration, external)

        var laterEdit = local
        laterEdit.connectOnLaunch = false
        model.updateDraft(laterEdit)
        XCTAssertEqual(model.document.draft, laterEdit)
        model.requestReload()
        XCTAssertTrue(model.isReloadConfirmationPresented)
        model.confirmDiscardAndReload()
        let reloadFinished = await eventually { !model.isLoading && model.configurationFailureKind == nil }
        XCTAssertTrue(reloadFinished)
        XCTAssertEqual(model.document.draft, external)
    }

    func testReloadFailureBlocksEditsAndAllowsSuccessfulReload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let model = makeModel(configurationURL: url, store: store)
        var lastValidConfiguration = AppConfiguration.empty
        lastValidConfiguration.connectOnLaunch = false
        model.updateDraft(lastValidConfiguration)
        await model.save()

        try Data("not = [valid TOML".utf8).write(to: url)
        model.requestReload()
        let failedReloadFinished = await eventually { !model.isLoading && model.configurationFailureKind == .load }
        XCTAssertTrue(failedReloadFinished)
        XCTAssertEqual(model.configurationFailureKind, .load)
        XCTAssertFalse(model.canEditConfiguration)
        XCTAssertTrue(model.canReloadConfiguration)
        XCTAssertEqual(model.document.draft, lastValidConfiguration)
        var attemptedEdit = lastValidConfiguration
        attemptedEdit.connectOnLaunch.toggle()
        model.updateDraft(attemptedEdit)
        XCTAssertEqual(model.document.draft, lastValidConfiguration)

        let validConfiguration = AppConfiguration.empty
        try ConfigurationCodec.encode(validConfiguration).write(to: url)
        model.requestReload()

        let reloadFinished = await eventually { !model.isLoading && model.configurationFailureKind == nil }
        XCTAssertTrue(reloadFinished)
        XCTAssertTrue(model.canEditConfiguration)
        XCTAssertEqual(model.document.draft, validConfiguration)
    }

    private func makeModel(
        configurationURL: URL,
        store: ConfigurationStore? = nil,
        sender: ShortcutSender = ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
            XCTFail("Tests must not post keyboard events")
        })
    ) -> AppModel {
        AppModel(
            configurationURL: configurationURL,
            store: store ?? ConfigurationStore(url: configurationURL),
            bolt: UIAlignmentNoopBindingSession(),
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggUIAlignment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func temporaryConfigurationURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggUIAlignment-\(UUID().uuidString)")
            .appendingPathComponent("config.toml")
    }

    private func eventually(
        attempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct UIAlignmentNoopBindingSession: BindingSession {
    let events = AsyncStream<BoltEvent> { $0.finish() }

    func discover() async {}
    func enable() async {}
    func disable() async {}
    func stop() async {}

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }
}
