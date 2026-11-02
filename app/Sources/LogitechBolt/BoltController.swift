import Foundation
import HidhoggDomain

private struct BoltMutationPreflightFailure: Error, Sendable {
    let failure: BoltFailure
}

private enum BoltHardwareObservationFailure: Error {
    case refused(HIDPPHardwareSnapshot)
    case changed(HIDPPHardwareSnapshot)

    var snapshot: HIDPPHardwareSnapshot {
        switch self {
        case .refused(let snapshot), .changed(let snapshot): snapshot
        }
    }
}

public actor BoltController {
    public nonisolated let events: AsyncStream<BoltEvent>
    public nonisolated let requiresExplicitAssociation: Bool
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let scrollPostingPreflight: @Sendable () -> Bool
    private let nativeNaturalScrolling: @Sendable () -> Bool
    private let makeTransport: @Sendable () -> any BoltTransport
    private let endpointCatalog: any LogitechEndpointCatalog
    private let candidateSnapshotRegistry: LogitechCandidateSnapshotRegistry
    private nonisolated let scrollAdmission: BoltPressAdmission
    private nonisolated let thumbwheelAdmission: BoltPressAdmission
    private nonisolated let admission: BoltPressAdmission
    private var transport: (any BoltTransport)?
    private var activeEndpointLocator: LogitechEndpointLocator?
    private var activeTarget: LogitechConnectionTarget?
    private var uncertainTarget: LogitechConnectionTarget?
    private var verifiedIdentity: LogitechIdentity?
    private var identityFeatureIndex: UInt8?
    private var model: LogitechMouseModel?
    private var connectionType: LogitechConnection?
    private var supportsManagement = true
    private var supportsButtonManagement = true
    private var selectedButtonControls: Set<MouseControl> = [.back, .forward]
    private var supportsWheelCapture: Bool {
        supportsManagement || (model == .mxMaster4 && wheel.support == .supported && wheelCapabilities?.supportsInversion == true && wheelMultiplier > 0)
    }
    private var supportsThumbwheelManagement: Bool {
        supportsManagement || (model == .mxMaster4 && thumbwheel.support == .supported)
    }
    private var observer: Task<Void, Never>?
    private var connectionMonitor: Task<Void, Never>?
    private var connectionProbeNonce: UInt8 = 0
    private var deviceResponding = false
    private var operationHeld = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationRevision: UInt64 = 0
    private var shutdownRequested = false
    private var disableRequested = false
    private var phase: BoltPhase = .idle
    private var generation: UInt64 = 0
    private var connection: UInt64 = 0
    private var available = Set<MouseControl>()
    private var slot: UInt8 = 0
    private var feature: UInt8 = 0
    private var capabilityTable: CapabilityTable?
    private var changed = Set<MouseControl>()
    private var uncertain = false
    private var freshWheelRoutingRequired = false
    private var freshThumbwheelRoutingRequired = false
    private var armed = Set<MouseControl>()
    private var pressed = Set<MouseControl>()
    private var terminalFailure: BoltFailure?
    private var enabledAt: ContinuousClock.Instant = .now
    private var wheel = BoltWheelStatus()
    private var wheelDirection = VerticalWheelDirection(nativeNaturalScrolling: false)
    private var wheelOwnership: WheelOwnership?
    private var wheelBaseline: (feature: UInt8, mode: UInt8)?
    private var latestVerifiedWheelMode: UInt8?
    private var pendingWheelRollback: UInt8?
    private var restorePreviousSettingsOnDisconnect = false
    private var wheelAssociationLost = false
    private var wheelCapabilities: HIDPP2121V1.Capabilities?
    private var wheelMultiplier: UInt8 = 0
    private var captureOwnership: CaptureOwnership?
    private var captureVerified = false
    private var scrollGeneration: UInt64 = 0
    private var scrollEnabledAt: ContinuousClock.Instant = .now
    private var captureBlocker: String?
    private var physicalWheelRequest: PhysicalWheelRequest?
    private var thumbwheel = ThumbwheelState()
    private var hardwareSettings = BoltHardwareSettingsStatus()
    private var hardwareOwnership: [UInt16: HardwareOwnership] = [:]
    private var hardwareRecovery: [UInt16: HardwareOwnership] = [:]
    private var hardwareRestore = false
    private var hardwareRefreshPending = false
    private var wheelRecovery: WheelSessionRecovery?
    private var thumbwheelRecovery: ThumbwheelState?
    private var buttonRecovery: [MouseControl: ButtonSessionRecovery] = [:]

    private struct WheelSessionRecovery {
        let ownership: WheelOwnership?
        let capture: CaptureOwnership?
        let baseline: (feature: UInt8, mode: UInt8)
        let capabilities: HIDPP2121V1.Capabilities
        let latest: UInt8?
        let rollback: UInt8?
        let restore: Bool
    }

    private struct ButtonSessionRecovery {
        let flags: UInt8
        let version: UInt8
        let row: [UInt8]
    }

    private struct HardwareOwnership {
        let original: HIDPPHardwareSnapshot
        var target: [UInt16]
        var mask: [UInt16]
    }
    private var pendingReclaims: [ConnectReclaim] = []
    private var deviceInformation = BoltDeviceInformation()
    private var informationRefreshPending = false
    private var batteryFeature: (index: UInt8, capabilities: BoltDeviceInformationReader.BatteryCapabilities)?
    private var batteryEventRevision: UInt64 = 0
    private var connectionOpenedAt: ContinuousClock.Instant = .now
    private var identityProbeNonce: UInt8 = 0
    private var statusMessage = ""
    private var statusFailure: BoltFailureContext?

    private struct ConnectReclaim {
        enum Control { case button(MouseControl), wheel, thumbwheel }
        let control: Control
        let feature: UInt8
        let root: [UInt8]
        let original: [UInt8]
        let native: [UInt8]
    }

    private struct PhysicalWheelRequest: Equatable {
        let inverted: Bool?
        let highResolution: Bool?
        let restore: Bool
        let direction: VerticalWheelDirection
    }

    private struct CaptureOwnership {
        let feature: UInt8
        let nativeMode: UInt8
        let capturedMode: UInt8
        let direction: VerticalWheelDirection
    }

    private struct WheelOwnership {
        let feature: UInt8
        let original: UInt8
        let target: UInt8
        let mask: UInt8
    }

    private enum FeatureMutation {
        case wheelCapture(UInt8)
        case thumbwheel(ThumbwheelState.Mode)
        case button(MouseControl)
    }

    private struct CapabilityTable {
        let feature: UInt8
        let rootFlags: UInt8
        let version: UInt8
        let rows: [[UInt8]]
        let controls: Set<MouseControl>
    }

    private struct FailureIntent {
        let connection: UInt64
        let generation: UInt64
        let phase: BoltPhase
        let failure: BoltFailure
    }

    private struct ScannedCandidate {
        let candidate: LogitechEndpointCandidate
        let locator: LogitechEndpointLocator
        let slot: UInt8
        let probe: LogitechIdentityProbe
    }

    private struct EndpointScan {
        var candidates: [ScannedCandidate] = []
        var identityUnavailable = false
        var identityMismatch = false
        var unsupportedModel = false
    }

    public init(scrollPostingPreflight: @escaping @Sendable () -> Bool = { false }, nativeNaturalScrolling: @escaping @Sendable () -> Bool = { false }) {
        let admission = BoltPressAdmission()
        let scrollAdmission = BoltPressAdmission()
        let thumbwheelAdmission = BoltPressAdmission()
        self.init(admission: admission, scrollAdmission: scrollAdmission, thumbwheelAdmission: thumbwheelAdmission, scrollPostingPreflight: scrollPostingPreflight, nativeNaturalScrolling: nativeNaturalScrolling, makeTransport: {
            IOKitBoltTransport(onTerminal: { admission.invalidate(); scrollAdmission.invalidate(); thumbwheelAdmission.invalidate() })
        }, endpointCatalog: IOKitLogitechEndpointCatalog(), candidateSnapshotRegistry: LogitechCandidateSnapshotRegistry(), requiresExplicitAssociation: true)
    }

    init(bufferSize: Int = 32, admission: BoltPressAdmission = BoltPressAdmission(), scrollAdmission: BoltPressAdmission = BoltPressAdmission(), thumbwheelAdmission: BoltPressAdmission = BoltPressAdmission(), scrollPostingPreflight: @escaping @Sendable () -> Bool = { false }, nativeNaturalScrolling: @escaping @Sendable () -> Bool = { false }, makeTransport: @escaping @Sendable () -> any BoltTransport, endpointCatalog: (any LogitechEndpointCatalog)? = nil, candidateSnapshotRegistry: LogitechCandidateSnapshotRegistry = LogitechCandidateSnapshotRegistry(), requiresExplicitAssociation: Bool = false) {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        events = stream.stream
        continuation = stream.continuation
        self.requiresExplicitAssociation = requiresExplicitAssociation
        self.makeTransport = makeTransport
        self.endpointCatalog = endpointCatalog ?? IOKitLogitechEndpointCatalog()
        self.candidateSnapshotRegistry = candidateSnapshotRegistry
        self.scrollPostingPreflight = scrollPostingPreflight
        self.nativeNaturalScrolling = nativeNaturalScrolling
        self.admission = admission
        self.scrollAdmission = scrollAdmission
        self.thumbwheelAdmission = thumbwheelAdmission
        continuation.onTermination = { [weak self, admission, scrollAdmission, thumbwheelAdmission] _ in
            admission.invalidate()
            scrollAdmission.invalidate()
            thumbwheelAdmission.invalidate()
            Task { await self?.stop() }
        }
        continuation.yield(.status(BoltStatus(phase: .idle, message: "Disconnected. Connect to discover a Bolt candidate.", availableControls: [], generation: 0, cleanupUncertain: false)))
    }

    public func discover() async {
        guard !requiresExplicitAssociation else {
            let failure = BoltFailureContext(code: BoltFailure.associationRequired.diagnosticCode,
                                             sourceFileID: #fileID, sourceLine: #line,
                                             stage: .identityPreflight)
            publish(phase, BoltFailure.associationRequired.errorDescription ?? "Select a saved Logitech association.", failure: failure)
            return
        }
        let requestedRevision = operationRevision
        guard !shutdownRequested, !disableRequested else {
            publish(phase, "Discovery was cancelled by the current session transition.")
            return
        }
        await acquireOperation()
        defer { releaseOperation() }
        guard requestedRevision == operationRevision, !shutdownRequested, !disableRequested,
              phase != .enabled, phase != .enabling, phase != .stopping else {
            publish(phase, "Discovery is unavailable while the current Bolt session is active or transitioning.")
            return
        }
        generation &+= 1
        admission.prepare(generation: generation)
        terminalFailure = nil
        connection &+= 1
        let current = connection
        deviceResponding = false
        publish(.discovering, "Discovering a Bolt candidate; model identity is unverified.")
        await performDiscovery(connection: current)
        await reconcileTerminalFailure()
    }

    public func existingConnections() async throws -> [LogitechEndpointCandidate] {
        let requestedRevision = operationRevision
        guard !shutdownRequested, !disableRequested else { throw BoltFailure.cancelled }
        await acquireOperation()
        defer { releaseOperation() }
        guard requestedRevision == operationRevision, !shutdownRequested, !disableRequested else {
            throw BoltFailure.cancelled
        }
        try prepareFreshCatalogBoundary()
        candidateSnapshotRegistry.invalidate()

        do {
            let scan = try await scanCurrentEndpoints()
            let candidates = scan.candidates.map(\.candidate)
            guard !candidates.isEmpty || !scan.identityUnavailable else {
                throw BoltFailure.identityUnavailable
            }
            candidateSnapshotRegistry.replace(with: candidates)
            return candidates
        } catch {
            candidateSnapshotRegistry.invalidate()
            throw error
        }
    }

    public func discover(target: LogitechConnectionTarget) async {
        let requestedRevision = operationRevision
        guard !shutdownRequested, !disableRequested else {
            publish(phase, "Discovery was cancelled by the current session transition.")
            return
        }
        await acquireOperation()
        defer { releaseOperation() }
        guard requestedRevision == operationRevision, !shutdownRequested, !disableRequested else {
            publish(phase, "Discovery was cancelled by the current session transition.")
            return
        }
        do {
            try prepareFreshCatalogBoundary()
            do { _ = try target.association.validated() }
            catch { throw BoltFailure.identityUnavailable }
            if let candidateID = target.candidateID {
                try candidateSnapshotRegistry.validate(candidateID, target: target)
            }
            if uncertain {
                guard let uncertainTarget,
                      uncertainTarget.model == target.model,
                      uncertainTarget.association == target.association else {
                    throw BoltFailure.identityMismatch
                }
            }

            generation &+= 1
            admission.prepare(generation: generation)
            terminalFailure = nil
            connection &+= 1
            deviceResponding = false
            publish(.discovering, "Resolving the saved Logitech association across current endpoints.")

            let scan = try await scanCurrentEndpoints()
            let matches = scan.candidates.filter {
                $0.candidate.model == target.model
                    && $0.candidate.identity == target.association.identity
                    && $0.candidate.connection == target.association.preferredConnection
            }
            guard !matches.isEmpty else {
                if scan.identityUnavailable { throw BoltFailure.identityUnavailable }
                if scan.identityMismatch { throw BoltFailure.identityMismatch }
                if scan.unsupportedModel { throw BoltFailure.unsupportedModel }
                throw scan.candidates.isEmpty ? BoltFailure.unavailable : BoltFailure.identityMismatch
            }
            guard matches.count == 1, let match = matches.first else { throw BoltFailure.ambiguous }
            await performAssociatedDiscovery(match, target: target, connection: connection)
            await reconcileTerminalFailure()
        } catch {
            await fail(error, stage: .identityPreflight)
        }
    }

    public func enable() async {
        await enable(controls: [.back, .forward])
    }

    public func enable(controls: Set<MouseControl>) async {
        let requestedRevision = operationRevision
        guard !shutdownRequested, !disableRequested else {
            publish(phase, "Enable was cancelled by the current session transition.")
            return
        }
        await acquireOperation()
        defer { releaseOperation() }
        guard requestedRevision == operationRevision, !shutdownRequested, !disableRequested,
              phase == .ready, transport != nil, !uncertain, supportsButtonManagement,
              changed.isEmpty, !controls.isEmpty, controls.isSubset(of: available) else {
            publish(phase, "Enable requires a ready connection with fresh eligible selected controls.")
            return
        }
        selectedButtonControls = controls
        generation &+= 1
        admission.prepare(generation: generation)
        terminalFailure = nil
        publish(.enabling, "Checking current button capabilities and native reporting.")
        await performEnable()
        await reconcileTerminalFailure()
    }

    public func disable() async { await disableBindings() }
    public func stop() async { await shutdown() }

    public func refreshHardwareSettings() async {
        guard requiresExplicitAssociation, !hardwareRefreshPending, !shutdownRequested,
              transport != nil, phase == .ready || phase == .enabled else { return }
        hardwareRefreshPending = true
        let revision = operationRevision
        let current = connection
        await acquireOperation()
        defer { hardwareRefreshPending = false; releaseOperation() }
        for identifier: UInt16 in [0x2111, 0x2201, 0x2205, 0x19B0, 0x19C0] {
            do {
                try checkMutationState(revision: revision, connection: current, duringCleanup: false)
                let snapshot = try await readHardwareSnapshot(identifier)
                observeHardware(snapshot)
            } catch {
                if identifier == 0x2111, (error as? BoltFailure) == .unavailable {
                    do { observeHardware(try await readHardwareSnapshot(0x2110)) }
                    catch { hardwareUnavailable(0x2110, error: error) }
                } else { hardwareUnavailable(identifier, error: error) }
            }
            guard connection == current, operationRevision == revision, !shutdownRequested else { return }
        }
        publish(phase, statusMessage)
    }

    public func applyHardwareSettings(_ preferences: BoltHardwareSettingsPreferences,
                                      restorePreviousSettingsOnDisconnect: Bool) async {
        let revision = operationRevision
        let current = connection
        await acquireOperation()
        defer { releaseOperation() }
        guard revision == operationRevision, current == connection, !shutdownRequested else { return }
        hardwareRestore = restorePreviousSettingsOnDisconnect
        guard preferences != .init() else { return }
        guard requiresExplicitAssociation, !uncertain, phase == .ready || phase == .enabled else {
            hardwareSettings.message = "Hardware settings require a ready, verified association."
            publish(phase, statusMessage)
            return
        }
        hardwareSettings.isApplying = true
        defer { hardwareSettings.isApplying = false; publish(phase, statusMessage) }
        let requested: [(UInt16, Bool)] = [
            (0x2111, preferences.smartShiftMode != nil || preferences.smartShiftThreshold != nil || preferences.smartShiftTorque != nil),
            (0x2201, preferences.dpi != nil), (0x2205, preferences.pointerSpeed != nil),
            (0x19B0, preferences.hapticsEnabled != nil || preferences.hapticIntensity != nil || preferences.hapticPowerSaving != nil),
            (0x19C0, preferences.forceThreshold != nil)
        ]
        for (identifier, shouldApply) in requested where shouldApply {
            do {
                try checkMutationState(revision: revision, connection: current, duringCleanup: false)
                var snapshot: HIDPPHardwareSnapshot
                do { snapshot = try await readHardwareSnapshot(identifier) }
                catch BoltFailure.unavailable where identifier == 0x2111 { snapshot = try await readHardwareSnapshot(0x2110) }
                if snapshot.identifier == 0x2201 {
                    observeHardware(snapshot)
                    if !hardwareSettings.dpi.canWrite {
                        hardwareSettings.dpi.message = "Current DPI is available. Changing DPI is unavailable for this sensor state."
                        hardwareSettings.message = hardwareSettings.dpi.message
                        continue
                    }
                }
                let plan = try snapshot.plan(preferences)
                try await writeHardware(snapshot, desired: plan.values, mask: plan.mask,
                                        revision: revision, connection: current)
                hardwareSettings.message = nil
            } catch {
                hardwareSettings.message = hardwareUnavailable(identifier, error: error)
            }
            guard connection == current, operationRevision == revision, !shutdownRequested else { return }
        }
    }

    public func playHapticTest(waveform: UInt8) async {
        let revision = operationRevision
        let current = connection
        await acquireOperation()
        defer { releaseOperation() }
        do {
            guard requiresExplicitAssociation, !uncertain, phase == .ready || phase == .enabled else { throw BoltFailure.associationRequired }
            try await verifyActiveTargetIdentityBeforeMutation(revision: revision, connection: current, duringCleanup: false)
            let snapshot = try await readHardwareSnapshot(0x19B0)
            try checkMutationState(revision: revision, connection: current, duringCleanup: false)
            guard waveform < 32, snapshot.values[0] & 1 != 0, snapshot.values[1] > 0, snapshot.values[2] == 0,
                  hapticWaveforms(snapshot).contains(waveform) else { throw BoltFailure.unsupported }
            if let owned = hardwareOwnership[0x19B0] {
                guard snapshot.hasSameContract(as: owned.original), HIDPPHardwareCodec.matches(snapshot.values, owned.target, mask: owned.mask) else { throw BoltFailure.foreignState }
            }
            var required: [UInt16: Int] = [UInt16(snapshot.index) << 8 | 4: 1]
            try addIdentityPreflightRequirements(writes: 1, to: &required)
            try requireNativeTokenCapacity(required)
            _ = try await request(feature: snapshot.index, function: 4, parameters: [waveform, 0, 0])
            try checkMutationState(revision: revision, connection: current, duringCleanup: false)
            observeHardware(snapshot)
            hardwareSettings.haptics.message = "Feedback requested."
        } catch { hardwareSettings.haptics.message = error.localizedDescription }
        publish(phase, statusMessage)
    }

    private func hardwareRead(feature: UInt8, function: UInt8, parameters: [UInt8] = [], cleanup: Bool) async throws -> [UInt8] {
        let revision = operationRevision
        let current = connection
        guard let transport else { throw BoltFailure.disconnected }
        let reply = try await transport.requestDeviceInformation(slot: slot, feature: feature, function: function, parameters: parameters)
        try checkMutationState(revision: revision, connection: current, duringCleanup: cleanup)
        return reply
    }

    private func readHardwareSnapshot(_ identifier: UInt16, cleanup: Bool = false) async throws -> HIDPPHardwareSnapshot {
        let rootReply = try await hardwareRead(feature: 0, function: 0, parameters: BoltWire.bytes(identifier), cleanup: cleanup)
        guard rootReply.count >= 3 else { throw BoltFailure.malformed }
        guard rootReply[0] != 0 else { throw BoltFailure.unavailable }
        let root = Array(rootReply.prefix(3))
        guard root[1] & 0xE0 == 0, root[2] == 0 || (identifier == 0x2201 && root[2] <= 2) else { throw BoltFailure.unsupported }
        let index = root[0]
        switch identifier {
        case 0x2110:
            let state = try await hardwareRead(feature: index, function: 0, cleanup: cleanup)
            guard state.count >= 3, state[0] == 1 || state[0] == 2, state[1] > 0, state[2] > 0 else { throw BoltFailure.malformed }
            return .init(identifier: identifier, root: root, capabilities: [state[2]], values: state.prefix(3).map(UInt16.init))
        case 0x2111:
            let caps = try await hardwareRead(feature: index, function: 0, cleanup: cleanup)
            let state = try await hardwareRead(feature: index, function: 1, cleanup: cleanup)
            guard caps.count >= 4, state.count >= 3, state[0] == 1 || state[0] == 2,
                  state[1] > 0, caps[1] > 0,
                  caps[0] & 1 == 0 || (caps[3] > 0 && state[2] > 0 && state[2] <= min(100, caps[3])) else { throw BoltFailure.malformed }
            return .init(identifier: identifier, root: root, capabilities: Array(caps.prefix(4)), values: state.prefix(3).map(UInt16.init))
        case 0x2201:
            let count = try await hardwareRead(feature: index, function: 0, cleanup: cleanup)
            guard let count = count.first, count == 1 else { throw BoltFailure.unsupported }
            let list = try await hardwareRead(feature: index, function: 1, parameters: [0], cleanup: cleanup)
            guard list.count >= 3, list[0] == 0 else { throw BoltFailure.malformed }
            let values = try HIDPPHardwareCodec.dpiValues(Array(list.dropFirst()))
            let state = try await hardwareRead(feature: index, function: 2, parameters: [0], cleanup: cleanup)
            guard state.count >= (root[2] == 0 ? 3 : 5), state[0] == 0 else { throw BoltFailure.malformed }
            let dpi = BoltWire.word(state, 1)
            let defaultDPI = root[2] == 0 ? 0 : BoltWire.word(state, 3)
            guard values.contains(dpi == 0 ? defaultDPI : dpi), defaultDPI == 0 || values.contains(defaultDPI) else { throw BoltFailure.malformed }
            return .init(identifier: identifier, root: root, capabilities: [count] + Array(list.dropFirst()), values: [dpi, defaultDPI])
        case 0x2205:
            let state = try await hardwareRead(feature: index, function: 0, cleanup: cleanup)
            guard state.count >= 2, BoltWire.word(state, 0) > 0 else { throw BoltFailure.malformed }
            return .init(identifier: identifier, root: root, capabilities: [], values: [BoltWire.word(state, 0)])
        case 0x19B0:
            let caps = try await hardwareRead(feature: index, function: 0, cleanup: cleanup)
            let state = try await hardwareRead(feature: index, function: 1, cleanup: cleanup)
            let engine = try await hardwareRead(feature: index, function: 3, cleanup: cleanup)
            guard caps.count >= 8, state.count >= 3, state[1] <= 100, let engine = engine.first else { throw BoltFailure.malformed }
            return .init(identifier: identifier, root: root, capabilities: Array(caps.prefix(8)) + [state[2]], values: [UInt16(state[0]), UInt16(state[1]), UInt16(engine)])
        case 0x19C0:
            let count = try await hardwareRead(feature: index, function: 0, cleanup: cleanup)
            guard count.first == 1 else { throw BoltFailure.ambiguous }
            let info = try await hardwareRead(feature: index, function: 1, parameters: [0], cleanup: cleanup)
            let state = try await hardwareRead(feature: index, function: 2, parameters: [0], cleanup: cleanup)
            guard info.count >= 8, state.count >= 2 else { throw BoltFailure.malformed }
            let minimum = BoltWire.word(info, 6), maximum = BoltWire.word(info, 4)
            let threshold = BoltWire.word(state, 0), defaultThreshold = BoltWire.word(info, 2)
            guard minimum <= maximum, (minimum...maximum).contains(threshold), (minimum...maximum).contains(defaultThreshold),
                  BoltWire.word(info, 0) & 1 != 0 else { throw BoltFailure.unsupported }
            return .init(identifier: identifier, root: root, capabilities: Array(info.prefix(8)), values: [threshold])
        default: throw BoltFailure.unsupported
        }
    }

    private func writeHardware(_ baseline: HIDPPHardwareSnapshot, desired: [UInt16], mask: [UInt16],
                               revision: UInt64, connection current: UInt64, cleanup: Bool = false) async throws {
        guard baseline.identifier != 0x2201 || baseline.root[2] <= 1 else { throw BoltFailure.unsupported }
        var owned = hardwareOwnership[baseline.identifier]
        if let owned {
            guard baseline.hasSameContract(as: owned.original), HIDPPHardwareCodec.matches(baseline.values, owned.target, mask: owned.mask) else {
                throw BoltHardwareObservationFailure.changed(baseline)
            }
        }
        let target = HIDPPHardwareCodec.merge(current: baseline.values, desired: desired, mask: mask)
        if target == baseline.values { observeHardware(baseline); return }
        var required: [UInt16: Int] = [0: cleanup ? 2 : 5, UInt16(baseline.index) << 8 | UInt16(baseline.setFunction): 2]
        for function in baseline.readFunctions { required[UInt16(baseline.index) << 8 | UInt16(function), default: 0] += cleanup ? 2 : 5 }
        try addIdentityPreflightRequirements(writes: 2, to: &required)
        try requireNativeTokenCapacity(required)
        try checkMutationState(revision: revision, connection: current, duringCleanup: cleanup)
        try await verifyActiveTargetIdentityBeforeMutation(revision: revision, connection: current, duringCleanup: cleanup)
        let fresh = try await readHardwareSnapshot(baseline.identifier, cleanup: cleanup)
        guard fresh == baseline else { throw BoltHardwareObservationFailure.changed(fresh) }
        try checkMutationState(revision: revision, connection: current, duringCleanup: cleanup)
        if !cleanup {
            if owned == nil { owned = .init(original: baseline, target: target, mask: mask) }
            else if var previous = owned {
                previous.target = target
                previous.mask = zip(previous.mask, mask).map { $0 | $1 }
                owned = previous
            }
            hardwareOwnership[baseline.identifier] = owned
        }
        var writeMask = mask
        if baseline.identifier == 0x2111, mask[2] != 0 { writeMask[0] = 0xFF }
        do {
            _ = try await request(feature: baseline.index, function: baseline.setFunction,
                                  parameters: baseline.parameters(values: target, mask: writeMask))
        } catch { }
        let readback = try await readHardwareSnapshot(baseline.identifier, cleanup: cleanup)
        observeHardware(readback)
        guard readback.hasSameContract(as: baseline) else { throw BoltHardwareObservationFailure.changed(readback) }
        guard HIDPPHardwareCodec.matches(readback.values, target, mask: mask) else { throw BoltHardwareObservationFailure.refused(readback) }
    }

    private func cleanupHardwareSettings() async -> Bool {
        guard hardwareRestore else {
            hardwareOwnership.removeAll()
            hardwareSettings.smartShift.isOwned = false
            hardwareSettings.dpi.isOwned = false
            hardwareSettings.pointerSpeed.isOwned = false
            hardwareSettings.haptics.isOwned = false
            hardwareSettings.forceButton.isOwned = false
            return true
        }
        var restored = true
        for identifier in hardwareOwnership.keys.sorted() {
            guard let owned = hardwareOwnership[identifier] else { continue }
            do {
                let current = try await readHardwareSnapshot(identifier, cleanup: true)
                guard current.hasSameContract(as: owned.original) else { throw BoltFailure.foreignState }
                if !HIDPPHardwareCodec.matches(current.values, owned.original.values, mask: owned.mask) {
                    try await writeHardware(current, desired: owned.original.values, mask: owned.mask,
                                            revision: operationRevision, connection: connection, cleanup: true)
                }
                hardwareOwnership.removeValue(forKey: identifier)
                hardwareRecovery.removeValue(forKey: identifier)
                observeHardware(try await readHardwareSnapshot(identifier, cleanup: true))
            } catch {
                restored = false
                hardwareRecovery[identifier] = owned
                hardwareUnavailable(identifier, error: error)
            }
        }
        return restored
    }

    private func hapticWaveforms(_ snapshot: HIDPPHardwareSnapshot) -> [UInt8] {
        let mask = snapshot.capabilities[4...7].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (0..<32).compactMap { mask & (UInt32(1) << $0) != 0 ? UInt8($0) : nil }
    }

    private func observeHardware(_ snapshot: HIDPPHardwareSnapshot) {
        let owned = hardwareOwnership[snapshot.identifier] != nil
        switch snapshot.identifier {
        case 0x2110, 0x2111:
            hardwareSettings.smartShift.support = .supported
            hardwareSettings.smartShift.mode = snapshot.values[0] == 1 ? .freeSpin : snapshot.values[1] == 255 ? .ratchet : .automatic
            hardwareSettings.smartShift.threshold = UInt8(snapshot.values[1])
            hardwareSettings.smartShift.defaultThreshold = snapshot.capabilities[snapshot.identifier == 0x2111 ? 1 : 0]
            hardwareSettings.smartShift.supportsTorque = snapshot.identifier == 0x2111 && snapshot.capabilities[0] & 1 != 0
            hardwareSettings.smartShift.torque = snapshot.identifier == 0x2111 ? UInt8(snapshot.values[2]) : nil
            hardwareSettings.smartShift.maximumTorque = snapshot.identifier == 0x2111 ? min(100, snapshot.capabilities[3]) : nil
            hardwareSettings.smartShift.isOwned = owned
            hardwareSettings.smartShift.message = nil
        case 0x2201:
            hardwareSettings.dpi.support = .supported
            hardwareSettings.dpi.canWrite = snapshot.root[2] <= 1 && snapshot.values[0] > 0
            hardwareSettings.dpi.sensorCount = snapshot.capabilities[0]
            hardwareSettings.dpi.sensor = 0
            hardwareSettings.dpi.current = snapshot.values[0] == 0 ? snapshot.values[1] : snapshot.values[0]
            hardwareSettings.dpi.defaultDPI = snapshot.values[1] == 0 ? nil : snapshot.values[1]
            hardwareSettings.dpi.values = (try? HIDPPHardwareCodec.dpiValues(Array(snapshot.capabilities.dropFirst()))) ?? []
            hardwareSettings.dpi.isOwned = owned
            hardwareSettings.dpi.message = nil
        case 0x2205:
            hardwareSettings.pointerSpeed.support = .supported
            hardwareSettings.pointerSpeed.current = Double(snapshot.values[0]) / 256
            hardwareSettings.pointerSpeed.isOwned = owned
            hardwareSettings.pointerSpeed.message = "Adjusts pointer movement independently of sensor DPI."
        case 0x19B0:
            hardwareSettings.haptics.support = .supported
            hardwareSettings.haptics.enabled = snapshot.values[0] & 1 != 0
            hardwareSettings.haptics.powerSaving = snapshot.values[0] & 2 != 0
            hardwareSettings.haptics.intensity = UInt8(snapshot.values[1])
            hardwareSettings.haptics.intensityStep = snapshot.capabilities[8] >> 4
            hardwareSettings.haptics.intensityCount = snapshot.capabilities[8] & 15
            hardwareSettings.haptics.supportedWaveforms = hapticWaveforms(snapshot)
            hardwareSettings.haptics.rawEngineStatus = UInt8(snapshot.values[2])
            hardwareSettings.haptics.isOwned = owned
            hardwareSettings.haptics.message = nil
        case 0x19C0:
            hardwareSettings.forceButton.support = .supported
            hardwareSettings.forceButton.threshold = snapshot.values[0]
            hardwareSettings.forceButton.defaultThreshold = BoltWire.word(snapshot.capabilities, 2)
            hardwareSettings.forceButton.minimum = BoltWire.word(snapshot.capabilities, 6)
            hardwareSettings.forceButton.maximum = BoltWire.word(snapshot.capabilities, 4)
            hardwareSettings.forceButton.isOwned = owned
            hardwareSettings.forceButton.message = nil
        default: break
        }
    }

    @discardableResult
    private func hardwareUnavailable(_ identifier: UInt16, error: Error) -> String {
        if let observation = error as? BoltHardwareObservationFailure {
            let snapshot = observation.snapshot
            observeHardware(snapshot)
            let actual: String
            switch snapshot.identifier {
            case 0x2110, 0x2111: actual = "Wheel threshold: \(snapshot.values[1])."
            case 0x2201: actual = "Sensor DPI: \(hardwareSettings.dpi.current ?? 0)."
            case 0x2205: actual = String(format: "Pointer speed: %.3g×.", Double(snapshot.values[0]) / 256)
            case 0x19B0: actual = "Feedback: \(snapshot.values[0] & 1 == 0 ? "Off" : "On"); intensity: \(snapshot.values[1])%."
            default: actual = "Force threshold: \(snapshot.values[0])."
            }
            let message: String
            switch observation {
            case .refused: message = "The device did not accept the requested setting. " + actual
            case .changed: message = "The device setting changed. " + actual
            }
            switch snapshot.identifier {
            case 0x2110, 0x2111: hardwareSettings.smartShift.message = message
            case 0x2201: hardwareSettings.dpi.message = message
            case 0x2205: hardwareSettings.pointerSpeed.message = message
            case 0x19B0: hardwareSettings.haptics.message = message
            case 0x19C0: hardwareSettings.forceButton.message = message
            default: break
            }
            return message
        }
        let failure = error as? BoltFailure
        let support: BoltFeatureSupport = failure == .unsupported || failure == .unavailable || failure == .ambiguous ? .unsupported : .unknown
        let message: String
        switch failure {
        case .unavailable: message = "This setting is unavailable on the connected mouse."
        case .unsupported: message = "This setting or requested value is unsupported by the connected mouse."
        case .foreignState: message = "Device settings changed or the requested value was not accepted. Refresh to read the current setting."
        case .ambiguous: message = "The connected mouse does not identify a single configurable control."
        default: message = error.localizedDescription
        }
        switch identifier {
        case 0x2110, 0x2111: hardwareSettings.smartShift.support = support; hardwareSettings.smartShift.message = message
        case 0x2201: hardwareSettings.dpi.support = support; hardwareSettings.dpi.message = message
        case 0x2205: hardwareSettings.pointerSpeed.support = support; hardwareSettings.pointerSpeed.message = message
        case 0x19B0: hardwareSettings.haptics.support = support; hardwareSettings.haptics.message = message
        case 0x19C0: hardwareSettings.forceButton.support = support; hardwareSettings.forceButton.message = message
        default: break
        }
        return message
    }

    public func refreshDeviceInformation() async {
        guard !informationRefreshPending, !shutdownRequested, !disableRequested,
              transport != nil, terminalFailure == nil, phase == .ready || phase == .enabled else { return }
        informationRefreshPending = true
        let current = connection
        let revision = operationRevision
        await acquireOperation()
        defer {
            informationRefreshPending = false
            deviceInformation.isRefreshing = false
            if deviceInformation.batteryState == .loading { deviceInformation.batteryState = .unavailable }
            if deviceInformation.firmwareState == .loading { deviceInformation.firmwareState = .unavailable }
            releaseOperation()
        }
        do {
            try checkInformationRefresh(connection: current, revision: revision)
            deviceInformation.isRefreshing = true
            deviceInformation.batteryState = .loading
            deviceInformation.firmwareState = .loading
            publishDeviceInformation()
            await refreshBatteryInformation(connection: current, revision: revision)
            try checkInformationRefresh(connection: current, revision: revision)
            await refreshFirmwareInformation(connection: current, revision: revision)
            try checkInformationRefresh(connection: current, revision: revision)
            deviceInformation.isRefreshing = false
            publishDeviceInformation()
        } catch {
            if connection == current, operationRevision == revision, !shutdownRequested, !disableRequested,
               terminalFailure == nil, transport != nil, phase == .ready || phase == .enabled {
                deviceInformation.isRefreshing = false
                if deviceInformation.batteryState == .loading { deviceInformation.batteryState = .unavailable }
                if deviceInformation.firmwareState == .loading { deviceInformation.firmwareState = .unavailable }
                publishDeviceInformation()
            }
        }
        await reconcileTerminalFailure()
    }

    private func checkInformationRefresh(connection current: UInt64, revision: UInt64) throws {
        try checkActive()
        guard connection == current, operationRevision == revision, !shutdownRequested, !disableRequested,
              transport != nil, phase == .ready || phase == .enabled else { throw BoltFailure.cancelled }
    }

    private func informationRequest(feature: UInt8, function: UInt8, parameters: [UInt8] = [],
                                    connection current: UInt64, revision: UInt64) async throws -> [UInt8] {
        try checkInformationRefresh(connection: current, revision: revision)
        guard let transport else { throw BoltFailure.disconnected }
        guard remainingNativeTokens(feature: feature, function: function) > 2 else { throw BoltFailure.tokenExhausted }
        do {
            let reply = try await transport.requestDeviceInformation(slot: slot, feature: feature, function: function, parameters: parameters)
            try checkInformationRefresh(connection: current, revision: revision)
            return reply
        } catch {
            if let failure = error as? BoltFailure,
               failure == .disconnected || failure == .transport || failure == .overflow || failure == .ambiguous {
                _ = recordFailure(failure, connection: current)
            }
            throw error
        }
    }

    private func informationFeature(_ identifier: UInt16, connection current: UInt64, revision: UInt64) async throws -> UInt8 {
        let root = try await informationRequest(feature: 0, function: 0, parameters: BoltWire.bytes(identifier),
                                                connection: current, revision: revision)
        let index = try BoltDeviceInformationReader.featureIndex(root)
        guard index != feature, index != wheelBaseline?.feature, index != thumbwheel.feature else { throw BoltFailure.malformed }
        return index
    }

    private func refreshBatteryInformation(connection current: UInt64, revision: UInt64) async {
        let eventRevision = batteryEventRevision
        do {
            let index = try await informationFeature(0x1004, connection: current, revision: revision)
            batteryFeature = nil
            let capabilities = try BoltDeviceInformationReader.BatteryCapabilities(
                await informationRequest(feature: index, function: 0, connection: current, revision: revision))
            batteryFeature = (index, capabilities)
            let battery = try BoltDeviceInformationReader.battery(
                await informationRequest(feature: index, function: 1, connection: current, revision: revision), capabilities: capabilities)
            guard eventRevision == batteryEventRevision else { return }
            deviceInformation.battery = battery
            deviceInformation.batteryState = .available
        } catch {
            guard (try? checkInformationRefresh(connection: current, revision: revision)) != nil else { return }
            if (error as? BoltFailure) == .unsupported { batteryFeature = nil }
            guard eventRevision == batteryEventRevision else { return }
            deviceInformation.battery = nil
            deviceInformation.batteryState = (error as? BoltFailure) == .unsupported ? .unsupported : .unavailable
        }
        publishDeviceInformation()
    }

    private func refreshFirmwareInformation(connection current: UInt64, revision: UInt64) async {
        do {
            let index = try await informationFeature(0x0003, connection: current, revision: revision)
            guard index != batteryFeature?.index else { throw BoltFailure.malformed }
            let count = try BoltDeviceInformationReader.firmwareCount(
                await informationRequest(feature: index, function: 0, connection: current, revision: revision))
            var entities: [BoltDeviceInformation.FirmwareEntity] = []
            for entity in 0..<count {
                entities.append(try BoltDeviceInformationReader.firmwareEntity(
                    await informationRequest(feature: index, function: 1, parameters: [entity], connection: current, revision: revision)))
            }
            deviceInformation.firmware = entities
            deviceInformation.firmwareState = .available
        } catch {
            guard (try? checkInformationRefresh(connection: current, revision: revision)) != nil else { return }
            deviceInformation.firmware = []
            deviceInformation.firmwareState = (error as? BoltFailure) == .unsupported ? .unsupported : .unavailable
        }
        publishDeviceInformation()
    }

    private func publishDeviceInformation() {
        publish(phase, statusMessage, failure: statusFailure)
    }

    public func stop(restorePreviousSettingsOnDisconnect: Bool) async {
        await shutdown(restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
    }

    public func applyWheelPreference(_ desired: Bool?) async {
        await applyWheelPreference(desired, restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
    }

    public func applyWheelPreference(_ desired: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        await applyWheelPreferences(inverted: desired, highResolution: nil, restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
    }

    public func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool) async {
        physicalWheelRequest = nil
        await reconcileWheelPreferences(inverted: inverted, highResolution: highResolution,
                                        restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect,
                                        amount: nil, scrollPostingAllowed: false)
    }

    public func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                                      amount: Double?, scrollPostingAllowed: Bool) async {
        guard supportsWheelCapture else {
            publish(phase, "Scroll capture is unavailable for this Logitech connection.")
            return
        }
        await reconcileWheelPreferences(inverted: inverted, highResolution: highResolution,
                                        restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect,
                                        amount: amount, scrollPostingAllowed: scrollPostingAllowed)
    }

    private func reconcileWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                                           amount: Double?, scrollPostingAllowed: Bool) async {
        guard supportsManagement || (model == .mxMaster4 && wheel.support == .supported && (amount == nil || supportsWheelCapture)) else {
            publish(phase, "These wheel settings are unavailable for this Logitech connection.")
            return
        }
        let requestedRevision = operationRevision
        guard !shutdownRequested, !disableRequested else {
            publish(phase, "The wheel preference request was cancelled by the current session transition.")
            return
        }
        await acquireOperation()
        defer { releaseOperation() }
        guard requestedRevision == operationRevision, !shutdownRequested, !disableRequested,
              (phase == .ready || phase == .enabled), transport != nil, !uncertain else {
            publish(phase, "A connected device is required to change its wheel preference.")
            return
        }
        if inverted != nil, let capabilities = wheelCapabilities, !capabilities.supportsInversion {
            publish(phase, "Wheel inversion is unavailable; input resolution remains available.")
            return
        }
        self.restorePreviousSettingsOnDisconnect = restorePreviousSettingsOnDisconnect
        do {
            if let amount, !amount.isFinite || !(0.25...10).contains(amount) { throw BoltFailure.malformed }
            wheelDirection = VerticalWheelDirection(nativeNaturalScrolling: nativeNaturalScrolling())
            let requested = PhysicalWheelRequest(inverted: inverted, highResolution: highResolution,
                                                 restore: restorePreviousSettingsOnDisconnect, direction: wheelDirection)
            let physicalChanged = physicalWheelRequest != requested
            let wantsCapture = amount != nil && scrollPostingAllowed
            if physicalChanged, let index = wheelBaseline?.feature, captureOwnership != nil || wantsCapture {
                let releasing = captureOwnership == nil ? 0 : 1
                let capturing = wantsCapture ? 1 : 0
                try reserveWheelTokens(feature: index, reads: releasing * 2 + 3 + capturing * 2,
                                       setters: releasing + 1 + capturing, rootReads: 1 + capturing, capabilityReads: 1 + capturing)
            }
            if physicalChanged, captureOwnership != nil {
                invalidateScrollAdmission()
                guard await cleanupCapture(final: false) else { throw BoltFailure.foreignState }
            }
            if physicalChanged {
                wheel = BoltWheelStatus(support: wheel.support, observedInverted: wheel.observedInverted,
                                       isOwned: wheelOwnership != nil, isApplying: true,
                                       observedHighResolution: wheel.observedHighResolution, supportsInversion: wheel.supportsInversion)
                publish(phase, "Checking the device wheel preferences.")
                await performWheelPreferences(inverted: inverted, highResolution: highResolution)
                guard phase == .ready || phase == .enabled else { return }
                physicalWheelRequest = requested
            }
            captureBlocker = amount != nil && !scrollPostingAllowed ? "Scroll amount posting is unavailable or requires an explicit retry; native scrolling remains active." : nil
            if amount == nil || !scrollPostingAllowed {
                invalidateScrollAdmission()
                guard await cleanupCapture(final: false) else { throw BoltFailure.foreignState }
            } else if captureOwnership == nil {
                try await beginCapture()
            } else {
                try checkActive()
                scrollGeneration &+= 1
                scrollEnabledAt = .now
                guard scrollAdmission.renew(generation: scrollGeneration) else { throw BoltFailure.cancelled }
            }
            refreshWheelCaptureStatus()
            publish(phase, "Device wheel preferences reconciled.")
        } catch {
            await fail(error)
        }
        await reconcileTerminalFailure()
    }

    public func applyThumbwheelPreferences(inverted: Bool?, amount: Double?, restorePreviousSettingsOnDisconnect: Bool,
                                          scrollPostingAllowed: Bool) async {
        guard supportsThumbwheelManagement else {
            publish(phase, "This Logitech connection is read-only; thumb-wheel settings are unavailable.")
            return
        }
        let requestedRevision = operationRevision
        guard !shutdownRequested, !disableRequested else { return }
        await acquireOperation()
        defer { releaseOperation() }
        guard requestedRevision == operationRevision, !shutdownRequested, !disableRequested,
              phase == .ready || phase == .enabled, transport != nil, !uncertain else { return }
        thumbwheel.restore = restorePreviousSettingsOnDisconnect
        if thumbwheel.support == .unknown, inverted != nil || amount != nil {
            do { try await discoverThumbwheel() }
            catch { await fail(error); return }
        }
        if thumbwheel.support == .unknown, inverted == nil, amount == nil { return }
        guard thumbwheel.support == .supported, let index = thumbwheel.feature else {
            thumbwheel.blocker = "Thumb-wheel settings are unavailable for this session."
            publish(phase, "Thumb-wheel preferences are unavailable; other controls remain connected.")
            return
        }
        do {
            if let amount, !amount.isFinite || !(0.25...10).contains(amount) { throw BoltFailure.malformed }
            let requested = ThumbwheelState.Request(inverted: inverted, restore: restorePreviousSettingsOnDisconnect)
            let physicalChanged = thumbwheel.request != requested
            let wantsCapture = amount != nil && scrollPostingAllowed
            if physicalChanged {
                let releasing = thumbwheel.capture == nil ? 0 : 1
                let capturing = wantsCapture ? 1 : 0
                try reserveThumbwheelTokens(feature: index, reads: releasing * 2 + 3 + capturing * 2,
                                           setters: releasing + 1 + capturing, rootReads: 1 + capturing,
                                           infoReads: 1 + capturing)
                if thumbwheel.capture != nil {
                    guard await cleanupThumbwheel(final: false) else { throw BoltFailure.foreignState }
                }
                try await performThumbwheelPreference(inverted: inverted)
                thumbwheel.request = requested
            }
            thumbwheel.blocker = amount != nil && !scrollPostingAllowed
                ? "Thumb-wheel posting is unavailable or requires an explicit retry; native scrolling remains active." : nil
            if !wantsCapture {
                guard await cleanupThumbwheel(final: false) else { throw BoltFailure.foreignState }
            } else if thumbwheel.capture == nil {
                try await beginThumbwheelCapture()
            } else {
                try checkActive()
                thumbwheel.generation &+= 1
                thumbwheel.enabledAt = .now
                guard thumbwheelAdmission.renew(generation: thumbwheel.generation) else { throw BoltFailure.cancelled }
            }
            publish(phase, "Thumb-wheel preferences reconciled.")
        } catch { await fail(error) }
        await reconcileTerminalFailure()
    }

    public nonisolated func suspendThumbwheelAdmission() { thumbwheelAdmission.suspend() }

    public nonisolated func invalidateThumbwheelAdmission() { thumbwheelAdmission.invalidate() }

    public nonisolated func withThumbwheelAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        switch thumbwheelAdmission.perform(generation: generation, observedAt: observedAt, operation) {
        case .accepted: return true
        case .rejected: return false
        case .stale:
            Task { await self.rejectStaleThumbwheelAdmission(generation: generation) }
            return false
        }
    }

    public func stopForRestart() async -> Bool {
        await shutdown()
        return phase == .idle && !uncertain && changed.isEmpty && wheelOwnership == nil && captureOwnership == nil && thumbwheel.ownership == nil && thumbwheel.capture == nil && transport == nil
    }

    public func stopForRestart(restorePreviousSettingsOnDisconnect: Bool) async -> Bool {
        await shutdown(restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect)
        return phase == .idle && !uncertain && changed.isEmpty && wheelOwnership == nil && captureOwnership == nil && thumbwheel.ownership == nil && thumbwheel.capture == nil && transport == nil
    }

    /// Runs synchronously under the admission lock; the closure must not reenter admission or wait for this actor.
    public nonisolated func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        switch admission.perform(generation: generation, observedAt: observedAt, operation) {
        case .accepted: return true
        case .rejected: return false
        case .stale:
            Task { await self.rejectStaleAdmission(generation: generation) }
            return false
        }
    }

    public nonisolated func suspendScrollAdmission() { scrollAdmission.suspend() }

    public nonisolated func invalidateScrollAdmission() { scrollAdmission.invalidate() }

    public nonisolated func withScrollAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        switch scrollAdmission.perform(generation: generation, observedAt: observedAt, operation) {
        case .accepted: return true
        case .rejected: return false
        case .stale:
            Task { await self.rejectStaleScrollAdmission(generation: generation) }
            return false
        }
    }

    private func shutdown(restorePreviousSettingsOnDisconnect: Bool? = nil) async {
        admission.invalidate()
        invalidateScrollAdmission()
        invalidateThumbwheelAdmission()
        if let restorePreviousSettingsOnDisconnect {
            self.restorePreviousSettingsOnDisconnect = restorePreviousSettingsOnDisconnect
            hardwareRestore = restorePreviousSettingsOnDisconnect
            thumbwheel.restore = restorePreviousSettingsOnDisconnect
        }
        if !shutdownRequested {
            operationRevision &+= 1
            shutdownRequested = true
            generation &+= 1
            armed.removeAll()
            pressed.removeAll()
            publish(.stopping, "Stopping delivery and verifying temporary diversion cleanup.")
        }
        await acquireOperation()
        defer { releaseOperation() }
        guard shutdownRequested else { return }
        await performShutdown()
    }

    private func performShutdown() async {
        armed.removeAll()
        pressed.removeAll()
        let restored = await cleanup()
        uncertain = uncertain || !restored
        if uncertain { uncertainTarget = activeTarget ?? uncertainTarget }
        else { uncertainTarget = nil }
        await closeTransport()
        available.removeAll()
        publish(restored ? .idle : .failed, restored ? "Disconnected. Session cleanup verified." : "Cleanup is unverified. Delivery is stopped; fresh discovery must verify capabilities and native routing before bindings can be enabled.")
        shutdownRequested = false
    }

    private func disableBindings() async {
        admission.invalidate()
        if !disableRequested {
            operationRevision &+= 1
            disableRequested = true
        }
        generation &+= 1
        armed.removeAll()
        pressed.removeAll()
        if phase == .enabling {
            publish(.stopping, "Cancelling activation and restoring temporary button diversion.")
        } else if phase == .enabled {
            publish(.enabled, "Stopping shortcut delivery and restoring temporary button diversion.")
        }
        await acquireOperation()
        defer {
            disableRequested = false
            releaseOperation()
        }
        guard !shutdownRequested else { return }
        if let terminalFailure {
            await fail(terminalFailure)
            return
        }
        guard phase != .failed, phase != .idle, !uncertain else { return }
        let restored = await cleanupButtons()
        guard !shutdownRequested else { return }
        guard restored else {
            await fail(BoltFailure.foreignState)
            return
        }
        uncertain = false
        publish(.ready, "Bindings disabled. The device remains connected with its current wheel preference.")
    }

    private func acquireOperation() async {
        guard operationHeld else {
            operationHeld = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationHeld = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    private func performDiscovery(connection current: UInt64) async {
        let revision = operationRevision
        var stage: BoltFailureStage?
        do {
            try await openCandidate(connection: current)
            try checkConnectActive(revision: revision)
            wheelDirection = VerticalWheelDirection(nativeNaturalScrolling: nativeNaturalScrolling())
            deviceResponding = true

            publish(.discovering, "Mouse detected; verifying capabilities and restoring the session.")
            let table = try await readCapabilities()
            capabilityTable = table
            available = table.controls
            stage = .connectPreflight
            try await reclaimConnectDiversion(table, revision: revision, stage: &stage)
            try checkConnectActive(revision: revision)
            uncertain = false
            publish(.ready, "Connected Bolt candidate; model identity is unverified. Keep competing mouse software closed while Hidhogg manages this device.")
            startConnectionMonitor(connection: current)
        } catch {
            guard phase != .stopping else { return }
            await fail(error, stage: (error as? BoltFailure) == .cancelled ? nil : stage)
        }
    }

    private func prepareFreshCatalogBoundary() throws {
        guard !shutdownRequested, !disableRequested, transport == nil, phase == .idle || phase == .failed else {
            throw BoltFailure.cancelled
        }
    }

    private func scanCurrentEndpoints() async throws -> EndpointScan {
        let endpoints = try await endpointCatalog.enumerate()
        guard endpoints.count <= 16 else { throw BoltFailure.ambiguous }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var combined = EndpointScan()
        for endpoint in endpoints {
            try checkCatalogDeadline(deadline)
            do {
                let result = try await scanEndpoint(endpoint, deadline: deadline)
                combined.candidates.append(contentsOf: result.candidates)
                combined.identityUnavailable = combined.identityUnavailable || result.identityUnavailable
                combined.identityMismatch = combined.identityMismatch || result.identityMismatch
                combined.unsupportedModel = combined.unsupportedModel || result.unsupportedModel
            } catch let failure as BoltFailure {
                try checkCatalogDeadline(deadline)
                switch failure {
                case .identityMismatch:
                    combined.identityMismatch = true
                case .unsupportedModel:
                    combined.unsupportedModel = true
                case .unavailable, .timeout, .identityUnavailable, .stale, .malformed, .disconnected, .transport:
                    combined.identityUnavailable = true
                default:
                    throw failure
                }
            } catch {
                try checkCatalogDeadline(deadline)
                combined.identityUnavailable = true
            }
        }
        guard combined.candidates.count <= 96 else { throw BoltFailure.ambiguous }
        return combined
    }

    private func scanEndpoint(_ endpoint: LogitechEndpointLocator, deadline: ContinuousClock.Instant) async throws -> EndpointScan {
        let probeTransport = endpointCatalog.makeTransport(for: endpoint, onTerminal: {})
        do { try await probeTransport.open() }
        catch {
            await probeTransport.close()
            throw error
        }

        var result = EndpointScan()
        let slots = endpoint.connection == .bolt ? Array(UInt8(1)...UInt8(6)) : [UInt8(0xFF)]
        do {
            for slot in slots {
                try checkCatalogDeadline(deadline)
                do {
                    let probe = try await readIdentity(on: probeTransport, endpoint: endpoint, slot: slot, deadline: deadline)
                    let candidate = LogitechEndpointCandidate(
                        id: UUID(), connection: endpoint.connection, model: probe.model, identity: probe.identity,
                        information: BoltDeviceInformation(featureVersions: [0x0003: probe.featureVersion])
                    )
                    result.candidates.append(ScannedCandidate(candidate: candidate, locator: endpoint, slot: slot, probe: probe))
                } catch let failure as BoltFailure {
                    switch failure {
                    case .unavailable, .timeout:
                        continue
                    case .identityUnavailable:
                        result.identityUnavailable = true
                    case .identityMismatch:
                        result.identityMismatch = true
                    case .unsupportedModel:
                        result.unsupportedModel = true
                    case .stale, .malformed, .disconnected, .transport:
                        result.identityUnavailable = true
                    default:
                        throw failure
                    }
                }
            }
        } catch {
            await probeTransport.close()
            throw error
        }
        await probeTransport.close()
        return result
    }

    private func readIdentity(on channel: any BoltTransport, endpoint: LogitechEndpointLocator,
                              slot: UInt8, deadline: ContinuousClock.Instant,
                              allowCancelled: Bool = false) async throws -> LogitechIdentityProbe {
        try checkCatalogDeadline(deadline, allowCancelled: allowCancelled)
        identityProbeNonce = identityProbeNonce == 200 ? 1 : identityProbeNonce &+ 1
        return try await LogitechIdentityReader.read(
            on: channel, endpoint: endpoint, slot: slot, nonce: identityProbeNonce,
            deadline: deadline, allowCancelled: allowCancelled
        )
    }

    private func checkCatalogDeadline(_ deadline: ContinuousClock.Instant, allowCancelled: Bool = false) throws {
        guard allowCancelled || !Task.isCancelled, ContinuousClock.now < deadline else { throw BoltFailure.timeout }
    }

    private func performAssociatedDiscovery(_ selection: ScannedCandidate, target: LogitechConnectionTarget,
                                            connection current: UInt64) async {
        let revision = operationRevision
        var stage: BoltFailureStage? = .identityPreflight
        do {
            let recoveryRequired = uncertain
            if !recoveryRequired, !(await cleanup()) { throw BoltFailure.foreignState }
            try checkConnectActive(revision: revision)
            await closeTransport()
            resetSessionStateForDiscovery()
            activeEndpointLocator = selection.locator
            activeTarget = target
            slot = selection.slot

            let candidate = endpointCatalog.makeTransport(for: selection.locator, onTerminal: { [
                admission = self.admission,
                scrollAdmission = self.scrollAdmission,
                thumbwheelAdmission = self.thumbwheelAdmission
            ] in
                admission.invalidate()
                scrollAdmission.invalidate()
                thumbwheelAdmission.invalidate()
            })
            transport = candidate
            connectionOpenedAt = .now
            observer = Task { [weak self] in
                for await event in candidate.events {
                    guard !Task.isCancelled else { break }
                    await self?.receive(event, connection: current)
                }
            }
            try await candidate.open()
            try checkConnectActive(revision: revision)

            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            let probe = try await readIdentity(on: candidate, endpoint: selection.locator, slot: selection.slot,
                                               deadline: deadline)
            guard probe.identity == target.association.identity, probe.model == target.model,
                  selection.locator.connection == target.association.preferredConnection else {
                throw BoltFailure.identityMismatch
            }
            try checkConnectActive(revision: revision)
            verifiedIdentity = probe.identity
            identityFeatureIndex = probe.featureIndex
            model = probe.model
            connectionType = selection.locator.connection
            supportsManagement = probe.model == .mxMaster3S
            deviceInformation.featureVersions = try await readFeatureVersions(initial: probe, slot: selection.slot,
                                                                               connection: current, revision: revision,
                                                                               deadline: deadline)
            deviceResponding = true
            if !hardwareRecovery.isEmpty {
                hardwareOwnership = hardwareRecovery
                hardwareRestore = true
                guard await cleanupHardwareSettings() else { throw BoltFailure.foreignState }
                try checkConnectActive(revision: revision)
            }
            try await restoreWheelAndThumbwheelRecovery()

            if supportsManagement {
                wheelDirection = VerticalWheelDirection(nativeNaturalScrolling: nativeNaturalScrolling())
                publish(.discovering, "Verified the saved MX Master 3S association; checking supported controls and cleanup state.")
                let table = try await readCapabilities()
                capabilityTable = table
                available = table.controls
                supportsButtonManagement = !available.isEmpty
                try await restoreButtonRecovery(table)
                stage = .connectPreflight
                try await reclaimConnectDiversion(table, revision: revision, stage: &stage)
                try checkConnectActive(revision: revision)
                uncertain = false
                uncertainTarget = nil
                publish(.ready, "Connected to the saved MX Master 3S association.")
            } else {
                available.removeAll()
                capabilityTable = nil
                supportsButtonManagement = false
                wheelDirection = VerticalWheelDirection(nativeNaturalScrolling: nativeNaturalScrolling())
                try await discoverWheel()
                try await discoverThumbwheel()
                do {
                    let table = try await readCapabilities()
                    capabilityTable = table
                    supportsButtonManagement = !table.controls.isEmpty
                    try await restoreButtonRecovery(table)
                    var nativeControls = Set<MouseControl>()
                    for control in table.controls {
                        if try await reporting(control) == .baseline { nativeControls.insert(control) }
                    }
                    capabilityTable = table
                    available = nativeControls
                    supportsButtonManagement = !nativeControls.isEmpty
                } catch {
                    try checkConnectActive(revision: revision)
                    if !buttonRecovery.isEmpty { throw error }
                    capabilityTable = nil
                    available.removeAll()
                }
                try checkConnectActive(revision: revision)
                if freshWheelRoutingRequired, wheelBaseline == nil { throw BoltFailure.foreignState }
                if freshThumbwheelRoutingRequired, thumbwheel.support != .supported { throw BoltFailure.foreignState }
                uncertain = false
                uncertainTarget = nil
                freshWheelRoutingRequired = false
                freshThumbwheelRoutingRequired = false
                publish(.ready, wheel.support == .supported
                    ? "Connected to the saved MX Master 4 association; supported wheel preferences are available."
                    : "Connected to the saved MX Master 4 association; wheel settings are unavailable for this session.")
            }

            startConnectionMonitor(connection: current)
            Task { await self.refreshDeviceInformation() }
            Task { await self.refreshHardwareSettings() }
        } catch {
            guard phase != .stopping else { return }
            await fail(error, stage: (error as? BoltFailure) == .cancelled ? nil : stage)
        }
    }

    private func readFeatureVersions(initial probe: LogitechIdentityProbe, slot: UInt8,
                                     connection current: UInt64, revision: UInt64,
                                     deadline: ContinuousClock.Instant) async throws -> [UInt16: UInt8] {
        var versions: [UInt16: UInt8] = [0x0003: probe.featureVersion]
        let featureIDs: [UInt16] = [0x1004, 0x1B04, 0x2121, 0x2150, 0x2201, 0x1814, 0x2110, 0x2111, 0x2205, 0x19B0, 0x19C0]
        for identifier in featureIDs {
            try checkConnectActive(revision: revision)
            guard ContinuousClock.now < deadline else { break }
            guard let transport else { throw BoltFailure.disconnected }
            do {
                let root = try await transport.requestDeviceInformation(slot: slot, feature: 0, function: 0,
                                                                          parameters: BoltWire.bytes(identifier))
                guard root.count >= 3, root[0] != 0, root[1] & 0xE0 == 0 else { continue }
                versions[identifier] = root[2]
            } catch let failure as BoltFailure where failure == .unavailable || failure == .timeout {
                continue
            } catch BoltDeviceInformationRequestError.protocolRejected {
                continue
            }
        }
        return versions
    }

    private func checkConnectActive(revision: UInt64) throws {
        try checkActive()
        guard operationRevision == revision, !shutdownRequested, !disableRequested else { throw BoltFailure.cancelled }
    }

    private func restoreWheelAndThumbwheelRecovery() async throws {
        if let recovery = wheelRecovery {
            let index = try await readWheelFeature()
            guard index == recovery.baseline.feature, wheelCapabilities == recovery.capabilities else { throw BoltFailure.foreignState }
            wheelBaseline = recovery.baseline
            wheelOwnership = recovery.ownership
            captureOwnership = recovery.capture
            latestVerifiedWheelMode = recovery.latest
            pendingWheelRollback = recovery.rollback
            restorePreviousSettingsOnDisconnect = recovery.restore
            wheelAssociationLost = false
            observeWheel(try await wheelMode(feature: index))
            guard await cleanupWheel() else { throw BoltFailure.foreignState }
            wheelRecovery = nil
        }
        if var recovery = thumbwheelRecovery {
            let index = try await readThumbwheelFeature()
            guard index == recovery.feature, thumbwheel.info == recovery.info else { throw BoltFailure.foreignState }
            recovery.associationLost = false
            thumbwheel = recovery
            guard await cleanupThumbwheel(final: true) else { throw BoltFailure.foreignState }
            thumbwheelRecovery = nil
        }
    }

    private func restoreButtonRecovery(_ table: CapabilityTable) async throws {
        for control in MouseControl.allCases {
            guard let recovery = buttonRecovery[control] else { continue }
            guard recovery.flags == table.rootFlags, recovery.version == table.version,
                  table.controls.contains(control),
                  table.rows.contains(recovery.row) else { throw BoltFailure.foreignState }
            let current = try await reporting(control)
            if current == .diverted {
                changed.insert(control)
                try await mutate(control, flags: 0x02, duringCleanup: true)
                guard try await reporting(control) == .baseline else { throw BoltFailure.foreignState }
            } else if current != .baseline { throw BoltFailure.foreignState }
            changed.remove(control)
            buttonRecovery.removeValue(forKey: control)
        }
    }

    private func reclaimConnectDiversion(_ table: CapabilityTable, revision: UInt64, stage: inout BoltFailureStage?) async throws {
        guard Set([MouseControl.back, .forward]).isSubset(of: table.controls) else { throw BoltFailure.unsupported }
        var preflight: [ConnectReclaim] = []
        for control in [MouseControl.back, .forward] {
            let state = try await reporting(control)
            try checkConnectActive(revision: revision)
            guard state != .foreign else { throw BoltFailure.foreignState }
            preflight.append(ConnectReclaim(control: .button(control), feature: table.feature,
                root: [table.feature, table.rootFlags, table.version],
                original: [state == .diverted ? 1 : 0], native: [0]))
        }
        let wheelRoot = try await request(feature: 0, function: 0, parameters: [0x21, 0x21])
        try checkConnectActive(revision: revision)
        guard wheelRoot.count >= 3 else { throw BoltFailure.malformed }
        let wheelRootSupported = wheelRoot[0] != 0 && wheelRoot[1] & 0xE0 == 0 && wheelRoot[2] == 1
        if freshWheelRoutingRequired, !wheelRootSupported { throw BoltFailure.unsupported }
        if wheelRootSupported {
            let capabilities = try await request(feature: wheelRoot[0], function: 0)
            try checkConnectActive(revision: revision)
            let decoded = try HIDPP2121V1.Capabilities(capabilities)
            guard decoded.supportsInversion || !freshWheelRoutingRequired else { throw BoltFailure.unsupported }
            if decoded.supportsInversion {
                wheelCapabilities = decoded
                wheelMultiplier = decoded.multiplier
                let mode = try await wheelMode(feature: wheelRoot[0])
                try checkConnectActive(revision: revision)
                preflight.append(ConnectReclaim(control: .wheel, feature: wheelRoot[0], root: Array(wheelRoot.prefix(3)),
                    original: [mode], native: [mode & ~0x01]))
            }
        }
        let thumbRoot = try await request(feature: 0, function: 0, parameters: [0x21, 0x50])
        try checkConnectActive(revision: revision)
        guard thumbRoot.count >= 3 else { throw BoltFailure.malformed }
        let thumbwheelRootSupported = thumbRoot[0] != 0 && thumbRoot[1] & 0xE0 == 0 && thumbRoot[2] == 0
        if freshThumbwheelRoutingRequired, !thumbwheelRootSupported { throw BoltFailure.unsupported }
        if thumbwheelRootSupported {
            let info = try await request(feature: thumbRoot[0], function: 0)
            try checkConnectActive(revision: revision)
            let decoded = try ThumbwheelState.Info(info)
            let reply = try await request(feature: thumbRoot[0], function: 1)
            guard try ThumbwheelState.Mode.decode(reply).statusFlags == 0 else { throw BoltFailure.foreignState }
            try checkConnectActive(revision: revision)
            thumbwheel.info = decoded
            preflight.append(ConnectReclaim(control: .thumbwheel, feature: thumbRoot[0], root: Array(thumbRoot.prefix(3)),
                original: Array(reply.prefix(2)), native: [0, reply[1]]))
        }
        let mutations = preflight.filter { $0.original != $0.native }
        try reserveConnectReclaimTokens(preflight, table: table)
        try await verifyCapabilities(table)
        try checkConnectActive(revision: revision)
        for item in preflight {
            try await verifyConnectReclaimRoot(item)
            try checkConnectActive(revision: revision)
        }
        if !mutations.isEmpty {
            publish(.discovering, "Recognised existing diversion; recovering and verifying native routing before connection.")
        }
        for item in mutations {
            stage = .connectPreflight
            try checkConnectActive(revision: revision)
            try await verifyConnectReclaimRoot(item)
            try checkConnectActive(revision: revision)
            guard try await connectReclaimState(item) == item.original else { throw BoltFailure.foreignState }
            try checkConnectActive(revision: revision)
            pendingReclaims.append(item)
            stage = .connectRecoveryWrite
            try await writeConnectReclaim(item, duringCleanup: false)
            try checkConnectActive(revision: revision)
            stage = .connectRecoveryReadback
            guard try await connectReclaimState(item) == item.native else { throw BoltFailure.foreignState }
            pendingReclaims.removeAll()
            try checkConnectActive(revision: revision)
        }
        stage = .connectRecoveryReadback
        for item in preflight {
            try await verifyConnectReclaimRoot(item)
            try checkConnectActive(revision: revision)
            guard try await connectReclaimState(item) == item.native else { throw BoltFailure.foreignState }
            try checkConnectActive(revision: revision)
        }
        wheel = BoltWheelStatus(support: .unsupported, message: "Device wheel settings are unavailable for this session.")
        thumbwheel.support = .unsupported
        thumbwheel.message = "Device thumb-wheel settings are unavailable for this session."
        for item in preflight {
            switch item.control {
            case .button: break
            case .wheel:
                wheelBaseline = (item.feature, item.native[0])
                latestVerifiedWheelMode = item.native[0]
                observeWheel(item.native[0])
            case .thumbwheel:
                let mode = try ThumbwheelState.Mode.decode(item.native)
                thumbwheel.feature = item.feature
                thumbwheel.baseline = mode
                thumbwheel.latest = mode
                thumbwheel.support = .supported
                thumbwheel.message = nil
            }
        }
        freshWheelRoutingRequired = false
        freshThumbwheelRoutingRequired = false
    }

    private func reserveConnectReclaimTokens(_ items: [ConnectReclaim], table: CapabilityTable) throws {
        var required: [UInt16: Int] = [:]
        let mutations = items.filter { $0.original != $0.native }
        required[0] = mutations.count + items.count * 2 + 2
        required[UInt16(table.feature) << 8] = 1
        required[UInt16(table.feature) << 8 | 1] = try eligibleCapabilityRowIndices(table).count
        for item in items {
            let getter: UInt8 = if case .button = item.control { 2 } else { 1 }
            let setter: UInt8 = if case .button = item.control { 3 } else { 2 }
            required[UInt16(item.feature) << 8 | UInt16(getter), default: 0] += item.original == item.native ? 1 : 5
            if item.original != item.native {
                required[UInt16(item.feature) << 8 | UInt16(setter), default: 0] += 2
            }
        }
        try addIdentityPreflightRequirements(writes: mutations.isEmpty ? 0 : mutations.count + 1, to: &required)
        try requireNativeTokenCapacity(required)
    }

    private func connectReclaimState(_ item: ConnectReclaim) async throws -> [UInt8] {
        switch item.control {
        case .button(let control):
            let state = try await reporting(control)
            guard state != .foreign else { throw BoltFailure.foreignState }
            return [state == .diverted ? 1 : 0]
        case .wheel:
            return [try await wheelMode(feature: item.feature, cleanup: true)]
        case .thumbwheel:
            let reply = try await request(feature: item.feature, function: 1)
            _ = try ThumbwheelState.Mode.decode(reply)
            return Array(reply.prefix(2))
        }
    }

    private func writeConnectReclaim(_ item: ConnectReclaim, duringCleanup: Bool) async throws {
        if case .button(let control) = item.control {
            try await mutate(control, flags: 0x02, duringCleanup: duringCleanup)
        } else {
            _ = try await mutateRequest(feature: item.feature, function: 2, parameters: item.native,
                                        duringCleanup: duringCleanup)
        }
    }

    private func cleanupConnectReclaims() async -> Bool {
        guard let item = pendingReclaims.first else { return true }
        do {
            try await verifyConnectReclaimRoot(item)
            let current = try await connectReclaimState(item)
            if current != item.native {
                guard current == item.original else { throw BoltFailure.foreignState }
                try await writeConnectReclaim(item, duringCleanup: true)
                guard try await connectReclaimState(item) == item.native else { throw BoltFailure.foreignState }
            }
            pendingReclaims.removeAll()
            return true
        } catch {
            return false
        }
    }

    private func verifyConnectReclaimRoot(_ item: ConnectReclaim) async throws {
        let query: [UInt8] = switch item.control {
        case .button: [0x1B, 0x04]
        case .wheel: [0x21, 0x21]
        case .thumbwheel: [0x21, 0x50]
        }
        let root = try await request(feature: 0, function: 0, parameters: query)
        guard Array(root.prefix(3)) == item.root else { throw BoltFailure.foreignState }
    }

    private func openCandidate(connection current: UInt64) async throws {
        let recoveryRequired = uncertain
        if !recoveryRequired {
            guard await cleanup() else { throw BoltFailure.foreignState }
        }
        try checkActive()
        await closeTransport()
        try checkActive()
        resetSessionStateForDiscovery()
        if recoveryRequired {
            publish(.discovering, "Verifying a fresh Bolt session after uncertain cleanup; native routing must be confirmed before delivery.")
        }
        let candidate = makeTransport()
        transport = candidate
        connectionOpenedAt = .now
        observer = Task { [weak self] in
            for await event in candidate.events {
                guard !Task.isCancelled else { break }
                await self?.receive(event, connection: current)
            }
        }
        try await candidate.open()
        try checkActive()
        var responsive: [UInt8] = []
        for index in UInt8(1)...6 {
            do {
                let nonce = UInt8((current % 200) + UInt64(index))
                let reply = try await candidate.request(slot: index, feature: 0, function: 1, parameters: [0, 0, nonce])
                guard reply.count >= 3, reply[2] == nonce else { throw BoltFailure.stale }
                guard reply[0] == 2 || reply[0] == 4 else { throw BoltFailure.unsupported }
                responsive.append(index)
            } catch BoltFailure.unavailable {
                // A rejected root probe cannot select this slot.
            } catch BoltFailure.timeout {
                // A sleeping or empty slot is not evidence of a second device.
            }
            try checkActive()
        }
        guard responsive.count == 1 else { throw responsive.isEmpty ? BoltFailure.unavailable : BoltFailure.ambiguous }
        slot = responsive[0]
    }

    private func resetSessionStateForDiscovery() {
        capabilityTable = nil
        slot = 0
        feature = 0
        available.removeAll()
        changed.removeAll()
        armed.removeAll()
        pressed.removeAll()
        wheel = BoltWheelStatus()
        wheelMultiplier = 0
        wheelCapabilities = nil
        wheelOwnership = nil
        wheelBaseline = nil
        latestVerifiedWheelMode = nil
        pendingWheelRollback = nil
        restorePreviousSettingsOnDisconnect = false
        wheelAssociationLost = false
        physicalWheelRequest = nil
        captureOwnership = nil
        captureVerified = false
        captureBlocker = nil
        scrollGeneration &+= 1
        scrollEnabledAt = .now
        thumbwheel = ThumbwheelState()
        hardwareSettings = .init()
        hardwareOwnership.removeAll()
        hardwareRestore = false
        pendingReclaims.removeAll()
        terminalFailure = nil
        activeEndpointLocator = nil
        activeTarget = nil
        verifiedIdentity = nil
        identityFeatureIndex = nil
        model = nil
        connectionType = nil
        supportsManagement = true
        supportsButtonManagement = true
        selectedButtonControls = [.back, .forward]
        scrollAdmission.invalidate()
        thumbwheelAdmission.invalidate()
    }

    private func performEnable() async {
        var stage: BoltFailureStage?
        do {
            guard transport != nil else { throw BoltFailure.disconnected }
            guard let table = capabilityTable else { throw BoltFailure.unsupported }
            try reserveEnableAndCleanupTokens(for: table)
            stage = .capabilities
            try await verifyCapabilities(table)
            stage = .verticalWheel
            try await verifyOwnedWheelForEnable()
            stage = .thumbWheel
            try await verifyOwnedThumbwheelForEnable()
            stage = .capabilities
            guard selectedButtonControls.isSubset(of: available) else { throw BoltFailure.unsupported }
            for control in MouseControl.allCases where selectedButtonControls.contains(control) {
                stage = control == .back ? .buttonBaselineBack : .buttonBaselineForward
                guard try await reporting(control) == .baseline else { throw BoltFailure.foreignState }
                try checkActive()
            }
            for control in MouseControl.allCases where selectedButtonControls.contains(control) {
                stage = control == .back ? .buttonWriteBack : .buttonWriteForward
                try checkActive()
                changed.insert(control)
                try await mutate(control, flags: 0x03)
                try checkActive()
                stage = control == .back ? .buttonReadbackBack : .buttonReadbackForward
                guard try await reporting(control) == .diverted else { throw BoltFailure.foreignState }
                try checkActive()
            }
            armed.removeAll()
            pressed.removeAll()
            stage = nil
            enabledAt = .now
            guard !disableRequested else { throw BoltFailure.cancelled }
            guard admission.enable(generation: generation) else { throw BoltFailure.transport }
            publish(.enabled, "Bindings enabled for selected controls. Release the selected buttons to arm delivery.")
        } catch {
            guard phase != .stopping else { return }
            await fail(error, stage: (error as? BoltFailure) == .cancelled ? nil : stage)
        }
    }

    private func readCapabilities() async throws -> CapabilityTable {
        let root = try await request(feature: 0, function: 0, parameters: [0x1B, 0x04])
        try checkActive()
        guard root.count >= 3, root[0] != 0, root[1] & 0xE0 == 0,
              root[2] == (model == .mxMaster4 ? 6 : 5) else { throw BoltFailure.unsupported }
        let index = root[0]
        let count = try await request(feature: index, function: 0)
        try checkActive()
        guard let count = count.first, count > 0, count <= (root[2] == 6 ? 32 : 12) else { throw BoltFailure.unsupported }
        var rows: [[UInt8]] = []
        for index in 0..<count {
            rows.append(try await request(feature: root[0], function: 1, parameters: [index]))
            try checkActive()
        }
        feature = root[0]
        return CapabilityTable(feature: root[0], rootFlags: root[1], version: root[2], rows: rows, controls: try BoltWire.eligible(rows, model: model))
    }

    private func verifyCapabilities(_ cached: CapabilityTable, cleanup: Bool = false) async throws {
        let root = try await request(feature: 0, function: 0, parameters: [0x1B, 0x04])
        if !cleanup { try checkActive() }
        guard root.count >= 3, root[0] != 0, root[1] & 0xE0 == 0,
              root[0] == cached.feature, root[1] == cached.rootFlags, root[2] == cached.version else {
            throw BoltFailure.foreignState
        }
        let count = try await request(feature: cached.feature, function: 0)
        if !cleanup { try checkActive() }
        guard count.first == UInt8(cached.rows.count) else { throw BoltFailure.foreignState }
        for index in try eligibleCapabilityRowIndices(cached) {
            let row = try await request(feature: cached.feature, function: 1, parameters: [UInt8(index)])
            if !cleanup { try checkActive() }
            guard row == cached.rows[index] else { throw BoltFailure.foreignState }
        }
        feature = cached.feature
        available = cached.controls
    }

    private func eligibleCapabilityRowIndices(_ table: CapabilityTable) throws -> [Int] {
        guard try BoltWire.eligible(table.rows, model: model) == table.controls else { throw BoltFailure.foreignState }
        let indices = BoltWire.controls.compactMap { (control, cid, _) -> Int? in
            guard table.controls.contains(control) else { return nil }
            return table.rows.firstIndex { row in row.count >= 2 && BoltWire.word(row, 0) == cid }
        }
        guard indices.count == table.controls.count else { throw BoltFailure.malformed }
        return indices.sorted()
    }

    private func reserveEnableAndCleanupTokens(for table: CapabilityTable) throws {
        let capabilityRows = try eligibleCapabilityRowIndices(table).count
        let controlCount = selectedButtonControls.count
        let additionalPreflights = supportsManagement ? 0 : controlCount * 2
        let buttonFeatureRootReads = 1 + (wheelOwnership == nil && captureOwnership == nil ? 0 : 1) + (thumbwheel.ownership == nil && thumbwheel.capture == nil ? 0 : 1)
        var required: [UInt16: Int] = [
            0: buttonFeatureRootReads + additionalPreflights,
            UInt16(table.feature) << 8: 1 + additionalPreflights,
            UInt16(table.feature) << 8 | 1: min(15, capabilityRows + additionalPreflights),
            UInt16(table.feature) << 8 | 2: min(15, controlCount * 4 + additionalPreflights),
            UInt16(table.feature) << 8 | 3: controlCount * 2
        ]
        try addIdentityPreflightRequirements(writes: controlCount * 2, to: &required)
        required[0] = min(15, required[0, default: 0])
        try requireNativeTokenCapacity(required)
    }

    private func verifyOwnedWheelForEnable() async throws {
        if let capture = captureOwnership {
            try reserveWheelTokens(feature: capture.feature, reads: 1, setters: 0, rootReads: 1, capabilityReads: 1)
            let index = try await readWheelFeature()
            guard index == capture.feature, try await wheelMode(feature: index) == capture.capturedMode else { throw BoltFailure.foreignState }
            try checkActive()
            return
        }
        guard let ownership = wheelOwnership else { return }
        try reserveWheelTokens(feature: ownership.feature, reads: 1, setters: 0, rootReads: 1, capabilityReads: 1)
        let index = try await readWheelFeature()
        guard index == ownership.feature else { throw BoltFailure.foreignState }
        let mode = try await wheelMode(feature: index)
        try checkActive()
        if mode == ownership.original {
            wheelOwnership = nil
            latestVerifiedWheelMode = mode
            observeWheel(mode, message: "The original device wheel mode is already restored.")
            return
        }
        guard mode == ownership.target else { throw BoltFailure.foreignState }
        observeWheel(mode)
    }

    private func request(feature: UInt8, function: UInt8, parameters: [UInt8] = []) async throws -> [UInt8] {
        guard let transport else { throw BoltFailure.disconnected }
        return try await transport.request(slot: slot, feature: feature, function: function, parameters: parameters)
    }

    private func mutateRequest(feature: UInt8, function: UInt8, parameters: [UInt8],
                               duringCleanup: Bool = false, physicalWheelMode: UInt8? = nil,
                               scopedMutation: FeatureMutation? = nil) async throws -> [UInt8] {
        let revision = operationRevision
        let currentConnection = connection
        do {
            let scopedWheelCapabilities = wheelCapabilities
            let scopedThumbwheelInfo = thumbwheel.info
            if !supportsManagement {
                guard requiresExplicitAssociation, model == .mxMaster4 else { throw BoltFailure.unsupportedModel }
                switch scopedMutation {
                case .wheelCapture(let baseline):
                    guard supportsWheelCapture, wheelBaseline?.feature == feature, function == 2, parameters.count == 1,
                          baseline & 0xF8 == 0, parameters[0] & 0xF8 == 0,
                          scopedWheelCapabilities?.supportsInversion == true else { throw BoltFailure.unsupported }
                case .thumbwheel(let baseline):
                    guard supportsThumbwheelManagement, thumbwheel.feature == feature, function == 2,
                          parameters.count == 2, parameters[0] <= 1, parameters[1] <= 1,
                          baseline.statusFlags == 0, scopedThumbwheelInfo != nil else { throw BoltFailure.unsupported }
                case .button(let control):
                    guard supportsButtonManagement, capabilityTable?.controls.contains(control) == true,
                          self.feature == feature, function == 3,
                          parameters == BoltWire.bytes(BoltWire.cid(control)) + [duringCleanup ? 2 : 3, 0, 0],
                          changed.contains(control) else { throw BoltFailure.unsupported }
                case nil:
                    guard wheel.support == .supported, wheelBaseline?.feature == feature, function == 2, parameters.count == 1,
                          let physicalWheelMode, let scopedWheelCapabilities,
                          HIDPP2121V1.permitsPhysicalChange(from: physicalWheelMode, to: parameters[0], capabilities: scopedWheelCapabilities) else {
                        throw BoltFailure.unsupportedModel
                    }
                }
            }
            try checkMutationState(revision: revision, connection: currentConnection, duringCleanup: duringCleanup)
            try await verifyActiveTargetIdentityBeforeMutation(revision: revision, connection: currentConnection,
                                                               duringCleanup: duringCleanup)
            try checkMutationState(revision: revision, connection: currentConnection, duringCleanup: duringCleanup)
            if !supportsManagement {
                switch scopedMutation {
                case .thumbwheel(let baseline):
                    guard try await readThumbwheelFeature(cleanup: duringCleanup) == feature,
                          thumbwheel.info == scopedThumbwheelInfo,
                          try await thumbwheelMode(feature: feature, cleanup: true) == baseline else { throw BoltFailure.foreignState }
                case .button(let control):
                    guard let table = capabilityTable else { throw BoltFailure.unsupported }
                    try await verifyCapabilities(table, cleanup: duringCleanup)
                    guard try await reporting(control) == (duringCleanup ? .diverted : .baseline) else { throw BoltFailure.foreignState }
                case .wheelCapture(let baseline):
                    guard try await readWheelFeature(cleanup: duringCleanup) == feature, wheelCapabilities == scopedWheelCapabilities,
                          try await wheelMode(feature: feature, cleanup: true) == baseline else { throw BoltFailure.foreignState }
                case nil:
                    guard try await readWheelFeature(cleanup: duringCleanup) == feature, wheelCapabilities == scopedWheelCapabilities,
                          try await wheelMode(feature: feature, cleanup: true) == physicalWheelMode else { throw BoltFailure.foreignState }
                }
                try checkMutationState(revision: revision, connection: currentConnection, duringCleanup: duringCleanup)
            }
        } catch let failure as BoltFailure {
            throw BoltMutationPreflightFailure(failure: failure)
        } catch {
            throw BoltMutationPreflightFailure(failure: .transport)
        }
        return try await request(feature: feature, function: function, parameters: parameters)
    }

    private func verifyActiveTargetIdentityBeforeMutation(revision: UInt64, connection current: UInt64,
                                                          duringCleanup: Bool) async throws {
        guard requiresExplicitAssociation else { return }
        guard let target = activeTarget, let endpoint = activeEndpointLocator else { throw BoltFailure.associationRequired }
        guard let identityFeatureIndex else { throw BoltFailure.associationRequired }
        guard let transport else { throw BoltFailure.disconnected }
        try checkMutationState(revision: revision, connection: current, duringCleanup: duringCleanup)
        try requireIdentityPreflightCapacity(writes: 1)
        let probe = try await readIdentity(on: transport, endpoint: endpoint, slot: slot,
                                           deadline: ContinuousClock.now.advanced(by: .seconds(8)),
                                           allowCancelled: duringCleanup)
        try checkMutationState(revision: revision, connection: current, duringCleanup: duringCleanup)
        guard probe.identity == target.association.identity, probe.model == target.model,
              endpoint.connection == target.association.preferredConnection,
              probe.featureIndex == identityFeatureIndex else {
            throw BoltFailure.identityMismatch
        }
        verifiedIdentity = probe.identity
    }

    private func checkMutationState(revision: UInt64, connection current: UInt64,
                                    duringCleanup: Bool) throws {
        guard duringCleanup || !Task.isCancelled, operationRevision == revision, connection == current else {
            throw BoltFailure.cancelled
        }
        guard transport != nil else { throw BoltFailure.disconnected }
        guard duringCleanup || (!Task.isCancelled && !shutdownRequested && !disableRequested && phase != .stopping && terminalFailure == nil) else {
            throw BoltFailure.cancelled
        }
    }

    private func requireIdentityPreflightCapacity(writes: Int) throws {
        var required: [UInt16: Int] = [:]
        try addIdentityPreflightRequirements(writes: writes, to: &required)
        try requireNativeTokenCapacity(required)
    }

    private func addIdentityPreflightRequirements(writes: Int, to required: inout [UInt16: Int]) throws {
        guard writes > 0, requiresExplicitAssociation else { return }
        guard let identityFeatureIndex else { throw BoltFailure.associationRequired }
        required[1, default: 0] += writes
        required[0, default: 0] += writes
        required[UInt16(identityFeatureIndex) << 8, default: 0] += writes
    }

    private func requireNativeTokenCapacity(_ required: [UInt16: Int]) throws {
        for (signature, count) in required where count > 0 {
            guard remainingNativeTokens(feature: UInt8(signature >> 8), function: UInt8(signature & 0xFF)) >= count else {
                throw BoltFailure.tokenExhausted
            }
        }
    }

    private func remainingNativeTokens(feature: UInt8, function: UInt8) -> Int {
        transport?.availableRequestIDs(slot: slot, feature: feature, function: function) ?? 0
    }

    private func reporting(_ control: MouseControl) async throws -> BoltWire.Reporting {
        let cid = BoltWire.cid(control)
        return try BoltWire.reporting(await request(feature: feature, function: 2, parameters: BoltWire.bytes(cid)), cid: cid)
    }

    private func mutate(_ control: MouseControl, flags: UInt8, duringCleanup: Bool = false) async throws {
        let reply = try await mutateRequest(feature: feature, function: 3,
                                            parameters: BoltWire.bytes(BoltWire.cid(control)) + [flags, 0, 0],
                                            duringCleanup: duringCleanup, scopedMutation: .button(control))
        guard reply.count == 16, BoltWire.word(reply, 0) == BoltWire.cid(control) else { throw BoltFailure.malformed }
    }

    private func readWheelFeature(cleanup: Bool = false) async throws -> UInt8 {
        let root = try await request(feature: 0, function: 0, parameters: [0x21, 0x21])
        let usable = root.count >= 3 && root[0] != 0 && root[1] & 0xE0 == 0 && root[2] == 1
        if let ownedFeature = captureOwnership?.feature ?? wheelOwnership?.feature, !usable || root[0] != ownedFeature {
            wheelAssociationLost = true
            throw BoltFailure.foreignState
        }
        if !cleanup { try checkActive() }
        let index = try HIDPP2121V1.featureIndex(root)
        let reply = try await request(feature: index, function: 0)
        guard let capabilities = try? HIDPP2121V1.Capabilities(reply) else {
            if wheelOwnership != nil || captureOwnership != nil { wheelAssociationLost = true }
            throw BoltFailure.malformed
        }
        let requiresInversion = captureOwnership != nil || wheelOwnership.map { supportsManagement || $0.mask & 0x04 != 0 } == true
        if requiresInversion, !capabilities.supportsInversion {
            wheelAssociationLost = true
            throw BoltFailure.foreignState
        }
        wheelCapabilities = capabilities
        wheelMultiplier = capabilities.multiplier
        if !cleanup { try checkActive() }
        return index
    }

    private func wheelMode(feature: UInt8, cleanup: Bool = false) async throws -> UInt8 {
        guard cleanup || remainingNativeTokens(feature: feature, function: 1) > 2 else { throw BoltFailure.tokenExhausted }
        let reply = try await request(feature: feature, function: 1)
        return try HIDPP2121V1.Mode(reply).rawValue
    }

    private func observeWheel(_ mode: UInt8, applying: Bool = false, message: String? = nil) {
        wheel = BoltWheelStatus(support: .supported, observedInverted: wheelDirection.naturalScrolling(for: mode), isOwned: wheelOwnership != nil, isApplying: applying, message: message, observedHighResolution: mode & 0x02 != 0, supportsInversion: wheelCapabilities?.supportsInversion == true)
    }

    private func discoverWheel() async throws {
        do {
            let index = try await readWheelFeature()
            let mode = try await wheelMode(feature: index)
            try checkActive()
            guard mode & 0x01 == 0 else { throw BoltFailure.foreignState }
            wheelBaseline = (index, mode)
            latestVerifiedWheelMode = mode
            observeWheel(mode)
        } catch {
            try checkActive()
            let unsupported = [BoltFailure.unsupported, .foreignState, .malformed].contains(error as? BoltFailure ?? .transport)
            let reason = (error as? BoltFailure)?.errorDescription ?? "The wheel response could not be verified."
            wheel = BoltWheelStatus(support: unsupported ? .unsupported : .unknown, message: "Device wheel settings are unavailable. " + reason)
        }
    }

    private func performWheelPreferences(inverted: Bool?, highResolution: Bool?) async {
        do {
            let restoringReleasedFields = restorePreviousSettingsOnDisconnect && wheelOwnership != nil
            if inverted == nil && highResolution == nil && restoringReleasedFields {
                guard await cleanupWheel() else { throw BoltFailure.foreignState }
            } else if inverted != nil || highResolution != nil {
                guard let knownFeature = wheelBaseline?.feature else { throw BoltFailure.unsupported }
                try reserveWheelTokens(feature: knownFeature, reads: 3, setters: 1, rootReads: 1, capabilityReads: 1)
                let index = try await readWheelFeature()
                let baseline = try await wheelMode(feature: index)
                try checkActive()
                guard baseline & 0x01 == 0 else { throw BoltFailure.foreignState }
                observeWheel(baseline, applying: true)
                if let ownership = wheelOwnership {
                    if baseline == ownership.original {
                        wheelOwnership = nil
                        latestVerifiedWheelMode = baseline
                    } else if baseline != ownership.target {
                        throw BoltFailure.foreignState
                    }
                }
                guard let captured = wheelBaseline, captured.feature == index,
                      let verifiedMode = latestVerifiedWheelMode,
                      baseline & 0x02 == verifiedMode & 0x02 else { throw BoltFailure.foreignState }
                let previousMask = wheelOwnership?.mask ?? 0
                guard let capabilities = wheelCapabilities else { throw BoltFailure.unsupported }
                guard inverted == nil || capabilities.supportsInversion else {
                    observeWheel(baseline, message: "Wheel inversion is unavailable; input resolution remains available.")
                    return
                }
                let target = try HIDPP2121V1.physicalMode(
                    current: baseline, original: captured.mode, ownedMask: previousMask,
                    inverted: inverted.map { wheelDirection.hardwareInverted(for: $0) }, highResolution: highResolution,
                    restoreReleasedFields: restorePreviousSettingsOnDisconnect, capabilities: capabilities)
                if target != baseline {
                    guard try await wheelMode(feature: index) == baseline else { throw BoltFailure.foreignState }
                    try checkActive()
                    let pendingMask = previousMask | (baseline ^ target)
                    wheelOwnership = WheelOwnership(feature: index, original: captured.mode, target: target, mask: pendingMask)
                    pendingWheelRollback = baseline
                    do {
                        _ = try await mutateRequest(feature: index, function: 2, parameters: [target], physicalWheelMode: baseline)
                    } catch let preflight as BoltMutationPreflightFailure {
                        throw preflight.failure
                    } catch {
                        // A failed acknowledgement may follow an applied write; readback decides the outcome.
                    }
                    let verified = try await wheelMode(feature: index)
                    try checkActive()
                    guard verified == target else { throw BoltFailure.foreignState }
                    pendingWheelRollback = nil
                    latestVerifiedWheelMode = verified
                    let ownedMask = pendingMask & (verified ^ captured.mode)
                    wheelOwnership = ownedMask == 0 ? nil : WheelOwnership(
                        feature: index, original: captured.mode, target: verified, mask: ownedMask
                    )
                    observeWheel(verified)
                } else {
                    latestVerifiedWheelMode = baseline
                    observeWheel(baseline)
                }
            }
            try checkActive()
            if let mode = latestVerifiedWheelMode { observeWheel(mode) }
            wheel = BoltWheelStatus(support: wheel.support, observedInverted: wheel.observedInverted, isOwned: wheelOwnership != nil, message: "Device wheel preferences verified.", observedHighResolution: wheel.observedHighResolution, supportsInversion: wheel.supportsInversion)
            let activePhase = phase
            guard activePhase == .ready || activePhase == .enabled else { return }
            let message = activePhase == .enabled
                ? "Wheel preference verified while button bindings remain enabled."
                : "Wheel preference verified for the connected device."
            publish(activePhase, message)
        } catch {
            guard phase != .stopping else { return }
            await fail(error)
        }
    }

    private func reserveWheelTokens(feature: UInt8, reads: Int, setters: Int, rootReads: Int = 0,
                                    capabilityReads: Int = 0, identityPreflights: Int? = nil) throws {
        var required: [UInt16: Int] = [
            UInt16(feature) << 8 | 1: reads + 2,
            UInt16(feature) << 8 | 2: setters + 1
        ]
        let wheelPreflights = supportsManagement ? 0 : setters + 1
        required[UInt16(feature) << 8 | 1, default: 0] += wheelPreflights
        required[0, default: 0] += rootReads + wheelPreflights
        required[UInt16(feature) << 8, default: 0] += capabilityReads + wheelPreflights
        let identityWrites = identityPreflights ?? (setters > 0 ? setters + 1 : 0)
        try addIdentityPreflightRequirements(writes: identityWrites, to: &required)
        try requireNativeTokenCapacity(required)
    }

    private func beginCapture() async throws {
        guard let knownFeature = wheelBaseline?.feature else { throw BoltFailure.unsupported }
        try reserveWheelTokens(feature: knownFeature, reads: 2, setters: 1, rootReads: 1, capabilityReads: 1)
        let index = try await readWheelFeature()
        guard wheelMultiplier != 0 else {
            captureBlocker = "The device reports a zero wheel multiplier; scroll amount is unavailable."
            return
        }
        let nativeMode = try await wheelMode(feature: index)
        try checkActive()
        guard index == knownFeature, nativeMode & 0x01 == 0,
              nativeMode == latestVerifiedWheelMode else { throw BoltFailure.foreignState }
        guard scrollPostingPreflight() else {
            captureBlocker = "Input posting permission changed before capture; native scrolling remains active."
            return
        }
        let capture = CaptureOwnership(feature: index, nativeMode: nativeMode, capturedMode: (nativeMode & ~0x04) | 0x01,
                                       direction: wheelDirection)
        captureOwnership = capture
        captureVerified = false
        scrollGeneration &+= 1
        scrollAdmission.prepare(generation: scrollGeneration)
        do { _ = try await mutateRequest(feature: index, function: 2, parameters: [capture.capturedMode], scopedMutation: .wheelCapture(nativeMode)) }
        catch let preflight as BoltMutationPreflightFailure { throw preflight.failure }
        catch { }
        let verified = try await wheelMode(feature: index)
        try checkActive()
        guard verified == capture.capturedMode else { throw BoltFailure.foreignState }
        observeWheel(verified)
        guard scrollPostingPreflight() else {
            captureBlocker = "Input posting permission changed during capture; native scrolling restored."
            guard await cleanupCapture(final: false) else { throw BoltFailure.foreignState }
            return
        }
        captureVerified = true
        scrollEnabledAt = .now
        guard scrollAdmission.enable(generation: scrollGeneration) else { throw BoltFailure.cancelled }
    }

    private func cleanupCapture(final: Bool) async -> Bool {
        invalidateScrollAdmission()
        captureVerified = false
        guard let capture = captureOwnership else { return true }
        var restoration = capture.nativeMode
        if final, let physical = wheelOwnership {
            if restorePreviousSettingsOnDisconnect {
                restoration = (restoration & ~physical.mask) | (physical.original & physical.mask)
            } else if let pendingWheelRollback {
                restoration = pendingWheelRollback
            }
        }
        do {
            if !final { try reserveWheelTokens(feature: capture.feature, reads: 2, setters: 1, identityPreflights: 1) }
            guard !wheelAssociationLost else { throw BoltFailure.foreignState }
            let current = try await wheelMode(feature: capture.feature, cleanup: true)
            guard current == capture.capturedMode || current == capture.nativeMode || current == restoration else { throw BoltFailure.foreignState }
            if current != restoration {
                do { _ = try await mutateRequest(feature: capture.feature, function: 2, parameters: [restoration], duringCleanup: true, scopedMutation: .wheelCapture(current)) }
                catch let preflight as BoltMutationPreflightFailure { throw preflight.failure }
                catch { }
                guard try await wheelMode(feature: capture.feature, cleanup: true) == restoration else { throw BoltFailure.foreignState }
            }
            captureOwnership = nil
            if final { wheelOwnership = nil; pendingWheelRollback = nil }
            latestVerifiedWheelMode = restoration
            observeWheel(restoration, message: "Temporary scroll capture released; native routing restored.")
            return true
        } catch {
            wheel = BoltWheelStatus(support: wheel.support, isOwned: true,
                                   message: "Scroll capture cleanup is unverified. Fresh discovery must verify native wheel routing before delivery can resume.", captureBlocker: "Native wheel routing could not be verified.", supportsInversion: wheel.supportsInversion)
            return false
        }
    }

    private func refreshWheelCaptureStatus() {
        wheel = BoltWheelStatus(support: wheel.support, observedInverted: wheel.observedInverted,
                               isOwned: wheelOwnership != nil || captureOwnership != nil, isApplying: wheel.isApplying,
                               message: wheel.message, observedHighResolution: wheel.observedHighResolution,
                               captureActive: captureOwnership != nil && captureVerified && captureBlocker == nil,
                               captureBlocker: captureBlocker ?? (uncertain ? wheel.captureBlocker : nil),
                               effectiveInverted: captureOwnership.map { $0.direction.naturalScrolling(for: $0.nativeMode) }, supportsInversion: wheel.supportsInversion)
    }

    private func rejectStaleScrollAdmission(generation requestedGeneration: UInt64) async {
        guard requestedGeneration == scrollGeneration, captureOwnership != nil else { return }
        guard let intent = recordFailure(BoltFailure.stale, connection: connection) else { return }
        await scheduleFailure(intent)
    }

    private func cleanupWheel() async -> Bool {
        if captureOwnership != nil { return await cleanupCapture(final: true) }
        guard let ownership = wheelOwnership else {
            wheel = BoltWheelStatus(support: wheel.support, observedInverted: wheel.observedInverted, message: wheel.message, observedHighResolution: wheel.observedHighResolution, supportsInversion: wheel.supportsInversion)
            return true
        }
        let restoration: UInt8
        if restorePreviousSettingsOnDisconnect {
            restoration = (ownership.target & ~ownership.mask) | (ownership.original & ownership.mask)
        } else if let pendingWheelRollback {
            restoration = pendingWheelRollback
        } else {
            wheelOwnership = nil
            wheel = BoltWheelStatus(
                support: wheel.support, observedInverted: wheel.observedInverted,
                message: "Wheel restoration is disabled; the device keeps its current settings.",
                observedHighResolution: wheel.observedHighResolution,
                supportsInversion: wheel.supportsInversion
            )
            return true
        }
        do {
            guard !wheelAssociationLost else { throw BoltFailure.foreignState }
            let current = try await wheelMode(feature: ownership.feature, cleanup: true)
            observeWheel(current)
            if current != restoration {
                guard current == ownership.target || pendingWheelRollback == current else { throw BoltFailure.foreignState }
                do {
                    _ = try await mutateRequest(feature: ownership.feature, function: 2, parameters: [restoration], duringCleanup: true, physicalWheelMode: current)
                } catch let preflight as BoltMutationPreflightFailure {
                    throw preflight.failure
                } catch {
                    // Restoration is established by a separate read even if the acknowledgement fails.
                }
                let verified = try await wheelMode(feature: ownership.feature, cleanup: true)
                observeWheel(verified)
                guard verified == restoration else { throw BoltFailure.foreignState }
            }
            wheelOwnership = nil
            pendingWheelRollback = nil
            latestVerifiedWheelMode = restoration
            observeWheel(restoration, message: restorePreviousSettingsOnDisconnect
                ? "Previous device wheel mode restored."
                : "Unverified wheel change rolled back.")
            return true
        } catch {
            wheel = BoltWheelStatus(support: wheel.support, observedInverted: nil, isOwned: true, message: "Wheel cleanup is unverified. Fresh discovery must verify wheel routing before bindings can be enabled.", supportsInversion: wheel.supportsInversion)
            return false
        }
    }

    private func readThumbwheelFeature(cleanup: Bool = false) async throws -> UInt8 {
        let root = try await request(feature: 0, function: 0, parameters: [0x21, 0x50])
        let usable = root.count >= 3 && root[0] != 0 && root[1] & 0xE0 == 0 && root[2] == 0
        if let index = thumbwheel.feature, thumbwheel.capture != nil || thumbwheel.ownership != nil,
           !usable || root[0] != index {
            thumbwheel.associationLost = true
            throw BoltFailure.foreignState
        }
        if !cleanup { try checkActive() }
        guard usable else { throw BoltFailure.unsupported }
        let info = try await request(feature: root[0], function: 0)
        thumbwheel.info = try ThumbwheelState.Info(info)
        if !cleanup { try checkActive() }
        return root[0]
    }

    private func thumbwheelMode(feature: UInt8, cleanup: Bool = false) async throws -> ThumbwheelState.Mode {
        guard cleanup || remainingNativeTokens(feature: feature, function: 1) > 2 else { throw BoltFailure.tokenExhausted }
        return try ThumbwheelState.Mode.decode(await request(feature: feature, function: 1))
    }

    private func discoverThumbwheel() async throws {
        do {
            let index = try await readThumbwheelFeature()
            let mode = try await thumbwheelMode(feature: index)
            try checkActive()
            guard !mode.diverted, mode.statusFlags == 0 else { throw BoltFailure.foreignState }
            thumbwheel.feature = index
            thumbwheel.baseline = mode
            thumbwheel.latest = mode
            thumbwheel.support = .supported
        } catch {
            try checkActive()
            guard let failure = error as? BoltFailure, [.unsupported, .malformed, .foreignState].contains(failure) else { throw error }
            thumbwheel.support = .unsupported
            thumbwheel.message = "Device thumb-wheel settings are unavailable for this session."
        }
    }

    private func reserveThumbwheelTokens(feature: UInt8, reads: Int, setters: Int, rootReads: Int = 0,
                                         infoReads: Int = 0, identityPreflights: Int? = nil) throws {
        var required: [UInt16: Int] = [
            UInt16(feature) << 8 | 1: reads + 2,
            UInt16(feature) << 8 | 2: setters + 1
        ]
        let featurePreflights = supportsManagement ? 0 : setters + 1
        required[UInt16(feature) << 8 | 1, default: 0] += featurePreflights
        required[0, default: 0] += rootReads + featurePreflights
        required[UInt16(feature) << 8, default: 0] += infoReads + featurePreflights
        let identityWrites = identityPreflights ?? (setters > 0 ? setters + 1 : 0)
        try addIdentityPreflightRequirements(writes: identityWrites, to: &required)
        try requireNativeTokenCapacity(required)
    }

    private func performThumbwheelPreference(inverted: Bool?) async throws {
        guard let index = thumbwheel.feature, let original = thumbwheel.baseline else { throw BoltFailure.unsupported }
        guard let inverted else {
            if thumbwheel.restore { guard await cleanupThumbwheel(final: true) else { throw BoltFailure.foreignState } }
            else { thumbwheel.ownership = nil }
            return
        }
        try reserveThumbwheelTokens(feature: index, reads: 3, setters: 1, rootReads: 1, infoReads: 1)
        guard try await readThumbwheelFeature() == index else { throw BoltFailure.foreignState }
        let current = try await thumbwheelMode(feature: index)
        try checkActive()
        guard !current.diverted, current.statusFlags == 0 else { throw BoltFailure.foreignState }
        if let owned = thumbwheel.ownership {
            guard current == owned.target || current == owned.original else { throw BoltFailure.foreignState }
            if current == owned.original { thumbwheel.ownership = nil }
        }
        let target = ThumbwheelState.Mode(diverted: false, inverted: inverted)
        thumbwheel.latest = current
        guard target != current else { return }
        guard try await thumbwheelMode(feature: index) == current else { throw BoltFailure.foreignState }
        try checkActive()
        thumbwheel.ownership = .init(original: original, target: target)
        thumbwheel.pendingRollback = current
        do { _ = try await mutateRequest(feature: index, function: 2, parameters: target.parameters, scopedMutation: .thumbwheel(current)) }
        catch let preflight as BoltMutationPreflightFailure { throw preflight.failure }
        catch { }
        let verified = try await thumbwheelMode(feature: index)
        try checkActive()
        guard verified == target else { throw BoltFailure.foreignState }
        thumbwheel.pendingRollback = nil
        thumbwheel.latest = verified
        thumbwheel.ownership = verified == original ? nil : .init(original: original, target: verified)
    }

    private func beginThumbwheelCapture() async throws {
        guard let index = thumbwheel.feature else { throw BoltFailure.unsupported }
        try reserveThumbwheelTokens(feature: index, reads: 2, setters: 1, rootReads: 1, infoReads: 1)
        guard try await readThumbwheelFeature() == index else { throw BoltFailure.foreignState }
        let native = try await thumbwheelMode(feature: index)
        try checkActive()
        guard !native.diverted, native.statusFlags == 0, native == thumbwheel.latest else { throw BoltFailure.foreignState }
        guard scrollPostingPreflight() else {
            thumbwheel.blocker = "Input posting permission changed before thumb-wheel capture; native scrolling remains active."
            return
        }
        let capture = ThumbwheelState.Capture(native: native)
        thumbwheel.capture = capture
        thumbwheel.captureVerified = false
        thumbwheel.generation &+= 1
        thumbwheelAdmission.prepare(generation: thumbwheel.generation)
        do { _ = try await mutateRequest(feature: index, function: 2, parameters: capture.captured.parameters, scopedMutation: .thumbwheel(native)) }
        catch let preflight as BoltMutationPreflightFailure { throw preflight.failure }
        catch { }
        let verified = try await thumbwheelMode(feature: index)
        try checkActive()
        guard verified == capture.captured else { throw BoltFailure.foreignState }
        thumbwheel.latest = verified
        guard scrollPostingPreflight() else {
            thumbwheel.blocker = "Input posting permission changed during thumb-wheel capture; native scrolling restored."
            guard await cleanupThumbwheel(final: false) else { throw BoltFailure.foreignState }
            return
        }
        thumbwheel.captureVerified = true
        thumbwheel.enabledAt = .now
        guard thumbwheelAdmission.enable(generation: thumbwheel.generation) else { throw BoltFailure.cancelled }
    }

    private func cleanupThumbwheel(final: Bool) async -> Bool {
        invalidateThumbwheelAdmission()
        thumbwheel.captureVerified = false
        guard let index = thumbwheel.feature else { return true }
        let capture = thumbwheel.capture
        let owned = thumbwheel.ownership
        if !final, capture == nil { return true }
        guard capture != nil || owned != nil else { return true }
        if capture == nil, !thumbwheel.restore, thumbwheel.pendingRollback == nil {
            thumbwheel.ownership = nil
            return true
        }
        let restoration: ThumbwheelState.Mode
        if final, thumbwheel.restore, let owned { restoration = owned.original }
        else if final, let rollback = thumbwheel.pendingRollback { restoration = rollback }
        else if let capture { restoration = capture.native }
        else if let owned { restoration = owned.original }
        else { return true }
        do {
            if !final { try reserveThumbwheelTokens(feature: index, reads: 2, setters: 1, identityPreflights: 1) }
            guard !thumbwheel.associationLost else { throw BoltFailure.foreignState }
            let current = try await thumbwheelMode(feature: index, cleanup: true)
            let attributable = [capture?.captured, capture?.native, owned?.target, thumbwheel.pendingRollback, restoration].compactMap { $0 }
            guard attributable.contains(current) else { throw BoltFailure.foreignState }
            if current != restoration {
                do { _ = try await mutateRequest(feature: index, function: 2, parameters: restoration.parameters, duringCleanup: true, scopedMutation: .thumbwheel(current)) }
                catch let preflight as BoltMutationPreflightFailure { throw preflight.failure }
                catch { }
                guard try await thumbwheelMode(feature: index, cleanup: true) == restoration else { throw BoltFailure.foreignState }
            }
            thumbwheel.capture = nil
            thumbwheel.latest = restoration
            if final { thumbwheel.ownership = nil; thumbwheel.pendingRollback = nil }
            thumbwheel.message = "Temporary thumb-wheel capture released; native routing restored."
            return true
        } catch {
            thumbwheel.latest = nil
            thumbwheel.blocker = "Native thumb-wheel routing could not be verified."
            thumbwheel.message = "Thumb-wheel cleanup is unverified. Fresh discovery must verify thumb-wheel routing before bindings can be enabled."
            return false
        }
    }

    private func verifyOwnedThumbwheelForEnable() async throws {
        guard let index = thumbwheel.feature, thumbwheel.capture != nil || thumbwheel.ownership != nil else { return }
        try reserveThumbwheelTokens(feature: index, reads: 1, setters: 0, rootReads: 1, infoReads: 1)
        guard try await readThumbwheelFeature() == index else { throw BoltFailure.foreignState }
        let current = try await thumbwheelMode(feature: index)
        try checkActive()
        if let capture = thumbwheel.capture {
            guard current == capture.captured else { throw BoltFailure.foreignState }
        } else if let owned = thumbwheel.ownership {
            guard current == owned.target || current == owned.original else { throw BoltFailure.foreignState }
            if current == owned.original { thumbwheel.ownership = nil }
        }
        thumbwheel.latest = current
    }

    private func rejectStaleThumbwheelAdmission(generation requestedGeneration: UInt64) async {
        guard requestedGeneration == thumbwheel.generation, thumbwheel.capture != nil else { return }
        guard let intent = recordFailure(BoltFailure.stale, connection: connection) else { return }
        await scheduleFailure(intent)
    }

    private func cleanup() async -> Bool {
        let pendingReclaim = pendingReclaims.first
        let connectRestored = await cleanupConnectReclaims()
        if !connectRestored, let pendingReclaim {
            switch pendingReclaim.control {
            case .wheel: freshWheelRoutingRequired = true
            case .thumbwheel: freshThumbwheelRoutingRequired = true
            case .button: break
            }
        }
        let wheelRoutingWasOwned = captureOwnership != nil || wheelOwnership != nil || pendingWheelRollback != nil
        let wheelRestored = await cleanupWheel()
        if !wheelRestored, wheelRoutingWasOwned {
            freshWheelRoutingRequired = true
            if let baseline = wheelBaseline, let capabilities = wheelCapabilities {
                wheelRecovery = .init(ownership: wheelOwnership, capture: captureOwnership, baseline: baseline,
                                      capabilities: capabilities, latest: latestVerifiedWheelMode,
                                      rollback: pendingWheelRollback, restore: restorePreviousSettingsOnDisconnect)
            }
        } else if wheelRestored { wheelRecovery = nil }
        let thumbwheelRoutingWasOwned = thumbwheel.capture != nil || thumbwheel.ownership != nil || thumbwheel.pendingRollback != nil
        let thumbwheelRestored = await cleanupThumbwheel(final: true)
        if !thumbwheelRestored, thumbwheelRoutingWasOwned {
            freshThumbwheelRoutingRequired = true
            thumbwheelRecovery = thumbwheel
        } else if thumbwheelRestored { thumbwheelRecovery = nil }
        let buttonsRestored = await cleanupButtons()
        let hardwareRestored = await cleanupHardwareSettings()
        let restored = connectRestored && wheelRestored && thumbwheelRestored && buttonsRestored && hardwareRestored
        uncertain = uncertain || !restored
        return restored && !uncertain
    }

    private func cleanupButtons() async -> Bool {
        var restored = true
        for control in MouseControl.allCases where changed.contains(control) {
            do {
                let observed = try await reporting(control)
                if observed == .diverted {
                    try await mutate(control, flags: 0x02, duringCleanup: true)
                    guard try await reporting(control) == .baseline else { throw BoltFailure.foreignState }
                } else if observed != .baseline {
                    throw BoltFailure.foreignState
                }
                changed.remove(control)
                buttonRecovery.removeValue(forKey: control)
            } catch {
                restored = false
                if let table = capabilityTable,
                   let row = table.rows.first(where: { BoltWire.word($0, 0) == BoltWire.cid(control) }) {
                    buttonRecovery[control] = .init(flags: table.rootFlags, version: table.version, row: row)
                }
            }
        }
        return restored
    }

    private func checkActive() throws {
        if let terminalFailure { throw terminalFailure }
        guard !Task.isCancelled, phase != .stopping else { throw BoltFailure.cancelled }
    }

    private func fail(_ error: Error, stage: BoltFailureStage? = nil, sourceFileID: String = #fileID, sourceLine: UInt = #line) async {
        deviceResponding = false
        admission.invalidate()
        invalidateScrollAdmission()
        invalidateThumbwheelAdmission()
        generation &+= 1
        armed.removeAll()
        pressed.removeAll()
        publish(.stopping, "Delivery stopped; checking temporary diversion cleanup.")
        let restored = await cleanup()
        uncertain = uncertain || !restored
        if uncertain { uncertainTarget = activeTarget ?? uncertainTarget }
        else { uncertainTarget = nil }
        await closeTransport()
        available.removeAll()
        let failure: BoltFailure
        if let preflight = error as? BoltMutationPreflightFailure {
            failure = preflight.failure
        } else {
            failure = (error as? BoltFailure) ?? .transport
        }
        let message = failure.errorDescription ?? "The Bolt session failed."
        let context = BoltFailureContext(code: failure.diagnosticCode, sourceFileID: sourceFileID, sourceLine: sourceLine, stage: stage)
        publish(.failed, message + (restored ? " Delivery stopped." : " Cleanup is unverified. Delivery is stopped; fresh discovery must verify capabilities and native routing before bindings can be enabled."), failure: context)
    }

    private func closeTransport() async {
        connectionMonitor?.cancel()
        connectionMonitor = nil
        deviceResponding = false
        observer?.cancel()
        observer = nil
        if let transport { await transport.close() }
        transport = nil
        activeEndpointLocator = nil
        activeTarget = nil
        verifiedIdentity = nil
        identityFeatureIndex = nil
        model = nil
        connectionType = nil
        supportsManagement = true
        deviceInformation = .init()
        batteryFeature = nil
        batteryEventRevision &+= 1
    }

    private func startConnectionMonitor(connection current: UInt64) {
        connectionMonitor?.cancel()
        connectionMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                guard await self.checkConnection(connection: current) else { return }
            }
        }
    }

    private func checkConnection(connection current: UInt64) async -> Bool {
        guard !Task.isCancelled, current == connection, transport != nil,
              !shutdownRequested, terminalFailure == nil else { return false }
        guard !operationHeld, !disableRequested,
              phase == .ready || phase == .enabled else { return true }
        await acquireOperation()
        defer { releaseOperation() }
        let revision = operationRevision
        connectionProbeNonce &+= 1
        let nonce = connectionProbeNonce
        do {
            let reply = try await request(feature: 0, function: 1, parameters: [0, 0, nonce])
            guard current == connection, !shutdownRequested, !Task.isCancelled else { return false }
            guard revision == operationRevision else { return true }
            try checkActive()
            guard reply.count >= 3, reply[2] == nonce else { throw BoltFailure.stale }
            guard reply[0] == 2 || reply[0] == 4 else { throw BoltFailure.unsupported }
            return true
        } catch {
            guard current == connection, !shutdownRequested, !Task.isCancelled else { return false }
            guard revision == operationRevision else { return true }
            _ = recordFailure(error, connection: current)
            await reconcileTerminalFailure()
            return false
        }
    }

    private func receive(_ event: BoltTransportEvent, connection current: UInt64) async {
        guard current == connection, transport != nil else { return }
        switch event {
        case .failure(let error):
            guard phase != .stopping, phase != .failed else { return }
            guard let intent = recordFailure(error, connection: current) else { return }
            if !operationHeld { await scheduleFailure(intent) }
        case .report(let report, let arrival):
            if receiveBatteryInformation(report, at: arrival) { return }
            if let capture = thumbwheel.capture, let index = thumbwheel.feature, thumbwheel.captureVerified,
               terminalFailure == nil, phase == .ready || phase == .enabled || phase == .enabling {
                do {
                    if let movement = try BoltWire.thumbwheelMovement(report, slot: slot, feature: index) {
                        let age = arrival.duration(to: .now)
                        guard age >= .zero, age <= .milliseconds(250) else { throw BoltFailure.stale }
                        guard arrival >= thumbwheel.enabledAt else { return }
                        guard movement.state != 0 else { return }
                        let rotation = Double(movement.rotation) * (capture.native.inverted ? -1 : 1)
                        if case .dropped = continuation.yield(.thumbwheel(rotation: rotation, state: movement.state,
                                                                        generation: thumbwheel.generation, observedAt: arrival)) {
                            throw BoltFailure.overflow
                        }
                        return
                    }
                } catch {
                    guard let intent = recordFailure(error, connection: current) else { return }
                    if !operationHeld { await scheduleFailure(intent) }
                    return
                }
            }
            if let capture = captureOwnership, captureVerified, terminalFailure == nil,
               phase == .ready || phase == .enabled || phase == .enabling {
                do {
                    if let movement = try BoltWire.wheelMovement(report, slot: slot, feature: capture.feature) {
                        let age = arrival.duration(to: .now)
                        guard age >= .zero, age <= .milliseconds(250) else { throw BoltFailure.stale }
                        guard arrival >= scrollEnabledAt else { return }
                        let divisor = movement.highResolution ? Double(wheelMultiplier) : 1
                        guard divisor > 0 else { throw BoltFailure.malformed }
                        let direction = capture.direction.naturalScrolling(for: capture.nativeMode) ? -1.0 : 1.0
                        let vertical = Double(movement.vertical) / divisor * direction
                        let horizontal = Double(movement.horizontal) / divisor
                        guard vertical != 0 || horizontal != 0 else { return }
                        if case .dropped = continuation.yield(.scroll(vertical: vertical, horizontal: horizontal, generation: scrollGeneration, observedAt: arrival)) {
                            throw BoltFailure.overflow
                        }
                        return
                    }
                } catch {
                    guard let intent = recordFailure(error, connection: current) else { return }
                    if !operationHeld { await scheduleFailure(intent) }
                    return
                }
            }
            guard phase == .enabled, terminalFailure == nil, !disableRequested else { return }
            do {
                guard let snapshot = try BoltWire.snapshot(report, slot: slot, feature: feature) else { return }
                let down = snapshot.intersection(selectedButtonControls)
                guard arrival >= enabledAt else { return }
                guard arrival.duration(to: .now) <= .milliseconds(250) else { throw BoltFailure.stale }
                let newlyPressed = down.subtracting(pressed).intersection(armed)
                armed.formUnion(selectedButtonControls.subtracting(down))
                pressed = down
                for control in MouseControl.allCases where newlyPressed.contains(control) {
                    if case .dropped = continuation.yield(.press(control, generation: generation, observedAt: arrival)) {
                        guard let intent = recordFailure(BoltFailure.overflow, connection: current) else { return }
                        if !operationHeld { await scheduleFailure(intent) }
                        return
                    }
                }
            } catch {
                guard let intent = recordFailure(error, connection: current) else { return }
                if !operationHeld { await scheduleFailure(intent) }
            }
        }
    }

    private func receiveBatteryInformation(_ report: [UInt8], at arrival: ContinuousClock.Instant) -> Bool {
        guard let batteryFeature, report.count >= 4, report[1] == slot,
              report[2] == batteryFeature.index, report[3] == 0 else { return false }
        guard terminalFailure == nil, !shutdownRequested,
              phase == .ready || phase == .enabled || phase == .enabling else { return true }
        batteryEventRevision &+= 1
        do {
            let age = arrival.duration(to: .now)
            guard report[0] == 0x11, report.count == 20 else { throw BoltFailure.malformed }
            guard arrival >= connectionOpenedAt, age >= .zero, age <= .milliseconds(250) else { throw BoltFailure.stale }
            deviceInformation.battery = try BoltDeviceInformationReader.battery(Array(report.dropFirst(4)),
                capabilities: batteryFeature.capabilities, observedAt: Date.now.addingTimeInterval(-Double(age.components.seconds) - Double(age.components.attoseconds) / 1e18))
            deviceInformation.batteryState = .available
        } catch {
            deviceInformation.battery = nil
            deviceInformation.batteryState = .unavailable
        }
        publishDeviceInformation()
        return true
    }

    private func recordFailure(_ error: Error, connection current: UInt64) -> FailureIntent? {
        guard current == connection, transport != nil, terminalFailure == nil,
              phase != .stopping, phase != .failed else { return nil }
        let failure = (error as? BoltFailure) ?? .transport
        admission.invalidate()
        invalidateScrollAdmission()
        invalidateThumbwheelAdmission()
        terminalFailure = failure
        generation &+= 1
        armed.removeAll()
        pressed.removeAll()
        guard phase == .ready || phase == .enabled else { return nil }
        return FailureIntent(connection: current, generation: generation, phase: phase, failure: failure)
    }

    private func scheduleFailure(_ intent: FailureIntent) async {
        await acquireOperation()
        defer { releaseOperation() }
        guard !shutdownRequested,
              connection == intent.connection,
              generation == intent.generation,
              phase == intent.phase,
              terminalFailure == intent.failure,
              phase == .ready || phase == .enabled else { return }
        await fail(intent.failure)
    }

    private func reconcileTerminalFailure() async {
        guard let terminalFailure, phase == .enabled || phase == .ready else { return }
        await fail(terminalFailure)
    }

    private func rejectStaleAdmission(generation requestedGeneration: UInt64) async {
        guard requestedGeneration == generation, phase == .enabled else { return }
        guard let intent = recordFailure(BoltFailure.stale, connection: connection) else { return }
        await scheduleFailure(intent)
    }

    private func publish(_ phase: BoltPhase, _ message: String, failure: BoltFailureContext? = nil) {
        self.phase = phase
        statusMessage = message
        statusFailure = failure
        refreshWheelCaptureStatus()
        let result = continuation.yield(.status(BoltStatus(phase: phase, message: message, availableControls: available,
                                                       generation: generation, cleanupUncertain: uncertain, wheel: wheel,
                                                       thumbwheel: thumbwheel.status, failure: failure,
                                                       deviceInformation: deviceInformation, deviceResponding: deviceResponding,
                                                       supportsManagement: supportsManagement, model: model,
                                                       connection: connectionType, verifiedIdentity: verifiedIdentity,
                                                       hardwareSettings: hardwareSettings,
                                                       supportsWheelCapture: supportsWheelCapture,
                                                       supportsThumbwheelManagement: supportsThumbwheelManagement,
                                                       supportsButtonManagement: supportsButtonManagement)))
        if case .dropped(let event) = result {
            switch event {
            case .status: return
            case .press, .scroll, .thumbwheel: break
            }
            guard let intent = recordFailure(BoltFailure.overflow, connection: connection) else { return }
            Task { await self.scheduleFailure(intent) }
        }
    }
}
