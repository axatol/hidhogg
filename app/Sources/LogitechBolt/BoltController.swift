import Foundation
import HidhoggDomain

public actor BoltController {
    public nonisolated let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let scrollPostingPreflight: @Sendable () -> Bool
    private let makeTransport: @Sendable () -> any BoltTransport
    private nonisolated let scrollAdmission: BoltPressAdmission
    private nonisolated let thumbwheelAdmission: BoltPressAdmission
    private nonisolated let admission: BoltPressAdmission
    private var transport: (any BoltTransport)?
    private var observer: Task<Void, Never>?
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
    private var armed = Set<MouseControl>()
    private var pressed = Set<MouseControl>()
    private var terminalFailure: BoltFailure?
    private var enabledAt: ContinuousClock.Instant = .now
    private var wheel = BoltWheelStatus()
    private var wheelOwnership: WheelOwnership?
    private var wheelBaseline: (feature: UInt8, mode: UInt8)?
    private var latestVerifiedWheelMode: UInt8?
    private var pendingWheelRollback: UInt8?
    private var restorePreviousSettingsOnDisconnect = false
    private var wheelAssociationLost = false
    private var wheelMultiplier: UInt8 = 0
    private var captureOwnership: CaptureOwnership?
    private var captureVerified = false
    private var scrollGeneration: UInt64 = 0
    private var scrollEnabledAt: ContinuousClock.Instant = .now
    private var captureBlocker: String?
    private var physicalWheelRequest: PhysicalWheelRequest?
    private var thumbwheel = ThumbwheelState()

    private struct PhysicalWheelRequest: Equatable {
        let inverted: Bool?
        let highResolution: Bool?
        let restore: Bool
    }

    private struct CaptureOwnership {
        let feature: UInt8
        let nativeMode: UInt8
        let capturedMode: UInt8
    }

    private struct WheelOwnership {
        let feature: UInt8
        let original: UInt8
        let target: UInt8
        let mask: UInt8
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

    public init(scrollPostingPreflight: @escaping @Sendable () -> Bool = { false }) {
        let admission = BoltPressAdmission()
        let scrollAdmission = BoltPressAdmission()
        let thumbwheelAdmission = BoltPressAdmission()
        self.init(admission: admission, scrollAdmission: scrollAdmission, thumbwheelAdmission: thumbwheelAdmission, scrollPostingPreflight: scrollPostingPreflight, makeTransport: {
            IOKitBoltTransport(onTerminal: { admission.invalidate(); scrollAdmission.invalidate(); thumbwheelAdmission.invalidate() })
        })
    }

    init(bufferSize: Int = 32, admission: BoltPressAdmission = BoltPressAdmission(), scrollAdmission: BoltPressAdmission = BoltPressAdmission(), thumbwheelAdmission: BoltPressAdmission = BoltPressAdmission(), scrollPostingPreflight: @escaping @Sendable () -> Bool = { false }, makeTransport: @escaping @Sendable () -> any BoltTransport) {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        events = stream.stream
        continuation = stream.continuation
        self.makeTransport = makeTransport
        self.scrollPostingPreflight = scrollPostingPreflight
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
        let requestedRevision = operationRevision
        guard !shutdownRequested, !disableRequested else {
            publish(phase, "Discovery was cancelled by the current session transition.")
            return
        }
        await acquireOperation()
        defer { releaseOperation() }
        guard requestedRevision == operationRevision, !shutdownRequested, !disableRequested,
              phase != .enabled, phase != .enabling, phase != .stopping, !uncertain else {
            publish(phase, "Discovery is unavailable while the current Bolt session is active or uncertain.")
            return
        }
        generation &+= 1
        admission.prepare(generation: generation)
        terminalFailure = nil
        connection &+= 1
        let current = connection
        publish(.discovering, "Discovering a Bolt candidate; model identity is unverified.")
        await performDiscovery(connection: current)
        await reconcileTerminalFailure()
    }

    public func enable() async {
        let requestedRevision = operationRevision
        guard !shutdownRequested, !disableRequested else {
            publish(phase, "Enable was cancelled by the current session transition.")
            return
        }
        await acquireOperation()
        defer { releaseOperation() }
        guard requestedRevision == operationRevision, !shutdownRequested, !disableRequested,
              phase == .ready, transport != nil, !uncertain,
              changed.isEmpty, available == Set(MouseControl.allCases) else {
            publish(phase, "Enable requires a ready Bolt handle with fresh eligible Back and Forward controls.")
            return
        }
        generation &+= 1
        admission.prepare(generation: generation)
        terminalFailure = nil
        publish(.enabling, "Checking current button capabilities and native reporting.")
        await performEnable()
        await reconcileTerminalFailure()
    }

    public func disable() async { await disableBindings() }
    public func stop() async { await shutdown() }

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
        await applyWheelPreferences(inverted: inverted, highResolution: highResolution,
                                   restorePreviousSettingsOnDisconnect: restorePreviousSettingsOnDisconnect,
                                   amount: nil, scrollPostingAllowed: false)
    }

    public func applyWheelPreferences(inverted: Bool?, highResolution: Bool?, restorePreviousSettingsOnDisconnect: Bool,
                                      amount: Double?, scrollPostingAllowed: Bool) async {
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
        self.restorePreviousSettingsOnDisconnect = restorePreviousSettingsOnDisconnect
        do {
            if let amount, !amount.isFinite || !(0.25...10).contains(amount) { throw BoltFailure.malformed }
            let requested = PhysicalWheelRequest(inverted: inverted, highResolution: highResolution, restore: restorePreviousSettingsOnDisconnect)
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
                                       observedHighResolution: wheel.observedHighResolution)
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
        await closeTransport()
        available.removeAll()
        publish(restored ? .idle : .failed, restored ? "Disconnected. Temporary diversion is off." : "Cleanup is unverified. Rearming is blocked; resolve receiver state before restarting.")
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
        do {
            try await openCandidate(connection: current)
            let table = try await readCapabilities()
            capabilityTable = table
            available = table.controls
            try await discoverWheel()
            try checkActive()
            publish(.ready, "Connected Bolt candidate; model identity is unverified. Confirm the intended mouse and close competing mouse software before activating bindings.")
        } catch {
            guard phase != .stopping else { return }
            await fail(error)
        }
    }

    private func openCandidate(connection current: UInt64) async throws {
        guard await cleanup() else { throw BoltFailure.foreignState }
        try checkActive()
        await closeTransport()
        try checkActive()
        capabilityTable = nil
        wheelMultiplier = 0
        physicalWheelRequest = nil
        captureBlocker = nil
        wheelAssociationLost = false
        wheelBaseline = nil
        latestVerifiedWheelMode = nil
        pendingWheelRollback = nil
        restorePreviousSettingsOnDisconnect = false
        available.removeAll()
        wheel = BoltWheelStatus()
        thumbwheel = ThumbwheelState()
        terminalFailure = nil
        let candidate = makeTransport()
        transport = candidate
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

    private func performEnable() async {
        do {
            guard transport != nil else { throw BoltFailure.disconnected }
            guard let table = capabilityTable else { throw BoltFailure.unsupported }
            try reserveEnableAndCleanupTokens(for: table)
            try await verifyCapabilities(table)
            try await verifyOwnedWheelForEnable()
            try await verifyOwnedThumbwheelForEnable()
            guard available == Set(MouseControl.allCases) else { throw BoltFailure.unsupported }
            for control in MouseControl.allCases {
                guard try await reporting(control) == .baseline else { throw BoltFailure.foreignState }
                try checkActive()
            }
            for control in MouseControl.allCases {
                try checkActive()
                changed.insert(control)
                try await mutate(control, flags: 0x03)
                try checkActive()
                guard try await reporting(control) == .diverted else { throw BoltFailure.foreignState }
                try checkActive()
            }
            armed.removeAll()
            pressed.removeAll()
            enabledAt = .now
            guard !disableRequested else { throw BoltFailure.cancelled }
            guard admission.enable(generation: generation) else { throw BoltFailure.transport }
            publish(.enabled, "Bindings enabled. Native Back/Forward behavior is suppressed. Release both buttons to arm delivery.")
        } catch {
            guard phase != .stopping else { return }
            await fail(error)
        }
    }

    private func readCapabilities() async throws -> CapabilityTable {
        let root = try await request(feature: 0, function: 0, parameters: [0x1B, 0x04])
        try checkActive()
        guard root.count >= 3, root[0] != 0, root[1] & 0xE0 == 0, root[2] == 5 else { throw BoltFailure.unsupported }
        let index = root[0]
        let count = try await request(feature: index, function: 0)
        try checkActive()
        guard let count = count.first, count > 0, count <= 12 else { throw BoltFailure.unsupported }
        var rows: [[UInt8]] = []
        for index in 0..<count {
            rows.append(try await request(feature: root[0], function: 1, parameters: [index]))
            try checkActive()
        }
        feature = root[0]
        return CapabilityTable(feature: root[0], rootFlags: root[1], version: root[2], rows: rows, controls: try BoltWire.eligible(rows))
    }

    private func verifyCapabilities(_ cached: CapabilityTable) async throws {
        let root = try await request(feature: 0, function: 0, parameters: [0x1B, 0x04])
        try checkActive()
        guard root.count >= 3, root[0] != 0, root[1] & 0xE0 == 0, root[2] == 5,
              root[0] == cached.feature, root[1] == cached.rootFlags, root[2] == cached.version else {
            throw BoltFailure.foreignState
        }
        let count = try await request(feature: cached.feature, function: 0)
        try checkActive()
        guard count.first == UInt8(cached.rows.count) else { throw BoltFailure.foreignState }
        for index in try eligibleCapabilityRowIndices(cached) {
            let row = try await request(feature: cached.feature, function: 1, parameters: [UInt8(index)])
            try checkActive()
            guard row == cached.rows[index] else { throw BoltFailure.foreignState }
        }
        feature = cached.feature
        available = cached.controls
    }

    private func eligibleCapabilityRowIndices(_ table: CapabilityTable) throws -> [Int] {
        guard try BoltWire.eligible(table.rows) == table.controls else { throw BoltFailure.foreignState }
        let indices = BoltWire.controls.compactMap { (_, cid, _) in
            table.rows.firstIndex { row in row.count >= 2 && BoltWire.word(row, 0) == cid }
        }
        guard indices.count == table.controls.count else { throw BoltFailure.malformed }
        return indices.sorted()
    }

    private func reserveEnableAndCleanupTokens(for table: CapabilityTable) throws {
        let capabilityRows = try eligibleCapabilityRowIndices(table).count
        let buttonFeatureRootReads = 1 + (wheelOwnership == nil && captureOwnership == nil ? 0 : 1) + (thumbwheel.ownership == nil && thumbwheel.capture == nil ? 0 : 1)
        guard remainingNativeTokens(feature: 0, function: 0) >= buttonFeatureRootReads,
              remainingNativeTokens(feature: table.feature, function: 0) >= 1,
              remainingNativeTokens(feature: table.feature, function: 1) >= capabilityRows,
              remainingNativeTokens(feature: table.feature, function: 2) >= 8,
              remainingNativeTokens(feature: table.feature, function: 3) >= 4 else {
            throw BoltFailure.tokenExhausted
        }
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

    private func remainingNativeTokens(feature: UInt8, function: UInt8) -> Int {
        transport?.availableRequestIDs(slot: slot, feature: feature, function: function) ?? 0
    }

    private func reporting(_ control: MouseControl) async throws -> BoltWire.Reporting {
        let cid = BoltWire.cid(control)
        return try BoltWire.reporting(await request(feature: feature, function: 2, parameters: BoltWire.bytes(cid)), cid: cid)
    }

    private func mutate(_ control: MouseControl, flags: UInt8) async throws {
        let reply = try await request(feature: feature, function: 3, parameters: BoltWire.bytes(BoltWire.cid(control)) + [flags, 0, 0])
        guard reply.count == 16, BoltWire.word(reply, 0) == BoltWire.cid(control) else { throw BoltFailure.malformed }
    }

    private func readWheelFeature() async throws -> UInt8 {
        let root = try await request(feature: 0, function: 0, parameters: [0x21, 0x21])
        let usable = root.count >= 3 && root[0] != 0 && root[1] & 0xE0 == 0 && root[2] == 1
        if let ownedFeature = captureOwnership?.feature ?? wheelOwnership?.feature, !usable || root[0] != ownedFeature {
            wheelAssociationLost = true
            throw BoltFailure.foreignState
        }
        try checkActive()
        guard usable else { throw BoltFailure.unsupported }
        let index = root[0]
        let capabilities = try await request(feature: index, function: 0)
        guard capabilities.count >= 2, capabilities[1] & 0x08 != 0 else {
            if wheelOwnership != nil || captureOwnership != nil { wheelAssociationLost = true }
            throw BoltFailure.unsupported
        }
        wheelMultiplier = capabilities[0]
        try checkActive()
        return index
    }

    private func wheelMode(feature: UInt8, cleanup: Bool = false) async throws -> UInt8 {
        guard cleanup || remainingNativeTokens(feature: feature, function: 1) > 2 else { throw BoltFailure.tokenExhausted }
        let reply = try await request(feature: feature, function: 1)
        guard reply.count >= 2, reply[1] == 0, reply[0] & 0xF8 == 0 else { throw BoltFailure.foreignState }
        return reply[0]
    }

    private func observeWheel(_ mode: UInt8, applying: Bool = false, message: String? = nil) {
        wheel = BoltWheelStatus(support: .supported, observedInverted: mode & 0x04 != 0, isOwned: wheelOwnership != nil, isApplying: applying, message: message, observedHighResolution: mode & 0x02 != 0)
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
            wheel = BoltWheelStatus(support: unsupported ? .unsupported : .unknown, message: "Device wheel settings are unavailable for this session.")
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
                var target = baseline
                for (desired, mask) in [(inverted, UInt8(0x04)), (highResolution, UInt8(0x02))] {
                    if let desired {
                        target = (target & ~mask) | (desired ? mask : 0)
                    } else if restorePreviousSettingsOnDisconnect && previousMask & mask != 0 {
                        target = (target & ~mask) | (captured.mode & mask)
                    }
                }
                if target != baseline {
                    guard try await wheelMode(feature: index) == baseline else { throw BoltFailure.foreignState }
                    try checkActive()
                    let pendingMask = previousMask | (baseline ^ target)
                    wheelOwnership = WheelOwnership(feature: index, original: captured.mode, target: target, mask: pendingMask)
                    pendingWheelRollback = baseline
                    do {
                        _ = try await request(feature: index, function: 2, parameters: [target])
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
            wheel = BoltWheelStatus(support: wheel.support, observedInverted: wheel.observedInverted, isOwned: wheelOwnership != nil, message: "Device wheel preferences verified.", observedHighResolution: wheel.observedHighResolution)
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

    private func reserveWheelTokens(feature: UInt8, reads: Int, setters: Int, rootReads: Int = 0, capabilityReads: Int = 0) throws {
        guard remainingNativeTokens(feature: feature, function: 1) >= reads + 2,
              remainingNativeTokens(feature: feature, function: 2) >= setters + 1,
              remainingNativeTokens(feature: 0, function: 0) >= rootReads,
              remainingNativeTokens(feature: feature, function: 0) >= capabilityReads else { throw BoltFailure.tokenExhausted }
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
        let capture = CaptureOwnership(feature: index, nativeMode: nativeMode, capturedMode: (nativeMode & ~0x04) | 0x01)
        captureOwnership = capture
        captureVerified = false
        scrollGeneration &+= 1
        scrollAdmission.prepare(generation: scrollGeneration)
        do { _ = try await request(feature: index, function: 2, parameters: [capture.capturedMode]) }
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
            if !final { try reserveWheelTokens(feature: capture.feature, reads: 2, setters: 1) }
            guard !wheelAssociationLost else { throw BoltFailure.foreignState }
            let current = try await wheelMode(feature: capture.feature, cleanup: true)
            guard current == capture.capturedMode || current == capture.nativeMode || current == restoration else { throw BoltFailure.foreignState }
            if current != restoration {
                do { _ = try await request(feature: capture.feature, function: 2, parameters: [restoration]) }
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
                                   message: "Scroll capture cleanup is unverified. Reconnection is blocked.", captureBlocker: "Native wheel routing could not be verified.")
            return false
        }
    }

    private func refreshWheelCaptureStatus() {
        wheel = BoltWheelStatus(support: wheel.support, observedInverted: wheel.observedInverted,
                               isOwned: wheelOwnership != nil || captureOwnership != nil, isApplying: wheel.isApplying,
                               message: wheel.message, observedHighResolution: wheel.observedHighResolution,
                               captureActive: captureOwnership != nil && captureVerified && captureBlocker == nil,
                               captureBlocker: captureBlocker ?? (uncertain ? wheel.captureBlocker : nil),
                               effectiveInverted: captureOwnership.map { $0.nativeMode & 0x04 != 0 })
    }

    private func rejectStaleScrollAdmission(generation requestedGeneration: UInt64) async {
        guard requestedGeneration == scrollGeneration, captureOwnership != nil else { return }
        guard let intent = recordFailure(BoltFailure.stale, connection: connection) else { return }
        await scheduleFailure(intent)
    }

    private func cleanupWheel() async -> Bool {
        if captureOwnership != nil { return await cleanupCapture(final: true) }
        guard let ownership = wheelOwnership else {
            wheel = BoltWheelStatus(support: wheel.support, observedInverted: wheel.observedInverted, message: wheel.message, observedHighResolution: wheel.observedHighResolution)
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
                observedHighResolution: wheel.observedHighResolution
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
                    _ = try await request(feature: ownership.feature, function: 2, parameters: [restoration])
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
            wheel = BoltWheelStatus(support: wheel.support, observedInverted: nil, isOwned: true, message: "Wheel cleanup is unverified. Rearming and reconnecting are blocked.")
            return false
        }
    }

    private func readThumbwheelFeature() async throws -> UInt8 {
        let root = try await request(feature: 0, function: 0, parameters: [0x21, 0x50])
        let usable = root.count >= 3 && root[0] != 0 && root[1] & 0xE0 == 0 && root[2] == 0
        if let index = thumbwheel.feature, thumbwheel.capture != nil || thumbwheel.ownership != nil,
           !usable || root[0] != index {
            thumbwheel.associationLost = true
            throw BoltFailure.foreignState
        }
        try checkActive()
        guard usable else { throw BoltFailure.unsupported }
        let info = try await request(feature: root[0], function: 0)
        thumbwheel.info = try ThumbwheelState.Info(info)
        try checkActive()
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
            guard !mode.diverted else { throw BoltFailure.foreignState }
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

    private func reserveThumbwheelTokens(feature: UInt8, reads: Int, setters: Int, rootReads: Int = 0, infoReads: Int = 0) throws {
        guard remainingNativeTokens(feature: feature, function: 1) >= reads + 2,
              remainingNativeTokens(feature: feature, function: 2) >= setters + 1,
              remainingNativeTokens(feature: 0, function: 0) >= rootReads,
              remainingNativeTokens(feature: feature, function: 0) >= infoReads else { throw BoltFailure.tokenExhausted }
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
        guard !current.diverted else { throw BoltFailure.foreignState }
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
        do { _ = try await request(feature: index, function: 2, parameters: target.parameters) }
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
        guard !native.diverted, native == thumbwheel.latest else { throw BoltFailure.foreignState }
        guard scrollPostingPreflight() else {
            thumbwheel.blocker = "Input posting permission changed before thumb-wheel capture; native scrolling remains active."
            return
        }
        let capture = ThumbwheelState.Capture(native: native)
        thumbwheel.capture = capture
        thumbwheel.captureVerified = false
        thumbwheel.generation &+= 1
        thumbwheelAdmission.prepare(generation: thumbwheel.generation)
        do { _ = try await request(feature: index, function: 2, parameters: capture.captured.parameters) }
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
            if !final { try reserveThumbwheelTokens(feature: index, reads: 2, setters: 1) }
            guard !thumbwheel.associationLost else { throw BoltFailure.foreignState }
            let current = try await thumbwheelMode(feature: index, cleanup: true)
            let attributable = [capture?.captured, capture?.native, owned?.target, thumbwheel.pendingRollback, restoration].compactMap { $0 }
            guard attributable.contains(current) else { throw BoltFailure.foreignState }
            if current != restoration {
                do { _ = try await request(feature: index, function: 2, parameters: restoration.parameters) }
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
            thumbwheel.message = "Thumb-wheel cleanup is unverified; reconnection is blocked."
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
        let wheelRestored = await cleanupWheel()
        let thumbwheelRestored = await cleanupThumbwheel(final: true)
        let buttonsRestored = await cleanupButtons()
        let restored = wheelRestored && thumbwheelRestored && buttonsRestored
        uncertain = !restored
        return restored
    }

    private func cleanupButtons() async -> Bool {
        var restored = true
        for control in MouseControl.allCases where changed.contains(control) {
            do {
                let observed = try await reporting(control)
                if observed == .diverted {
                    try await mutate(control, flags: 0x02)
                    guard try await reporting(control) == .baseline else { throw BoltFailure.foreignState }
                } else if observed != .baseline {
                    throw BoltFailure.foreignState
                }
                changed.remove(control)
            } catch {
                restored = false
            }
        }
        return restored
    }

    private func checkActive() throws {
        if let terminalFailure { throw terminalFailure }
        guard !Task.isCancelled, phase != .stopping else { throw BoltFailure.cancelled }
    }

    private func fail(_ error: Error, sourceFileID: String = #fileID, sourceLine: UInt = #line) async {
        admission.invalidate()
        invalidateScrollAdmission()
        invalidateThumbwheelAdmission()
        generation &+= 1
        armed.removeAll()
        pressed.removeAll()
        publish(.stopping, "Delivery stopped; checking temporary diversion cleanup.")
        let restored = await cleanup()
        await closeTransport()
        available.removeAll()
        let failure = (error as? BoltFailure) ?? .transport
        let message = failure.errorDescription ?? "The Bolt session failed."
        let context = BoltFailureContext(code: failure.diagnosticCode, sourceFileID: sourceFileID, sourceLine: sourceLine)
        publish(.failed, message + (restored ? " Delivery stopped." : " Cleanup is unverified; rearming is blocked."), failure: context)
    }

    private func closeTransport() async {
        observer?.cancel()
        observer = nil
        if let transport { await transport.close() }
        transport = nil
    }

    private func receive(_ event: BoltTransportEvent, connection current: UInt64) async {
        guard current == connection, transport != nil else { return }
        switch event {
        case .failure(let error):
            guard phase != .stopping, phase != .failed else { return }
            guard let intent = recordFailure(error, connection: current) else { return }
            if !operationHeld { await scheduleFailure(intent) }
        case .report(let report, let arrival):
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
                        let direction = capture.nativeMode & 0x04 == 0 ? 1.0 : -1.0
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
                guard let down = try BoltWire.snapshot(report, slot: slot, feature: feature) else { return }
                guard arrival >= enabledAt else { return }
                guard arrival.duration(to: .now) <= .milliseconds(250) else { throw BoltFailure.stale }
                let newlyPressed = down.subtracting(pressed).intersection(armed)
                armed.formUnion(Set(MouseControl.allCases).subtracting(down))
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
        refreshWheelCaptureStatus()
        let result = continuation.yield(.status(BoltStatus(phase: phase, message: message, availableControls: available, generation: generation, cleanupUncertain: uncertain, wheel: wheel, thumbwheel: thumbwheel.status, failure: failure)))
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
