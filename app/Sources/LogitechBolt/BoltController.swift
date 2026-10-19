import Foundation
import HidhoggDomain

public actor BoltController {
    public nonisolated let events: AsyncStream<BoltEvent>
    private let continuation: AsyncStream<BoltEvent>.Continuation
    private let makeTransport: @Sendable () -> any BoltTransport
    private nonisolated let admission: BoltPressAdmission
    private var transport: (any BoltTransport)?
    private var observer: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var phase: BoltPhase = .idle
    private var generation: UInt64 = 0
    private var connection: UInt64 = 0
    private var available = Set<MouseControl>()
    private var slot: UInt8 = 0
    private var feature: UInt8 = 0
    private var changed = Set<MouseControl>()
    private var uncertain = false
    private var armed = Set<MouseControl>()
    private var pressed = Set<MouseControl>()
    private var terminalFailure: BoltFailure?
    private var enabledAt: ContinuousClock.Instant = .now

    public init() {
        let admission = BoltPressAdmission()
        self.init(admission: admission, makeTransport: { IOKitBoltTransport(onTerminal: { admission.invalidate() }) })
    }

    init(bufferSize: Int = 32, admission: BoltPressAdmission = BoltPressAdmission(), makeTransport: @escaping @Sendable () -> any BoltTransport) {
        let stream = AsyncStream<BoltEvent>.makeStream(bufferingPolicy: .bufferingNewest(bufferSize))
        events = stream.stream
        continuation = stream.continuation
        self.makeTransport = makeTransport
        self.admission = admission
        continuation.onTermination = { [weak self, admission] _ in
            admission.invalidate()
            Task { await self?.stop() }
        }
        continuation.yield(.status(BoltStatus(phase: .idle, message: "Disconnected. Connect to discover a Bolt candidate.", availableControls: [], generation: 0, cleanupUncertain: false)))
    }

    public func discover() async {
        guard operation == nil, shutdownTask == nil, phase != .enabled, phase != .enabling, phase != .stopping, !uncertain else { return }
        generation &+= 1
        admission.prepare(generation: generation)
        terminalFailure = nil
        connection &+= 1
        let current = connection
        publish(.discovering, "Discovering a Bolt candidate; model identity is unverified.")
        let task = Task { await self.performDiscovery(connection: current) }
        operation = task
        await task.value
        operation = nil
        await reconcileTerminalFailure()
    }

    public func enable() async {
        guard phase == .ready, operation == nil, shutdownTask == nil, !uncertain,
              available == Set(MouseControl.allCases) else { return }
        generation &+= 1
        admission.prepare(generation: generation)
        terminalFailure = nil
        publish(.enabling, "Checking fresh capabilities and native reporting before temporary diversion.")
        let task = Task { await self.performEnable() }
        operation = task
        await task.value
        operation = nil
        await reconcileTerminalFailure()
    }

    public func disable() async { await shutdown() }
    public func stop() async { await shutdown() }

    /// Runs synchronously under the admission lock; the closure must not reenter admission or wait for this actor.
    public nonisolated func withPressAdmission(generation: UInt64, observedAt: ContinuousClock.Instant, _ operation: () -> Void) -> Bool {
        switch admission.perform(generation: generation, observedAt: observedAt, operation) {
        case .accepted: return true
        case .rejected: return false
        case .stale:
            Task { await self.rejectStaleAdmission() }
            return false
        }
    }

    private func shutdown() async {
        admission.invalidate()
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { await self.performShutdown() }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func performShutdown() async {
        generation &+= 1
        armed.removeAll()
        pressed.removeAll()
        publish(.stopping, "Stopping delivery and verifying temporary diversion cleanup.")
        operation?.cancel()
        if let operation { await operation.value }
        let restored = await cleanup()
        await closeTransport()
        available.removeAll()
        publish(restored ? .idle : .failed, restored ? "Disconnected. Temporary diversion is off." : "Cleanup is unverified. Rearming is blocked; resolve receiver state before restarting.")
    }

    private func performDiscovery(connection current: UInt64) async {
        do {
            try await openCandidate(connection: current)
            available = try await readCapabilities()
            try checkActive()
            publish(.ready, "Bolt candidate discovered; model is unverified. Confirm the intended mouse and close competing mouse software before enabling.")
        } catch {
            await fail(error)
        }
    }

    private func openCandidate(connection current: UInt64) async throws {
        await closeTransport()
        try checkActive()
        available.removeAll()
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
            connection &+= 1
            try await openCandidate(connection: connection)
            available = try await readCapabilities()
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
            guard admission.enable(generation: generation) else { throw BoltFailure.transport }
            publish(.enabled, "Bindings enabled. Native Back/Forward behavior is suppressed. Release both buttons to arm delivery.")
        } catch {
            await fail(error)
        }
    }

    private func readCapabilities() async throws -> Set<MouseControl> {
        let root = try await request(feature: 0, function: 0, parameters: [0x1B, 0x04])
        guard root.count >= 3, root[0] != 0, root[1] & 0xE0 == 0, root[2] == 5 else { throw BoltFailure.unsupported }
        feature = root[0]
        let count = try await request(feature: feature, function: 0)
        guard let count = count.first, count > 0, count <= 12 else { throw BoltFailure.unsupported }
        var rows: [[UInt8]] = []
        for index in 0..<count {
            rows.append(try await request(feature: feature, function: 1, parameters: [index]))
            try checkActive()
        }
        return try BoltWire.eligible(rows)
    }

    private func request(feature: UInt8, function: UInt8, parameters: [UInt8] = []) async throws -> [UInt8] {
        guard let transport else { throw BoltFailure.disconnected }
        return try await transport.request(slot: slot, feature: feature, function: function, parameters: parameters)
    }

    private func reporting(_ control: MouseControl) async throws -> BoltWire.Reporting {
        let cid = BoltWire.cid(control)
        return try BoltWire.reporting(await request(feature: feature, function: 2, parameters: BoltWire.bytes(cid)), cid: cid)
    }

    private func mutate(_ control: MouseControl, flags: UInt8) async throws {
        let reply = try await request(feature: feature, function: 3, parameters: BoltWire.bytes(BoltWire.cid(control)) + [flags, 0, 0])
        guard reply.count == 16, BoltWire.word(reply, 0) == BoltWire.cid(control) else { throw BoltFailure.malformed }
    }

    private func cleanup() async -> Bool {
        guard !changed.isEmpty else { return !uncertain }
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
        uncertain = !restored
        return restored
    }

    private func checkActive() throws {
        if let terminalFailure { throw terminalFailure }
        guard !Task.isCancelled, phase != .stopping else { throw BoltFailure.cancelled }
    }

    private func fail(_ error: Error) async {
        admission.invalidate()
        generation &+= 1
        armed.removeAll()
        pressed.removeAll()
        publish(.stopping, "Delivery stopped; checking temporary diversion cleanup.")
        let restored = await cleanup()
        await closeTransport()
        available.removeAll()
        let message = (error as? LocalizedError)?.errorDescription ?? "The Bolt session failed."
        publish(.failed, message + (restored ? " Delivery stopped." : " Cleanup is unverified; rearming is blocked."))
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
            admission.invalidate()
            guard phase != .stopping, phase != .failed else { return }
            terminalFailure = error
            generation &+= 1
            armed.removeAll()
            pressed.removeAll()
            if operation == nil { await scheduleFailure(error) }
        case .report(let report, let arrival):
            guard phase == .enabled, terminalFailure == nil else { return }
            do {
                guard arrival >= enabledAt else { return }
                guard arrival.duration(to: .now) <= .milliseconds(250) else { throw BoltFailure.stale }
                guard let down = try BoltWire.snapshot(report, slot: slot, feature: feature) else { return }
                let newlyPressed = down.subtracting(pressed).intersection(armed)
                armed.formUnion(Set(MouseControl.allCases).subtracting(down))
                pressed = down
                for control in MouseControl.allCases where newlyPressed.contains(control) {
                    if case .dropped(.press) = continuation.yield(.press(control, generation: generation, observedAt: arrival)) {
                        admission.invalidate()
                        await scheduleFailure(BoltFailure.overflow)
                        return
                    }
                }
            } catch { await scheduleFailure(error) }
        }
    }

    private func scheduleFailure(_ error: Error) async {
        guard operation == nil, shutdownTask == nil else { return }
        terminalFailure = (error as? BoltFailure) ?? .transport
        let task = Task { await self.fail(error) }
        operation = task
        await task.value
        operation = nil
    }

    private func reconcileTerminalFailure() async {
        guard let terminalFailure, phase == .enabled || phase == .ready else { return }
        await scheduleFailure(terminalFailure)
    }

    private func rejectStaleAdmission() async {
        terminalFailure = .stale
        if operation == nil { await scheduleFailure(BoltFailure.stale) }
    }

    private func publish(_ phase: BoltPhase, _ message: String) {
        self.phase = phase
        let result = continuation.yield(.status(BoltStatus(phase: phase, message: message, availableControls: available, generation: generation, cleanupUncertain: uncertain)))
        if case .dropped(.press) = result, phase == .enabled {
            admission.invalidate()
            terminalFailure = .overflow
            generation &+= 1
            Task { await self.scheduleFailure(BoltFailure.overflow) }
        }
    }
}
