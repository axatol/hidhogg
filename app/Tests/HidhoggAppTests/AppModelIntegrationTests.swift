import Foundation
import Combine
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class AppModelIntegrationTests: XCTestCase {
    func testConnectAndDraftChangesDeliverImmediatelyBeforeAutosave() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        var posted = [KeyboardShortcut]()
        let model = AppModel(
            configurationURL: url, store: ConfigurationStore(url: url), bolt: session,
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { posted.append($0) }),
            loadImmediately: false, observeSleep: false, frontmostApplication: { "com.example.browser" }
        )
        var configuration = AppConfiguration.empty
        let first = KeyboardShortcut(keyCode: 12)
        let second = KeyboardShortcut(keyCode: 13)
        configuration.devices[0].defaults["back"] = .key(first)
        model.updateDraft(configuration)
        model.connect()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        session.press(.back)
        let firstPosted = await eventually { posted == [first] }
        XCTAssertTrue(firstPosted)
        configuration.devices[0].applications["com.example.browser"] = ["back": .key(second)]
        model.updateDraft(configuration)
        session.press(.back)
        let secondPosted = await eventually { posted == [first, second] }
        XCTAssertTrue(secondPosted)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(session.enableCount, 1)
        XCTAssertEqual(session.stopCount, 0)
    }

    func testAutosaveUsesOneSecondTrailingDebounceAndLatestDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let model = AppModel(
            configurationURL: url, store: ConfigurationStore(url: url), bolt: FixtureBindingSession(),
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
            loadImmediately: false, observeSleep: false
        )
        model.setWheelPreference(false)
        try await Task.sleep(for: .milliseconds(600))
        model.setWheelPreference(true)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let saved = await eventually { !model.isDirty }
        XCTAssertTrue(saved)
        let persisted = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(persisted.configuration.mouse?.wheelInverted, true)
    }

    func testAllDisabledConnectDoesNotDivertAndDelayedReadyStillEnablesLatestDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let model = AppModel(
            configurationURL: url, store: ConfigurationStore(url: url), bolt: session,
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
            loadImmediately: false, observeSleep: false
        )
        model.connect()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        await drainMainActorTasks()
        XCTAssertEqual(session.enableCount, 0)
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults["back"] = .key(KeyboardShortcut(keyCode: 12))
        model.updateDraft(configuration)
        let firstEnabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(firstEnabled)
        session.pauseNextDisableStatus()
        model.updateDraft(.empty)
        let disabled = await eventually { session.disableCount == 1 }
        XCTAssertTrue(disabled)
        model.updateDraft(configuration)
        await drainMainActorTasks()
        XCTAssertEqual(session.enableCount, 1)
        session.resumeDisableStatus()
        let reenabled = await eventually { session.enableCount == 2 && model.isBindingsEnabled }
        XCTAssertTrue(reenabled)
        model.disconnect()
        let stopped = await eventually { session.stopCount == 1 }
        XCTAssertTrue(stopped)
        model.setWheelPreference(true)
        await drainMainActorTasks()
        XCTAssertEqual(session.discoverCount, 1)
        XCTAssertEqual(session.enableCount, 2)
    }

    func testDiskConflictRetainsImmediateDraftAndRefusesTermination() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let session = FixtureBindingSession()
        var posted = [KeyboardShortcut]()
        let model = AppModel(
            configurationURL: url, store: store, bolt: session,
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { posted.append($0) }),
            loadImmediately: false, observeSleep: false, frontmostApplication: { nil }
        )
        await model.save()
        let initial = try await store.load()
        var external = AppConfiguration.empty
        external.devices[0].wheelInverted = true
        _ = try await store.save(external, expecting: initial.revision)
        var edited = AppConfiguration.empty
        let shortcut = KeyboardShortcut(keyCode: 12)
        edited.devices[0].defaults["back"] = .key(shortcut)
        model.updateDraft(edited)
        model.connect()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)
        let flushed = await model.flushPendingSave()
        XCTAssertFalse(flushed)
        XCTAssertNotNil(model.configurationSaveError)
        XCTAssertEqual(model.configurationStatus, "Save failed")
        session.press(.back)
        let delivered = await eventually { posted == [shortcut] }
        XCTAssertTrue(delivered)
        let terminated = await model.stopForTermination()
        XCTAssertFalse(terminated)
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertEqual(model.document.draft, edited)
        XCTAssertTrue(model.isDirty)
        let persisted = try await store.load()
        XCTAssertEqual(persisted.configuration, external)
    }

    func testReloadReconcilesLoadedBindingsWithoutDisconnecting() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let session = FixtureBindingSession()
        let model = AppModel(
            configurationURL: url, store: store, bolt: session,
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
            loadImmediately: false, observeSleep: false
        )
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults["back"] = .key(KeyboardShortcut(keyCode: 12))
        model.updateDraft(configuration)
        await model.save()
        model.connect()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)
        let initial = try await store.load()
        _ = try await store.save(.empty, expecting: initial.revision)
        model.requestReload()
        let reloaded = await eventually { !model.isLoading && model.boltStatus.phase == .ready }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(model.document.draft, .empty)
        XCTAssertEqual(session.disableCount, 1)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(session.discoverCount, 1)
    }

    func testReloadConfirmationPausesAutosaveAndDiscardNeverWritesDraft() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let model = AppModel(
            configurationURL: url, store: store, bolt: FixtureBindingSession(),
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in }),
            loadImmediately: false, observeSleep: false
        )
        await model.save()
        model.setWheelPreference(true)
        model.requestReload()
        XCTAssertTrue(model.isReloadConfirmationPresented)
        try await Task.sleep(for: .milliseconds(1100))
        let before = try await store.load()
        XCTAssertEqual(before.configuration, .empty)
        model.confirmDiscardAndReload()
        let loaded = await eventually { !model.isLoading }
        XCTAssertTrue(loaded)
        try await Task.sleep(for: .milliseconds(1100))
        let after = try await store.load()
        XCTAssertEqual(after.configuration, .empty)
        XCTAssertFalse(model.isDirty)
    }

    func testMalformedReloadRetainsLastValidatedDeliveryAndBlocksDiskOverwrite() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        var posted = [KeyboardShortcut]()
        let model = AppModel(
            configurationURL: url, store: ConfigurationStore(url: url), bolt: session,
            sender: ShortcutSender(preflight: { true }, request: { true }, postPair: { posted.append($0) }),
            loadImmediately: false, observeSleep: false, frontmostApplication: { nil }
        )
        var configuration = AppConfiguration.empty
        let shortcut = KeyboardShortcut(keyCode: 12)
        configuration.devices[0].defaults["back"] = .key(shortcut)
        model.updateDraft(configuration)
        await model.save()
        model.connect()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)
        let invalidBytes = Data("schema_version = 2\n".utf8)
        try invalidBytes.write(to: url)
        model.requestReload()
        let failed = await eventually { !model.isLoading && model.configurationLoadFailed }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.document.draft, configuration)
        XCTAssertTrue(model.isBindingsEnabled)
        XCTAssertFalse(model.canSaveConfiguration)
        session.press(.back)
        let delivered = await eventually { posted == [shortcut] }
        XCTAssertTrue(delivered)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(session.disableCount, 0)
        await model.save()
        XCTAssertEqual(try Data(contentsOf: url), invalidBytes)
    }

    func testPermissionChecksPublishTogetherAndDiagnosticsUseEmittedSnapshot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var accessibilityTrusted = true
        var eventPostingAllowed = false
        let sender = ShortcutSender(
            accessibilityPreflight: { accessibilityTrusted },
            preflight: { eventPostingAllowed },
            request: { true },
            postPair: { _ in }
        )
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: FixtureBindingSession(),
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        var publishedChecks = [PermissionChecks]()
        let observation = model.$permissionChecks.sink { publishedChecks.append($0) }
        var persistedMessages = [String]()
        let diagnostics = DiagnosticsStore(model: model, persist: { message, _ in persistedMessages.append(message) })
        persistedMessages.removeAll()

        let postingDenied = PermissionChecks(accessibilityTrusted: true, eventPostingAllowed: false)
        XCTAssertEqual(model.refreshPermission(), .denied)
        XCTAssertEqual(model.permissionChecks, postingDenied)
        XCTAssertEqual(model.permission, .denied)
        XCTAssertEqual(publishedChecks.last, postingDenied)
        XCTAssertTrue(persistedMessages.last?.contains("Permission checks: accessibilityTrusted=true, eventPostingAllowed=false.") == true)

        accessibilityTrusted = false
        eventPostingAllowed = true
        let accessibilityUntrusted = PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: true)
        XCTAssertEqual(model.requestPermission(), .granted)
        XCTAssertEqual(model.permissionChecks, accessibilityUntrusted)
        XCTAssertEqual(model.permission, .granted)
        XCTAssertEqual(publishedChecks.last, accessibilityUntrusted)
        XCTAssertTrue(persistedMessages.last?.contains("Permission checks: accessibilityTrusted=false, eventPostingAllowed=true.") == true)

        model.reportError("Failure at /private/secret/config.toml after Command-Option-X delivery.")
        let persistedError = try XCTUnwrap(persistedMessages.last)
        XCTAssertTrue(persistedError.contains("code=app.error"))
        XCTAssertTrue(persistedError.contains("An operation failed. See the error shown by Hidhogg."))
        XCTAssertFalse(persistedError.contains("/private/secret"))
        XCTAssertFalse(persistedError.contains("Command-Option-X"))
        XCTAssertEqual(diagnostics.entries.last?.message, "An operation failed. See the error shown by Hidhogg.")
        withExtendedLifetime((observation, diagnostics)) {}
    }

    func testBoltFailureDiagnosticsCorrelateTypedSourceAndConsoleIdentity() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: ShortcutSender(preflight: { false }, request: { true }, postPair: { _ in }),
            loadImmediately: false,
            observeSleep: false
        )
        var persistedMessages = [String]()
        let diagnostics = DiagnosticsStore(model: model, persist: { message, _ in persistedMessages.append(message) })
        persistedMessages.removeAll()
        let status = BoltStatus(
            phase: .failed,
            message: "Session failed.",
            availableControls: [],
            generation: 7,
            cleanupUncertain: false,
            failure: BoltFailureContext(
                code: .endpointAmbiguous,
                sourceFileID: "LogitechBolt/BoltController.swift",
                sourceLine: 1083
            )
        )

        session.emit(status)

        let received = await eventually {
            diagnostics.entries.contains { $0.code == .boltEndpointAmbiguous }
        }
        XCTAssertTrue(received)
        let entry = try XCTUnwrap(diagnostics.entries.last { $0.code == .boltEndpointAmbiguous })
        let consoleRecord = try XCTUnwrap(persistedMessages.first { $0.contains("id=\(entry.id.uuidString)") })
        XCTAssertEqual(entry.message, "Session failed.")
        XCTAssertEqual(entry.source.description, "LogitechBolt/BoltController.swift:1083")
        XCTAssertEqual(entry.buildID, ApplicationIdentity.current.buildID)
        XCTAssertTrue(consoleRecord.contains("code=bolt.endpoint.ambiguous"))
        XCTAssertTrue(consoleRecord.contains("id=\(entry.id.uuidString)"))
        XCTAssertTrue(consoleRecord.contains("build=\(entry.buildID)"))
        XCTAssertTrue(consoleRecord.contains("source=\(entry.source.description)"))
        XCTAssertTrue(consoleRecord.contains("message=Session failed."))
        withExtendedLifetime((model, diagnostics)) {}
    }

    func testMissingConfigurationDoesNotGateValidatedDraftReadiness() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )

        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.refreshPermission(), .granted)
        XCTAssertTrue(model.canEnableBindings)
        XCTAssertTrue(model.canSaveConfiguration)

        await model.save()

        XCTAssertEqual(model.document.saved, .empty)
        XCTAssertEqual(model.document.draft, .empty)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertTrue(model.canEnableBindings)
        let saved = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(saved.configuration, .empty)
    }

    func testRestartGateRejectsNewDeviceAndConfigurationWorkButAllowsDisconnect() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        _ = model.refreshPermission()
        XCTAssertTrue(model.canEnableBindings)

        var edited = AppConfiguration.empty
        edited.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 0x7B))
        model.updateDraft(edited)
        XCTAssertTrue(model.isDirty)
        model.setRestarting(true)

        XCTAssertTrue(model.isRestarting)
        XCTAssertFalse(model.canDiscover)
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertFalse(model.canSaveConfiguration)
        model.connect()
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        model.updateDraft(.empty)
        await model.save()
        model.requestReload()
        await drainMainActorTasks()

        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.document.draft, edited)
        let persisted = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(persisted.configuration, .empty)
        XCTAssertEqual(session.discoverCount, 0)
        XCTAssertEqual(session.enableCount, 0)

        model.disconnect()
        let stopped = await eventually { session.stopCount == 1 }
        XCTAssertTrue(stopped)
    }

    func testInvalidConfigurationBlocksSavingAndPreservesOriginalBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let invalidBytes = Data("schema_version = 2\n".utf8)
        try invalidBytes.write(to: url)
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: true,
            observeSleep: false
        )

        session.emitReady()
        let loaded = await eventually { !model.isLoading }
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.refreshPermission(), .granted)
        XCTAssertEqual(model.configurationStatus, "Configuration unavailable")
        XCTAssertTrue(model.configurationLoadFailed)
        XCTAssertFalse(model.canSaveConfiguration)
        XCTAssertFalse(model.canEnableBindings)

        await model.save()

        XCTAssertEqual(try Data(contentsOf: url), invalidBytes)
    }

    func testPermissionRevocationOnPressSuppressesDeliveryAndDisablesSession() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var permissionAvailable = true
        var posted = [KeyboardShortcut]()
        let session = FixtureBindingSession()
        let sender = ShortcutSender(
            preflight: { permissionAvailable },
            request: { permissionAvailable },
            postPair: { posted.append($0) }
        )
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false,
            frontmostApplication: { "com.example.browser" }
        )
        var configuration = AppConfiguration.empty
        let shortcut = KeyboardShortcut(keyCode: 0x7B, modifiers: [.command])
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(shortcut)
        model.updateDraft(configuration)
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.refreshPermission(), .granted)
        XCTAssertTrue(model.canEnableBindings)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)

        session.press(.back)
        let firstPressPosted = await eventually { posted.count == 1 }
        XCTAssertTrue(firstPressPosted)
        XCTAssertEqual(posted, [shortcut])

        permissionAvailable = false
        session.press(.back)
        let disabled = await eventually { session.disableCount == 1 }
        XCTAssertTrue(disabled)
        XCTAssertEqual(model.permission, .denied)
        XCTAssertFalse(model.isBindingsEnabled)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(posted, [shortcut])
    }

    func testDisconnectSleepAndTerminationInvalidateQueuedSessionIntents() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        _ = model.refreshPermission()
        await model.save()

        model.connect()
        model.disconnect()
        let disconnected = await eventually { session.stopCount == 1 }
        XCTAssertTrue(disconnected)
        await drainMainActorTasks()
        XCTAssertEqual(session.discoverCount, 0)
        XCTAssertEqual(session.enableCount, 0)

        model.connect()
        model.prepareForLifecycleStop()
        let sleepCleanup = Task { await model.stopForSleep() }
        await sleepCleanup.value
        await drainMainActorTasks()
        XCTAssertEqual(session.stopCount, 2)
        XCTAssertEqual(session.discoverCount, 0)

        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        model.prepareForLifecycleStop()
        let terminationCleanup = Task { await model.stopForTermination() }
        let terminationSucceeded = await terminationCleanup.value
        XCTAssertTrue(terminationSucceeded)
        await drainMainActorTasks()
        XCTAssertEqual(session.stopCount, 3)
        XCTAssertEqual(session.enableCount, 0)
    }

    func testSavePreservesConnectionAndConcurrentDraftEdits() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        _ = model.refreshPermission()
        model.requestEnableConfirmation()
        model.confirmEnableBindings()

        var edited = AppConfiguration.empty
        edited.devices[0].defaults[MouseControl.forward.rawValue] = .key(KeyboardShortcut(keyCode: 0x7C))
        model.updateDraft(edited)
        var newer = edited
        newer.devices[0].wheelInverted = true
        let observation = model.$isSaving.dropFirst().sink { saving in
            if saving { model.updateDraft(newer) }
        }

        await model.save()

        XCTAssertEqual(model.document.saved, edited)
        XCTAssertEqual(model.document.draft, newer)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(session.stopCount, 0)
        withExtendedLifetime(observation) {}
        let flushed = await model.flushPendingSave()
        XCTAssertTrue(flushed)
        XCTAssertEqual(model.document.saved, newer)
    }

    func testReloadFromReadyStateRetainsConnection() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        _ = model.refreshPermission()
        XCTAssertTrue(model.canEnableBindings)

        model.requestReload()

        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.canEnableBindings)
        let loaded = await eventually { !model.isLoading }
        XCTAssertTrue(loaded)
        await drainMainActorTasks()
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertTrue(model.canEnableBindings)
    }

    func testReloadWithActivationIntentRetainsReadySession() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        _ = model.refreshPermission()
        model.requestEnableConfirmation()
        model.confirmEnableBindings()

        model.requestReload()

        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertFalse(model.isEnableConfirmationPresented)
        let loaded = await eventually { !model.isLoading }
        XCTAssertTrue(loaded)
        await drainMainActorTasks()
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertEqual(session.stopCount, 0)
        XCTAssertEqual(model.boltStatus.phase, .ready)
    }

    func testRecordingFromReadyStateRetainsConnection() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)

        model.beginRecording(for: .back)
        await drainMainActorTasks()

        XCTAssertEqual(model.boltStatus.phase, .ready)
        XCTAssertEqual(session.stopCount, 0)
    }

    func testRecordingSuppressesDeliveryAndResumesWithoutDisconnecting() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let shortcut = KeyboardShortcut(keyCode: 0x7B)
        var posted = [KeyboardShortcut]()
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { posted.append($0) })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(shortcut)
        model.updateDraft(configuration)
        await model.save()
        session.emitReady()
        let ready = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.refreshPermission(), .granted)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        let enabled = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(enabled)

        model.beginRecording(for: .back)
        await drainMainActorTasks()
        session.press(.back)
        await drainMainActorTasks()

        XCTAssertEqual(model.recordingTarget, ShortcutRecordingTarget(control: .back, applicationID: nil))
        XCTAssertEqual(model.boltStatus.phase, .enabled)
        XCTAssertFalse(model.isBindingsEnabled)
        XCTAssertEqual(posted, [])
        XCTAssertEqual(session.stopCount, 0)
        model.cancelRecording()
        session.press(.back)
        let resumed = await eventually { posted == [shortcut] }
        XCTAssertTrue(resumed)
    }

    func testSleepAndTerminationAwaitInjectedSessionCleanup() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var posted = 0
        let session = FixtureBindingSession()
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in posted += 1 })
        let model = AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: session,
            sender: sender,
            loadImmediately: false,
            observeSleep: false
        )
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults[MouseControl.back.rawValue] = .key(KeyboardShortcut(keyCode: 0x7B))
        model.updateDraft(configuration)
        await model.save()
        session.emitReady()
        let firstReady = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(firstReady)
        _ = model.refreshPermission()
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        let firstEnable = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(firstEnable)

        await model.stopForSleep()
        XCTAssertEqual(session.stopCount, 1)
        XCTAssertFalse(model.isBindingsEnabled)
        session.press(.back)
        await Task.yield()
        XCTAssertEqual(posted, 0)

        session.emitReady()
        let secondReady = await eventually { model.boltStatus.phase == .ready }
        XCTAssertTrue(secondReady)
        model.requestEnableConfirmation()
        model.confirmEnableBindings()
        let secondEnable = await eventually { model.isBindingsEnabled }
        XCTAssertTrue(secondEnable)

        await model.stopForTermination()
        XCTAssertEqual(session.stopCount, 2)
        XCTAssertFalse(model.isBindingsEnabled)
        session.press(.back)
        await Task.yield()
        XCTAssertEqual(posted, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = base.appendingPathComponent("HidhoggAppIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func drainMainActorTasks() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

private final class FixtureBindingSession: BindingSession, @unchecked Sendable {
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var admissionEnabled = false
    private var nextGeneration: UInt64 = 10
    private var discoverCalls = 0
    private var enableCalls = 0
    private var disableCalls = 0
    private var stopCalls = 0
    private var pauseNextStopCall = false
    private var stopIsPendingValue = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var pauseDisableStatus = false

    init() {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var discoverCount: Int { locked { discoverCalls } }
    var enableCount: Int { locked { enableCalls } }
    var disableCount: Int { locked { disableCalls } }
    var stopCount: Int { locked { stopCalls } }
    var stopIsPending: Bool { locked { stopIsPendingValue } }

    func discover() async {
        locked { discoverCalls += 1 }
        emitReady()
    }

    func enable() async {
        let status = locked { () -> BoltStatus in
            enableCalls += 1
            nextGeneration &+= 1
            generation = nextGeneration
            admissionEnabled = true
            return BoltStatus(
                phase: .enabled,
                message: "Fixture enabled",
                availableControls: Set(MouseControl.allCases),
                generation: generation,
                cleanupUncertain: false
            )
        }
        continuation.yield(.status(status))
    }

    func disable() async {
        let paused = locked {
            disableCalls += 1
            admissionEnabled = false
            return pauseDisableStatus
        }
        if !paused { emitReady() }
    }

    func pauseNextDisableStatus() { locked { pauseDisableStatus = true } }

    func resumeDisableStatus() {
        locked { pauseDisableStatus = false }
        emitReady()
    }

    func stop() async {
        let shouldPause = locked { () -> Bool in
            stopCalls += 1
            guard pauseNextStopCall else { return false }
            pauseNextStopCall = false
            return true
        }
        if shouldPause {
            await withCheckedContinuation { continuation in
                locked {
                    stopIsPendingValue = true
                    stopContinuation = continuation
                }
            }
            locked { stopIsPendingValue = false }
        }
        finishSession()
    }

    func withPressAdmission(
        generation requestedGeneration: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        locked {
            let age = observedAt.duration(to: .now)
            guard admissionEnabled, generation == requestedGeneration,
                  age >= .zero, age <= .milliseconds(250) else { return false }
            operation()
            return true
        }
    }

    func emitReady() {
        let status = locked { () -> BoltStatus in
            admissionEnabled = false
            nextGeneration &+= 1
            generation = nextGeneration
            return BoltStatus(
                phase: .ready,
                message: "Fixture ready",
                availableControls: Set(MouseControl.allCases),
                generation: generation,
                cleanupUncertain: false
            )
        }
        continuation.yield(.status(status))
    }

    func emit(_ status: BoltStatus) {
        continuation.yield(.status(status))
    }

    func press(_ control: MouseControl) {
        let currentGeneration = locked { generation }
        continuation.yield(.press(control, generation: currentGeneration, observedAt: .now))
    }

    func pauseNextStop() {
        locked { pauseNextStopCall = true }
    }

    func resumeStop() {
        let continuation = locked { () -> CheckedContinuation<Void, Never>? in
            let current = stopContinuation
            stopContinuation = nil
            return current
        }
        continuation?.resume()
    }

    private func finishSession() {
        let status = locked { () -> BoltStatus in
            admissionEnabled = false
            nextGeneration &+= 1
            generation = nextGeneration
            return BoltStatus(
                phase: .idle,
                message: "Fixture stopped",
                availableControls: [],
                generation: generation,
                cleanupUncertain: false
            )
        }
        continuation.yield(.status(status))
    }

    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
