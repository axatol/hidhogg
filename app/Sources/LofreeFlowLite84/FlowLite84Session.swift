import Foundation

public actor FlowLite84Session: FlowLite84SessionProtocol {
    public nonisolated let events: AsyncStream<FlowLite84Event>
    public private(set) var status: FlowLite84ConnectionStatus = .disconnected
    public private(set) var generation: UInt64 = 0
    private let continuation: AsyncStream<FlowLite84Event>.Continuation
    private let timing: FlowLite84Timing
    private let makeTransport: @Sendable () -> any FlowLite84Transport
    private var transport: (any FlowLite84Transport)?
    private var identity: FlowLite84Identity?
    private var lastSnapshot: FlowLite84Snapshot?
    private var reader: Task<Void, Never>?
    private var batch: Task<Void, Error>?
    private var batchScope: BatchScope?
    private var closing: Task<Void, Never>?
    private var terminalFailure: FlowLite84Failure?
    private var batchSequence: UInt64 = 0
    private var exchangeSequence: UInt64 = 0
    private var writer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var refreshRequested = false
    private var pending: Pending?
    private var receiptSequence: UInt64 = 0
    private var latestBattery: BatteryObservation?

    private enum BatchScope: Equatable {
        case full
        case battery
    }

    private struct Pending {
        let request: FlowLite84Request
        let sequence: UInt64
        let waiter: CheckedContinuation<FlowLite84Reply, Error>
        var written = false
        var result: Result<FlowLite84Reply, FlowLite84Failure>?
        var battery: BatteryObservation?
    }

    private struct BatteryObservation {
        let sequence: UInt64
        let receivedAt: Date
        let value: FlowLite84Battery

        var unavailableFields: [String] {
            var fields: [String] = []
            if value.reportedLevel == nil { fields.append("battery.reportedLevel") }
            if value.charging == nil { fields.append("battery.charging") }
            if value.voltageMillivolts == nil { fields.append("battery.voltageMillivolts") }
            return fields
        }
    }

    public init(
        timing: FlowLite84Timing = FlowLite84Timing(),
        makeTransport: @escaping @Sendable () -> any FlowLite84Transport = { IOKitFlowLite84Transport() }
    ) {
        let stream = AsyncStream<FlowLite84Event>.makeStream(bufferingPolicy: .bufferingNewest(32))
        events = stream.stream
        continuation = stream.continuation
        self.timing = timing
        self.makeTransport = makeTransport
    }

    deinit {
        batch?.cancel()
        reader?.cancel()
        writer?.cancel()
        deadline?.cancel()
        pending?.waiter.resume(throwing: FlowLite84Failure.cancelled)
        continuation.finish()
        if let transport { Task { await transport.close() } }
    }

    public func connect() async throws {
        try Task.checkCancellation()
        guard transport == nil, closing == nil, status != .disconnecting else { throw FlowLite84Failure.busy }
        generation &+= 1
        let token = generation
        transport = makeTransport()
        publish(.connecting)
        lastSnapshot = nil
        latestBattery = nil
        let task = startBatch(initial: true, scope: .full, token: token)
        try await wait(for: task, token: token)
    }

    public func refresh() async throws {
        try Task.checkCancellation()
        guard case .connected = status, transport != nil else { throw FlowLite84Failure.disconnected }
        let token = generation
        let task: Task<Void, Error>
        if let batch {
            if batchScope == .battery { refreshRequested = true }
            task = batch
        } else {
            task = startBatch(initial: false, scope: .full, token: token)
        }
        try await wait(for: task, token: token)
    }

    public func refreshBattery() async throws {
        try Task.checkCancellation()
        guard case .connected = status, transport != nil else { throw FlowLite84Failure.disconnected }
        let token = generation
        let task = batch ?? startBatch(initial: false, scope: .battery, token: token)
        try await wait(for: task, token: token)
    }

    public func disconnect() async {
        await stop(failure: nil, token: generation)
    }

    private func wait(for task: Task<Void, Error>, token: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.stop(failure: .cancelled, token: token) }
        }
    }

    private func startBatch(initial: Bool, scope: BatchScope, token: UInt64) -> Task<Void, Error> {
        batchSequence &+= 1
        let sequence = batchSequence
        let task = Task { try await performBatch(initial: initial, scope: scope, token: token, sequence: sequence) }
        batch = task
        batchScope = scope
        return task
    }

    private func performBatch(initial: Bool, scope: BatchScope, token: UInt64, sequence: UInt64) async throws {
        do {
            try checkActive(token)
            if initial {
                guard let link = transport else { throw FlowLite84Failure.disconnected }
                try await link.open()
                try checkActive(token)
                startReading(link.reports, token: token)
                let challenge = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
                let reply = try await exchange(.identify(challenge), token: token)
                let found = FlowLite84Identity(cid: reply.fields[0], mid: reply.fields[1], connectionType: reply.fields[2])
                guard found.isSupported else { throw FlowLite84Failure.unsupportedDevice }
                identity = found
            }
            var nextScope = scope
            var publishesConnected = initial
            while true {
                let batteryBoundary = receiptSequence
                var snapshot = switch nextScope {
                case .full: try await readSnapshot(token: token)
                case .battery: try await readBatterySnapshot(token: token)
                }
                try checkActive(token)
                if let latestBattery, latestBattery.sequence > batteryBoundary {
                    snapshot = applying(latestBattery, to: snapshot)
                }
                lastSnapshot = snapshot
                if publishesConnected { publish(.connected(snapshot.identity)) }
                continuation.yield(.snapshot(snapshot, generation: token))
                publishesConnected = false

                guard refreshRequested, case .connected = status else { break }
                refreshRequested = false
                nextScope = .full
                batchScope = .full
            }
            finishBatch(token: token, sequence: sequence)
        } catch {
            let failure = Self.failure(error)
            await stop(failure: failure, token: token)
            throw failure
        }
    }

    private func finishBatch(token: UInt64, sequence: UInt64) {
        guard token == generation, sequence == batchSequence else { return }
        batch = nil
        batchScope = nil
        refreshRequested = false
    }

    private func startReading(_ reports: AsyncThrowingStream<Data, Error>, token: UInt64) {
        reader = Task { [weak self] in
            do {
                for try await report in reports {
                    guard !Task.isCancelled else { return }
                    await self?.receive(report, token: token)
                }
                guard !Task.isCancelled else { return }
                await self?.stop(failure: .disconnected, token: token)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.stop(failure: Self.failure(error), token: token)
            }
        }
    }

    private func exchange(_ request: FlowLite84Request, token: UInt64) async throws -> FlowLite84Reply {
        try checkActive(token)
        guard pending == nil, let link = transport else { throw FlowLite84Failure.busy }
        let report = try FlowLite84Codec.encode(request)
        exchangeSequence &+= 1
        let sequence = exchangeSequence
        return try await withCheckedThrowingContinuation { waiter in
            pending = Pending(request: request, sequence: sequence, waiter: waiter)
            let sleep = timing.sleep
            let timeout = timing.responseTimeout
            deadline = Task { [weak self] in
                do {
                    try await sleep(timeout)
                    guard !Task.isCancelled else { return }
                    await self?.timedOut(token: token, sequence: sequence)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.stop(failure: Self.failure(error), token: token)
                }
            }
            writer = Task { [weak self] in
                do {
                    try await link.write(report)
                    await self?.written(token: token, sequence: sequence)
                } catch {
                    await self?.stop(failure: Self.failure(error), token: token)
                }
            }
        }
    }

    private func written(token: UInt64, sequence: UInt64) {
        guard token == generation, pending?.sequence == sequence, transport != nil else { return }
        pending?.written = true
        completePending()
    }

    private func timedOut(token: UInt64, sequence: UInt64) async {
        guard token == generation, pending?.sequence == sequence else { return }
        await stop(failure: .timeout, token: token)
    }

    private func receive(_ data: Data, token: UInt64) async {
        guard token == generation, transport != nil else { return }
        do {
            let reply = try FlowLite84Codec.decode(data)
            receiptSequence &+= 1
            if reply.command == 10 {
                guard reply.status == 0 else { throw FlowLite84Failure.invalidResponse(.notificationStatus) }
                guard reply.fields[0] & 0xdc != 0 else { return }
                if batch != nil { refreshRequested = true; return }
                guard case .connected = status else { return }
                _ = startBatch(initial: false, scope: .full, token: token)
                return
            }
            if let current = pending, reply.matches(current.request) {
                do {
                    try reply.validate(for: current.request)
                    try validatePayload(reply, for: current.request)
                    if let result = current.result {
                        if case .success(let buffered) = result, buffered == reply { return }
                        throw FlowLite84Failure.invalidResponse(.duplicateReply(command: reply.command))
                    }
                    pending?.result = .success(reply)
                    if reply.command == 4 {
                        pending?.battery = batteryObservation(reply)
                    }
                } catch let failure as FlowLite84Failure {
                    guard case .rejected = failure, current.result == nil else { throw failure }
                    pending?.result = .failure(failure)
                }
                completePending()
                return
            }
            if reply.command == 1 {
                if reply.status == 0, let identity,
                   reply.fields == [identity.cid, identity.mid, identity.connectionType] { return }
                if let current = pending { try reply.validate(for: current.request) }
                throw FlowLite84Failure.invalidResponse(.unexpectedReply(command: reply.command))
            }
            guard reply.command == 4, identity != nil, reply.status == 0 else { return }
            let observation = batteryObservation(reply)
            guard observation.unavailableFields.isEmpty else { return }
            retain(observation)
            guard let snapshot = lastSnapshot else { return }
            let updated = applying(observation, to: snapshot)
            lastSnapshot = updated
            continuation.yield(.snapshot(updated, generation: token))
        } catch {
            await stop(failure: Self.failure(error), token: token)
        }
    }

    private func completePending() {
        guard let current = pending, current.written, let result = current.result else { return }
        if let battery = current.battery { retain(battery) }
        pending = nil
        deadline?.cancel()
        deadline = nil
        writer = nil
        current.waiter.resume(with: result.mapError { $0 as Error })
    }

    private func validatePayload(_ reply: FlowLite84Reply, for request: FlowLite84Request) throws {
        switch request {
        case .identify:
            let found = FlowLite84Identity(cid: reply.fields[0], mid: reply.fields[1], connectionType: reply.fields[2])
            guard found.isSupported else { throw FlowLite84Failure.unsupportedDevice }
        case .online:
            guard reply.fields[0] <= 1 else { throw FlowLite84Failure.invalidResponse(.onlineFlag) }
        case .setting:
            _ = try FlowLite84Codec.scalar(reply)
        case .effect:
            guard reply.fields.reduce(UInt8(0), &+) == 0x55 else {
                throw FlowLite84Failure.invalidResponse(.effectChecksum)
            }
        default: break
        }
    }

    private func batteryObservation(_ reply: FlowLite84Reply) -> BatteryObservation {
        BatteryObservation(sequence: receiptSequence, receivedAt: timing.now(), value: FlowLite84Codec.battery(reply))
    }

    private func retain(_ observation: BatteryObservation) {
        if let latestBattery, observation.sequence <= latestBattery.sequence { return }
        latestBattery = observation
    }

    private func applying(_ observation: BatteryObservation, to snapshot: FlowLite84Snapshot) -> FlowLite84Snapshot {
        let unavailable = snapshot.unavailableFields.filter { $0 != "battery" && !$0.hasPrefix("battery.") }
        let value = observation.value
        let battery = value.reportedLevel == nil && value.charging == nil && value.voltageMillivolts == nil ? nil : value
        return FlowLite84Snapshot(
            identity: snapshot.identity, online: snapshot.online,
            keyboardVersion: snapshot.keyboardVersion, receiverVersion: snapshot.receiverVersion,
            battery: battery, lighting: snapshot.lighting, systemMode: snapshot.systemMode,
            readAt: snapshot.readAt, batteryReadAt: observation.receivedAt,
            unavailableFields: unavailable + observation.unavailableFields
        )
    }

    private func readSnapshot(token: UInt64) async throws -> FlowLite84Snapshot {
        guard let identity else { throw FlowLite84Failure.unsupportedDevice }
        let onlineReply = try await exchange(.online, token: token)
        guard onlineReply.fields[0] <= 1 else { throw FlowLite84Failure.invalidResponse(.onlineFlag) }
        let online = onlineReply.fields[0] == 1
        var unavailable = ["receiverVersion"]
        guard online else {
            unavailable += ["keyboardVersion", "battery", "lighting", "systemMode"]
            return FlowLite84Snapshot(
                identity: identity, online: false,
                readAt: timing.now(), unavailableFields: unavailable
            )
        }

        let keyboardReply = try await optional(.keyboardVersion, field: "keyboardVersion", unavailable: &unavailable, token: token)
        let keyboardVersion = keyboardReply.flatMap(FlowLite84Codec.version)
        if keyboardReply != nil, keyboardVersion == nil { unavailable.append("keyboardVersion") }
        _ = try await optional(.battery, field: "battery", unavailable: &unavailable, token: token)
        let mode = try await readScalar(.lightingMode, field: "lighting.mode", unavailable: &unavailable, token: token)
        let enabled = try await readScalar(.lightingEnabled, field: "lighting.enabled", unavailable: &unavailable, token: token)
        let idle = try await readScalar(.idleOff, field: "lighting.idleOffUnits", unavailable: &unavailable, token: token)
        let system = try await readScalar(.systemMode, field: "systemMode", unavailable: &unavailable, token: token)
        var brightness: UInt8?
        var speed: UInt8?
        if let mode, mode <= 15,
           let effect = try await optional(.effect(mode: mode), field: "lighting.parameters", unavailable: &unavailable, token: token) {
            guard effect.fields.reduce(UInt8(0), &+) == 0x55 else { throw FlowLite84Failure.invalidResponse(.effectChecksum) }
            speed = effect.fields[1] <= 4 ? effect.fields[1] : nil
            brightness = effect.fields[2] <= 4 ? effect.fields[2] : nil
        }
        if speed == nil { unavailable.append("lighting.speedLevel") }
        if brightness == nil { unavailable.append("lighting.brightnessLevel") }
        let lighting: FlowLite84Lighting?
        if let mode, let enabled, enabled <= 1, let idle {
            lighting = FlowLite84Lighting(mode: mode, enabled: enabled == 1, idleOffUnits: idle, brightnessLevel: brightness, speedLevel: speed)
        } else {
            lighting = nil
            unavailable.append("lighting")
        }
        return FlowLite84Snapshot(
            identity: identity, online: true, keyboardVersion: keyboardVersion,
            lighting: lighting,
            systemMode: system, readAt: timing.now(), unavailableFields: unavailable
        )
    }

    private func readBatterySnapshot(token: UInt64) async throws -> FlowLite84Snapshot {
        guard let identity else { throw FlowLite84Failure.unsupportedDevice }
        let onlineReply = try await exchange(.online, token: token)
        guard onlineReply.fields[0] <= 1 else { throw FlowLite84Failure.invalidResponse(.onlineFlag) }

        let previous = lastSnapshot
        let retainedUnavailable = previous?.unavailableFields.filter {
            $0 != "battery" && !$0.hasPrefix("battery.")
        } ?? []
        guard onlineReply.fields[0] == 1 else {
            return FlowLite84Snapshot(
                identity: identity, online: false,
                keyboardVersion: previous?.keyboardVersion,
                receiverVersion: previous?.receiverVersion,
                lighting: previous?.lighting,
                systemMode: previous?.systemMode,
                readAt: previous?.readAt ?? timing.now(),
                unavailableFields: retainedUnavailable + ["battery"]
            )
        }

        var unavailable = retainedUnavailable
        _ = try await optional(.battery, field: "battery", unavailable: &unavailable, token: token)
        return FlowLite84Snapshot(
            identity: identity, online: true,
            keyboardVersion: previous?.keyboardVersion,
            receiverVersion: previous?.receiverVersion,
            lighting: previous?.lighting,
            systemMode: previous?.systemMode,
            readAt: previous?.readAt ?? timing.now(),
            unavailableFields: unavailable
        )
    }

    private func optional(
        _ request: FlowLite84Request, field: String, unavailable: inout [String], token: UInt64
    ) async throws -> FlowLite84Reply? {
        do { return try await exchange(request, token: token) }
        catch let failure as FlowLite84Failure {
            guard case .rejected = failure else { throw failure }
            unavailable.append(field)
            return nil
        }
    }

    private func readScalar(
        _ setting: FlowLite84Setting, field: String, unavailable: inout [String], token: UInt64
    ) async throws -> UInt8? {
        guard let reply = try await optional(.setting(setting), field: field, unavailable: &unavailable, token: token) else { return nil }
        return try FlowLite84Codec.scalar(reply)
    }

    private func stop(failure: FlowLite84Failure?, token: UInt64) async {
        guard token == generation else { return }
        if failure == nil { terminalFailure = nil }
        guard let link = transport else {
            if let closing { await closing.value }
            else if failure == nil { publish(.disconnected) }
            return
        }
        terminalFailure = failure
        publish(.disconnecting)
        transport = nil
        identity = nil
        lastSnapshot = nil
        latestBattery = nil
        refreshRequested = false
        batchSequence &+= 1
        batch?.cancel()
        batch = nil
        batchScope = nil
        reader?.cancel()
        reader = nil
        writer?.cancel()
        writer = nil
        deadline?.cancel()
        deadline = nil
        let waiter = pending?.waiter
        pending = nil
        waiter?.resume(throwing: failure ?? .disconnected)
        let cleanup = Task {
            await link.close()
            finishStop(token: token)
        }
        closing = cleanup
        await cleanup.value
    }

    private func finishStop(token: UInt64) {
        guard token == generation else { return }
        closing = nil
        publish(terminalFailure.map(FlowLite84ConnectionStatus.failed) ?? .disconnected)
        terminalFailure = nil
    }

    private func checkActive(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation, transport != nil else { throw FlowLite84Failure.disconnected }
    }

    private func publish(_ value: FlowLite84ConnectionStatus) {
        status = value
        continuation.yield(.status(value, generation: generation))
    }

    private static func failure(_ error: Error) -> FlowLite84Failure {
        if error is CancellationError { return .cancelled }
        return error as? FlowLite84Failure ?? .transport
    }
}
