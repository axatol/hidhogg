import AppKit
import Foundation
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import SwiftUI
import XCTest
@testable import HidhoggApp

@MainActor
final class PairingCompletionLayoutReproTests: XCTestCase {
    func testBoltChallengeVerificationAndCompletionRemainLayouterSafe() async throws {
        for destination in [SetupDestination.newRegistration, .reassociate] {
            for _ in 0..<3 {
                try await exerciseCompletion(for: destination)
            }
        }
    }

    func testPostConnectMX4CapabilitiesRemainLayouterSafeAtNarrowAndWideWidths() async throws {
        for destination in [SetupDestination.newRegistration, .reassociate] {
            try await exercisePostConnectCapabilities(for: destination)
        }
    }

    private func exercisePostConnectCapabilities(for destination: SetupDestination) async throws {
        let fixture = try await makeCapabilityFixture(for: destination)
        defer { fixture.remove() }

        let restartCoordinator = RestartCoordinator(
            cleanup: { true },
            launch: {},
            terminate: {},
            reportError: { _ in }
        )
        let diagnostics = DiagnosticsStore(model: fixture.model, persist: { _, _ in })
        let loginItemController = LoginItemController(service: LayoutReproLoginItemService())
        let presentationCoordinator = WorkspacePresentationCoordinator(setActivationPolicy: { _ in true })
        let rootView = WorkspaceView(presentationCoordinator: presentationCoordinator)
            .environmentObject(fixture.model)
            .environmentObject(diagnostics)
            .environmentObject(loginItemController)
            .environmentObject(restartCoordinator)
            .frame(minWidth: 820, minHeight: 560)
        let host = HiddenWorkspaceLayoutHost(rootView: rootView)
        defer { host.close() }
        let sizes = [NSSize(width: 820, height: 560), NSSize(width: 1_280, height: 800)]

        fixture.model.presentLogitechSetup(destination: fixture.setupDestination)
        try await waitUntil("capability fixture setup inventory") { !fixture.model.isLogitechSetupLoading }
        host.driveLayout(at: sizes, rounds: 3)

        fixture.model.pairLogitechSetup()
        try await waitUntil("capability fixture receiver selection") {
            fixture.model.boltPairingStatus?.phase == .awaitingSelection
        }
        fixture.model.selectBoltPairingCandidate(fixture.pairing.candidate.id)
        try await waitUntil("capability fixture click challenge") {
            fixture.model.boltPairingStatus?.phase == .authenticating &&
                fixture.model.boltPairingStatus?.challenge != nil
        }
        fixture.pairing.emitCompletedChallenge()
        try await waitUntil("capability fixture completed challenge") {
            fixture.model.boltPairingStatus?.challenge?.entryComplete == true
        }
        fixture.pairing.emitVerifying()
        try await waitUntil("capability fixture verification") { fixture.model.boltPairingStatus?.phase == .verifying }
        fixture.pairing.pauseNextClose()
        fixture.pairing.emitVerified()
        try await waitUntil("capability fixture verified state") {
            fixture.model.boltPairingStatus?.phase == .verified && fixture.pairing.closeIsPending
        }
        host.driveLayout(at: sizes, rounds: 3)
        fixture.pairing.resumeClose()

        try await waitUntil("MX4 route reaches its initial ready status") {
            guard let id = fixture.model.selectedMouseID else { return false }
            return fixture.model.navigation.current.route == .mouse(id) &&
                fixture.model.presentedMouseOwnerID == id &&
                fixture.model.selectedMouseStatus.phase == .ready
        }
        try await waitForInitialMX4Reconciliation(fixture)
        XCTAssertTrue(host.containsInspector)
        host.driveLayout(at: sizes, rounds: 3)

        let supportedSettings = fullRangeMX4HardwareSettings()
        let controls = Set(MouseControl.allCases)
        let capabilityGeneration = fixture.binding.emitReadySnapshot(
            availableControls: controls,
            hardwareSettings: supportedSettings,
            deviceInformation: .init(batteryState: .loading, firmwareState: .loading, isRefreshing: true)
        )
        try await waitUntil("MX4 hardware capability snapshot") {
            fixture.model.selectedMouseStatus.generation == capabilityGeneration &&
                fixture.model.selectedMouseStatus.availableControls == controls &&
                fixture.model.selectedMouseStatus.hardwareSettings == supportedSettings &&
                hasSettledInitialMX4Reconciliation(fixture)
        }
        let operationsBeforeCapabilityLayout = fixture.binding.operationCounts
        host.driveLayout(at: sizes, rounds: 4)
        XCTAssertEqual(fixture.binding.operationCounts, operationsBeforeCapabilityLayout)
        XCTAssertTrue(host.containsInspector)

        let deviceInformation = fullMX4DeviceInformation()
        let informationGeneration = fixture.binding.emitReadySnapshot(
            availableControls: controls,
            hardwareSettings: supportedSettings,
            deviceInformation: deviceInformation
        )
        try await waitUntil("MX4 battery and firmware snapshot") {
            fixture.model.selectedMouseStatus.generation == informationGeneration &&
                fixture.model.selectedMouseStatus.deviceInformation == deviceInformation &&
                hasSettledInitialMX4Reconciliation(fixture)
        }
        let operationsBeforeInformationLayout = fixture.binding.operationCounts
        host.driveLayout(at: sizes, rounds: 4)
        XCTAssertEqual(fixture.binding.operationCounts, operationsBeforeInformationLayout)

        XCTAssertEqual(fixture.model.selectedMouseStatus.hardwareSettings.forceButton.minimum, 0)
        XCTAssertEqual(fixture.model.selectedMouseStatus.hardwareSettings.forceButton.maximum, UInt16.max)
        XCTAssertEqual(fixture.model.selectedMouseStatus.deviceInformation.batteryState, .available)
        XCTAssertEqual(fixture.model.selectedMouseStatus.deviceInformation.firmware.count, 3)
        XCTAssertFalse(host.window.isVisible)
        XCTAssertFalse(host.window.isKeyWindow)

        let registrationID = try XCTUnwrap(fixture.model.selectedMouseID)
        let registration = try XCTUnwrap(fixture.model.registration(id: registrationID))
        let saved = try await fixture.store.load()
        XCTAssertEqual(saved.workspace.devices.first { $0.id == registrationID }, registration)
        XCTAssertEqual(registration.mouseModel, .mxMaster4)
        XCTAssertEqual(registration.logitechAssociation?.identity, fixture.pairing.verified.identity)
        XCTAssertEqual(fixture.outputProbe.count, 0)
        XCTAssertEqual(fixture.binding.inputOutputCount, 0)

        let priorStopCount = fixture.binding.stopCount
        fixture.model.disconnect()
        try await waitUntil("capability fake stopped after disconnect") {
            fixture.binding.stopCount > priorStopCount
        }
    }

    private func exerciseCompletion(for destination: SetupDestination) async throws {
        let fixture = try await makeFixture(for: destination)
        defer { fixture.remove() }

        let restartCoordinator = RestartCoordinator(
            cleanup: { true },
            launch: {},
            terminate: {},
            reportError: { _ in }
        )
        let diagnostics = DiagnosticsStore(model: fixture.model, persist: { _, _ in })
        let loginItemController = LoginItemController(service: LayoutReproLoginItemService())
        let presentationCoordinator = WorkspacePresentationCoordinator(setActivationPolicy: { _ in true })
        let rootView = WorkspaceView(presentationCoordinator: presentationCoordinator)
            .environmentObject(fixture.model)
            .environmentObject(diagnostics)
            .environmentObject(loginItemController)
            .environmentObject(restartCoordinator)
            .frame(minWidth: 820, minHeight: 560)
        let host = HiddenWorkspaceLayoutHost(rootView: rootView)
        defer { host.close() }

        fixture.model.presentLogitechSetup(destination: fixture.setupDestination)
        try await waitUntil("setup inventory") { !fixture.model.isLogitechSetupLoading }
        host.driveLayout()
        XCTAssertFalse(host.window.isVisible)
        XCTAssertFalse(host.window.isKeyWindow)
        XCTAssertFalse(host.containsInspector)

        fixture.model.pairLogitechSetup()
        try await waitUntil("receiver candidate selection") {
            fixture.model.boltPairingStatus?.phase == .awaitingSelection
        }
        host.driveLayout()

        fixture.model.selectBoltPairingCandidate(fixture.pairing.candidate.id)
        try await waitUntil("initial challenge grid") {
            fixture.model.boltPairingStatus?.phase == .authenticating &&
                fixture.model.boltPairingStatus?.challenge?.entryComplete == false &&
                fixture.pairing.selectionCount == 1
        }
        host.driveLayout()

        fixture.pairing.emitCompletedChallenge()
        try await waitUntil("completed click challenge") {
            fixture.model.boltPairingStatus?.phase == .authenticating &&
                fixture.model.boltPairingStatus?.challenge?.entryComplete == true
        }
        host.driveLayout()
        XCTAssertNil(fixture.model.workspace.devices.first?.logitechAssociation)
        if destination == .newRegistration {
            XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        }

        fixture.pairing.emitVerifying()
        try await waitUntil("identity verification") { fixture.model.boltPairingStatus?.phase == .verifying }
        host.driveLayout()

        fixture.pairing.pauseNextClose()
        fixture.pairing.emitVerified()
        try await waitUntil("verified status with pairing close held") {
            fixture.model.boltPairingStatus?.phase == .verified && fixture.pairing.closeIsPending
        }
        host.driveLayout()
        XCTAssertNil(fixture.model.workspace.devices.first?.logitechAssociation)
        if destination == .newRegistration {
            XCTAssertTrue(fixture.model.registeredDevices.isEmpty)
        }

        fixture.pairing.resumeClose()
        try await waitUntil("saved MX4 activation and inspector route") {
            guard let id = fixture.model.selectedMouseID else { return false }
            return fixture.model.navigation.current.route == .mouse(id) &&
                fixture.binding.targets.count == 1 &&
                fixture.model.presentedMouseOwnerID == id &&
                fixture.model.selectedMouseStatus.phase == .ready
        }
        host.driveLayout()

        let registrationID = try XCTUnwrap(fixture.model.selectedMouseID)
        let registration = try XCTUnwrap(fixture.model.registration(id: registrationID))
        XCTAssertEqual(registration.mouseModel, .mxMaster4)
        XCTAssertEqual(registration.logitechAssociation?.identity, fixture.pairing.verified.identity)
        XCTAssertTrue(host.containsInspector, "The real WorkspaceView should render the MX4 device inspector after completion.")
        XCTAssertFalse(host.window.isVisible)
        XCTAssertFalse(host.window.isKeyWindow)

        let saved = try await fixture.store.load()
        XCTAssertEqual(saved.workspace.devices.first { $0.id == registrationID }, registration)
        XCTAssertEqual(fixture.binding.writeCount, 0, "The offline pairing UI reproduction must not write device settings.")
        XCTAssertEqual(fixture.outputProbe.count, 0, "The offline pairing UI reproduction must not emit input.")

        let priorStopCount = fixture.binding.stopCount
        fixture.model.disconnect()
        try await waitUntil("fake binding stop after disconnect") {
            fixture.binding.stopCount > priorStopCount
        }
    }

    private func makeFixture(for destination: SetupDestination) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggPairingCompletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let candidate = LogitechEndpointCandidate(
            id: UUID(),
            connection: .bolt,
            model: .mxMaster4,
            identity: .init(unitID: "12345678", modelID: "123456789abc"),
            information: .init()
        )
        let binding = PairingBindingSession(candidates: [candidate])
        let pairing = LayoutReproBoltPairingSession()
        let store = ConfigurationStore(url: root.appendingPathComponent("config.toml"))
        var devices = [RegisteredDevice]()
        var setupDestination = LogitechSetupDestination.newRegistration

        if destination == .reassociate {
            let registration = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster4))
            devices = [registration]
            setupDestination = .reassociate(registration.id)
        }

        _ = try await store.save(
            WorkspaceConfiguration(connectOnLaunch: false, devices: devices),
            expecting: .missing
        )

        let outputProbe = LayoutReproOutputProbe()
        let sender = ShortcutSender(
            preflight: { false },
            request: { false },
            postPair: { _ in outputProbe.record() }
        )
        let model = AppModel(
            configurationURL: root.appendingPathComponent("config.toml"),
            store: store,
            bolt: binding,
            makeBoltPairingSession: { @Sendable in pairing },
            sender: sender,
            loadImmediately: true,
            observeSleep: false,
            frontmostApplication: { nil }
        )
        try await waitUntil("AppModel initial load") { !model.isLoading }
        return Fixture(
            root: root,
            store: store,
            model: model,
            binding: binding,
            pairing: pairing,
            outputProbe: outputProbe,
            setupDestination: setupDestination
        )
    }

    private func makeCapabilityFixture(for destination: SetupDestination) async throws -> CapabilityFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggPairingCapabilityRepro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let pairing = LayoutReproBoltPairingSession()
        let binding = LayoutReproBindingSession(candidates: [pairing.verified])
        let store = ConfigurationStore(url: root.appendingPathComponent("config.toml"))
        var devices = [RegisteredDevice]()
        var setupDestination = LogitechSetupDestination.newRegistration

        if destination == .reassociate {
            let registration = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster4))
            devices = [registration]
            setupDestination = .reassociate(registration.id)
        }

        _ = try await store.save(
            WorkspaceConfiguration(connectOnLaunch: false, devices: devices),
            expecting: .missing
        )

        let outputProbe = LayoutReproOutputProbe()
        let sender = ShortcutSender(
            preflight: { false },
            request: { false },
            postPair: { _ in outputProbe.record() }
        )
        let model = AppModel(
            configurationURL: root.appendingPathComponent("config.toml"),
            store: store,
            bolt: binding,
            makeBoltPairingSession: { @Sendable in pairing },
            sender: sender,
            loadImmediately: true,
            observeSleep: false,
            frontmostApplication: { nil }
        )
        try await waitUntil("capability AppModel initial load") { !model.isLoading }
        return CapabilityFixture(
            root: root,
            store: store,
            model: model,
            binding: binding,
            pairing: pairing,
            outputProbe: outputProbe,
            setupDestination: setupDestination
        )
    }

    private func fullRangeMX4HardwareSettings() -> BoltHardwareSettingsStatus {
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
        status.dpi.values = [400, 800, 1_600, 3_200]
        status.pointerSpeed.support = .supported
        status.pointerSpeed.current = 1
        status.haptics.support = .supported
        status.haptics.enabled = true
        status.haptics.intensity = 50
        status.haptics.intensityStep = 10
        status.haptics.supportedWaveforms = [0, 1]
        status.haptics.rawEngineStatus = 0
        status.forceButton.support = .supported
        status.forceButton.minimum = 0
        status.forceButton.maximum = UInt16.max
        status.forceButton.threshold = UInt16.max / 2
        return status
    }

    private func fullMX4DeviceInformation() -> BoltDeviceInformation {
        let observedAt = Date(timeIntervalSince1970: 1_798_000_000)
        let battery = BoltDeviceInformation.Battery(percentage: 74, charging: .discharging, observedAt: observedAt)
        let firmware = [
            BoltDeviceInformation.FirmwareEntity(type: 0, prefix: "MX4", rawVersion: 0x0102, rawBuild: 0x0304, flags: 1),
            BoltDeviceInformation.FirmwareEntity(type: 1, prefix: "BLD", rawVersion: 0x0101, rawBuild: 0x0203, flags: 0),
            BoltDeviceInformation.FirmwareEntity(type: 2, prefix: "", rawVersion: 0, rawBuild: 0, flags: 0, hardwareRevision: 2)
        ]
        return BoltDeviceInformation(
            batteryState: .available,
            firmwareState: .available,
            battery: battery,
            firmware: firmware,
            isRefreshing: false,
            featureVersions: [0x2111: 1]
        )
    }

    private func waitUntil(
        _ description: String,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        throw ReproWaitTimeout(description: description)
    }

    private func waitForInitialMX4Reconciliation(_ fixture: CapabilityFixture) async throws {
        try await waitUntil("initial MX4 hardware and scroll preference reconciliation") {
            hasSettledInitialMX4Reconciliation(fixture)
        }
    }

    private func hasSettledInitialMX4Reconciliation(_ fixture: CapabilityFixture) -> Bool {
        fixture.binding.hasAppliedInitialMX4Preferences &&
            !fixture.model.isWheelApplyInFlight &&
            !fixture.model.isThumbwheelApplyInFlight
    }

    private enum SetupDestination: Equatable {
        case newRegistration
        case reassociate
    }

    private struct Fixture {
        let root: URL
        let store: ConfigurationStore
        let model: AppModel
        let binding: PairingBindingSession
        let pairing: LayoutReproBoltPairingSession
        let outputProbe: LayoutReproOutputProbe
        let setupDestination: LogitechSetupDestination

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct CapabilityFixture {
        let root: URL
        let store: ConfigurationStore
        let model: AppModel
        let binding: LayoutReproBindingSession
        let pairing: LayoutReproBoltPairingSession
        let outputProbe: LayoutReproOutputProbe
        let setupDestination: LogitechSetupDestination

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private struct ReproWaitTimeout: LocalizedError {
    let description: String

    var errorDescription: String? { "Timed out waiting for \(description)." }
}

@MainActor
private final class HiddenWorkspaceLayoutHost<RootView: View> {
    let hostingView: NSHostingView<RootView>
    let window: NSWindow

    init(rootView: RootView) {
        NSApplication.shared.setActivationPolicy(.accessory)
        hostingView = NSHostingView(rootView: rootView)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: NSSize(width: 820, height: 560)),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
    }

    var containsInspector: Bool {
        allSubviews(in: hostingView).contains { $0 is WorkspaceInspectorInitialWidthView }
    }

    func driveLayout() {
        driveLayout(
            at: [
            NSSize(width: 820, height: 560),
            NSSize(width: 1_024, height: 700),
            NSSize(width: 1_280, height: 800),
            NSSize(width: 820, height: 560)
            ],
            rounds: 8
        )
    }

    func driveLayout(at sizes: [NSSize], rounds: Int) {
        for _ in 0..<rounds {
            for size in sizes {
                window.setContentSize(size)
                hostingView.frame = NSRect(origin: .zero, size: size)
                hostingView.needsLayout = true
                window.contentView?.layoutSubtreeIfNeeded()
                hostingView.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
            }
        }

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func close() {
        window.close()
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    private func allSubviews(in root: NSView) -> [NSView] {
        var result = [root]
        var cursor = 0
        while cursor < result.count {
            result.append(contentsOf: result[cursor].subviews)
            cursor += 1
        }
        return result
    }
}

private final class LayoutReproOutputProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events = 0

    var count: Int { lock.withLock { events } }

    func record() {
        lock.withLock { events += 1 }
    }
}

@MainActor
private final class LayoutReproLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus { .notRegistered }

    func register() async throws {}
    func unregister() async throws {}
    func openLoginItemsSettings() {}
}

private final class LayoutReproBindingSession: BindingSession, @unchecked Sendable {
    private enum Operation: Int, CaseIterable {
        case deviceInformationRefresh
        case hardwareSettingsApply
        case hardwareSettingsRefresh
        case hapticTest
        case buttonEnable
        case buttonDisable
        case wheelPreferencesApply
        case thumbwheelPreferencesApply
    }

    let requiresExplicitAssociation = true
    let events: AsyncStream<BoltEvent>

    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let candidates: [LogitechEndpointCandidate]
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var identity: LogitechIdentity?
    private var connection: LogitechConnection?
    private var isConnected = false
    private var stopCountValue = 0
    private var operationValues = Array(repeating: 0, count: Operation.allCases.count)

    init(candidates: [LogitechEndpointCandidate]) {
        self.candidates = candidates
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var stopCount: Int { lock.withLock { stopCountValue } }
    var operationCounts: [Int] { lock.withLock { operationValues } }
    var hasAppliedInitialMX4Preferences: Bool {
        lock.withLock {
            operationValues[Operation.hardwareSettingsApply.rawValue] >= 1 &&
                operationValues[Operation.wheelPreferencesApply.rawValue] >= 1 &&
                operationValues[Operation.thumbwheelPreferencesApply.rawValue] >= 1
        }
    }
    var inputOutputCount: Int { 0 }

    func existingConnections() async throws -> [LogitechEndpointCandidate] { candidates }

    func discover() async {}

    func discover(target: LogitechConnectionTarget) async {
        lock.withLock {
            identity = target.association.identity
            connection = target.association.preferredConnection
            isConnected = true
        }
        emitStatus(
            phase: .discovering,
            availableControls: [],
            hardwareSettings: .init(),
            deviceInformation: .init()
        )
        emitStatus(
            phase: .ready,
            availableControls: [],
            hardwareSettings: .init(),
            deviceInformation: .init(batteryState: .loading, firmwareState: .loading, isRefreshing: true)
        )
    }

    func refreshDeviceInformation() async {
        recordOperation(.deviceInformationRefresh)
    }

    func applyHardwareSettings(
        _ preferences: BoltHardwareSettingsPreferences,
        restorePreviousSettingsOnDisconnect: Bool
    ) async {
        recordOperation(.hardwareSettingsApply)
    }

    func refreshHardwareSettings() async {
        recordOperation(.hardwareSettingsRefresh)
    }

    func playHapticTest(waveform: UInt8) async {
        recordOperation(.hapticTest)
    }

    func enable() async {
        recordOperation(.buttonEnable)
    }

    func enable(controls: Set<MouseControl>) async {
        recordOperation(.buttonEnable)
    }

    func disable() async {
        recordOperation(.buttonDisable)
    }

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }

    func stop() async {
        lock.withLock { stopCountValue += 1 }
        emitStatus(
            phase: .idle,
            availableControls: [],
            hardwareSettings: .init(),
            deviceInformation: .init()
        )
        lock.withLock { isConnected = false }
    }

    func stopForRestart() async -> Bool {
        await stop()
        return true
    }

    func stopForRestart(restorePreviousSettingsOnDisconnect: Bool) async -> Bool {
        await stop()
        return true
    }

    func applyWheelPreference(_ inverted: Bool?) async {
        recordOperation(.wheelPreferencesApply)
    }

    func applyWheelPreference(_ inverted: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        recordOperation(.wheelPreferencesApply)
    }

    func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        recordOperation(.wheelPreferencesApply)
    }

    func applyWheelPreferences(
        inverted: Bool?,
        highResolution: Bool?,
        restorePreviousSettingsOnDisconnect: Bool,
        amount: Double?,
        scrollPostingAllowed: Bool
    ) async {
        recordOperation(.wheelPreferencesApply)
    }

    func applyThumbwheelPreferences(
        inverted: Bool?,
        amount: Double?,
        restorePreviousSettingsOnDisconnect: Bool,
        scrollPostingAllowed: Bool
    ) async {
        recordOperation(.thumbwheelPreferencesApply)
    }

    func emitReadySnapshot(
        availableControls: Set<MouseControl>,
        hardwareSettings: BoltHardwareSettingsStatus,
        deviceInformation: BoltDeviceInformation
    ) -> UInt64 {
        emitStatus(
            phase: .ready,
            availableControls: availableControls,
            hardwareSettings: hardwareSettings,
            deviceInformation: deviceInformation
        )
    }

    @discardableResult
    private func emitStatus(
        phase: BoltPhase,
        availableControls: Set<MouseControl>,
        hardwareSettings: BoltHardwareSettingsStatus,
        deviceInformation: BoltDeviceInformation
    ) -> UInt64 {
        let status = lock.withLock { () -> BoltStatus in
            generation &+= 1
            return BoltStatus(
                phase: phase,
                message: "Synthetic MX4 capability session",
                availableControls: availableControls,
                generation: generation,
                cleanupUncertain: false,
                wheel: .init(support: .supported, supportsInversion: true),
                thumbwheel: .init(support: .supported),
                deviceInformation: deviceInformation,
                deviceResponding: phase == .ready,
                supportsManagement: true,
                model: .mxMaster4,
                connection: connection,
                verifiedIdentity: identity,
                hardwareSettings: hardwareSettings,
                supportsWheelCapture: true,
                supportsThumbwheelManagement: true,
                supportsButtonManagement: true
            )
        }
        continuation.yield(.status(status))
        return status.generation
    }

    private func recordOperation(_ operation: Operation) {
        lock.withLock { operationValues[operation.rawValue] += 1 }
    }
}

private final class LayoutReproBoltPairingSession: BoltPairingManaging, @unchecked Sendable {
    let candidate = BoltPairingCandidate(id: UUID(), name: "Synthetic MX Master 4", model: .mxMaster4)
    let receiver = BoltReceiverCandidate(id: UUID(), label: "Synthetic Logi Bolt receiver")
    let verified = LogitechEndpointCandidate(
        id: UUID(),
        connection: .bolt,
        model: .mxMaster4,
        identity: .init(unitID: "12345678", modelID: "123456789abc"),
        information: .init()
    )
    let events: AsyncStream<BoltPairingStatus>

    private let continuation: AsyncStream<BoltPairingStatus>.Continuation
    private let lock = NSLock()
    private var status = BoltPairingStatus(phase: .idle, message: "Synthetic pairing")
    private var closePauseRequested = false
    private var closeWait: CheckedContinuation<Void, Never>?
    private var selections = 0

    init() {
        let stream = AsyncStream<BoltPairingStatus>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    var selectionCount: Int { lock.withLock { selections } }
    var closeIsPending: Bool { lock.withLock { closeWait != nil } }

    func receivers() async throws -> [BoltReceiverCandidate] { [receiver] }

    func start(receiverID: UUID) async {
        emit(.init(phase: .awaitingSelection, message: "Synthetic candidate", candidates: [candidate]))
    }

    func select(candidateID: UUID) async {
        lock.withLock { selections += 1 }
        guard candidateID == candidate.id else { return }
        emitChallenge(completedClicks: 0, entryComplete: false)
    }

    func emitCompletedChallenge() {
        emitChallenge(completedClicks: 10, entryComplete: true)
    }

    private func emitChallenge(completedClicks: Int, entryComplete: Bool) {
        let challenge = BoltPairingChallenge(
            directions: (0..<10).map { $0.isMultiple(of: 2) ? .left : .right },
            confirmationDirection: .both,
            completedClicks: completedClicks,
            requiredClicks: 10,
            entryComplete: entryComplete
        )
        emit(.init(
            phase: .authenticating,
            message: entryComplete ? "Synthetic click challenge complete" : "Synthetic click challenge",
            challenge: challenge,
            pairingMayHaveSucceeded: entryComplete
        ))
    }

    func cancel() async {
        emit(.init(phase: .cancelled, message: "Synthetic pairing cancelled"))
    }

    func close() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard closePauseRequested else { return true }
                closePauseRequested = false
                closeWait = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func currentStatus() async -> BoltPairingStatus { lock.withLock { status } }

    func pauseNextClose() {
        lock.withLock { closePauseRequested = true }
    }

    func resumeClose() {
        let wait = lock.withLock {
            let continuation = closeWait
            closeWait = nil
            return continuation
        }
        wait?.resume()
    }

    func emitVerifying() {
        emit(.init(phase: .verifying, message: "Synthetic identity verification"))
    }

    func emitVerified() {
        emit(.init(
            phase: .verified,
            message: "Synthetic mouse paired and verified",
            verifiedCandidate: verified,
            pairingMayHaveSucceeded: true
        ))
    }

    private func emit(_ next: BoltPairingStatus) {
        lock.withLock { status = next }
        continuation.yield(next)
    }
}
