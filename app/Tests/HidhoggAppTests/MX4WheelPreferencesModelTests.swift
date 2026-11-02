import AppKit
import SwiftUI
import XCTest
@testable import HidhoggApp
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions

@MainActor
final class MX4WheelPreferencesModelTests: XCTestCase {
    func testMX4AppliesAndSavesOnlyPhysicalMainWheelPreferences() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var registration = try makeMX4Registration(unitID: "12345678")
        let registrationID = registration.id
        registration.updateMouseConfiguration {
            $0.wheelInverted = false
            $0.wheelHighResolution = true
            $0.wheelScrollAmount = WheelScrollAmount.defaultSelection
            $0.thumbwheelInverted = true
            $0.thumbwheelScrollAmount = WheelScrollAmount.defaultSelection
            $0.restorePreviousSettingsOnDisconnect = true
            $0.defaults["back"] = .key(.init(keyCode: 12))
        }
        let workspace = WorkspaceConfiguration(
            connectOnLaunch: true,
            devices: [registration],
            preferredMouseID: registrationID
        )
        _ = try await store.save(workspace, expecting: .missing)

        let association = try XCTUnwrap(registration.logitechAssociation)
        let session = MX4WheelPreferencesSession(supportsInversion: true, association: association)
        let model = makeModel(url: url, store: store, session: session)
        let appliedSavedSettings = await eventually {
            model.presentedMouseOwnerID == registrationID && session.physicalRequests.count == 1
        }
        XCTAssertTrue(appliedSavedSettings)
        XCTAssertFalse(model.selectedMouseSupportsManagement)
        XCTAssertFalse(model.canEnableBindings)
        XCTAssertEqual(model.selectedMouseSettingsAvailability, .physicalMainWheel)
        XCTAssertTrue(model.selectedWheelInversionAvailable)
        XCTAssertEqual(model.mainWheelSettingsReadiness, "Direction and input resolution available")
        XCTAssertEqual(session.physicalRequests, [.init(inverted: false, highResolution: true, restore: true)])
        XCTAssertEqual(session.captureApplyCount, 0)
        XCTAssertEqual(session.thumbwheelApplyCount, 0)
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertEqual(session.syntheticAdmissionCount, 0)
        XCTAssertEqual(model.observedWheelDirection, "Standard")
        XCTAssertEqual(model.observedWheelResolution, "High")

        model.setWheelPreference(true)
        model.setWheelHighResolution(false)
        let appliedEditedSettings = await eventually { session.physicalRequests.count == 2 }
        XCTAssertTrue(appliedEditedSettings)
        XCTAssertEqual(session.physicalRequests.last, .init(inverted: true, highResolution: false, restore: true))
        XCTAssertEqual(model.observedWheelDirection, "Natural")
        XCTAssertEqual(model.observedWheelResolution, "Low")

        await model.save()
        let saved = try await store.load()
        let savedMouse = try XCTUnwrap(saved.workspace.configuration(forMouseID: registrationID).mouse)
        XCTAssertEqual(savedMouse.wheelInverted, true)
        XCTAssertEqual(savedMouse.wheelHighResolution, false)
        XCTAssertEqual(savedMouse.wheelScrollAmount, WheelScrollAmount.defaultSelection)
        XCTAssertEqual(savedMouse.thumbwheelInverted, true)
        XCTAssertEqual(savedMouse.thumbwheelScrollAmount, WheelScrollAmount.defaultSelection)
        XCTAssertEqual(savedMouse.defaults["back"], .key(.init(keyCode: 12)))

        model.disconnect()
        let stopped = await eventually { session.stopRestorePolicies == [true] }
        XCTAssertTrue(stopped)
        XCTAssertEqual(session.captureApplyCount, 0)
        XCTAssertEqual(session.thumbwheelApplyCount, 0)
        XCTAssertEqual(session.enableCount, 0)
    }

    func testUnsupportedInversionIsNotForwardedWhileResolutionStillApplies() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var registration = try makeMX4Registration(unitID: "87654321")
        let registrationID = registration.id
        registration.updateMouseConfiguration {
            $0.wheelInverted = true
            $0.wheelHighResolution = true
        }
        let workspace = WorkspaceConfiguration(
            connectOnLaunch: true,
            devices: [registration],
            preferredMouseID: registrationID
        )
        _ = try await store.save(workspace, expecting: .missing)

        let association = try XCTUnwrap(registration.logitechAssociation)
        let session = MX4WheelPreferencesSession(supportsInversion: false, association: association)
        let model = makeModel(url: url, store: store, session: session)
        let applied = await eventually {
            model.presentedMouseOwnerID == registrationID && session.physicalRequests.count == 1
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(model.selectedMouseSettingsAvailability, .physicalMainWheel)
        XCTAssertFalse(model.selectedWheelInversionAvailable)
        XCTAssertEqual(model.mainWheelSettingsReadiness, "Input resolution available; direction inversion unsupported")
        XCTAssertEqual(session.physicalRequests, [.init(inverted: nil, highResolution: true, restore: false)])
        XCTAssertEqual(session.captureApplyCount, 0)
        XCTAssertEqual(session.thumbwheelApplyCount, 0)
        XCTAssertEqual(session.enableCount, 0)
        XCTAssertEqual(model.savedWheelPreference, true)
        XCTAssertEqual(model.observedWheelDirection, "Standard")
        XCTAssertEqual(model.observedWheelResolution, "High")
    }

    func testWheelEditsStayWithSelectedRegistrationWhileAnotherMX4OwnsLease() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var activeRegistration = try makeMX4Registration(unitID: "12345678")
        let activeID = activeRegistration.id
        activeRegistration.updateMouseConfiguration {
            $0.wheelInverted = true
            $0.wheelHighResolution = true
            $0.restorePreviousSettingsOnDisconnect = true
        }
        var selectedRegistration = try makeMX4Registration(unitID: "87654321")
        let selectedID = selectedRegistration.id
        selectedRegistration.updateMouseConfiguration {
            $0.wheelInverted = true
            $0.wheelHighResolution = true
        }
        let workspace = WorkspaceConfiguration(
            connectOnLaunch: true,
            devices: [activeRegistration, selectedRegistration],
            preferredMouseID: activeID
        )
        _ = try await store.save(workspace, expecting: .missing)

        let association = try XCTUnwrap(activeRegistration.logitechAssociation)
        let session = MX4WheelPreferencesSession(supportsInversion: true, association: association)
        let model = makeModel(url: url, store: store, session: session)
        let appliedActiveSettings = await eventually {
            model.presentedMouseOwnerID == activeID && session.physicalRequests.count == 1
        }
        XCTAssertTrue(appliedActiveSettings)
        XCTAssertEqual(session.physicalRequests, [.init(inverted: true, highResolution: true, restore: true)])

        model.navigate(to: .mouse(selectedID))
        XCTAssertEqual(model.selectedMouseID, selectedID)
        model.setWheelPreference(false)
        model.setWheelHighResolution(false)
        await model.save()
        let saved = try await store.load()
        let savedActiveMouse = try XCTUnwrap(saved.workspace.configuration(forMouseID: activeID).mouse)
        let savedSelectedMouse = try XCTUnwrap(saved.workspace.configuration(forMouseID: selectedID).mouse)
        XCTAssertEqual(savedActiveMouse.wheelInverted, true)
        XCTAssertEqual(savedActiveMouse.wheelHighResolution, true)
        XCTAssertEqual(savedSelectedMouse.wheelInverted, false)
        XCTAssertEqual(savedSelectedMouse.wheelHighResolution, false)
        XCTAssertEqual(session.physicalRequests.count, 1)

        model.disconnect()
        let stopped = await eventually { session.stopRestorePolicies == [true] }
        XCTAssertTrue(stopped)
    }

    func testMX4WheelOnlyMainPanelAndInspectorRenderOffscreen() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var registration = try makeMX4Registration(unitID: "12345678")
        let registrationID = registration.id
        registration.updateMouseConfiguration {
            $0.wheelInverted = true
            $0.wheelHighResolution = true
            $0.wheelScrollAmount = WheelScrollAmount.defaultSelection
            $0.thumbwheelInverted = true
            $0.thumbwheelScrollAmount = WheelScrollAmount.defaultSelection
            $0.defaults["back"] = .key(.init(keyCode: 12))
        }
        let workspace = WorkspaceConfiguration(
            connectOnLaunch: true,
            devices: [registration],
            preferredMouseID: registrationID
        )
        _ = try await store.save(workspace, expecting: .missing)

        let association = try XCTUnwrap(registration.logitechAssociation)
        let session = MX4WheelPreferencesSession(supportsInversion: true, association: association)
        let model = makeModel(url: url, store: store, session: session)
        let ready = await eventually {
            model.presentedMouseOwnerID == registrationID && session.physicalRequests.count == 1
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.selectedMouseSettingsAvailability, .physicalMainWheel)

        let physicalRequestsBeforeRender = session.physicalRequests
        let captureApplyCountBeforeRender = session.captureApplyCount
        let thumbwheelApplyCountBeforeRender = session.thumbwheelApplyCount
        let enableCountBeforeRender = session.enableCount
        let syntheticAdmissionCountBeforeRender = session.syntheticAdmissionCount
        let artifacts = URL(fileURLWithPath: "/Volumes/Data/tmp/hidhogg-mx4-settings-offscreen", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)

        try await capture(
            AnyView(DevicesView(isInspectorPresented: .constant(true)).environmentObject(model)),
            named: "mx4-main-panel",
            size: NSSize(width: 760, height: 760),
            in: artifacts
        )
        try await capture(
            AnyView(DeviceInspectorView().environmentObject(model)),
            named: "mx4-wheel-inspector",
            size: NSSize(width: 380, height: 760),
            in: artifacts
        )

        XCTAssertEqual(session.physicalRequests, physicalRequestsBeforeRender)
        XCTAssertEqual(session.captureApplyCount, captureApplyCountBeforeRender)
        XCTAssertEqual(session.thumbwheelApplyCount, thumbwheelApplyCountBeforeRender)
        XCTAssertEqual(session.enableCount, enableCountBeforeRender)
        XCTAssertEqual(session.syntheticAdmissionCount, syntheticAdmissionCountBeforeRender)

        model.disconnect()
        let stopped = await eventually { session.stopRestorePolicies == [false] }
        XCTAssertTrue(stopped)
    }

    private func makeModel(url: URL, store: ConfigurationStore, session: MX4WheelPreferencesSession) -> AppModel {
        AppModel(
            configurationURL: url,
            store: store,
            bolt: session,
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in }),
            loadImmediately: true,
            observeSleep: false,
            frontmostApplication: { nil }
        )
    }

    private func makeMX4Registration(unitID: String) throws -> RegisteredDevice {
        var registration = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster4))
        registration.logitechAssociation = LogitechAssociation(
            identity: LogitechIdentity(unitID: unitID, modelID: "123456789abc"),
            preferredConnection: .bolt
        )
        return registration
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
        XCTAssertGreaterThan(png.count, 100)
        try png.write(to: directory.appendingPathComponent("\(name).png"))

        window.contentView = nil
        window.close()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }
}

private struct MX4PhysicalWheelRequest: Equatable {
    let inverted: Bool?
    let highResolution: Bool?
    let restore: Bool
}

private final class MX4WheelPreferencesSession: BindingSession, @unchecked Sendable {
    let requiresExplicitAssociation = true
    let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let candidate: LogitechEndpointCandidate
    private let supportsInversion: Bool
    private let lock = NSLock()
    private var generation: UInt64 = 1
    private var sessionIdentity: LogitechIdentity?
    private var sessionConnection: LogitechConnection?
    private var observedInverted = false
    private var observedHighResolution = false
    private var physicalRequestValues = [MX4PhysicalWheelRequest]()
    private var stopRestoreValues = [Bool]()
    private var captureApplyValue = 0
    private var thumbwheelApplyValue = 0
    private var enableValue = 0
    private var syntheticAdmissionValue = 0

    init(supportsInversion: Bool, association: LogitechAssociation) {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        self.supportsInversion = supportsInversion
        candidate = LogitechEndpointCandidate(
            id: UUID(),
            connection: association.preferredConnection,
            model: .mxMaster4,
            identity: association.identity,
            information: .init()
        )
    }

    var physicalRequests: [MX4PhysicalWheelRequest] { lock.withLock { physicalRequestValues } }
    var stopRestorePolicies: [Bool] { lock.withLock { stopRestoreValues } }
    var captureApplyCount: Int { lock.withLock { captureApplyValue } }
    var thumbwheelApplyCount: Int { lock.withLock { thumbwheelApplyValue } }
    var enableCount: Int { lock.withLock { enableValue } }
    var syntheticAdmissionCount: Int { lock.withLock { syntheticAdmissionValue } }

    func existingConnections() async throws -> [LogitechEndpointCandidate] { [candidate] }
    func discover() async {}

    func discover(target: LogitechConnectionTarget) async {
        lock.withLock {
            sessionIdentity = target.association.identity
            sessionConnection = target.association.preferredConnection
        }
        emitStatus(phase: .ready)
    }

    func enable() async { lock.withLock { enableValue += 1 } }
    func disable() async {}
    func stop() async { emitStatus(phase: .idle) }

    func stopForRestart() async -> Bool {
        await stop()
        return true
    }

    func stop(restorePreviousSettingsOnDisconnect: Bool) async {
        lock.withLock { stopRestoreValues.append(restorePreviousSettingsOnDisconnect) }
        await stop()
    }

    func stopForRestart(restorePreviousSettingsOnDisconnect: Bool) async -> Bool {
        lock.withLock { stopRestoreValues.append(restorePreviousSettingsOnDisconnect) }
        await stop()
        return true
    }

    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        let result = lock.withLock { () -> (Bool, Bool) in
            physicalRequestValues.append(.init(
                inverted: inverted,
                highResolution: highResolution,
                restore: restorePreviousSettingsOnDisconnect
            ))
            if let inverted { observedInverted = inverted }
            if let highResolution { observedHighResolution = highResolution }
            return (observedInverted, observedHighResolution)
        }
        emitStatus(
            phase: .ready,
            observedInverted: result.0,
            observedHighResolution: result.1,
            isOwned: true
        )
    }

    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                               amount: Double?, scrollPostingAllowed: Bool) async {
        lock.withLock { captureApplyValue += 1 }
    }

    func applyThumbwheelPreferences(inverted: Bool?, amount: Double?, restorePreviousSettingsOnDisconnect: Bool,
                                    scrollPostingAllowed: Bool) async {
        lock.withLock { thumbwheelApplyValue += 1 }
    }

    func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        lock.withLock { syntheticAdmissionValue += 1 }
        return false
    }

    func withScrollAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        lock.withLock { syntheticAdmissionValue += 1 }
        return false
    }

    func withThumbwheelAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        lock.withLock { syntheticAdmissionValue += 1 }
        return false
    }

    private func emitStatus(
        phase: BoltPhase,
        identity: LogitechIdentity? = nil,
        connection: LogitechConnection? = nil,
        observedInverted: Bool? = nil,
        observedHighResolution: Bool? = nil,
        isOwned: Bool = false
    ) {
        let state = lock.withLock { () -> (UInt64, LogitechIdentity?, LogitechConnection?) in
            generation += 1
            return (generation, sessionIdentity, sessionConnection)
        }
        continuation.yield(.status(BoltStatus(
            phase: phase,
            message: "Synthetic MX4 session",
            availableControls: [],
            generation: state.0,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(
                support: phase == .ready ? .supported : .unknown,
                observedInverted: observedInverted ?? lock.withLock { self.observedInverted },
                isOwned: isOwned,
                observedHighResolution: observedHighResolution ?? lock.withLock { self.observedHighResolution },
                supportsInversion: supportsInversion
            ),
            supportsManagement: false,
            model: .mxMaster4,
            connection: connection ?? state.2,
            verifiedIdentity: identity ?? state.1
        )))
    }
}

private extension RegisteredDevice {
    mutating func updateMouseConfiguration(_ update: (inout DeviceBindings) -> Void) {
        guard case .mouse(var configuration) = self.configuration else { return }
        update(&configuration)
        self.configuration = .mouse(configuration)
    }
}
