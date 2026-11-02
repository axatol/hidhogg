import AppKit
import SwiftUI
import XCTest
@testable import HidhoggApp
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions

@MainActor
final class MouseHardwareSettingsModelTests: XCTestCase {
    func testHardwarePreferenceChangesWaitForDebounceAndApplyOnlyLatestValue() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let registration = try makeRegistration(unitID: "12345678")
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session)
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)
        let initialApply = await eventually { session.hardwareSettingsRequests.count == 1 }
        XCTAssertTrue(initialApply)

        model.setMouseHardwarePreference(\.dpi, Optional(UInt16(1600)))
        try await Task.sleep(for: .milliseconds(100))
        model.setMouseHardwarePreference(\.pointerSpeed, Optional(1.25))
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(session.hardwareSettingsRequests.count, 1)
        let editedApply = await eventually { session.hardwareSettingsRequests.count == 2 }
        XCTAssertTrue(editedApply)
        XCTAssertEqual(session.hardwareSettingsRequests.count, 2)
        XCTAssertEqual(
            session.hardwareSettingsRequests.last,
            .init(preferences: .init(dpi: 1600, pointerSpeed: 1.25), restorePreviousSettingsOnDisconnect: false)
        )

        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
        _ = await model.flushPendingSave()
    }

    func testSelectedNonownerPreferenceSavesToItsRegistrationWithoutHardwareWrite() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let owner = try makeRegistration(unitID: "12345678", hardwarePreferences: .init(dpi: 800))
        let selected = try makeRegistration(unitID: "87654321", hardwarePreferences: .init(pointerSpeed: 1.1))
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(owner.logitechAssociation))
        let (model, store) = try await makeModel(
            url: url,
            registrations: [owner, selected],
            preferredMouseID: owner.id,
            session: session
        )
        let connected = await connect(model, ownerID: owner.id)
        XCTAssertTrue(connected)
        let initialApply = await eventually { session.hardwareSettingsRequests.count == 1 }
        XCTAssertTrue(initialApply)

        model.navigate(to: .mouse(selected.id))
        XCTAssertEqual(model.selectedMouseID, selected.id)
        XCTAssertFalse(model.canChangeMouseHardware)
        model.setMouseHardwarePreference(\.dpi, Optional(UInt16(1600)))
        await model.save()
        try await Task.sleep(for: .milliseconds(250))

        let saved = try await store.load()
        let ownerPreferences = try XCTUnwrap(saved.workspace.configuration(forMouseID: owner.id).mouse?.hardwarePreferences)
        let selectedPreferences = try XCTUnwrap(saved.workspace.configuration(forMouseID: selected.id).mouse?.hardwarePreferences)
        XCTAssertEqual(ownerPreferences, .init(dpi: 800))
        XCTAssertEqual(selectedPreferences, .init(dpi: 1600, pointerSpeed: 1.1))
        XCTAssertEqual(session.hardwareSettingsRequests.count, 1)

        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
    }

    func testDisconnectPreventsPendingHardwarePreferenceWrite() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let registration = try makeRegistration(unitID: "12345678")
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session)
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)
        let initialApply = await eventually { session.hardwareSettingsRequests.count == 1 }
        XCTAssertTrue(initialApply)

        model.setMouseHardwarePreference(\.dpi, Optional(UInt16(2400)))
        model.disconnect()
        let stopped = await eventually { session.stopCount == 1 && model.boltStatus.phase == .idle }
        XCTAssertTrue(stopped)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(session.hardwareSettingsRequests.count, 1)
    }

    func testSavedHardwarePreferencesAreAppliedAgainAfterReconnect() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let preferences = MouseHardwarePreferences(dpi: 1600, pointerSpeed: 1.25, hapticsEnabled: true)
        let registration = try makeRegistration(
            unitID: "12345678",
            hardwarePreferences: preferences,
            restorePreviousSettingsOnDisconnect: true
        )
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session)

        let firstConnection = await connect(model, ownerID: registration.id)
        XCTAssertTrue(firstConnection)
        let firstApply = await eventually { session.hardwareSettingsRequests.count == 1 }
        XCTAssertTrue(firstApply)
        let firstRequest = try XCTUnwrap(session.hardwareSettingsRequests.first)
        XCTAssertEqual(
            firstRequest,
            .init(preferences: .init(preferences), restorePreviousSettingsOnDisconnect: true)
        )

        model.disconnect()
        let stopped = await eventually { session.stopCount == 1 && model.boltStatus.phase == .idle }
        XCTAssertTrue(stopped)
        model.connect()

        let secondApply = await eventually { session.hardwareSettingsRequests.count == 2 }
        XCTAssertTrue(secondApply)
        let secondRequest = try XCTUnwrap(session.hardwareSettingsRequests.dropFirst().first)
        XCTAssertEqual(
            secondRequest,
            .init(preferences: .init(preferences), restorePreviousSettingsOnDisconnect: true)
        )

        model.disconnect()
        _ = await eventually { session.stopCount == 2 }
    }

    func testDefaultWheelDirectionsAreAppliedAsStandardMainAndNaturalThumbwheel() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let registration = try makeRegistration(unitID: "12345678")
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session)
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)

        let applied = await eventually {
            session.mainWheelDirections.count == 1 && session.thumbwheelDirections.count == 1
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(model.wheelPreferenceDraft, false)
        XCTAssertEqual(model.thumbwheelPreferenceDraft, true)
        XCTAssertEqual(session.mainWheelDirections, [false])
        XCTAssertEqual(session.thumbwheelDirections, [true])

        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
    }

    func testHapticTestRequiresKnownEnabledIdleAndNondebouncingSettings() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let registration = try makeRegistration(unitID: "12345678")
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session)
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)
        let initialApply = await eventually { session.hardwareSettingsRequests.count == 1 }
        XCTAssertTrue(initialApply)

        let blockedStates: [(String, BoltHardwareSettingsStatus)] = [
            ("disabled", hapticStatus(support: .supported, enabled: false, engineStatus: 0)),
            ("unknown", hapticStatus(support: .unknown, enabled: true, engineStatus: 0)),
            ("engine busy", hapticStatus(support: .supported, enabled: true, engineStatus: 1)),
            ("settings apply busy", hapticStatus(support: .supported, enabled: true, engineStatus: 0, isApplying: true))
        ]

        for (label, status) in blockedStates {
            session.emitStatus(hardwareSettings: status)
            let visible = await eventually { model.mouseHardwareStatus == status }
            XCTAssertTrue(visible, label)
            model.testMouseHaptics()
            await drain()
            XCTAssertTrue(session.hapticWaveforms.isEmpty, label)
        }

        model.setMouseHardwarePreference(\.dpi, Optional(UInt16(1200)))
        let idleHaptics = hapticStatus(support: .supported, enabled: true, engineStatus: 0, waveform: 7)
        session.emitStatus(hardwareSettings: idleHaptics)
        let idleStatusVisible = await eventually { model.mouseHardwareStatus == idleHaptics }
        XCTAssertTrue(idleStatusVisible)
        model.testMouseHaptics()
        await drain()
        XCTAssertTrue(session.hapticWaveforms.isEmpty)

        let debouncedPreferenceApplied = await eventually { session.hardwareSettingsRequests.count == 2 }
        XCTAssertTrue(debouncedPreferenceApplied)
        session.emitStatus(hardwareSettings: idleHaptics)
        let readyAgain = await eventually { model.mouseHardwareStatus == idleHaptics }
        XCTAssertTrue(readyAgain)
        model.testMouseHaptics()
        let hapticTestPlayed = await eventually { session.hapticWaveforms == [7] }
        XCTAssertTrue(hapticTestPlayed)

        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
    }

    func testOptionalControlsRemainNativeUntilAssignedAndNativeClearingRemovesCapture() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let registration = try makeRegistration(unitID: "12345678")
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session, sender: inputSender())
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)

        let initialEnable = await eventually { session.enabledControlRequests.count == 1 && model.isBindingsEnabled }
        XCTAssertTrue(initialEnable)
        XCTAssertEqual(model.bindingMode(for: .middle), .native)
        XCTAssertEqual(model.bindingMode(for: .wheelMode), .native)
        XCTAssertEqual(model.bindingMode(for: .thumbRest), .native)
        XCTAssertEqual(session.enabledControlRequests, [[.back, .forward]])

        var configuration = model.document.draft
        configuration.devices[0].defaults[MouseControl.middle.rawValue] = .key(KeyboardShortcut(keyCode: 12))
        model.updateDraft(configuration)
        XCTAssertFalse(model.isBindingsEnabled)

        let middleCaptured = await eventually {
            session.enabledControlRequests.count == 2 && model.isBindingsEnabled
        }
        XCTAssertTrue(middleCaptured)
        XCTAssertEqual(session.disableCount, 1)
        XCTAssertEqual(session.enabledControlRequests.last, [.back, .forward, .middle])

        model.setBindingMode(.native, for: .middle)
        XCTAssertFalse(model.isBindingsEnabled)
        let middleReleased = await eventually {
            session.enabledControlRequests.count == 3 && model.isBindingsEnabled
        }
        XCTAssertTrue(middleReleased)
        XCTAssertEqual(session.disableCount, 2)
        XCTAssertEqual(session.enabledControlRequests.last, [.back, .forward])
        XCTAssertNil(model.document.draft.mouse?.configuredBinding(for: .middle, application: nil))

        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
    }

    func testApplicationOverrideOnlyOptionalControlReturnsToNativeWhenFrontmostChanges() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let applicationID = "com.example.synthetic-editor"
        let frontmost = MutableFrontmostApplication(applicationID)
        let registration = try makeRegistration(
            unitID: "12345678",
            applicationBindings: [applicationID: [.middle: .key(KeyboardShortcut(keyCode: 12))]]
        )
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(
            url: url,
            registrations: [registration],
            session: session,
            sender: inputSender(),
            frontmostApplication: { frontmost.bundleIdentifier }
        )
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)

        let appOverrideCaptured = await eventually {
            session.enabledControlRequests.count == 1 && model.isBindingsEnabled
        }
        XCTAssertTrue(appOverrideCaptured)
        XCTAssertEqual(session.enabledControlRequests[0], [.back, .forward, .middle])
        XCTAssertNil(model.document.draft.mouse?.configuredBinding(for: .middle, application: nil))

        frontmost.bundleIdentifier = "com.example.synthetic-native"
        model.foregroundMouseApplicationChanged()
        XCTAssertFalse(model.isBindingsEnabled)
        let overrideReleased = await eventually {
            session.enabledControlRequests.count == 2 && model.isBindingsEnabled
        }
        XCTAssertTrue(overrideReleased)
        XCTAssertEqual(session.disableCount, 1)
        XCTAssertEqual(session.enabledControlRequests.last, [.back, .forward])

        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
    }

    func testUnsupportedOptionalControlIsNeverIncludedInRequestedCaptureSet() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let registration = try makeRegistration(
            unitID: "12345678",
            defaultBindings: [.middle: .key(KeyboardShortcut(keyCode: 12))]
        )
        let session = MouseHardwareSettingsSession(
            association: try XCTUnwrap(registration.logitechAssociation),
            availableControls: [.back, .forward]
        )
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session, sender: inputSender())
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)

        let enabled = await eventually { session.enabledControlRequests.count == 1 && model.isBindingsEnabled }
        XCTAssertTrue(enabled)
        XCTAssertEqual(session.enabledControlRequests, [[.back, .forward]])
        XCTAssertFalse(session.enabledControlRequests[0].contains(.middle))

        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
    }

    func testLargeForceRangeLayoutStaysResponsive() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let registration = try makeRegistration(unitID: "12345678")
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session)
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)
        let initialApply = await eventually { session.hardwareSettingsRequests.count == 1 }
        XCTAssertTrue(initialApply)

        let operationsBeforeLayout = session.operationCounts
        let ranges: [(String, UInt16)] = [("reference", 100), ("large", 4_095), ("maximum", UInt16.max)]
        for (label, maximum) in ranges {
            var status = BoltHardwareSettingsStatus()
            status.smartShift.support = .unsupported
            status.dpi.support = .unsupported
            status.pointerSpeed.support = .unsupported
            status.haptics.support = .unsupported
            status.forceButton.support = .supported
            status.forceButton.minimum = 0
            status.forceButton.maximum = maximum
            status.forceButton.threshold = maximum / 2
            session.emitStatus(phase: model.boltStatus.phase, hardwareSettings: status)
            let statusVisible = await eventually { model.mouseHardwareStatus == status }
            XCTAssertTrue(statusVisible)

            let initialLayoutStart = DispatchTime.now().uptimeNanoseconds
            let hostingView = NSHostingView(rootView: MouseHardwareSettingsView().environmentObject(model))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: 1400)),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.setContentSize(NSSize(width: 380, height: 1400))
            hostingView.layoutSubtreeIfNeeded()
            let initialLayoutSeconds = Double(DispatchTime.now().uptimeNanoseconds - initialLayoutStart) / 1_000_000_000

            var widthChangeSeconds = [Double]()
            for width in [720.0, 380.0] {
                let layoutStart = DispatchTime.now().uptimeNanoseconds
                window.setContentSize(NSSize(width: width, height: 1400))
                hostingView.layoutSubtreeIfNeeded()
                widthChangeSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - layoutStart) / 1_000_000_000)
            }

            print("[layout-metric] range=0...\(maximum) initial=\(initialLayoutSeconds)s widthChanges=\(widthChangeSeconds)s")
            if label != "reference" {
                XCTAssertLessThan(initialLayoutSeconds, 3.0, "Initial layout for force range 0...\(maximum) exceeded 3 seconds.")
                for elapsed in widthChangeSeconds {
                    XCTAssertLessThan(elapsed, 3.0, "Width-change layout for force range 0...\(maximum) exceeded 3 seconds.")
                }
            }

            XCTAssertFalse(window.isVisible, "Offscreen layout fixture must remain hidden.")
            XCTAssertFalse(window.isKeyWindow, "Offscreen layout fixture must remain non-key.")
            window.contentView = nil
            window.close()
        }

        XCTAssertEqual(session.operationCounts, operationsBeforeLayout)
        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
    }

    func testHardwareSettingsViewCapturesSupportedControlsAtNarrowAndWideWidthsWithoutOperations() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let registration = try makeRegistration(unitID: "12345678")
        let session = MouseHardwareSettingsSession(association: try XCTUnwrap(registration.logitechAssociation))
        let (model, _) = try await makeModel(url: url, registrations: [registration], session: session, sender: inputSender())
        let connected = await connect(model, ownerID: registration.id)
        XCTAssertTrue(connected)
        let initialApply = await eventually { session.hardwareSettingsRequests.count == 1 }
        XCTAssertTrue(initialApply)

        let settings = supportedHardwareSettings()
        session.emitStatus(phase: model.boltStatus.phase, hardwareSettings: settings)
        let supportedStatusVisible = await eventually { model.mouseHardwareStatus == settings }
        XCTAssertTrue(supportedStatusVisible)

        let operationsBeforeRender = session.operationCounts
        let artifacts = URL(fileURLWithPath: "/Volumes/Data/tmp/hidhogg-mouse-hardware-settings-offscreen", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        try await capture(
            AnyView(MouseHardwareSettingsView().environmentObject(model)),
            named: "mouse-hardware-settings-380",
            size: NSSize(width: 380, height: 1400),
            in: artifacts
        )
        try await capture(
            AnyView(MouseHardwareSettingsView().environmentObject(model)),
            named: "mouse-hardware-settings-720",
            size: NSSize(width: 720, height: 1400),
            in: artifacts
        )

        XCTAssertEqual(session.operationCounts, operationsBeforeRender)

        model.disconnect()
        _ = await eventually { session.stopCount == 1 }
    }

    private func makeModel(
        url: URL,
        registrations: [RegisteredDevice],
        preferredMouseID: UUID? = nil,
        session: MouseHardwareSettingsSession,
        sender: ShortcutSender? = nil,
        frontmostApplication: @escaping @MainActor () -> String? = { nil }
    ) async throws -> (AppModel, ConfigurationStore) {
        let store = ConfigurationStore(url: url)
        let workspace = WorkspaceConfiguration(
            connectOnLaunch: false,
            devices: registrations,
            preferredMouseID: preferredMouseID ?? registrations[0].id
        )
        _ = try await store.save(workspace, expecting: .missing)
        let model = AppModel(
            configurationURL: url,
            store: store,
            bolt: session,
            sender: sender ?? ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in }),
            loadImmediately: true,
            observeSleep: false,
            observeFrontmostMouseApplication: false,
            frontmostApplication: frontmostApplication
        )
        return (model, store)
    }

    private func makeRegistration(
        unitID: String,
        hardwarePreferences: MouseHardwarePreferences? = nil,
        restorePreviousSettingsOnDisconnect: Bool = false,
        defaultBindings: [MouseControl: ControlBinding] = [:],
        applicationBindings: [String: [MouseControl: ControlBinding]] = [:]
    ) throws -> RegisteredDevice {
        var registration = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster4))
        registration.logitechAssociation = LogitechAssociation(
            identity: LogitechIdentity(unitID: unitID, modelID: "123456789abc"),
            preferredConnection: .bolt
        )
        guard case .mouse(var bindings) = registration.configuration else {
            XCTFail("Expected a mouse registration.")
            return registration
        }
        bindings.hardwarePreferences = hardwarePreferences
        bindings.restorePreviousSettingsOnDisconnect = restorePreviousSettingsOnDisconnect
        for (control, binding) in defaultBindings {
            bindings.defaults[control.rawValue] = binding
        }
        for (applicationID, overrides) in applicationBindings {
            bindings.applications[applicationID] = Dictionary(uniqueKeysWithValues: overrides.map {
                ($0.key.rawValue, $0.value)
            })
        }
        registration.configuration = .mouse(bindings)
        return registration
    }

    private func inputSender() -> ShortcutSender {
        ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in })
    }

    private func connect(_ model: AppModel, ownerID: UUID) async -> Bool {
        let loaded = await eventually { !model.isLoading && model.selectedMouseID == ownerID }
        guard loaded else { return false }
        model.connect()
        return await eventually {
            model.presentedMouseOwnerID == ownerID && [.ready, .enabled].contains(model.selectedMouseStatus.phase)
        }
    }

    private func hapticStatus(
        support: BoltFeatureSupport,
        enabled: Bool,
        engineStatus: UInt8,
        waveform: UInt8 = 1,
        isApplying: Bool = false
    ) -> BoltHardwareSettingsStatus {
        var status = BoltHardwareSettingsStatus()
        status.isApplying = isApplying
        status.haptics.support = support
        status.haptics.enabled = enabled
        status.haptics.rawEngineStatus = engineStatus
        status.haptics.supportedWaveforms = [waveform]
        return status
    }

    private func supportedHardwareSettings() -> BoltHardwareSettingsStatus {
        var status = BoltHardwareSettingsStatus()
        status.smartShift.support = .supported
        status.smartShift.mode = .automatic
        status.smartShift.threshold = 10
        status.smartShift.torque = 4
        status.smartShift.supportsTorque = true
        status.smartShift.maximumTorque = 8
        status.dpi.support = .supported
        status.dpi.canWrite = true
        status.dpi.current = 800
        status.dpi.values = [400, 800, 1600, 3200]
        status.pointerSpeed.support = .supported
        status.pointerSpeed.current = 1
        status.haptics.support = .supported
        status.haptics.enabled = true
        status.haptics.intensity = 50
        status.haptics.intensityStep = 10
        status.haptics.supportedWaveforms = [0, 1]
        status.haptics.rawEngineStatus = 0
        status.forceButton.support = .supported
        status.forceButton.minimum = 1
        status.forceButton.maximum = 100
        status.forceButton.threshold = 50
        return status
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func capture(_ rootView: AnyView, named name: String, size: NSSize, in directory: URL) async throws {
        let hostingView = NSHostingView(rootView: rootView
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: size)

        for _ in 0..<10 {
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(window.isVisible, "Offscreen fixture \(name) must remain hidden.")
        XCTAssertFalse(window.isKeyWindow, "Offscreen fixture \(name) must remain non-key.")
        XCTAssertEqual(hostingView.bounds.width, size.width)
        XCTAssertEqual(hostingView.bounds.height, size.height)

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 100, "Fixture \(name) should contain rendered controls.")
        try png.write(to: directory.appendingPathComponent("\(name).png"))

        window.contentView = nil
        window.close()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}

private struct AppliedHardwareSettingsRequest: Equatable {
    let preferences: BoltHardwareSettingsPreferences
    let restorePreviousSettingsOnDisconnect: Bool
}

@MainActor
private final class MutableFrontmostApplication {
    var bundleIdentifier: String?

    init(_ bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
    }
}

private final class MouseHardwareSettingsSession: BindingSession, @unchecked Sendable {
    let requiresExplicitAssociation = true
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let candidate: LogitechEndpointCandidate
    private let availableControls: Set<MouseControl>
    private let lock = NSLock()
    private var generation: UInt64 = 1
    private var identity: LogitechIdentity?
    private var connection: LogitechConnection?
    private var hardwareSettings = BoltHardwareSettingsStatus()
    private var hardwareSettingsRequestValues = [AppliedHardwareSettingsRequest]()
    private var mainWheelDirectionValues = [Bool?]()
    private var thumbwheelDirectionValues = [Bool?]()
    private var hapticWaveformValues = [UInt8]()
    private var enabledControlRequestValues = [Set<MouseControl>]()
    private var disableCountValue = 0
    private var stopCountValue = 0
    private var refreshHardwareSettingsCountValue = 0
    private var isConnected = false

    init(association: LogitechAssociation, availableControls: Set<MouseControl> = Set(MouseControl.allCases)) {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        self.availableControls = availableControls
        candidate = LogitechEndpointCandidate(
            id: UUID(),
            connection: association.preferredConnection,
            model: .mxMaster4,
            identity: association.identity,
            information: .init()
        )
    }

    var hardwareSettingsRequests: [AppliedHardwareSettingsRequest] { lock.withLock { hardwareSettingsRequestValues } }
    var mainWheelDirections: [Bool?] { lock.withLock { mainWheelDirectionValues } }
    var thumbwheelDirections: [Bool?] { lock.withLock { thumbwheelDirectionValues } }
    var hapticWaveforms: [UInt8] { lock.withLock { hapticWaveformValues } }
    var enabledControlRequests: [Set<MouseControl>] { lock.withLock { enabledControlRequestValues } }
    var disableCount: Int { lock.withLock { disableCountValue } }
    var stopCount: Int { lock.withLock { stopCountValue } }
    var operationCounts: [Int] {
        lock.withLock {
            [hardwareSettingsRequestValues.count, mainWheelDirectionValues.count, thumbwheelDirectionValues.count,
             hapticWaveformValues.count, enabledControlRequestValues.count, disableCountValue,
             stopCountValue, refreshHardwareSettingsCountValue]
        }
    }

    func existingConnections() async throws -> [LogitechEndpointCandidate] { [candidate] }
    func discover() async {}

    func discover(target: LogitechConnectionTarget) async {
        lock.withLock {
            identity = target.association.identity
            connection = target.association.preferredConnection
            isConnected = true
        }
        emitStatus(phase: .discovering)
        emitStatus(phase: .ready)
    }

    func enable() async { await enable(controls: [.back, .forward]) }

    func enable(controls: Set<MouseControl>) async {
        lock.withLock { enabledControlRequestValues.append(controls) }
        emitStatus(phase: .enabled)
        try? await Task.sleep(for: .milliseconds(1))
    }

    func disable() async {
        lock.withLock { disableCountValue += 1 }
        emitStatus(phase: .ready)
        try? await Task.sleep(for: .milliseconds(1))
    }

    func stop() async {
        lock.withLock {
            if isConnected { stopCountValue += 1 }
            isConnected = false
        }
        emitStatus(phase: .idle)
    }

    func stopForRestart() async -> Bool {
        await stop()
        return true
    }

    func stopForRestart(restorePreviousSettingsOnDisconnect: Bool) async -> Bool {
        await stop()
        return true
    }

    func applyHardwareSettings(
        _ preferences: BoltHardwareSettingsPreferences,
        restorePreviousSettingsOnDisconnect: Bool
    ) async {
        lock.withLock {
            hardwareSettingsRequestValues.append(.init(
                preferences: preferences,
                restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect
            ))
        }
    }

    func refreshHardwareSettings() async {
        lock.withLock { refreshHardwareSettingsCountValue += 1 }
    }

    func playHapticTest(waveform: UInt8) async {
        lock.withLock { hapticWaveformValues.append(waveform) }
    }

    func applyWheelPreferences(
        inverted: Bool?,
        highResolution: Bool?,
        restorePreviousSettingsOnDisconnect: Bool,
        amount: Double?,
        scrollPostingAllowed: Bool
    ) async {
        lock.withLock { mainWheelDirectionValues.append(inverted) }
    }

    func applyThumbwheelPreferences(
        inverted: Bool?,
        amount: Double?,
        restorePreviousSettingsOnDisconnect: Bool,
        scrollPostingAllowed: Bool
    ) async {
        lock.withLock { thumbwheelDirectionValues.append(inverted) }
    }

    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        false
    }

    func withScrollAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        false
    }

    func withThumbwheelAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        false
    }

    func emitStatus(phase: BoltPhase = .ready, hardwareSettings updatedHardwareSettings: BoltHardwareSettingsStatus? = nil) {
        let status = lock.withLock { () -> BoltStatus in
            generation &+= 1
            if let updatedHardwareSettings { hardwareSettings = updatedHardwareSettings }
            return BoltStatus(
                phase: phase,
                message: "Synthetic MX4 session",
                availableControls: availableControls,
                generation: generation,
                cleanupUncertain: false,
                wheel: BoltWheelStatus(support: .supported, supportsInversion: true),
                thumbwheel: BoltThumbwheelStatus(support: .supported),
                deviceResponding: true,
                supportsManagement: true,
                model: .mxMaster4,
                connection: connection,
                verifiedIdentity: identity,
                hardwareSettings: hardwareSettings
            )
        }
        continuation.yield(.status(status))
    }
}
