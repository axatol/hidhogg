import Combine
import Foundation
import HidhoggCore

public enum ProfileSwitchCoordinatorState: Equatable, Sendable {
    case idle
    case waitingForRuntime
    case loadingCatalog
    case current(profileID: String)
    case switching(profileID: String)
    case unmatched(bundleIdentifier: String)
    case invalidMapping(bundleIdentifier: String, profileID: String)
    case unavailable
    case outcomeUnknown(profileID: String)
    case stopped
}

@MainActor
public final class ProfileSwitchCoordinator: ObservableObject {
    @Published public private(set) var state: ProfileSwitchCoordinatorState = .idle
    @Published public private(set) var currentProfileID: String?
    @Published public private(set) var currentBundleIdentifier: String?
    @Published public private(set) var catalog: [RuntimeOperationProfile]?

    public private(set) var mappings: ProfileMappingPreferences
    public private(set) var runtimeIdentity: String?

    private var operations: (any HidhoggProfileOperations)?
    private var foregroundObserver: (any ForegroundApplicationObserving)?
    private var pendingBundleIdentifier: String?
    private var pendingCatalogRefresh = false
    private var processingBundleIdentifier: String?
    private var foregroundResetGeneration = 0
    private var operationTask: Task<ProfileEvaluationResult, Never>?
    private var generation = 0
    private var hasQuit = false
    private var isQuiescing = false
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        mappings: ProfileMappingPreferences = ProfileMappingPreferences()
    ) {
        self.mappings = mappings
    }

    public var isBusy: Bool {
        isQuiescing || operationTask != nil || pendingBundleIdentifier != nil || pendingCatalogRefresh
    }

    public func startObserving(_ observer: any ForegroundApplicationObserving) {
        guard !hasQuit else { return }
        foregroundObserver?.stop()
        foregroundObserver = observer
        observer.start { [weak self] bundleIdentifier in
            self?.receive(bundleIdentifier: bundleIdentifier)
        }
    }

    public func startObserving(observer: any ForegroundApplicationObserving) {
        startObserving(observer)
    }

    public func stopObserving() {
        foregroundObserver?.stop()
        foregroundObserver = nil
    }

    func setRuntimeOperations(_ handle: RuntimeOperationsHandle?) async {
        await waitForQuiescence()
        guard !hasQuit else { return }
        guard handle?.identity != runtimeIdentity || operations == nil else { return }

        let currentOperation = beginQuiescence()
        _ = await currentOperation?.value

        guard !hasQuit else {
            endQuiescence()
            return
        }

        let bundleToReevaluate = currentBundleIdentifier
        runtimeIdentity = handle?.identity
        operations = handle.map { $0.operations as any HidhoggProfileOperations }
        catalog = nil
        currentProfileID = nil
        pendingCatalogRefresh = false

        guard handle != nil else {
            state = .waitingForRuntime
            endQuiescence()
            return
        }

        if let bundleToReevaluate {
            pendingBundleIdentifier = bundleToReevaluate
        } else if foregroundObserver != nil {
            pendingCatalogRefresh = true
        }
        endQuiescence()
        startNextEvaluationIfPossible()
    }

    public func refreshCatalog() {
        guard !hasQuit, !isQuiescing else { return }
        pendingCatalogRefresh = true
        startNextEvaluationIfPossible()
    }

    public func setMappings(_ mappings: ProfileMappingPreferences) {
        guard !hasQuit else { return }
        self.mappings = mappings
        enqueueCurrentBundle()
    }

    public func updateMappings(_ mappings: ProfileMappingPreferences) {
        setMappings(mappings)
    }

    @discardableResult
    public func setMapping(
        profileID: String,
        forBundleIdentifier bundleIdentifier: String
    ) throws -> ProfileMappingPreferences {
        let updated = try mappings.setting(
            profileID: profileID,
            forBundleIdentifier: bundleIdentifier
        )
        setMappings(updated)
        return updated
    }

    @discardableResult
    public func removeMapping(forBundleIdentifier bundleIdentifier: String) -> ProfileMappingPreferences {
        let updated = mappings.removing(bundleIdentifier: bundleIdentifier)
        setMappings(updated)
        return updated
    }

    public func retry() {
        enqueueCurrentBundle()
    }

    public func shutdown() async {
        guard !hasQuit else {
            await waitForQuiescence()
            return
        }
        hasQuit = true
        generation += 1
        stopObserving()
        if isQuiescing {
            await waitForQuiescence()
        } else {
            let currentOperation = beginQuiescence()
            _ = await currentOperation?.value
            endQuiescence()
        }

        pendingBundleIdentifier = nil
        pendingCatalogRefresh = false
        processingBundleIdentifier = nil
        operationTask = nil
        operations = nil
        runtimeIdentity = nil
        catalog = nil
        currentProfileID = nil
        state = .stopped
    }

    public func waitForIdle() async {
        while isBusy {
            await Task.yield()
        }
    }

    private func receive(bundleIdentifier: String?) {
        guard !hasQuit else { return }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            let shouldRefreshCatalog = !isQuiescing
                && runtimeIdentity != nil
                && operations != nil
                && currentProfileID == nil
                && operationTask == nil
            currentBundleIdentifier = nil
            pendingBundleIdentifier = nil
            processingBundleIdentifier = nil
            foregroundResetGeneration += 1
            if shouldRefreshCatalog {
                pendingCatalogRefresh = true
                startNextEvaluationIfPossible()
            }
            return
        }
        guard !isQuiescing else { return }
        if processingBundleIdentifier == bundleIdentifier,
           (pendingBundleIdentifier == nil || pendingBundleIdentifier == bundleIdentifier) {
            return
        }
        currentBundleIdentifier = bundleIdentifier
        pendingBundleIdentifier = bundleIdentifier
        startNextEvaluationIfPossible()
    }

    private func enqueueCurrentBundle() {
        guard !hasQuit,
              !isQuiescing,
              let bundleIdentifier = currentBundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return
        }
        pendingBundleIdentifier = bundleIdentifier
        startNextEvaluationIfPossible()
    }

    private func startNextEvaluationIfPossible() {
        guard !isQuiescing else { return }
        guard operationTask == nil else { return }
        guard pendingBundleIdentifier != nil || pendingCatalogRefresh else { return }
        guard let operations else {
            pendingBundleIdentifier = nil
            pendingCatalogRefresh = false
            state = runtimeIdentity == nil ? .waitingForRuntime : .unavailable
            return
        }

        state = .loadingCatalog
        let generation = self.generation

        let bundleIdentifier = pendingBundleIdentifier
        pendingBundleIdentifier = nil
        pendingCatalogRefresh = false
        processingBundleIdentifier = bundleIdentifier
        let mappings = self.mappings.mappings
        let foregroundResetGeneration = self.foregroundResetGeneration
        let operation = Task.detached(priority: nil) {
            if let bundleIdentifier {
                return await ProfileSwitchCoordinator.evaluate(
                    bundleIdentifier: bundleIdentifier,
                    mappings: mappings,
                    operations: operations
                )
            }
            return await ProfileSwitchCoordinator.refreshCatalog(
                operations: operations
            )
        }
        operationTask = operation
        Task { @MainActor [weak self] in
            let result = await operation.value
            self?.finish(
                result: result,
                bundleIdentifier: bundleIdentifier ?? "",
                generation: generation,
                foregroundResetGeneration: bundleIdentifier == nil ? nil : foregroundResetGeneration
            )
        }
    }

    private func finish(
        result: ProfileEvaluationResult,
        bundleIdentifier: String,
        generation: Int,
        foregroundResetGeneration: Int? = nil
    ) {
        guard generation == self.generation else { return }
        operationTask = nil
        processingBundleIdentifier = nil
        guard !hasQuit, !isQuiescing else { return }

        if let foregroundResetGeneration,
           foregroundResetGeneration != self.foregroundResetGeneration {
            applyCurrentProfileWithoutActivation(from: result)
            startNextEvaluationIfPossible()
            return
        }

        switch result {
        case .catalogOnly(let response):
            applyCatalog(response)
            if let currentProfileID {
                state = .current(profileID: currentProfileID)
            } else {
                state = .unavailable
            }
        case .unavailable:
            state = .unavailable
        case .invalidMapping(let response, let profileID):
            applyCatalog(response)
            state = .invalidMapping(bundleIdentifier: bundleIdentifier, profileID: profileID)
        case .alreadyCurrent(let response, let profileID):
            applyCatalog(response)
            currentProfileID = profileID
            state = .current(profileID: profileID)
        case .needsActivation(let response, let profileID):
            applyCatalog(response)
            state = .switching(profileID: profileID)
            startActivation(
                response: response,
                profileID: profileID,
                bundleIdentifier: bundleIdentifier,
                generation: generation
            )
            return
        case .activationSucceeded(let response, let profileID):
            applyCatalog(response)
            currentProfileID = profileID
            state = .current(profileID: profileID)
        case .outcomeUnknown(let response, let profileID):
            applyCatalog(response)
            state = .outcomeUnknown(profileID: profileID)
        }
        startNextEvaluationIfPossible()
    }

    private func applyCurrentProfileWithoutActivation(from result: ProfileEvaluationResult) {
        switch result {
        case .catalogOnly(let response),
             .invalidMapping(let response, _),
             .alreadyCurrent(let response, _),
             .needsActivation(let response, _),
             .activationSucceeded(let response, _),
             .outcomeUnknown(let response, _):
            applyCatalog(response)
            if let currentProfileID {
                state = .current(profileID: currentProfileID)
            }
        case .unavailable:
            if let currentProfileID {
                state = .current(profileID: currentProfileID)
            }
        }
    }

    private func beginQuiescence() -> Task<ProfileEvaluationResult, Never>? {
        precondition(!isQuiescing)
        isQuiescing = true
        generation += 1
        pendingBundleIdentifier = nil
        let currentOperation = operationTask
        operationTask = nil
        processingBundleIdentifier = nil
        return currentOperation
    }

    private func waitForQuiescence() async {
        guard isQuiescing else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    private func endQuiescence() {
        isQuiescing = false
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func startActivation(
        response: [RuntimeOperationProfile],
        profileID: String,
        bundleIdentifier: String,
        generation: Int
    ) {
        guard let operations else {
            operationTask = nil
            processingBundleIdentifier = nil
            state = .unavailable
            startNextEvaluationIfPossible()
            return
        }
        processingBundleIdentifier = bundleIdentifier
        let operation = Task.detached(priority: nil) {
            do {
                let activation = try await operations.activateProfile(profileID)
                guard activation.profileID == profileID else {
                    return ProfileEvaluationResult.outcomeUnknown(
                        response: response,
                        profileID: profileID
                    )
                }
                return ProfileEvaluationResult.activationSucceeded(
                    response: response,
                    profileID: profileID
                )
            } catch {
                return ProfileEvaluationResult.outcomeUnknown(
                    response: response,
                    profileID: profileID
                )
            }
        }
        operationTask = operation
        Task { @MainActor [weak self] in
            let result = await operation.value
            self?.finish(
                result: result,
                bundleIdentifier: bundleIdentifier,
                generation: generation
            )
        }
    }

    private func applyCatalog(_ response: [RuntimeOperationProfile]) {
        catalog = response
        currentProfileID = response.first(where: \.isCurrent)?.id
    }

    nonisolated private static func evaluate(
        bundleIdentifier: String,
        mappings: [String: String],
        operations: any HidhoggProfileOperations
    ) async -> ProfileEvaluationResult {
        let profiles: [RuntimeOperationProfile]
        do {
            profiles = try await operations.profiles()
        } catch {
            return .unavailable
        }

        guard let currentProfileID = profiles.first(where: \.isCurrent)?.id else {
            return .unavailable
        }
        let profileID: String
        if let mappedProfileID = mappings[bundleIdentifier] {
            guard profiles.contains(where: { $0.id == mappedProfileID }) else {
                return .invalidMapping(response: profiles, profileID: mappedProfileID)
            }
            profileID = mappedProfileID
        } else {
            guard let defaultProfileID = profiles.first(where: \.isDefault)?.id else {
                return .unavailable
            }
            profileID = defaultProfileID
        }
        guard profileID != currentProfileID else {
            return .alreadyCurrent(response: profiles, profileID: profileID)
        }
        return .needsActivation(response: profiles, profileID: profileID)
    }

    nonisolated private static func refreshCatalog(
        operations: any HidhoggProfileOperations
    ) async -> ProfileEvaluationResult {
        do {
            return .catalogOnly(try await operations.profiles())
        } catch {
            return .unavailable
        }
    }
}

private enum ProfileEvaluationResult: Sendable {
    case catalogOnly([RuntimeOperationProfile])
    case unavailable
    case invalidMapping(response: [RuntimeOperationProfile], profileID: String)
    case alreadyCurrent(response: [RuntimeOperationProfile], profileID: String)
    case needsActivation(response: [RuntimeOperationProfile], profileID: String)
    case activationSucceeded(response: [RuntimeOperationProfile], profileID: String)
    case outcomeUnknown(response: [RuntimeOperationProfile], profileID: String)
}

public typealias ProfileSwitchState = ProfileSwitchCoordinatorState
