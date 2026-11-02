import Foundation
import HidhoggDomain

public actor BoltPairingSession: BoltPairingManaging {
    public nonisolated let events: AsyncStream<BoltPairingStatus>

    private let continuation: AsyncStream<BoltPairingStatus>.Continuation
    private let catalog: any LogitechEndpointCatalog
    private let discoveryTimeout: Duration
    private let authenticationTimeout: Duration
    private let cancellationReconciliationTimeout: Duration

    private var status = BoltPairingStatus(phase: .idle, message: "Ready to inspect Bolt receivers.")
    private var receiverLocators: [UUID: LogitechEndpointLocator] = [:]
    private var transport: (any BoltReceiverTransport)?
    private var selectedEndpoint: LogitechEndpointLocator?
    private var receiverTask: Task<Void, Never>?
    private var discoveryTimeoutTask: Task<Void, Never>?
    private var authenticationTimeoutTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var discoveryActive = false
    private var discoveryStartInFlight = false
    private var discoveryStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var discoveryCancelSent = false
    private var discoveryCancelOutcome: BoltPairingCancellationOutcome?
    private var discoveryCancelTask: Task<BoltPairingCancellationOutcome, Never>?
    private var discoveryStopRequestedForSelection = false
    private var pairCommandSent = false
    private var pairRequestInFlight = false
    private var pairRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var pairingVerificationInFlight = false
    private var pairingVerificationWaiters: [CheckedContinuation<Void, Never>] = []
    private var pairCancelSent = false
    private var pairCancellationInFlight = false
    private var pairCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelRequested = false
    private var cancellationInFlight = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var notificationSetupTask: Task<Bool, Never>?
    private var notificationCleanupTask: Task<Void, Never>?
    private var notificationLease: BoltReceiverNotificationLease?
    private var notificationChannelUncertain = false
    private var notificationSetupMessage: String?
    private var notificationCleanupMessage: String?
    private var notificationCleanupRequiresAttention = false
    private var pairingResolved = false
    private var pairingMayHaveSucceeded = false
    private var terminalPairingStatusReceived = false
    private var pairingSuccessNotificationClaimed = false
    private var identityProbeNonce: UInt8 = 0
    private var baselineInventory: BoltPairingInventory?
    private var candidateAssemblies: [BoltPairingCandidateKey: BoltPairingCandidateAssembly] = [:]
    private var candidateAliases: [BoltPairingCandidateKey: BoltPairingCandidateKey] = [:]
    private var candidateAliasOrder: [BoltPairingCandidateKey] = []
    private var candidateIDs: [UUID: BoltPairingCandidateKey] = [:]
    private var selectedCandidate: BoltPairingCandidateKey?
    private var challenge: BoltPairingChallenge?
    private var authenticationProgress = 0
    private var authenticationComplete = false
    private var unsupportedAdvertisementObserved = false
    private var discoveryDiagnostics = BoltDiscoveryDiagnostics()
    private var nativeInputDiagnostics = BoltNativeInputDiagnostics()

    public init() {
        self.init(catalog: IOKitLogitechEndpointCatalog())
    }

    init(catalog: any LogitechEndpointCatalog,
         discoveryTimeout: Duration = .seconds(30),
         authenticationTimeout: Duration = .seconds(60),
         cancellationReconciliationTimeout: Duration = .seconds(2)) {
        let stream = AsyncStream<BoltPairingStatus>.makeStream(bufferingPolicy: .bufferingNewest(64))
        events = stream.stream
        continuation = stream.continuation
        self.catalog = catalog
        self.discoveryTimeout = discoveryTimeout
        self.authenticationTimeout = authenticationTimeout
        self.cancellationReconciliationTimeout = cancellationReconciliationTimeout
        continuation.yield(status)
    }

    public func currentStatus() async -> BoltPairingStatus {
        if let transport {
            await refreshNativeInputDiagnostics(from: transport, generation: generation)
            publishDiagnosticsSnapshotIfNeeded()
        }
        return status
    }

    public func receivers() async throws -> [BoltReceiverCandidate] {
        guard transport == nil else { throw BoltReceiverTransportFailure.busy }
        resetAttempt()
        let endpoints = try await catalog.enumerate()
        guard endpoints.count <= 16 else { throw BoltFailure.ambiguous }

        let boltEndpoints = endpoints.filter {
            $0.connection == .bolt && $0.productID == LogitechEndpointEligibility.boltProductID
        }
        receiverLocators = Dictionary(uniqueKeysWithValues: boltEndpoints.map { ($0.id, $0) })
        let receivers = boltEndpoints.enumerated().map { index, endpoint in
            BoltReceiverCandidate(id: endpoint.id,
                                  label: boltEndpoints.count == 1
                                    ? "Logi Bolt receiver"
                                    : "Logi Bolt receiver \(index + 1)")
        }
        publish(.idle, receivers.isEmpty ? "No eligible Bolt receiver is available." : "Select a Bolt receiver.")
        return receivers
    }

    public func start(receiverID: UUID) async {
        guard transport == nil, let endpoint = receiverLocators[receiverID],
              endpoint.connection == .bolt,
              endpoint.productID == LogitechEndpointEligibility.boltProductID else {
            publish(.failed, "The selected receiver is no longer available.")
            return
        }

        discoveryDiagnostics = .init()
        nativeInputDiagnostics = .init()
        generation &+= 1
        let attempt = generation
        selectedEndpoint = endpoint
        closing = false
        cancelRequested = false
        let receiver = catalog.makeReceiverTransport(for: endpoint, onTerminal: {})
        guard let receiver else {
            publish(.failed, "The selected receiver cannot open a pairing session.")
            return
        }

        transport = receiver
        do {
            try await receiver.open()
        } catch {
            guard generation == attempt, !closing else { return }
            await releaseTransport(receiver, generation: attempt)
            publish(.failed, "The selected receiver could not be opened.")
            return
        }
        guard generation == attempt, !cancelRequested, !closing else { return }

        await refreshNativeInputDiagnostics(from: receiver, generation: attempt)
        guard generation == attempt, !cancelRequested, !closing else { return }

        receiverTask = Task { [weak self, stream = receiver.receiverEvents] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.receive(event, generation: attempt)
            }
        }

        do {
            let inventory = try await readInventory(on: receiver, endpoint: endpoint)
            await refreshNativeInputDiagnostics(from: receiver, generation: attempt)
            guard generation == attempt, !cancelRequested, !closing else { return }
            baselineInventory = inventory
            guard inventory.records.count < inventory.capacity else {
                publish(.failed, "All \(inventory.capacity) receiver slots contain stored pairings, including offline devices. Use another receiver to pair a new mouse.")
                return
            }
        } catch {
            await refreshNativeInputDiagnostics(from: receiver, generation: attempt)
            guard generation == attempt else { return }
            publish(.failed, "Receiver pairing records could not be verified.")
            return
        }

        guard !cancelRequested, !closing else { return }
        let setupTask = Task { await self.prepareNotifications(on: receiver) }
        notificationSetupTask = setupTask
        let setupVerified = await setupTask.value
        guard generation == attempt else { return }
        notificationSetupTask = nil
        guard !cancelRequested, !closing else { return }
        guard setupVerified, !notificationChannelUncertain else {
            publish(.failed, "Receiver notifications could not be verified; discovery was not started.")
            await cleanupNotifications(on: receiver)
            return
        }
        discoveryActive = true
        discoveryStartInFlight = true
        do {
            try await registerWrite(on: receiver, register: 0x00C0, payload: [30, 1])
            finishDiscoveryStart()
        } catch {
            finishDiscoveryStart()
            guard generation == attempt, !closing else { return }
            _ = await cancelDiscoveryIfNeeded()
            guard generation == attempt, !cancelRequested, !closing else { return }
            publish(.failed, "Receiver discovery could not be started.")
            return
        }
        await refreshNativeInputDiagnostics(from: receiver, generation: attempt)
        if cancelRequested || closing {
            _ = await cancelDiscoveryIfNeeded()
            return
        }
        guard generation == attempt, !cancelRequested, !closing else { return }
        publish(.discovering, "Searching for supported Logitech mice.")
        discoveryTimeoutTask = Task { [weak self, discoveryTimeout] in
            try? await Task.sleep(for: discoveryTimeout)
            guard !Task.isCancelled else { return }
            await self?.discoveryTimedOut(generation: attempt)
        }
    }

    public func select(candidateID: UUID) async {
        guard status.phase != .failed else { return }
        guard !closing, transport != nil, !pairCommandSent,
              let endpoint = selectedEndpoint,
              let key = candidateIDs[candidateID],
              let assembly = candidateAssemblies[key],
              let metadata = assembly.metadata,
              BoltPairingProtocolDecoder.model(productID: metadata.productID) != nil,
              metadata.deviceKind == BoltPairingProtocolDecoder.mouseDeviceKind,
              metadata.authentication == BoltPairingProtocolDecoder.twoButtonAuthentication else {
            publish(.failed, "The selected candidate is stale or does not have a supported mouse authentication method.")
            return
        }

        let attempt = generation
        selectedCandidate = key
        if discoveryActive {
            discoveryStopRequestedForSelection = true
            await waitForDiscoveryStart()
            guard generation == attempt, !cancelRequested, !closing else { return }
            guard await cancelDiscoveryIfNeeded() else {
                publish(.failed, "Discovery could not be stopped safely.")
                return
            }
            guard generation == attempt, !cancelRequested, !closing else { return }
            discoveryTimeoutTask?.cancel()
            discoveryTimeoutTask = nil
        }
        guard generation == attempt, !cancelRequested, !closing,
              let receiver = transport else { return }

        do {
            let freshInventory = try await readInventory(on: receiver, endpoint: endpoint)
            guard generation == attempt, !cancelRequested, !closing else { return }
            guard let baselineInventory,
                  freshInventory.hasSameRecords(as: baselineInventory) else {
                publish(.failed, "Receiver pairing records changed during discovery.")
                return
            }
            guard freshInventory.records.count < freshInventory.capacity else {
                publish(.failed, "All \(freshInventory.capacity) receiver slots contain stored pairings, including offline devices. Use another receiver to pair a new mouse.")
                return
            }
        } catch {
            guard generation == attempt, !cancelRequested, !closing else { return }
            publish(.failed, "Receiver pairing records are no longer authoritative.")
            return
        }

        guard generation == attempt, !cancelRequested, !closing, status.phase != .failed else { return }
        pairingMayHaveSucceeded = true
        pairingResolved = false
        pairCommandSent = true
        publish(.authenticating, "Follow the mouse authentication instructions.")
        let payload = [UInt8(1), 0] + metadata.address + [metadata.authentication, 10]
        pairRequestInFlight = true
        do {
            try await registerWrite(on: receiver, register: 0x02C1, payload: payload)
            finishPairRequest()
            guard generation == attempt else { return }
            if cancelRequested || closing {
                publish(.cancelled, "Cancellation was requested; checking whether pairing completed.",
                        pairingMayHaveSucceeded: true)
                return
            }
            authenticationTimeoutTask = Task { [weak self, authenticationTimeout] in
                try? await Task.sleep(for: authenticationTimeout)
                guard !Task.isCancelled else { return }
                await self?.authenticationTimedOut(generation: attempt)
            }
        } catch let failure as BoltReceiverTransportFailure where failure == .registerRejected(code: 0x05) {
            finishPairRequest()
            guard generation == attempt else { return }
            pairingMayHaveSucceeded = false
            pairingResolved = true
            publish(.failed, "The receiver rejected the pairing because its capacity changed.")
        } catch let failure as BoltReceiverTransportFailure where isRejected(failure) {
            finishPairRequest()
            guard generation == attempt else { return }
            pairingMayHaveSucceeded = false
            pairingResolved = true
            publish(.failed, "The receiver rejected the pairing request.")
        } catch {
            finishPairRequest()
            guard generation == attempt else { return }
            publishPossiblePairing("Pairing may have completed, but no verified mouse was added.")
        }
    }

    public func cancel() async {
        if cancellationInFlight {
            await waitForCancellation()
            return
        }
        guard let receiver = transport, !closing else { return }
        cancellationInFlight = true
        defer { finishCancellation() }
        let attempt = generation
        await cancelPairing()
        guard generation == attempt, !closing else { return }
        await cleanupNotifications(on: receiver)
    }

    private func cancelPairing() async {
        guard transport != nil, !cancelRequested else { return }
        cancelRequested = true
        if let notificationSetupTask { _ = await notificationSetupTask.value }
        guard !closing else { return }
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil

        guard let receiver = transport else { return }
        let attempt = generation
        if pairCommandSent {
            if status.phase == .failed, pairingResolved, !pairingMayHaveSucceeded { return }
            if pairingSuccessNotificationClaimed && pairingResolved {
                publish(.pairedButNotAdded, "Pairing completed before cancellation and was not added to Hidhogg.",
                        pairingMayHaveSucceeded: true)
                return
            }
            await sendPairCancel(on: receiver)
            guard generation == attempt, !closing else { return }
            guard status.phase != .pairedButNotAdded, status.phase != .verified else { return }
            publish(.cancelled, "Cancellation was requested; checking whether pairing completed.",
                    pairingMayHaveSucceeded: true)
            return
        }

        if discoveryActive {
            await waitForDiscoveryStart()
            guard generation == attempt, !closing else { return }
            guard await cancelDiscoveryIfNeeded() else {
                publish(.failed, "Discovery could not be stopped safely.")
                return
            }
        }
        publish(.cancelled, "Pairing was cancelled.")
    }

    public func close() async {
        if closing {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        guard let receiver = transport else {
            receiverLocators.removeAll()
            return
        }
        closing = true
        await waitForCancellation()
        if let notificationSetupTask { _ = await notificationSetupTask.value }
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil

        await waitForPairingVerification()
        if pairCommandSent, status.phase == .failed, !pairingMayHaveSucceeded,
           let endpoint = selectedEndpoint {
            do {
                let inventory = try await readInventory(on: receiver, endpoint: endpoint)
                if status.phase == .failed, !pairingSuccessNotificationClaimed,
                   baselineInventory?.hasSameRecords(as: inventory) != true {
                    publishPossiblePairing("Receiver pairing records changed after the reported failure; pairing outcome is uncertain.")
                }
            } catch {
                if status.phase == .failed, !pairingSuccessNotificationClaimed {
                    publishPossiblePairing("Pairing outcome is uncertain; receiver records could not be rechecked after the reported failure.")
                }
            }
        }

        if pairCommandSent && pairingMayHaveSucceeded && status.phase != .verified {
            if !terminalPairingStatusReceived {
                await sendPairCancel(on: receiver)
            }
            if pairingVerificationInFlight {
                await waitForPairingVerification()
            } else if !pairingResolved {
                await waitForPairingResolution()
            }
            if status.phase != .verified, let endpoint = selectedEndpoint {
                do {
                    let finalInventory = try await readInventory(on: receiver, endpoint: endpoint)
                    if let baselineInventory,
                       !finalInventory.hasSameRecords(as: baselineInventory) {
                        publishPossiblePairing("Pairing may have completed, but it was not added to Hidhogg.")
                    } else if terminalPairingStatusReceived && status.phase == .failed && !pairingMayHaveSucceeded {
                        pairingResolved = true
                    } else if terminalPairingStatusReceived && status.phase == .cancelled {
                        pairingMayHaveSucceeded = false
                        pairingResolved = true
                        publish(.cancelled, "Receiver cancellation was confirmed and no new pairing record appeared.")
                    } else {
                        publishPossiblePairing("Pairing outcome is uncertain; no mouse was added to Hidhogg.")
                    }
                } catch {
                    publishPossiblePairing("Pairing outcome is uncertain; no mouse was added to Hidhogg.")
                }
                pairingResolved = true
            }
        } else if discoveryActive && !pairCommandSent {
            await waitForDiscoveryStart()
            if !(await cancelDiscoveryIfNeeded()) {
                publish(.failed, "Discovery cleanup could not be verified.")
            }
            if !cancelRequested { publish(.cancelled, "Pairing was closed before selection.") }
        }

        await releaseTransport(receiver, generation: generation)
        selectedEndpoint = nil
        receiverLocators.removeAll()
        candidateAssemblies.removeAll()
        candidateAliases.removeAll()
        candidateAliasOrder.removeAll()
        candidateIDs.removeAll()
        selectedCandidate = nil
        baselineInventory = nil
        challenge = nil
        authenticationProgress = 0
        authenticationComplete = false
        discoveryActive = false
        discoveryStartInFlight = false
        discoveryCancelSent = false
        discoveryCancelOutcome = nil
        discoveryCancelTask = nil
        pairCommandSent = false
        pairRequestInFlight = false
        pairingVerificationInFlight = false
        pairCancelSent = false
        cancelRequested = false
        closing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
        generation &+= 1
    }

    private func receive(_ event: BoltReceiverEvent, generation expectedGeneration: UInt64) async {
        guard expectedGeneration == generation else { return }
        if let transport {
            await refreshNativeInputDiagnostics(from: transport, generation: expectedGeneration)
        }
        guard expectedGeneration == generation else { return }
        defer { publishDiagnosticsSnapshotIfNeeded() }

        switch event {
        case .failure(let failure):
            noteNotificationChannelFailure(failure)
            discoveryDiagnostics.recordTransportFailure()
            guard status.phase != .verified, status.phase != .failed else { return }
            if pairCommandSent {
                publishPossiblePairing("Pairing may have completed, but no verified mouse was added.")
            } else {
                publish(.failed, "The receiver session ended before pairing could be verified.")
                pairingResolved = true
            }
        case .notification(let notification, _):
            switch notification {
            case .discoveryAdvertisement:
                discoveryDiagnostics.recordAdvertisementEvent()
            case .recoveryAdvertisement:
                discoveryDiagnostics.recordRecoveryEvent()
            case .discoveryStatus:
                discoveryDiagnostics.recordDiscoveryStatusEvent()
            case .pairingStatus, .passkeyDisplayed, .passkeyEntry:
                break
            }

            guard status.phase != .failed || pairCommandSent else { return }
            if case .pairingStatus = notification {
                await receivePairingStatusForEvent(notification, generation: expectedGeneration)
                return
            }
            guard !cancelRequested, !closing, discoveryActive || pairCommandSent else { return }
            if pairCommandSent {
                guard !pairingResolved, !terminalPairingStatusReceived else { return }
                switch notification {
                case .passkeyDisplayed(let payload):
                    receiveChallenge(payload)
                case .passkeyEntry(let code, let payload):
                    receiveAuthenticationProgress(code: code, payload: payload)
                default:
                    return
                }
                return
            }
            switch notification {
            case .discoveryAdvertisement(let payload):
                receiveAdvertisement(payload)
            case .recoveryAdvertisement:
                unsupportedAdvertisementObserved = true
                discoveryTimeoutTask?.cancel()
                discoveryTimeoutTask = nil
                if pairCommandSent {
                    publishPossiblePairing("A recovery event interrupted pairing; no verified mouse was added.")
                } else {
                    publish(.failed, "Receiver recovery advertisements are not supported in this pairing flow.")
                }
                _ = await cancelDiscoveryIfNeeded()
            case .discoveryStatus(let state, let error, let payload):
                receiveDiscoveryStatus(state: state, error: error, payload: payload)
            case .pairingStatus:
                return
            case .passkeyDisplayed(let payload):
                receiveChallenge(payload)
            case .passkeyEntry(let code, let payload):
                receiveAuthenticationProgress(code: code, payload: payload)
            }
        }
    }

    private func receiveAdvertisement(_ payload: [UInt8]) {
        let fragment: BoltPairingAdvertisementFragment
        do {
            fragment = try BoltPairingProtocolDecoder.advertisement(payload)
        } catch {
            discoveryDiagnostics.recordRejectedAdvertisement()
            if pairCommandSent {
                publishPossiblePairing("An unsupported receiver message interrupted pairing.")
            } else {
                publish(.failed, "An unsupported or malformed discovery message was ignored safely.")
            }
            return
        }
        discoveryDiagnostics.recordDecodedAdvertisement()
        if let metadata = fragment.metadata,
           BoltPairingProtocolDecoder.model(productID: metadata.productID) == nil {
            discoveryDiagnostics.recordUnsupportedModelAdvertisement()
        }

        var key = candidateAliases[fragment.key] ?? fragment.key
        var assembly = candidateAssemblies[key] ?? BoltPairingCandidateAssembly()
        var observation = BoltPairingCandidateAssembly()
        observation.metadata = fragment.metadata
        observation.nameTotalLength = fragment.nameTotalLength
        if let bytes = fragment.nameBytes { observation.fragments[fragment.part] = bytes }
        guard assembly.merge(observation) else {
            discoveryDiagnostics.recordRejectedAdvertisement()
            removeCandidate(for: key)
            publish(.failed, "A conflicting discovery fragment invalidated the candidate.")
            return
        }

        if let metadata = assembly.metadata,
           let existing = candidateAssemblies.first(where: {
               $0.key != key && $0.value.metadata?.address == metadata.address
           }) {
            var canonical = existing.value
            guard canonical.merge(assembly) else {
                discoveryDiagnostics.recordRejectedAdvertisement()
                removeCandidate(for: key)
                removeCandidate(for: existing.key)
                publish(.failed, "Conflicting discovery metadata or name invalidated the candidate.")
                return
            }
            if let retiredID = assembly.candidateID, retiredID != canonical.candidateID {
                candidateIDs.removeValue(forKey: retiredID)
            }
            for alias in candidateAliasOrder where candidateAliases[alias] == key {
                candidateAliases[alias] = existing.key
            }
            candidateAssemblies.removeValue(forKey: key)
            key = existing.key
            assembly = canonical
        }

        if candidateAssemblies[key] == nil {
            guard candidateAssemblies.count < BoltPairingProtocolDecoder.maximumAssemblies else {
                discoveryDiagnostics.recordRejectedAdvertisement()
                publish(.failed, "Discovery exceeded its bounded candidate limit.")
                return
            }
        }
        retainCandidateAlias(fragment.key, canonical: key)

        if let metadata = assembly.metadata {
            guard let model = BoltPairingProtocolDecoder.model(productID: metadata.productID),
                  metadata.deviceKind == BoltPairingProtocolDecoder.mouseDeviceKind,
                  metadata.authentication == BoltPairingProtocolDecoder.twoButtonAuthentication else {
                unsupportedAdvertisementObserved = true
                candidateAssemblies[key] = assembly
                publishDiscoveryCandidates()
                return
            }
            if assembly.candidateID == nil {
                guard candidateIDs.count < BoltPairingProtocolDecoder.maximumCandidates else {
                    discoveryDiagnostics.recordRejectedAdvertisement()
                    publish(.failed, "Discovery exceeded its bounded candidate limit.")
                    return
                }
                let candidateID = UUID()
                assembly.candidateID = candidateID
                candidateIDs[candidateID] = key
            }
            _ = model
        }

        candidateAssemblies[key] = assembly
        publishDiscoveryCandidates()
    }

    private func receiveDiscoveryStatus(state: UInt8, error: UInt8, payload: [UInt8]) {
        guard !pairCommandSent else { return }
        guard BoltPairingProtocolDecoder.validDiscoveryStatus(state: state, error: error, payload: payload) else {
            publish(.failed, "The receiver returned an unsupported discovery state.")
            return
        }
        guard error == 0 else {
            discoveryActive = false
            publish(.failed, "Receiver discovery ended with an error.")
            return
        }
        switch state {
        case 0:
            discoveryActive = true
        case 1:
            discoveryActive = false
            if discoveryStopRequestedForSelection || cancelRequested { return }
            publish(.cancelled, "Receiver discovery was cancelled.")
        case 2:
            discoveryActive = false
            discoveryTimeoutTask?.cancel()
            discoveryTimeoutTask = nil
            if !candidateIDs.isEmpty {
                publishDiscoveryCandidates()
            } else {
                let suffix = unsupportedAdvertisementObserved ? " Unsupported candidates were ignored." : ""
                publish(.failed, "No verified supported mouse was found.\(suffix)")
            }
        default:
            publish(.failed, "The receiver returned an unsupported discovery state.")
        }
    }

    private func receiveChallenge(_ payload: [UInt8]) {
        guard pairCommandSent, !cancelRequested, !closing else { return }
        do {
            let decoded = try BoltPairingProtocolDecoder.challenge(payload)
            challenge = BoltPairingChallenge(directions: decoded.directions,
                                             completedClicks: authenticationProgress,
                                             requiredClicks: BoltPairingProtocolDecoder.requiredClicks,
                                             entryComplete: authenticationComplete)
            publish(.authenticating, "Complete the ten-click mouse challenge, then press both buttons together.")
        } catch {
            publishPossiblePairing("The mouse authentication challenge could not be verified.")
        }
    }

    private func receiveAuthenticationProgress(code: UInt8, payload: [UInt8]) {
        guard code <= 4, pairCommandSent, !cancelRequested, !closing,
              let selectedCandidate,
              let metadata = candidateAssemblies[selectedCandidate]?.metadata,
              let progress = try? BoltPairingProtocolDecoder.authenticationProgress(code: code, payload: payload),
              progress.address == metadata.address else { return }

        switch code {
        case 0, 3:
            authenticationProgress = 0
            authenticationComplete = false
        case 1:
            authenticationProgress = min(authenticationProgress + 1, BoltPairingProtocolDecoder.requiredClicks)
            authenticationComplete = false
        case 2:
            authenticationProgress = max(authenticationProgress - 1, 0)
            authenticationComplete = false
        case 4:
            authenticationComplete = true
        default:
            return
        }

        if let challenge {
            self.challenge = BoltPairingChallenge(directions: challenge.directions,
                                                  confirmationDirection: challenge.confirmationDirection,
                                                  completedClicks: authenticationProgress,
                                                  requiredClicks: challenge.requiredClicks,
                                                  entryComplete: authenticationComplete)
        }
        publish(.authenticating, authenticationComplete
                ? "Mouse authentication is complete; waiting for receiver confirmation."
                : "Follow the mouse authentication instructions.")
    }

    private func receivePairingStatus(state: UInt8, error: UInt8, payload: [UInt8]) async {
        var ownsVerification = false
        defer {
            if ownsVerification { finishPairingVerification() }
        }
        do {
            let terminal = try BoltPairingProtocolDecoder.pairingStatus(state: state, error: error,
                                                                         payload: payload)
            guard pairCommandSent else { return }
            guard !pairingSuccessNotificationClaimed, status.phase != .verified else { return }
            if terminal.state == 0 { return }
            if status.phase == .failed, terminal.state != 2 || terminal.error != 0 { return }
            if terminal.state == 2 && terminal.error == 0 {
                pairingSuccessNotificationClaimed = true
                pairingResolved = false
                pairingVerificationInFlight = true
                ownsVerification = true
            }
            let authenticationFailure = terminal.state == 2 && terminal.error == 2
                && challenge != nil && !cancelRequested
                && selectedCandidate.flatMap { candidateAssemblies[$0]?.metadata?.address } == terminal.address
            if authenticationFailure {
                pairingVerificationInFlight = true
                ownsVerification = true
            }
            let attempt = generation
            await waitForPairRequest()
            guard generation == attempt, pairCommandSent else { return }
            terminalPairingStatusReceived = true
            authenticationTimeoutTask?.cancel()
            authenticationTimeoutTask = nil

            guard terminal.state == 2, terminal.error == 0 else {
                if authenticationFailure, let receiver = transport,
                   let endpoint = selectedEndpoint, let baselineInventory {
                    let inventory = try await readInventory(on: receiver, endpoint: endpoint)
                    guard generation == attempt else { return }
                    if inventory.hasSameRecords(as: baselineInventory) {
                        pairingResolved = true
                        pairingMayHaveSucceeded = false
                        publish(.failed, "The receiver reported a pairing failure during authentication; no new pairing was found.")
                        return
                    }
                }
                pairingResolved = true
                if cancelRequested {
                    publish(.cancelled, "Pairing was cancelled; no new association was added.")
                    pairingMayHaveSucceeded = true
                } else {
                    publishPossiblePairing("The receiver did not confirm a verified pairing.")
                }
                return
            }

            guard let selectedCandidate,
                  let assembly = candidateAssemblies[selectedCandidate],
                  let metadata = assembly.metadata,
                  terminal.address == metadata.address,
                  terminal.slot > 0,
                  let endpoint = selectedEndpoint else {
                pairingResolved = true
                publishPossiblePairing("The receiver confirmation did not match the selected mouse and slot.")
                return
            }
            let capacity = try BoltPairingProtocolDecoder.capacity(for: endpoint.productID)
            guard terminal.slot <= capacity else {
                pairingResolved = true
                publishPossiblePairing("The receiver confirmation assigned an unsupported slot.")
                return
            }

            publish(.verifying, "Verifying the new receiver pairing and mouse identity.",
                    pairingMayHaveSucceeded: true)
            await verifyPairing(slot: terminal.slot, metadata: metadata,
                                wasCancelled: cancelRequested || closing, generation: generation)
        } catch {
            pairingResolved = true
            publishPossiblePairing("The receiver pairing status could not be verified.")
        }
    }

    private func verifyPairing(slot: UInt8, metadata: BoltPairingAdvertisementMetadata,
                               wasCancelled: Bool, generation expectedGeneration: UInt64) async {
        guard let receiver = transport, let endpoint = selectedEndpoint,
              let baselineInventory else {
            pairingResolved = true
            publishPossiblePairing("Pairing may have completed, but no verified mouse was added.")
            return
        }

        if let notificationCleanupTask { await notificationCleanupTask.value }
        guard generation == expectedGeneration else { return }
        do {
            let inventory = try await readInventory(on: receiver, endpoint: endpoint)
            guard generation == expectedGeneration else { return }
            guard baselineInventory.records[slot] == nil else {
                pairingResolved = true
                publishPossiblePairing("The assigned slot was not verified as empty before pairing.")
                return
            }
            guard let pairedRecord = inventory.records[slot],
                  pairedRecord.productID == metadata.productID,
                  pairedRecord.deviceKind == BoltPairingProtocolDecoder.mouseDeviceKind,
                  inventory.hasOnlyAddedRecord(slot, comparedTo: baselineInventory) else {
                pairingResolved = true
                publishPossiblePairing("Receiver records changed without proving the selected mouse.")
                return
            }

            identityProbeNonce = identityProbeNonce == 200 ? 1 : identityProbeNonce &+ 1
            let identity = try await LogitechIdentityReader.read(
                on: receiver, endpoint: endpoint, slot: slot, nonce: identityProbeNonce,
                deadline: ContinuousClock.now.advanced(by: .seconds(8))
            )
            guard generation == expectedGeneration else { return }
            guard identity.model == BoltPairingProtocolDecoder.model(productID: metadata.productID) else {
                pairingResolved = true
                publishPossiblePairing("The new mouse identity did not match its discovery and receiver records.")
                return
            }

            let candidate = LogitechEndpointCandidate(
                id: UUID(), connection: .bolt, model: identity.model, identity: identity.identity,
                information: BoltDeviceInformation(featureVersions: [0x0003: identity.featureVersion])
            )
            pairingResolved = true
            terminalPairingStatusReceived = true
            if wasCancelled || cancelRequested || closing {
                publish(.pairedButNotAdded, "Pairing completed during cancellation and was not added to Hidhogg.",
                        verifiedCandidate: nil, pairingMayHaveSucceeded: true)
            } else {
                publish(.verified, "The receiver pairing and mouse identity were verified.",
                        verifiedCandidate: candidate, pairingMayHaveSucceeded: true)
            }
        } catch {
            pairingResolved = true
            publishPossiblePairing("Pairing may have completed, but no verified mouse was added.")
        }
    }

    private func discoveryTimedOut(generation expectedGeneration: UInt64) async {
        guard generation == expectedGeneration, discoveryActive, !pairCommandSent, !closing,
              status.phase != .failed else { return }
        let cancelled = await cancelDiscoveryIfNeeded()
        if let transport {
            await refreshNativeInputDiagnostics(from: transport, generation: expectedGeneration)
        }
        guard generation == expectedGeneration, !cancelRequested, !closing else { return }
        guard cancelled else {
            publish(.failed, "Discovery cleanup could not be verified.")
            return
        }
        if candidateIDs.isEmpty {
            publish(.failed, "Discovery timed out without finding a verified supported mouse.")
        } else {
            publishDiscoveryCandidates()
        }
    }

    private func authenticationTimedOut(generation expectedGeneration: UInt64) async {
        guard generation == expectedGeneration, pairCommandSent, !pairingResolved, !closing else { return }
        cancelRequested = true
        await sendPairCancel(on: transport)
        if let transport {
            await refreshNativeInputDiagnostics(from: transport, generation: expectedGeneration)
        }
        guard generation == expectedGeneration else { return }
        publishPossiblePairing("Authentication timed out; pairing may have completed and was not added.")
        pairingResolved = false
    }

    private func cancelDiscoveryIfNeeded() async -> Bool {
        let attempt = generation
        await waitForDiscoveryStart()
        guard generation == attempt, let receiver = transport else { return false }
        if let discoveryCancelOutcome { return discoveryCancelOutcome == .acknowledged }
        guard discoveryActive else { return true }
        if let discoveryCancelTask { return await discoveryCancelTask.value == .acknowledged }
        guard !discoveryCancelSent else { return false }

        let request: BoltReceiverRegisterRequest
        do {
            request = try BoltReceiverRegisterRequest(operation: .write, register: 0x00C0, payload: [0, 2])
        } catch {
            discoveryCancelOutcome = .failed
            return false
        }

        discoveryCancelSent = true
        let task = Task { [self, receiver] in
            let outcome: BoltPairingCancellationOutcome
            do {
                switch try await receiver.cancelRequest(request) {
                case .acknowledged:
                    outcome = .acknowledged
                case .dispatchedUnconfirmed:
                    notificationChannelUncertain = true
                    outcome = .dispatchedUnconfirmed
                }
            } catch let failure as BoltReceiverTransportFailure where failure == .busy {
                outcome = .busy
            } catch {
                noteNotificationChannelFailure(error)
                outcome = .failed
            }
            await finishDiscoveryCancellation(outcome, generation: attempt)
            return outcome
        }
        discoveryCancelTask = task
        return await task.value == .acknowledged
    }

    private func finishDiscoveryCancellation(_ outcome: BoltPairingCancellationOutcome,
                                             generation expectedGeneration: UInt64) {
        guard generation == expectedGeneration else { return }
        discoveryCancelTask = nil
        switch outcome {
        case .acknowledged:
            discoveryActive = false
            discoveryCancelOutcome = .acknowledged
        case .dispatchedUnconfirmed, .failed:
            discoveryCancelOutcome = outcome
        case .busy:
            discoveryCancelSent = false
            discoveryCancelOutcome = nil
        }
    }

    private func sendPairCancel(on receiver: (any BoltReceiverTransport)?) async {
        if pairCancellationInFlight {
            await waitForPairCancellation()
            return
        }
        guard pairCommandSent, !pairCancelSent, !terminalPairingStatusReceived,
              !pairingSuccessNotificationClaimed, let receiver else { return }
        pairCancellationInFlight = true
        defer { finishPairCancellation() }
        do {
            await waitForPairRequest()
            guard pairCommandSent, !terminalPairingStatusReceived,
                  !pairingSuccessNotificationClaimed else { return }
            let request = try BoltReceiverRegisterRequest(operation: .write, register: 0x02C1, payload: [2])
            pairCancelSent = true
            let result = try await receiver.cancelRequest(request)
            if case .dispatchedUnconfirmed = result {
                notificationChannelUncertain = true
                publishPossiblePairing("Cancellation was attempted, but the receiver outcome remains uncertain.")
            }
        } catch {
            noteNotificationChannelFailure(error)
            if let failure = error as? BoltReceiverTransportFailure, failure == .busy {
                pairCancelSent = false
            } else {
                pairCancelSent = true
            }
            publishPossiblePairing("Cancellation could not be verified; the receiver outcome remains uncertain.")
        }
    }

    private func receivePairingStatusForEvent(_ notification: BoltReceiverNotification,
                                              generation expectedGeneration: UInt64) async {
        guard case .pairingStatus(let state, let error, let payload) = notification,
              expectedGeneration == generation else { return }
        await receivePairingStatus(state: state, error: error, payload: payload)
    }

    private func isRejected(_ failure: BoltReceiverTransportFailure) -> Bool {
        if case .registerRejected = failure { return true }
        return false
    }

    private func waitForPairingResolution() async {
        guard pairCommandSent, !pairingResolved else { return }
        let deadline = ContinuousClock.now.advanced(by: cancellationReconciliationTimeout)
        while !pairingResolved, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForDiscoveryStart() async {
        guard discoveryStartInFlight else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            discoveryStartWaiters.append(continuation)
        }
    }

    private func waitForCancellation() async {
        guard cancellationInFlight else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func finishCancellation() {
        cancellationInFlight = false
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForPairRequest() async {
        guard pairRequestInFlight else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pairRequestWaiters.append(continuation)
        }
    }

    private func waitForPairCancellation() async {
        guard pairCancellationInFlight else { return }
        await withCheckedContinuation { pairCancellationWaiters.append($0) }
    }

    private func finishPairCancellation() {
        pairCancellationInFlight = false
        let waiters = pairCancellationWaiters
        pairCancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForPairingVerification() async {
        guard pairingVerificationInFlight else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pairingVerificationWaiters.append(continuation)
        }
    }

    private func finishDiscoveryStart() {
        discoveryStartInFlight = false
        let waiters = discoveryStartWaiters
        discoveryStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishPairRequest() {
        pairRequestInFlight = false
        let waiters = pairRequestWaiters
        pairRequestWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func finishPairingVerification() {
        pairingVerificationInFlight = false
        let waiters = pairingVerificationWaiters
        pairingVerificationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func prepareNotifications(on receiver: any BoltReceiverTransport) async -> Bool {
        do {
            let baseline = try await readNotificationMask(on: receiver)
            guard !cancelRequested, !closing else { return false }
            let lease = BoltReceiverNotificationLease(baseline: baseline)
            notificationLease = lease
            if lease.ownedBits == 0 {
                notificationSetupMessage = "Required receiver notifications were already enabled; no change was made."
                publishDiagnosticsSnapshotIfNeeded()
                return true
            }
            // Retain mutation intent before suspension: a lost acknowledgement can still mean a write occurred.
            do {
                try await registerWrite(on: receiver, register: 0, payload: lease.setupBytes)
            } catch {
                if let failure = error as? BoltReceiverTransportFailure, isRejected(failure) {
                    notificationLease = nil
                }
                throw error
            }
            let readback = try await readNotificationMask(on: receiver)
            guard readback == lease.expectedMask else {
                notificationSetupMessage = "Receiver notification setup did not match its verification readback."
                publishDiagnosticsSnapshotIfNeeded()
                return false
            }
            notificationSetupMessage = "Temporary receiver notifications were enabled and verified."
            publishDiagnosticsSnapshotIfNeeded()
            return true
        } catch {
            noteNotificationChannelFailure(error)
            notificationSetupMessage = "Receiver notification setup could not be verified."
            publishDiagnosticsSnapshotIfNeeded()
            return false
        }
    }

    private func cleanupNotifications(on receiver: any BoltReceiverTransport) async {
        if let notificationSetupTask { _ = await notificationSetupTask.value }
        await waitForPairCancellation()
        await waitForPairingVerification()
        if let notificationCleanupTask {
            await notificationCleanupTask.value
            return
        }
        guard let lease = notificationLease, lease.ownedBits != 0 else { return }
        guard !pairCommandSent || pairingResolved || closing else {
            notificationCleanupRequiresAttention = true
            publishDiagnosticsSnapshotIfNeeded()
            return
        }
        let task = Task { await self.restoreNotifications(lease, on: receiver) }
        notificationCleanupTask = task
        await task.value
    }

    private func restoreNotifications(_ lease: BoltReceiverNotificationLease,
                                      on receiver: any BoltReceiverTransport) async {
        defer { publishDiagnosticsSnapshotIfNeeded() }
        guard !notificationChannelUncertain else {
            notificationCleanupRequiresAttention = true
            notificationCleanupMessage = "Receiver notification restoration is uncertain; the request channel was not safe to reuse."
            return
        }
        do {
            let current = try await readNotificationMask(on: receiver)
            guard current == lease.expectedMask else {
                notificationCleanupRequiresAttention = true
                notificationCleanupMessage = "Receiver notification flags changed; restoration was skipped to preserve external changes."
                return
            }
            let restored = current & ~lease.ownedBits
            try requireNotificationChannel()
            try await registerWrite(on: receiver, register: 0,
                                    payload: BoltReceiverNotificationLease.bytes(restored))
            let readback = try await readNotificationMask(on: receiver)
            guard readback == restored else {
                notificationCleanupRequiresAttention = true
                notificationCleanupMessage = "Receiver notification restoration did not match its verification readback."
                return
            }
            notificationCleanupMessage = "Temporary receiver notification changes were restored and verified."
            notificationCleanupRequiresAttention = false
        } catch {
            noteNotificationChannelFailure(error)
            notificationCleanupRequiresAttention = true
            notificationCleanupMessage = notificationChannelUncertain
                ? "Receiver notification restoration is uncertain; the request channel was not safe to reuse."
                : "Receiver notification restoration could not be verified."
        }
    }

    private func readNotificationMask(on receiver: any BoltReceiverTransport) async throws -> UInt32 {
        try requireNotificationChannel()
        let request = try BoltReceiverRegisterRequest(operation: .read, register: 0, payload: [])
        do {
            let reply = try await receiver.registerRequest(request)
            try requireNotificationChannel()
            guard reply.register == 0, reply.payload.count >= 3 else {
                throw BoltReceiverTransportFailure.malformed
            }
            return UInt32(reply.payload[0]) << 16 | UInt32(reply.payload[1]) << 8 | UInt32(reply.payload[2])
        } catch {
            noteNotificationChannelFailure(error)
            throw error
        }
    }

    private func requireNotificationChannel() throws {
        guard !notificationChannelUncertain else { throw BoltPairingSessionFailure.notificationChannelUncertain }
    }

    private func noteNotificationChannelFailure(_ error: any Error) {
        guard let failure = error as? BoltReceiverTransportFailure else { return }
        switch failure {
        case .timeout, .transport, .disconnected, .eventOverflow:
            notificationChannelUncertain = true
        default:
            break
        }
    }

    private func registerWrite(on receiver: any BoltReceiverTransport,
                               register: UInt16, payload: [UInt8]) async throws {
        let request = try BoltReceiverRegisterRequest(operation: .write, register: register, payload: payload)
        if register == 0 { try requireNotificationChannel() }
        do {
            _ = try await receiver.registerRequest(request)
        } catch {
            noteNotificationChannelFailure(error)
            throw error
        }
    }

    private func readInventory(on receiver: any BoltReceiverTransport,
                               endpoint: LogitechEndpointLocator) async throws -> BoltPairingInventory {
        let capacity = try BoltPairingProtocolDecoder.capacity(for: endpoint.productID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var records: [UInt8: BoltPairingRecord] = [:]
        for slot in UInt8(1)...UInt8(capacity) {
            guard ContinuousClock.now < deadline else { throw BoltPairingSessionFailure.unknownOccupancy }
            do {
                let request = try BoltReceiverRegisterRequest(operation: .read, register: 0x02B5,
                                                              payload: [0x50 &+ slot])
                let reply = try await receiver.registerRequest(request)
                guard reply.register == 0x02B5 else { throw BoltPairingSessionFailure.unknownOccupancy }
                records[slot] = try BoltPairingProtocolDecoder.pairingRecord(reply.payload)
            } catch let failure as BoltReceiverTransportFailure where failure == .registerRejected(code: 0x08) {
                continue
            } catch {
                noteNotificationChannelFailure(error)
                throw BoltPairingSessionFailure.unknownOccupancy
            }
        }

        let linkCount = try await readConnectionCount(on: receiver, capacity: capacity)
        if let linkCount, linkCount > records.count {
            throw BoltPairingSessionFailure.inconsistentInventory
        }
        return BoltPairingInventory(capacity: capacity, records: records, activeConnectionCount: linkCount)
    }

    private func readConnectionCount(on receiver: any BoltReceiverTransport,
                                     capacity: Int) async throws -> Int? {
        let request = try BoltReceiverRegisterRequest(operation: .read, register: 0x0002, payload: [])
        do {
            let reply = try await receiver.registerRequest(request)
            guard reply.register == 0x0002, reply.payload.count >= 2 else { return nil }
            let count = Int(reply.payload[1])
            guard count <= capacity else { throw BoltPairingSessionFailure.inconsistentInventory }
            return count
        } catch let failure as BoltReceiverTransportFailure {
            if case .registerRejected = failure { return nil }
            noteNotificationChannelFailure(failure)
            throw failure
        }
    }

    private func publishDiscoveryCandidates() {
        let candidates = candidateAssemblies.values.compactMap { assembly -> BoltPairingCandidate? in
            guard let id = assembly.candidateID,
                  let metadata = assembly.metadata,
                  let model = BoltPairingProtocolDecoder.model(productID: metadata.productID) else { return nil }
            return BoltPairingCandidate(id: id, name: assembly.displayName, model: model)
        }
        let phase: BoltPairingPhase = pairCommandSent ? .authenticating : .awaitingSelection
        let message = candidates.isEmpty ? "Searching for supported Logitech mice." : "Select the intended mouse."
        publish(phase, message, candidates: candidates)
    }

    private func removeCandidate(for key: BoltPairingCandidateKey) {
        let aliases = candidateAliasOrder.filter { candidateAliases[$0] == key }
        for alias in aliases { candidateAliases.removeValue(forKey: alias) }
        candidateAliasOrder.removeAll { aliases.contains($0) }
        guard let assembly = candidateAssemblies.removeValue(forKey: key),
              let candidateID = assembly.candidateID else { return }
        candidateIDs.removeValue(forKey: candidateID)
    }

    private func retainCandidateAlias(_ alias: BoltPairingCandidateKey, canonical: BoltPairingCandidateKey) {
        guard alias != canonical else { return }
        if candidateAliases[alias] == nil { candidateAliasOrder.append(alias) }
        candidateAliases[alias] = canonical
        while candidateAliasOrder.count > BoltPairingProtocolDecoder.maximumAssemblies {
            candidateAliases.removeValue(forKey: candidateAliasOrder.removeFirst())
        }
    }

    private func publishPossiblePairing(_ message: String) {
        pairingMayHaveSucceeded = true
        challenge = nil
        publish(.pairedButNotAdded, message, pairingMayHaveSucceeded: true)
    }

    private func publish(_ phase: BoltPairingPhase, _ message: String,
                         candidates: [BoltPairingCandidate]? = nil,
                         challenge newChallenge: BoltPairingChallenge? = nil,
                         verifiedCandidate: LogitechEndpointCandidate? = nil,
                         pairingMayHaveSucceeded mayHaveSucceeded: Bool? = nil) {
        guard status.phase != .failed || pairCommandSent else { return }
        if phase == .failed || phase == .cancelled || phase == .verified || phase == .pairedButNotAdded {
            challenge = newChallenge
        } else if let newChallenge {
            challenge = newChallenge
        }
        if let mayHaveSucceeded { pairingMayHaveSucceeded = mayHaveSucceeded }
        let result = BoltPairingStatus(phase: phase, message: message,
                                       candidates: candidates ?? statusCandidates,
                                       challenge: challenge,
                                       verifiedCandidate: verifiedCandidate,
                                       pairingMayHaveSucceeded: pairingMayHaveSucceeded,
                                       discoveryDiagnostics: discoveryDiagnostics,
                                       nativeInputDiagnostics: nativeInputDiagnostics,
                                       notificationSetupMessage: notificationSetupMessage,
                                       notificationCleanupMessage: notificationCleanupMessage,
                                       notificationCleanupRequiresAttention: notificationCleanupRequiresAttention)
        status = result
        continuation.yield(result)
    }

    private func publishDiagnosticsSnapshotIfNeeded() {
        guard status.discoveryDiagnostics != discoveryDiagnostics
                || status.nativeInputDiagnostics != nativeInputDiagnostics
                || status.notificationSetupMessage != notificationSetupMessage
                || status.notificationCleanupMessage != notificationCleanupMessage
                || status.notificationCleanupRequiresAttention != notificationCleanupRequiresAttention else { return }
        let result = BoltPairingStatus(phase: status.phase, message: status.message,
                                       candidates: status.candidates,
                                       challenge: status.challenge,
                                       verifiedCandidate: status.verifiedCandidate,
                                       pairingMayHaveSucceeded: status.pairingMayHaveSucceeded,
                                       discoveryDiagnostics: discoveryDiagnostics,
                                       nativeInputDiagnostics: nativeInputDiagnostics,
                                       notificationSetupMessage: notificationSetupMessage,
                                       notificationCleanupMessage: notificationCleanupMessage,
                                       notificationCleanupRequiresAttention: notificationCleanupRequiresAttention)
        status = result
        continuation.yield(result)
    }

    private var statusCandidates: [BoltPairingCandidate] {
        candidateAssemblies.values.compactMap { assembly in
            guard let id = assembly.candidateID, let metadata = assembly.metadata,
                  let model = BoltPairingProtocolDecoder.model(productID: metadata.productID) else { return nil }
            return BoltPairingCandidate(id: id, name: assembly.displayName, model: model)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func releaseTransport(_ receiver: any BoltReceiverTransport, generation expectedGeneration: UInt64) async {
        await cleanupNotifications(on: receiver)
        await waitForPairingVerification()
        await receiver.close()
        await refreshNativeInputDiagnostics(from: receiver, generation: expectedGeneration)
        publishDiagnosticsSnapshotIfNeeded()
        if let receiverTask {
            await receiverTask.value
        }
        if generation == expectedGeneration {
            receiverTask = nil
            transport = nil
        }
    }

    private func refreshNativeInputDiagnostics(from receiver: any BoltReceiverTransport,
                                              generation expectedGeneration: UInt64) async {
        let snapshot = await receiver.inputDiagnostics()
        guard generation == expectedGeneration else { return }
        nativeInputDiagnostics.merge(snapshot)
    }

    private func resetAttempt() {
        generation &+= 1
        discoveryDiagnostics = .init()
        nativeInputDiagnostics = .init()
        notificationSetupTask = nil
        notificationCleanupTask = nil
        notificationLease = nil
        notificationChannelUncertain = false
        notificationSetupMessage = nil
        notificationCleanupMessage = nil
        notificationCleanupRequiresAttention = false
        receiverLocators.removeAll()
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil
        selectedEndpoint = nil
        discoveryActive = false
        discoveryStartInFlight = false
        discoveryCancelSent = false
        discoveryCancelOutcome = nil
        discoveryCancelTask = nil
        discoveryStopRequestedForSelection = false
        pairCommandSent = false
        pairRequestInFlight = false
        pairCancelSent = false
        cancelRequested = false
        closing = false
        pairingResolved = false
        pairingMayHaveSucceeded = false
        terminalPairingStatusReceived = false
        pairingSuccessNotificationClaimed = false
        baselineInventory = nil
        candidateAssemblies.removeAll()
        candidateAliases.removeAll()
        candidateAliasOrder.removeAll()
        candidateIDs.removeAll()
        selectedCandidate = nil
        challenge = nil
        authenticationProgress = 0
        authenticationComplete = false
        unsupportedAdvertisementObserved = false
        status = BoltPairingStatus(phase: .idle, message: "Ready to inspect Bolt receivers.")
    }
}

enum BoltPairingSessionFailure: Error {
    case unknownOccupancy
    case inconsistentInventory
    case notificationChannelUncertain
}

private enum BoltPairingCancellationOutcome: Equatable, Sendable {
    case acknowledged
    case dispatchedUnconfirmed
    case busy
    case failed
}

struct BoltPairingCandidateKey: Hashable, Sendable {
    let first: UInt8
    let second: UInt8
}

struct BoltPairingAdvertisementMetadata: Equatable, Sendable {
    let productID: UInt16
    let deviceKind: UInt8
    let address: [UInt8]
    let authentication: UInt8
}

struct BoltPairingAdvertisementFragment: Equatable, Sendable {
    let key: BoltPairingCandidateKey
    let part: Int
    let metadata: BoltPairingAdvertisementMetadata?
    let nameBytes: [UInt8]?
    let nameTotalLength: Int?
    let report: [UInt8]
}

struct BoltPairingCandidateAssembly: Sendable {
    var fragments: [Int: [UInt8]] = [:]
    private var firstNameDifferences: [Int: Int] = [:]
    var metadata: BoltPairingAdvertisementMetadata?
    var nameTotalLength: Int?
    var candidateID: UUID?

    mutating func merge(_ other: Self) -> Bool {
        if let metadata, let incoming = other.metadata, metadata != incoming { return false }
        if let nameTotalLength, let incoming = other.nameTotalLength, nameTotalLength != incoming { return false }
        if metadata == nil { metadata = other.metadata }
        if nameTotalLength == nil { nameTotalLength = other.nameTotalLength }
        for (part, bytes) in other.fragments {
            if let previous = fragments[part] {
                if let difference = zip(previous, bytes).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                    firstNameDifferences[part] = min(firstNameDifferences[part] ?? difference, difference)
                }
            } else {
                fragments[part] = bytes
            }
        }
        for (part, difference) in other.firstNameDifferences {
            firstNameDifferences[part] = min(firstNameDifferences[part] ?? difference, difference)
        }
        guard fragments.values.reduce(0, { $0 + $1.count }) <= BoltPairingProtocolDecoder.maximumNameBytes else { return false }
        guard let nameTotalLength else { return true }
        for (part, difference) in firstNameDifferences {
            let offset = part == 1 ? 0 : (part == 2 ? 13 : 27)
            let length = min(max(nameTotalLength - offset, 0), part == 1 ? 13 : 14)
            if difference < length { return false }
        }
        return true
    }

    var displayName: String? {
        guard let nameTotalLength, nameTotalLength > 0 else { return nil }
        var bytes: [UInt8] = []
        let lengths = [1: min(nameTotalLength, 13),
                       2: min(max(nameTotalLength - 13, 0), 14),
                       3: min(max(nameTotalLength - 27, 0), 14)]
        for part in 1...3 {
            guard let length = lengths[part], length > 0 else { continue }
            guard let fragment = fragments[part], fragment.count >= length else { return nil }
            bytes += fragment.prefix(length)
        }
        guard bytes.count <= BoltPairingProtocolDecoder.maximumNameBytes,
              bytes.count == nameTotalLength,
              let name = String(bytes: bytes, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }
}

struct BoltPairingRecord: Equatable, Sendable {
    let productID: UInt16
    let deviceKind: UInt8
    let signature: [UInt8]
}

struct BoltPairingInventory: Equatable, Sendable {
    let capacity: Int
    let records: [UInt8: BoltPairingRecord]
    let activeConnectionCount: Int?

    func hasSameRecords(as other: Self) -> Bool {
        capacity == other.capacity && records == other.records
    }

    func hasOnlyAddedRecord(_ slot: UInt8, comparedTo other: Self) -> Bool {
        guard records.count == other.records.count + 1,
              other.records[slot] == nil,
              records[slot] != nil else { return false }
        for (existingSlot, record) in other.records where records[existingSlot] != record { return false }
        return records.keys.allSatisfy { $0 == slot || other.records[$0] != nil }
    }
}

enum BoltPairingProtocolDecoder {
    static let capacityProductID = LogitechEndpointEligibility.boltProductID
    static let mouseDeviceKind: UInt8 = 0x02
    static let twoButtonAuthentication: UInt8 = 0x02
    static let requiredClicks = 10
    static let maximumCandidates = 16
    static let maximumAssemblies = 32
    static let maximumNameBytes = 41

    struct Challenge: Equatable, Sendable {
        let directions: [BoltPairingClickDirection]
    }

    struct AuthenticationProgress: Equatable, Sendable {
        let address: [UInt8]
    }

    struct PairingStatus: Equatable, Sendable {
        let state: UInt8
        let error: UInt8
        let address: [UInt8]
        let slot: UInt8
    }

    static func model(productID: UInt16) -> LogitechMouseModel? {
        switch productID {
        case 0xB034: .mxMaster3S
        case 0xB042: .mxMaster4
        default: nil
        }
    }

    static func capacity(for productID: Int) throws -> Int {
        guard productID == capacityProductID else { throw BoltPairingSessionFailure.unknownOccupancy }
        return 6
    }

    static func advertisement(_ report: [UInt8]) throws -> BoltPairingAdvertisementFragment {
        guard report.count == 20, report[0] == 0x11, report[1] == 0xFF, report[2] == 0x4F,
              report[5] <= 3 else { throw BoltFailure.malformed }
        let part = Int(report[5])
        let key = BoltPairingCandidateKey(first: report[3], second: report[4])
        if part == 0 {
            let productID = UInt16(report[9]) << 8 | UInt16(report[8])
            let metadata = BoltPairingAdvertisementMetadata(productID: productID,
                                                            deviceKind: report[7] & 0x0F,
                                                            address: Array(report[10...15]),
                                                            authentication: report[18])
            return BoltPairingAdvertisementFragment(key: key, part: part,
                                                    metadata: metadata, nameBytes: nil,
                                                    nameTotalLength: nil, report: report)
        }

        let bytes: [UInt8]
        let totalLength: Int?
        if part == 1 {
            let length = Int(report[6])
            guard length <= maximumNameBytes else { throw BoltFailure.malformed }
            bytes = Array(report[7..<20])
            totalLength = length
        } else {
            bytes = Array(report[6..<20])
            totalLength = nil
        }
        return BoltPairingAdvertisementFragment(key: key, part: part, metadata: nil,
                                                nameBytes: bytes, nameTotalLength: totalLength,
                                                report: report)
    }

    static func challenge(_ report: [UInt8]) throws -> Challenge {
        guard report.count == 20, report[0] == 0x11, report[1] == 0xFF, report[2] == 0x4D else {
            throw BoltFailure.malformed
        }
        let length = Int(report[3])
        guard (1...6).contains(length),
              let digits = String(bytes: report[4..<(4 + length)], encoding: .ascii),
              digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let value = UInt16(digits), value <= 1023 else { throw BoltFailure.malformed }
        let binary = String(value, radix: 2)
        guard binary.count <= requiredClicks else { throw BoltFailure.malformed }
        let padded = String(repeating: "0", count: requiredClicks - binary.count) + binary
        let directions = padded.map { $0 == "0" ? BoltPairingClickDirection.left : .right }
        return Challenge(directions: directions)
    }

    static func authenticationProgress(code: UInt8, payload: [UInt8]) throws -> AuthenticationProgress {
        guard payload.count == 20, payload[0] == 0x11, payload[1] == 0xFF, payload[2] == 0x4E,
              payload[3] == code, code <= 4 else { throw BoltFailure.malformed }
        return AuthenticationProgress(address: Array(payload[4...9]))
    }

    static func pairingStatus(state: UInt8, error: UInt8, payload: [UInt8]) throws -> PairingStatus {
        guard payload.count == 20, payload[0] == 0x11, payload[1] == 0xFF,
              payload[2] == 0x54, payload[3] == state, payload[4] == error,
              state <= 2, error <= 2 else { throw BoltFailure.malformed }
        return PairingStatus(state: state, error: error,
                             address: Array(payload[5...10]), slot: payload[11])
    }

    static func validDiscoveryStatus(state: UInt8, error: UInt8, payload: [UInt8]) -> Bool {
        (payload.count == 7 || payload.count == 20) && payload[0] == (payload.count == 7 ? 0x10 : 0x11)
            && payload[1] == 0xFF && payload[2] == 0x53 && payload[3] == state
            && payload[4] == error && state <= 2
    }

    static func pairingRecord(_ payload: [UInt8]) throws -> BoltPairingRecord {
        guard (8...16).contains(payload.count) else { throw BoltPairingSessionFailure.unknownOccupancy }
        let signature = Array(payload.prefix(8))
        let productID = UInt16(payload[3]) << 8 | UInt16(payload[2])
        return BoltPairingRecord(productID: productID,
                                 deviceKind: payload[1] & 0x0F,
                                 signature: signature)
    }
}
