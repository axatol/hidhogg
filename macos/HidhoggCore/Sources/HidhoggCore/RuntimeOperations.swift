import Darwin
import Foundation

public enum RuntimeOperationError: Error, Sendable, Equatable {
    case invalidConfigurationPath
    case closed
    case cancelledBeforeAdmission
    case staleSource
    case profileNotFound
    case editInvalid
    case configurationUnavailable
    case fileCommitFailed(uncertain: Bool)
    case deviceWriteFailed
    case activationFailed
    case reloadRejected
}

public enum RuntimeOperationEffect: String, Sendable, Equatable {
    case unchanged
    case actionOnly = "action-only"
    case display
    case brightness
    case idle
    case `default`
    case catalog
}

public enum RuntimeOperationReason: String, Sendable, Equatable {
    case none
    case candidateRejected = "candidate-rejected"
    case canceled
    case deviceWriteFailed = "device-write-failed"
    case closed
}

public enum RuntimeOperationConfigurationState: String, Sendable, Equatable {
    case idle
    case reloading
    case closed
}

public enum RuntimeOperationReloadStatus: String, Sendable, Equatable {
    case ready
    case changed
    case unchanged
    case rejected
}

public struct RuntimeOperationProfile: Sendable, Equatable {
    public let id: String
    public let label: String
    public let isDefault: Bool
    public let isCurrent: Bool

    public init(id: String, label: String, isDefault: Bool, isCurrent: Bool) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.isCurrent = isCurrent
    }
}

public struct RuntimeOperationEditorSnapshot: Sendable, Equatable {
    public let sourceDigest: String
    public let revision: UInt64
    public let defaultProfileID: String
    public let currentProfileID: String
    public let profileIDs: [String]

    public init(sourceDigest: String, revision: UInt64, defaultProfileID: String, currentProfileID: String, profileIDs: [String]) {
        self.sourceDigest = sourceDigest
        self.revision = revision
        self.defaultProfileID = defaultProfileID
        self.currentProfileID = currentProfileID
        self.profileIDs = profileIDs
    }
}

public struct RuntimeOperationEditorProfile: Sendable, Equatable {
    public let sourceDigest: String
    public let profileID: String
    public let label: String

    public init(sourceDigest: String, profileID: String, label: String) {
        self.sourceDigest = sourceDigest
        self.profileID = profileID
        self.label = label
    }
}

public struct RuntimeOperationPositionSummary: Sendable, Equatable {
    public let positionID: String
    public let position: String

    public init(positionID: String, position: String) {
        self.positionID = positionID
        self.position = position
    }
}

public struct RuntimeOperationEditorPositions: Sendable, Equatable {
    public let sourceDigest: String
    public let profileID: String
    public let positions: [RuntimeOperationPositionSummary]

    public init(sourceDigest: String, profileID: String, positions: [RuntimeOperationPositionSummary]) {
        self.sourceDigest = sourceDigest
        self.profileID = profileID
        self.positions = positions
    }
}

public struct RuntimeOperationEditorPosition: Sendable, Equatable {
    public let sourceDigest: String
    public let profileID: String
    public let positionID: String
    public let label: String
    public let background: String
    public let labelAlignment: String
    public let labelSize: Int
    public let notificationSources: [String]
    public let action: ConfiguredAction?

    public init(sourceDigest: String, profileID: String, positionID: String, label: String, background: String, labelAlignment: String, labelSize: Int, notificationSources: [String], action: ConfiguredAction?) {
        self.sourceDigest = sourceDigest
        self.profileID = profileID
        self.positionID = positionID
        self.label = label
        self.background = background
        self.labelAlignment = labelAlignment
        self.labelSize = labelSize
        self.notificationSources = notificationSources
        self.action = action
    }
}

public struct RuntimeOperationEditResult: Sendable {
    public let sourceDigest: String
    public let fileCommit: ConfigurationStoreOutcome
    public let reloadOutcome: RuntimeConfigurationReloadOutcome
    public let revision: UInt64
    public let effect: RuntimeOperationEffect
    public let reason: RuntimeOperationReason

    public init(sourceDigest: String, fileCommit: ConfigurationStoreOutcome, reloadOutcome: RuntimeConfigurationReloadOutcome, revision: UInt64, effect: RuntimeOperationEffect, reason: RuntimeOperationReason) {
        self.sourceDigest = sourceDigest
        self.fileCommit = fileCommit
        self.reloadOutcome = reloadOutcome
        self.revision = revision
        self.effect = effect
        self.reason = reason
    }
}

public struct RuntimeOperationDisplayResult: Sendable, Equatable {
    public let displayAwake: Bool
    public let changed: Bool

    public init(displayAwake: Bool, changed: Bool) {
        self.displayAwake = displayAwake
        self.changed = changed
    }
}

public struct RuntimeOperationReloadEffects: Sendable, Equatable {
    public let catalogChanged: Bool
    public let defaultChanged: Bool
    public let currentProfileChanged: Bool
    public let currentProfileFallback: Bool
    public let actionChanged: Bool
    public let displayChanged: Bool
    public let brightnessChanged: Bool
    public let idleChanged: Bool
    public let effect: RuntimeOperationEffect

    public init(catalogChanged: Bool, defaultChanged: Bool, currentProfileChanged: Bool, currentProfileFallback: Bool, actionChanged: Bool, displayChanged: Bool, brightnessChanged: Bool, idleChanged: Bool, effect: RuntimeOperationEffect) {
        self.catalogChanged = catalogChanged
        self.defaultChanged = defaultChanged
        self.currentProfileChanged = currentProfileChanged
        self.currentProfileFallback = currentProfileFallback
        self.actionChanged = actionChanged
        self.displayChanged = displayChanged
        self.brightnessChanged = brightnessChanged
        self.idleChanged = idleChanged
        self.effect = effect
    }
}

public struct RuntimeOperationReloadResult: Sendable, Equatable {
    public let revision: UInt64
    public let changed: Bool
    public let effects: RuntimeOperationReloadEffects
    public let displayUpdated: Bool

    public init(revision: UInt64, changed: Bool, effects: RuntimeOperationReloadEffects, displayUpdated: Bool) {
        self.revision = revision
        self.changed = changed
        self.effects = effects
        self.displayUpdated = displayUpdated
    }
}

public struct RuntimeOperationConfigurationStatus: Sendable, Equatable {
    public let revision: UInt64
    public let active: Bool
    public let state: RuntimeOperationConfigurationState
    public let outcome: RuntimeOperationReloadStatus
    public let reason: RuntimeOperationReason
    public let diagnostic: ConfigurationDiagnosticProjection?

    public init(revision: UInt64, active: Bool, state: RuntimeOperationConfigurationState, outcome: RuntimeOperationReloadStatus, reason: RuntimeOperationReason, diagnostic: ConfigurationDiagnosticProjection?) {
        self.revision = revision
        self.active = active
        self.state = state
        self.outcome = outcome
        self.reason = reason
        self.diagnostic = diagnostic
    }
}

private struct RuntimeTrackedOperation: Sendable {
    let cancel: @Sendable () -> Void
    let drain: @Sendable () async -> Void
}

public actor RuntimeOperations {
    nonisolated let coordinator: RuntimeCoordinator
    nonisolated let configurationPath: String
    private var retired = false
    private var tasks = [UUID: RuntimeTrackedOperation]()
    private(set) var pendingConfigurationOperations = 0
    private(set) var pendingRetirementCount = 0
    private var lastReloadOutcome: RuntimeOperationReloadStatus = .ready
    private var lastReloadReason: RuntimeOperationReason = .none
    private var lastReloadDiagnostic: ConfigurationDiagnosticProjection?

    public init(coordinator: RuntimeCoordinator, configurationPath: String) throws {
        guard !configurationPath.isEmpty,
              configurationPath.utf8.first == 0x2f,
              !configurationPath.utf8.contains(0) else {
            throw RuntimeOperationError.invalidConfigurationPath
        }
        self.coordinator = coordinator
        self.configurationPath = URL(fileURLWithPath: configurationPath).standardizedFileURL.path
    }

    public func retire() async {
        retired = true
        pendingRetirementCount += 1
        defer { pendingRetirementCount -= 1 }
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }
        for operation in pending { await operation.drain() }
    }

    func checkAvailability() async throws {
        guard !retired else { throw RuntimeOperationError.closed }
        try await requireRunning()
        guard !retired else { throw RuntimeOperationError.closed }
    }

    private func requireRunning() async throws {
        let snapshot = await coordinator.snapshot()
        guard snapshot.lifecycle == .running, !snapshot.cleanupUncertain else { throw RuntimeOperationError.closed }
    }

    private func run<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard !retired else { throw RuntimeOperationError.closed }
        guard !Task.isCancelled else { throw RuntimeOperationError.cancelledBeforeAdmission }
        let id = UUID()
        let task = Task {
            try Task.checkCancellation()
            try await self.requireRunning()
            try Task.checkCancellation()
            return try await operation()
        }
        tasks[id] = RuntimeTrackedOperation(cancel: { task.cancel() }, drain: { _ = await task.result })
        defer { tasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            do { return try await task.value }
            catch { throw Self.operationError(error) }
        } onCancel: {
            task.cancel()
        }
    }

    public func profiles() async throws -> [RuntimeOperationProfile] {
        try await run {
            let view = await self.coordinator.configurationView()
            return view.configuration.profiles.map {
                RuntimeOperationProfile(id: $0.id, label: $0.label, isDefault: $0.id == view.configuration.defaultProfileID, isCurrent: $0.id == view.snapshot.profileID)
            }
        }
    }

    public func activateProfile(_ profileID: String) async throws -> RuntimeActivationResult {
        try await run {
            do { return try await self.coordinator.activateProfile(profileID) }
            catch {
                let mapped = Self.operationError(error)
                if mapped == .configurationUnavailable { throw RuntimeOperationError.activationFailed }
                throw mapped
            }
        }
    }

    public func editorSnapshot() async throws -> RuntimeOperationEditorSnapshot {
        try await run {
            let loaded = try Self.loadSource(self.configurationPath)
            let snapshot = await self.coordinator.snapshot()
            return RuntimeOperationEditorSnapshot(sourceDigest: loaded.source.digest, revision: snapshot.revision, defaultProfileID: loaded.configuration.defaultProfileID, currentProfileID: snapshot.profileID ?? loaded.configuration.defaultProfileID, profileIDs: loaded.configuration.profiles.map(\.id))
        }
    }

    public func editorProfile(sourceDigest: String, profileID: String) async throws -> RuntimeOperationEditorProfile {
        try await run {
            let loaded = try Self.loadSource(self.configurationPath, expectedDigest: sourceDigest)
            guard let profile = loaded.configuration.profile(id: profileID) else { throw RuntimeOperationError.profileNotFound }
            return RuntimeOperationEditorProfile(sourceDigest: loaded.source.digest, profileID: profileID, label: profile.label)
        }
    }

    public func editorPositions(sourceDigest: String, profileID: String) async throws -> RuntimeOperationEditorPositions {
        try await run {
            let loaded = try Self.loadSource(self.configurationPath, expectedDigest: sourceDigest)
            guard loaded.configuration.profile(id: profileID) != nil else { throw RuntimeOperationError.profileNotFound }
            return RuntimeOperationEditorPositions(sourceDigest: loaded.source.digest, profileID: profileID, positions: HidhoggConfiguration.supportedPositions.map { RuntimeOperationPositionSummary(positionID: $0.name, position: $0.name) })
        }
    }

    public func editorPosition(sourceDigest: String, profileID: String, positionID: String) async throws -> RuntimeOperationEditorPosition {
        try await run {
            let loaded = try Self.loadSource(self.configurationPath, expectedDigest: sourceDigest)
            guard let profile = loaded.configuration.profile(id: profileID), let position = profile.position(named: positionID) else { throw RuntimeOperationError.profileNotFound }
            return RuntimeOperationEditorPosition(sourceDigest: loaded.source.digest, profileID: profileID, positionID: position.position, label: position.label, background: position.background, labelAlignment: position.labelAlignment, labelSize: position.labelSize, notificationSources: position.notificationSources ?? [], action: position.action)
        }
    }

    public func edit(expectedDigest: String, edit: RuntimeConfigurationEdit) async throws -> RuntimeOperationEditResult {
        try await run { try await self.performEdit(expectedDigest: expectedDigest) { _ in edit } }
    }

    public func cloneProfile(expectedDigest: String, sourceProfileID: String?, profileID: String, label: String) async throws -> RuntimeOperationEditResult {
        try await run {
            try await self.performEdit(expectedDigest: expectedDigest) { configuration in
                .cloneProfile(sourceID: sourceProfileID ?? configuration.defaultProfileID, newID: profileID, label: label)
            }
        }
    }

    private func performEdit(expectedDigest: String, makeEdit: @Sendable (HidhoggConfiguration) -> RuntimeConfigurationEdit) async throws -> RuntimeOperationEditResult {
        pendingConfigurationOperations += 1
        defer { pendingConfigurationOperations -= 1 }
        let loaded = try Self.loadSource(configurationPath, expectedDigest: expectedDigest)
        let edit = makeEdit(loaded.configuration)
        let before = await coordinator.configurationView()
        do {
            let changed = try Self.apply(edit, to: loaded.source.bytes, currentProfileID: before.snapshot.profileID ?? before.configuration.defaultProfileID)
            _ = try HidhoggConfigurationDecoder.decode(changed)
        } catch { throw RuntimeOperationError.editInvalid }
        let result = try await coordinator.applyConfigurationEdit(at: configurationPath, expectedDigest: ConfigurationStore.digest(loaded.source.bytes), edit: edit)
        let effects = result.reloadResult.map { Self.reloadEffects(from: $0.previous, to: $0.current, displayChanged: $0.displayChanged) } ?? Self.reloadEffects(from: before, to: before, displayChanged: false)
        let reason: RuntimeOperationReason
        switch result.reloadOutcome {
        case .unchanged, .reloaded: reason = .none
        case .rejected: reason = .candidateRejected
        case .runtimeFailed: reason = .deviceWriteFailed
        }
        if result.fileOutcome != .unchanged {
            switch result.reloadOutcome {
            case .unchanged: recordReload(outcome: .unchanged, reason: .none)
            case .reloaded: recordReload(outcome: .changed, reason: .none)
            case .rejected: recordReload(outcome: .rejected, reason: reason, diagnostic: ConfigurationDiagnostic.make(.validation).safeProjection())
            case .runtimeFailed: recordReload(outcome: .rejected, reason: reason)
            }
        }
        return RuntimeOperationEditResult(sourceDigest: result.digest.description, fileCommit: result.fileOutcome, reloadOutcome: result.reloadOutcome, revision: result.snapshot.revision, effect: effects.effect, reason: reason)
    }

    public func reloadConfiguration() async throws -> RuntimeOperationReloadResult {
        try await run { try await self.performReload() }
    }

    private func performReload() async throws -> RuntimeOperationReloadResult {
        pendingConfigurationOperations += 1
        defer { pendingConfigurationOperations -= 1 }
        let source: IPCConfigurationSource
        do { source = try IPCConfigurationSource.read(configurationPath) }
        catch let error as IPCConfigurationReadError {
            recordReload(outcome: .rejected, reason: .candidateRejected, diagnostic: error.projection)
            throw RuntimeOperationError.reloadRejected
        } catch {
            recordReload(outcome: .rejected, reason: .candidateRejected, diagnostic: ConfigurationDiagnostic.make(.read).safeProjection())
            throw RuntimeOperationError.reloadRejected
        }
        do { _ = try HidhoggConfigurationDecoder.decode(source.bytes) }
        catch let error as ConfigurationDiagnostic {
            recordReload(outcome: .rejected, reason: .candidateRejected, diagnostic: error.safeProjection())
            throw RuntimeOperationError.reloadRejected
        } catch {
            recordReload(outcome: .rejected, reason: .candidateRejected, diagnostic: ConfigurationDiagnostic.make(.decode).safeProjection())
            throw RuntimeOperationError.reloadRejected
        }
        do {
            let result = try await coordinator.reload(source: source.bytes)
            recordReload(outcome: result.changed ? .changed : .unchanged, reason: .none)
            return RuntimeOperationReloadResult(revision: result.revision, changed: result.changed, effects: Self.reloadEffects(from: result.previous, to: result.current, displayChanged: result.displayChanged), displayUpdated: result.displayUpdated)
        } catch {
            let mapped = Self.operationError(error)
            if mapped == .deviceWriteFailed {
                recordReload(outcome: .rejected, reason: .deviceWriteFailed)
                throw mapped
            }
            if mapped == .cancelledBeforeAdmission {
                recordReload(outcome: .rejected, reason: .canceled)
                throw mapped
            }
            if mapped == .closed { throw mapped }
            recordReload(outcome: .rejected, reason: .candidateRejected, diagnostic: ConfigurationDiagnostic.make(.decode).safeProjection())
            throw RuntimeOperationError.reloadRejected
        }
    }

    public func configurationStatus() async throws -> RuntimeOperationConfigurationStatus {
        try await run {
            let snapshot = await self.coordinator.snapshot()
            return await self.makeConfigurationStatus(snapshot)
        }
    }

    private func makeConfigurationStatus(_ snapshot: RuntimeSnapshot) -> RuntimeOperationConfigurationStatus {
        let active = snapshot.lifecycle == .running
        return RuntimeOperationConfigurationStatus(revision: snapshot.revision, active: active, state: active ? (pendingConfigurationOperations > 0 ? .reloading : .idle) : .closed, outcome: lastReloadOutcome, reason: active ? lastReloadReason : .closed, diagnostic: active ? lastReloadDiagnostic : nil)
    }

    public func setHostDisplayAwake(_ awake: Bool) async throws -> RuntimeOperationDisplayResult {
        try await run {
            let before = await self.coordinator.snapshot().displayAwake
            try await self.coordinator.setHostDisplayAwake(awake)
            let after = await self.coordinator.snapshot().displayAwake
            return RuntimeOperationDisplayResult(displayAwake: after, changed: before != after)
        }
    }

    private func recordReload(outcome: RuntimeOperationReloadStatus, reason: RuntimeOperationReason, diagnostic: ConfigurationDiagnosticProjection? = nil) {
        lastReloadOutcome = outcome
        lastReloadReason = reason
        lastReloadDiagnostic = diagnostic
    }

    private static func loadSource(_ path: String, expectedDigest: String? = nil) throws -> (source: IPCConfigurationSource, configuration: HidhoggConfiguration) {
        let source: IPCConfigurationSource
        do { source = try IPCConfigurationSource.read(path) }
        catch { throw RuntimeOperationError.configurationUnavailable }
        if let expectedDigest, source.digest != expectedDigest { throw RuntimeOperationError.staleSource }
        do { return (source, try HidhoggConfigurationDecoder.decode(source.bytes)) }
        catch { throw RuntimeOperationError.configurationUnavailable }
    }

    private static func apply(_ edit: RuntimeConfigurationEdit, to source: Data, currentProfileID: String) throws -> Data {
        switch edit {
        case let .setProfileLabel(profileID, label): try ConfigurationEditor.setProfileLabel(in: source, profileID: profileID, label: label)
        case let .cloneProfile(sourceID, newID, label): try ConfigurationEditor.cloneProfile(in: source, sourceID: sourceID, newID: newID, label: label)
        case let .deleteProfile(profileID): try ConfigurationEditor.deleteProfile(in: source, profileID: profileID, currentProfileID: currentProfileID)
        case let .patchPosition(profileID, coordinate, patch): try ConfigurationEditor.patchPosition(in: source, profileID: profileID, coordinate: coordinate, patch: patch)
        }
    }

    private static func operationError(_ error: Error) -> RuntimeOperationError {
        if let error = error as? RuntimeOperationError { return error }
        if error is CancellationError { return .cancelledBeforeAdmission }
        if let error = error as? RuntimeCoordinatorError {
            switch error {
            case .unknownProfile: return .profileNotFound
            case .physicalWriteFailed: return .deviceWriteFailed
            case .cancelledBeforeAdmission: return .cancelledBeforeAdmission
            case .storeFailure(.stale): return .staleSource
            case .storeFailure(.invalidConfiguration), .storeFailure(.mutationFailed): return .editInvalid
            case .storeFailure(.uncertain): return .fileCommitFailed(uncertain: true)
            case .storeFailure(.invalidDestination), .storeFailure(.diskFailure): return .fileCommitFailed(uncertain: false)
            case .configurationRejected: return .configurationUnavailable
            default: return .closed
            }
        }
        if let error = error as? ConfigurationEditingError {
            return error == .profileNotFound ? .profileNotFound : .editInvalid
        }
        return .configurationUnavailable
    }

    private static func reloadEffects(from previous: RuntimeConfigurationView, to current: RuntimeConfigurationView, displayChanged: Bool) -> RuntimeOperationReloadEffects {
        let previousConfiguration = previous.configuration
        let currentConfiguration = current.configuration
        let oldID = previous.snapshot.profileID ?? previousConfiguration.defaultProfileID
        let newID = current.snapshot.profileID ?? currentConfiguration.defaultProfileID
        let fallback = previousConfiguration.profile(id: oldID) != nil && currentConfiguration.profile(id: oldID) == nil
        let oldProfile = previousConfiguration.profile(id: oldID)
        let newProfile = currentConfiguration.profile(id: newID)
        let currentChanged = oldID != newID || oldProfile != newProfile
        let actionChanged: Bool
        if let oldProfile, let newProfile {
            actionChanged = zip(oldProfile.positions, newProfile.positions).contains { $0.0.action != $0.1.action }
        } else { actionChanged = false }
        let catalogChanged = previousConfiguration.profiles != currentConfiguration.profiles
        let defaultChanged = previousConfiguration.defaultProfileID != currentConfiguration.defaultProfileID
        let brightnessChanged = previousConfiguration.brightness != currentConfiguration.brightness
        let idleChanged = previousConfiguration.idleTimeoutSeconds != currentConfiguration.idleTimeoutSeconds
        let changed = catalogChanged || defaultChanged || currentChanged || fallback || actionChanged || displayChanged || brightnessChanged || idleChanged
        let effect: RuntimeOperationEffect
        if !changed { effect = .unchanged }
        else if actionChanged && !displayChanged && !brightnessChanged && !idleChanged && !defaultChanged && !fallback && currentChanged { effect = .actionOnly }
        else if displayChanged { effect = .display }
        else if brightnessChanged { effect = .brightness }
        else if idleChanged { effect = .idle }
        else if defaultChanged || fallback { effect = .default }
        else { effect = .catalog }
        return RuntimeOperationReloadEffects(catalogChanged: catalogChanged, defaultChanged: defaultChanged, currentProfileChanged: currentChanged, currentProfileFallback: fallback, actionChanged: actionChanged, displayChanged: displayChanged, brightnessChanged: brightnessChanged, idleChanged: idleChanged, effect: effect)
    }
}

enum IPCConfigurationReadError: Error {
    case notFound
    case denied
    case invalid
    case read
    case decode

    var projection: ConfigurationDiagnosticProjection {
        switch self {
        case .notFound: ConfigurationDiagnostic.make(.readNotFound).safeProjection()
        case .denied: ConfigurationDiagnostic.make(.readDenied).safeProjection()
        case .invalid: ConfigurationDiagnostic.make(.readInvalid).safeProjection()
        case .read: ConfigurationDiagnostic.make(.read).safeProjection()
        case .decode: ConfigurationDiagnostic.make(.decode).safeProjection()
        }
    }
}

struct IPCConfigurationSource {
    let bytes: Data
    let digest: String

    static func read(_ path: String) throws -> Self {
        guard !path.isEmpty, path.utf8.first == 0x2f, !path.utf8.contains(0) else { throw IPCConfigurationReadError.invalid }
        var before = stat()
        guard path.withCString({ lstat($0, &before) }) == 0 else { throw readError(errno) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw IPCConfigurationReadError.invalid }
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw readError(errno) }
        var descriptorOpen = true
        defer { if descriptorOpen { _ = Darwin.close(descriptor) } }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw IPCConfigurationReadError.read }
        guard opened.st_mode & S_IFMT == S_IFREG,
              sameConfigurationFile(before, opened),
              opened.st_size >= 0, opened.st_size <= 1_048_576 else {
            throw IPCConfigurationReadError.invalid
        }

        let maximumBytes = 1_048_576
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw readError(errno)
            }
            guard bytes.count + count <= maximumBytes else { throw IPCConfigurationReadError.invalid }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0,
              sameConfigurationFile(opened, afterRead),
              Int64(bytes.count) == afterRead.st_size else {
            throw IPCConfigurationReadError.invalid
        }
        let closeResult = Darwin.close(descriptor)
        descriptorOpen = false
        guard closeResult == 0 else { throw IPCConfigurationReadError.read }
        var after = stat()
        guard path.withCString({ lstat($0, &after) }) == 0,
              sameConfigurationFile(afterRead, after),
              after.st_mode & S_IFMT == S_IFREG else {
            throw IPCConfigurationReadError.invalid
        }
        return Self(bytes: bytes, digest: ConfigurationStore.digest(bytes).description)
    }
}

private func readError(_ code: Int32) -> IPCConfigurationReadError {
    switch code {
    case ENOENT: .notFound
    case EACCES, EPERM: .denied
    case ELOOP, EISDIR, ENOTDIR: .invalid
    default: .read
    }
}

private func sameConfigurationFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}
