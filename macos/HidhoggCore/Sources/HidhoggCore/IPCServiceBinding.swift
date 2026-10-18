import Darwin
import Foundation

public enum IPCServiceBindingError: Error, Sendable, Equatable {
    case invalidConfigurationPath
}

public actor IPCServiceBinding {
    private let coordinator: RuntimeCoordinator
    private let configurationPath: String
    private(set) var pendingConfigurationOperations = 0
    private var lastReloadOutcome = "ready"
    private var lastReloadReason = "none"
    private var lastReloadDiagnostic: IPCJSONValue?

    private var reloadInProgress: Bool { pendingConfigurationOperations > 0 }

    public init(coordinator: RuntimeCoordinator, configurationPath: String) throws {
        guard !configurationPath.isEmpty,
              configurationPath.utf8.first == 0x2f,
              !configurationPath.utf8.contains(0) else {
            throw IPCServiceBindingError.invalidConfigurationPath
        }
        self.coordinator = coordinator
        self.configurationPath = URL(fileURLWithPath: configurationPath).standardizedFileURL.path
    }

    public func startServer(
        runtimeDirectory: String,
        instanceID: String = UUID().uuidString.lowercased(),
        deadlines: IPCDeadlines = IPCDeadlines()
    ) throws -> IPCServer {
        try IPCServer.start(runtimeDirectory: runtimeDirectory, instanceID: instanceID, deadlines: deadlines) { request in
            await self.handle(request)
        }
    }

    func handle(_ request: IPCWireRequest) async -> IPCWireResponse {
        let snapshot = await coordinator.snapshot()
        guard snapshot.lifecycle == .running, !snapshot.cleanupUncertain else {
            return failure(request, "shutting_down", "runtime is not ready")
        }

        switch request.method {
        case .health:
            return success(request, [("state", .string("ready"))], includeInstanceID: true)
        case .status:
            return success(request, [
                ("state", .string("ready")),
                ("protocol_version", .number(IPCJSONNumber(integer: 1))),
            ], includeInstanceID: true)
        case .profilesList:
            return await profilesList(request)
        case .profilesActivate:
            return await activateProfile(request)
        case .executionsList:
            return await executionList(request)
        case .executionsGet:
            return await executionGet(request)
        case .configReload:
            return await reloadConfiguration(request)
        case .configStatus:
            return await configurationStatus(request)
        case .editorSnapshot:
            return await editorSnapshot(request)
        case .editorPositionsList:
            return await editorPositions(request)
        case .editorProfileGet:
            return await editorProfile(request)
        case .editorPositionGet:
            return await editorPosition(request)
        case .editorProfileLabelSet, .editorPositionLabelSet, .editorProfileCreate, .editorProfileDelete, .editorPositionPatch:
            return await editConfiguration(request)
        case .displayHostStateSet:
            return await setDisplayHostState(request)
        case .inputStatus:
            return await inputStatus(request, requestPermission: false)
        case .inputRequestPermission:
            return await inputStatus(request, requestPermission: true)
        case .doctor:
            return await doctor(request)
        case .notificationsEmit:
            return await emitNotification(request)
        case .notificationsClear:
            return await clearNotification(request)
        }
    }

    private func profilesList(_ request: IPCWireRequest) async -> IPCWireResponse {
        let view = await coordinator.configurationView()
        let profiles = view.configuration.profiles.map { profile in
            IPCJSONValue.object([
                ("id", .string(profile.id)),
                ("label", .string(profile.label)),
                ("is_default", .boolean(profile.id == view.configuration.defaultProfileID)),
                ("is_current", .boolean(profile.id == view.snapshot.profileID)),
            ])
        }
        return success(request, [("profiles", .array(profiles))])
    }

    private func activateProfile(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let profileID = request.params.value(for: "profile_id")?.stringValue else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        do {
            let result = try await coordinator.activateProfile(profileID)
            return success(request, [
                ("profile_id", .string(result.profileID)),
                ("changed", .boolean(result.changed)),
            ], includeInstanceID: false)
        } catch RuntimeCoordinatorError.unknownProfile {
            return failure(request, "profile_not_found", "profile was not found")
        } catch RuntimeCoordinatorError.physicalWriteFailed {
            return failure(request, "device_write_failed", "device update failed")
        } catch {
            return failure(request, "activation_failed", "profile activation failed")
        }
    }

    private func executionList(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let services = await coordinator.actionServices() else {
            return failure(request, "history_unavailable", "history is unavailable")
        }
        let requestedLimit = request.params.value(for: "limit")?.integerValue.map(Int.init)
        let limit = requestedLimit ?? 10
        do {
            let processHistory = try services.execution.listSummaries(limit: 32)
            let inputHistory = try services.nativeInput.listSummaries(limit: 32)
            var summaries = processHistory.map { ($0.submittedAt, executionSummary($0, services: services)) }
            summaries.append(contentsOf: inputHistory.map { ($0.submittedAt, nativeInputSummary($0, services: services)) })
            summaries.sort { $0.0 > $1.0 }
            return success(request, [("executions", .array(summaries.prefix(limit).map(\.1)))])
        } catch {
            return failure(request, "history_unavailable", "history is unavailable")
        }
    }

    private func executionGet(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let services = await coordinator.actionServices() else {
            return failure(request, "history_unavailable", "history is unavailable")
        }
        guard let id = request.params.value(for: "execution_id")?.stringValue else {
            return failure(request, "execution_not_found", "execution was not found")
        }
        if let record = services.execution.get(id: id) {
            return success(request, [("execution", executionRecord(record, services: services))])
        }
        guard let summary = services.nativeInput.get(id: id) else {
            return failure(request, "execution_not_found", "execution was not found")
        }
        return success(request, [("execution", nativeInputRecord(summary, services: services))])
    }

    private func reloadConfiguration(_ request: IPCWireRequest) async -> IPCWireResponse {
        pendingConfigurationOperations += 1
        defer { pendingConfigurationOperations -= 1 }
        let source: IPCConfigurationSource
        do { source = try IPCConfigurationSource.read(configurationPath) }
        catch let error as IPCConfigurationReadError {
            recordReload(outcome: "rejected", reason: "candidate-rejected", diagnostic: error.projection)
            return failure(request, "reload_rejected", "configuration reload was rejected")
        } catch {
            recordReload(outcome: "rejected", reason: "candidate-rejected", diagnostic: readDiagnostic(.read))
            return failure(request, "reload_rejected", "configuration reload was rejected")
        }
        do { _ = try HidhoggConfigurationDecoder.decode(source.bytes) }
        catch let diagnostic as ConfigurationDiagnostic {
            recordReload(outcome: "rejected", reason: "candidate-rejected", diagnostic: diagnosticValue(diagnostic.safeProjection()))
            return failure(request, "reload_rejected", "configuration reload was rejected")
        } catch {
            recordReload(outcome: "rejected", reason: "candidate-rejected", diagnostic: readDiagnostic(.decode))
            return failure(request, "reload_rejected", "configuration reload was rejected")
        }
        do {
            let result = try await coordinator.reload(source: source.bytes)
            let effects = reloadEffects(
                from: result.previous,
                to: result.current,
                displayChanged: result.displayChanged
            )
            recordReload(outcome: result.changed ? "changed" : "unchanged", reason: "none", diagnostic: nil)
            return success(request, reloadFields(
                revision: result.revision,
                changed: result.changed,
                effects: effects,
                displayUpdated: result.displayUpdated
            ))
        } catch RuntimeCoordinatorError.physicalWriteFailed {
            recordReload(outcome: "rejected", reason: "device-write-failed", diagnostic: nil)
            return failure(request, "device_write_failed", "device update failed")
        } catch RuntimeCoordinatorError.cancelledBeforeAdmission {
            recordReload(outcome: "rejected", reason: "canceled", diagnostic: nil)
            return failure(request, "busy", "runtime is busy")
        } catch {
            recordReload(outcome: "rejected", reason: "candidate-rejected", diagnostic: readDiagnostic(.decode))
            return failure(request, "reload_rejected", "configuration reload was rejected")
        }
    }

    private func configurationStatus(_ request: IPCWireRequest) async -> IPCWireResponse {
        let view = await coordinator.configurationView()
        let state = view.snapshot.lifecycle == .running ? (reloadInProgress ? "reloading" : "idle") : "closed"
        return success(request, [
            ("revision", integer(view.snapshot.revision)),
            ("active", .boolean(view.snapshot.lifecycle == .running)),
            ("state", .string(state)),
            ("outcome", .string(lastReloadOutcome)),
            ("reason", .string(view.snapshot.lifecycle == .running ? lastReloadReason : "closed")),
            ("diagnostic", view.snapshot.lifecycle == .running ? (lastReloadDiagnostic ?? .null) : .null),
        ])
    }

    private func editorSnapshot(_ request: IPCWireRequest) async -> IPCWireResponse {
        let configuration: HidhoggConfiguration
        let source: IPCConfigurationSource
        do {
            source = try IPCConfigurationSource.read(configurationPath)
            configuration = try HidhoggConfigurationDecoder.decode(source.bytes)
        } catch {
            return failure(request, "reload_rejected", "configuration is unavailable")
        }
        let snapshot = await coordinator.snapshot()
        let current = snapshot.profileID ?? configuration.defaultProfileID
        return success(request, [
            ("source_digest", .string(source.digest)),
            ("revision", integer(snapshot.revision)),
            ("default_profile_id", .string(configuration.defaultProfileID)),
            ("current_profile_id", .string(current)),
            ("profile_ids", .array(configuration.profiles.map { .string($0.id) })),
        ])
    }

    private func editorPositions(_ request: IPCWireRequest) async -> IPCWireResponse {
        let loaded: (source: IPCConfigurationSource, configuration: HidhoggConfiguration)
        do { loaded = try loadEditorSource(request) }
        catch { return editorReadFailure(request, error) }
        guard let profileID = string(request, "profile_id"), loaded.configuration.profile(id: profileID) != nil else {
            return failure(request, "profile_not_found", "profile was not found")
        }
        let positions = HidhoggConfiguration.supportedPositions.map { spec in
            IPCJSONValue.object([
                ("position_id", .string(spec.name)),
                ("position", .string(spec.name)),
            ])
        }
        return success(request, [
            ("source_digest", .string(loaded.source.digest)),
            ("profile_id", .string(profileID)),
            ("positions", .array(positions)),
        ])
    }

    private func editorProfile(_ request: IPCWireRequest) async -> IPCWireResponse {
        let loaded: (source: IPCConfigurationSource, configuration: HidhoggConfiguration)
        do { loaded = try loadEditorSource(request) }
        catch { return editorReadFailure(request, error) }
        guard let profileID = string(request, "profile_id"), let profile = loaded.configuration.profile(id: profileID) else {
            return failure(request, "profile_not_found", "profile was not found")
        }
        return success(request, [
            ("source_digest", .string(loaded.source.digest)),
            ("profile_id", .string(profile.id)),
            ("label", .string(profile.label)),
        ])
    }

    private func editorPosition(_ request: IPCWireRequest) async -> IPCWireResponse {
        let loaded: (source: IPCConfigurationSource, configuration: HidhoggConfiguration)
        do { loaded = try loadEditorSource(request) }
        catch { return editorReadFailure(request, error) }
        guard let profileID = string(request, "profile_id"),
              let positionID = string(request, "position_id"),
              let profile = loaded.configuration.profile(id: profileID),
              let position = profile.position(named: positionID) else {
            return failure(request, "profile_not_found", "profile or position was not found")
        }
        var fields: [(String, IPCJSONValue)] = [
            ("source_digest", .string(loaded.source.digest)),
            ("profile_id", .string(profile.id)),
            ("position_id", .string(position.position)),
            ("label", .string(position.label)),
            ("background", .string(position.background)),
            ("label_alignment", .string(position.labelAlignment)),
            ("label_size", integer(position.labelSize)),
            ("notification_sources", .array((position.notificationSources ?? []).map(IPCJSONValue.string))),
        ]
        if let action = position.action { fields.append(("action", IPCProtocol.encodeAction(action))) }
        return success(request, fields)
    }

    private func editConfiguration(_ request: IPCWireRequest) async -> IPCWireResponse {
        pendingConfigurationOperations += 1
        defer { pendingConfigurationOperations -= 1 }
        let source: IPCConfigurationSource
        let before: RuntimeConfigurationView
        let configurationEdit: RuntimeConfigurationEdit
        do {
            source = try IPCConfigurationSource.read(configurationPath)
            guard source.digest == string(request, "expected_digest") else {
                return failure(request, "stale_source", "configuration source changed")
            }
            let current = try HidhoggConfigurationDecoder.decode(source.bytes)
            before = await coordinator.configurationView()
            configurationEdit = try makeConfigurationEdit(request, configuration: current)
        } catch is ConfigurationEditingError {
            return failure(request, "edit_invalid", "configuration edit is invalid")
        } catch let error as RuntimeCoordinatorError {
            return runtimeError(request, error)
        } catch {
            return failure(request, "reload_rejected", "configuration is unavailable")
        }

        do {
            let changedSource = try applyConfigurationEdit(
                configurationEdit,
                to: source.bytes,
                currentProfileID: before.snapshot.profileID ?? before.configuration.defaultProfileID
            )
            _ = try HidhoggConfigurationDecoder.decode(changedSource)
        } catch {
            return failure(request, "edit_invalid", "configuration edit is invalid")
        }

        do {
            let result = try await coordinator.applyConfigurationEdit(
                at: configurationPath,
                expectedDigest: ConfigurationStore.digest(source.bytes),
                edit: configurationEdit
            )
            let effects: IPCReloadEffects
            if let reloadResult = result.reloadResult {
                effects = reloadEffects(
                    from: reloadResult.previous,
                    to: reloadResult.current,
                    displayChanged: reloadResult.displayChanged
                )
            } else {
                effects = reloadEffects(from: before, to: before, displayChanged: false)
            }
            if result.fileOutcome != .unchanged {
                let status: (String, String, IPCJSONValue?)
                switch result.reloadOutcome {
                case .unchanged: status = ("unchanged", "none", nil)
                case .reloaded: status = ("changed", "none", nil)
                case .rejected: status = ("rejected", "candidate-rejected", readDiagnostic(.validation))
                case .runtimeFailed: status = ("rejected", "device-write-failed", nil)
                }
                recordReload(outcome: status.0, reason: status.1, diagnostic: status.2)
            }
            let reason: String
            switch result.reloadOutcome {
            case .unchanged, .reloaded: reason = "none"
            case .rejected: reason = "candidate-rejected"
            case .runtimeFailed: reason = "device-write-failed"
            }
            return success(request, [
                ("source_digest", .string(result.digest.description)),
                ("file_commit", .string(result.fileOutcome.rawValue)),
                ("reload_outcome", .string(reloadOutcome(result.reloadOutcome))),
                ("revision", integer(result.snapshot.revision)),
                ("effect", .string(effects.effect)),
                ("reason", .string(reason)),
            ])
        } catch {
            return runtimeError(request, error)
        }
    }

    private func setDisplayHostState(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let awake = request.params.value(for: "display_awake")?.booleanValue else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        let before = await coordinator.snapshot().displayAwake
        do {
            try await coordinator.setHostDisplayAwake(awake)
            let after = await coordinator.snapshot().displayAwake
            return success(request, [
                ("display_awake", .boolean(after)),
                ("changed", .boolean(before != after)),
            ])
        } catch {
            return runtimeError(request, error)
        }
    }

    private func inputStatus(_ request: IPCWireRequest, requestPermission: Bool) async -> IPCWireResponse {
        guard let services = await coordinator.actionServices() else {
            return failure(request, "history_unavailable", "input service is unavailable")
        }
        if requestPermission { _ = services.nativeInput.requestPermission() }
        return success(request, [("input", encodeInputStatus(services.nativeInput.status()))])
    }

    private func doctor(_ request: IPCWireRequest) async -> IPCWireResponse {
        let snapshot = await coordinator.snapshot()
        guard let services = await coordinator.actionServices() else {
            return failure(request, "history_unavailable", "input service is unavailable")
        }
        let sourceStatus: (String, IPCJSONValue)
        do {
            let source = try IPCConfigurationSource.read(configurationPath)
            _ = try HidhoggConfigurationDecoder.decode(source.bytes)
            sourceStatus = ("ready", .null)
        } catch let error as IPCConfigurationReadError {
            sourceStatus = ("failed", error.projection)
        } catch let diagnostic as ConfigurationDiagnostic {
            sourceStatus = ("failed", diagnosticValue(diagnostic.safeProjection()))
        } catch {
            sourceStatus = ("failed", readDiagnostic(.decode))
        }
        let input = encodeInputStatus(services.nativeInput.status())
        let runtimeState = snapshot.lifecycle == .running && !snapshot.cleanupUncertain ? "ready" : "failed"
        let checks = [
            doctorCheck("runtime", runtimeState, runtimeState == "ready" ? "runtime is ready" : "runtime is not ready"),
            doctorCheck("config", sourceStatus.0, sourceStatus.0 == "ready" ? "configuration is valid" : "configuration is unavailable"),
            doctorCheck("device", snapshot.displayAwake ? "ready" : "sleeping", snapshot.displayAwake ? "display is awake" : "display is asleep"),
            doctorCheck("input", input.value(for: "ready")?.booleanValue == true ? "ready" : "unavailable", "input service status is available"),
        ]
        return success(request, [
            ("doctor", .object([
                ("checks", .array(checks)),
                ("input", input),
            ])),
        ])
    }

    private func emitNotification(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let source = string(request, "source"), let text = string(request, "text") else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        let ttl = request.params.value(for: "ttl_seconds")?.integerValue.map(Int.init)
        do {
            let result = try await coordinator.emitNotification(RuntimeNotificationRequest(source: source, text: text, ttlSeconds: ttl))
            return success(request, [
                ("notification_id", .string(result.notificationID)),
                ("matched_count", integer(result.matchedCount)),
            ])
        } catch RuntimeNotificationError.invalidRequest {
            return failure(request, "invalid_notification", "notification is invalid")
        } catch RuntimeNotificationError.busy {
            return failure(request, "busy", "runtime is busy")
        } catch RuntimeNotificationError.uncertain {
            return failure(request, "device_write_failed", "device update failed")
        } catch {
            return failure(request, "shutting_down", "runtime is not ready")
        }
    }

    private func clearNotification(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let id = string(request, "notification_id") else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        do {
            let result = try await coordinator.clearNotification(id: id)
            return success(request, [("cleared_count", integer(result.clearedCount))])
        } catch RuntimeNotificationError.invalidRequest {
            return failure(request, "invalid_notification", "notification is invalid")
        } catch RuntimeNotificationError.busy {
            return failure(request, "busy", "runtime is busy")
        } catch RuntimeNotificationError.uncertain {
            return failure(request, "device_write_failed", "device update failed")
        } catch {
            return failure(request, "shutting_down", "runtime is not ready")
        }
    }

    private func loadEditorSource(_ request: IPCWireRequest) throws -> (source: IPCConfigurationSource, configuration: HidhoggConfiguration) {
        let source = try IPCConfigurationSource.read(configurationPath)
        guard source.digest == string(request, "source_digest") else { throw IPCServiceRequestError.staleSource }
        return (source, try HidhoggConfigurationDecoder.decode(source.bytes))
    }

    private func editorReadFailure(_ request: IPCWireRequest, _ error: Error) -> IPCWireResponse {
        if case IPCServiceRequestError.staleSource = error {
            return failure(request, "stale_source", "configuration source changed")
        }
        if error is ConfigurationDiagnostic {
            return failure(request, "reload_rejected", "configuration is unavailable")
        }
        return failure(request, "reload_rejected", "configuration is unavailable")
    }

    private func makeConfigurationEdit(
        _ request: IPCWireRequest,
        configuration: HidhoggConfiguration
    ) throws -> RuntimeConfigurationEdit {
        guard let profileID = string(request, "profile_id") else { throw IPCServiceRequestError.invalidRequest }
        switch request.method {
        case .editorProfileLabelSet:
            guard let label = string(request, "label") else { throw IPCServiceRequestError.invalidRequest }
            return .setProfileLabel(profileID: profileID, label: label)
        case .editorPositionLabelSet:
            guard let positionID = string(request, "position_id"), let label = string(request, "label") else {
                throw IPCServiceRequestError.invalidRequest
            }
            return .patchPosition(
                profileID: profileID,
                coordinate: positionID,
                patch: ConfigurationPositionPatch(label: .set(label))
            )
        case .editorProfileCreate:
            guard let label = string(request, "label") else { throw IPCServiceRequestError.invalidRequest }
            let sourceID = string(request, "source_profile_id") ?? configuration.defaultProfileID
            return .cloneProfile(sourceID: sourceID, newID: profileID, label: label)
        case .editorProfileDelete:
            return .deleteProfile(profileID: profileID)
        case .editorPositionPatch:
            guard let positionID = string(request, "position_id"),
                  let value = request.params.value(for: "patch"),
                  let patch = IPCProtocol.decodePatch(value) else {
                throw IPCServiceRequestError.invalidRequest
            }
            return .patchPosition(profileID: profileID, coordinate: positionID, patch: patch)
        default:
            throw IPCServiceRequestError.invalidRequest
        }
    }

    private func applyConfigurationEdit(
        _ edit: RuntimeConfigurationEdit,
        to source: Data,
        currentProfileID: String
    ) throws -> Data {
        switch edit {
        case let .setProfileLabel(profileID, label):
            try ConfigurationEditor.setProfileLabel(in: source, profileID: profileID, label: label)
        case let .cloneProfile(sourceID, newID, label):
            try ConfigurationEditor.cloneProfile(in: source, sourceID: sourceID, newID: newID, label: label)
        case let .deleteProfile(profileID):
            try ConfigurationEditor.deleteProfile(in: source, profileID: profileID, currentProfileID: currentProfileID)
        case let .patchPosition(profileID, coordinate, patch):
            try ConfigurationEditor.patchPosition(in: source, profileID: profileID, coordinate: coordinate, patch: patch)
        }
    }

    private func reloadEffects(
        from previous: RuntimeConfigurationView,
        to current: RuntimeConfigurationView,
        displayChanged: Bool
    ) -> IPCReloadEffects {
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
            actionChanged = zip(oldProfile.positions, newProfile.positions).contains { pair in pair.0.action != pair.1.action }
        } else {
            actionChanged = false
        }
        let effects = IPCReloadEffects(
            catalogChanged: previousConfiguration.profiles != currentConfiguration.profiles,
            defaultChanged: previousConfiguration.defaultProfileID != currentConfiguration.defaultProfileID,
            currentProfileChanged: currentChanged,
            currentProfileFallback: fallback,
            actionChanged: actionChanged,
            displayChanged: displayChanged,
            brightnessChanged: previousConfiguration.brightness != currentConfiguration.brightness,
            idleChanged: previousConfiguration.idleTimeoutSeconds != currentConfiguration.idleTimeoutSeconds,
            effect: ""
        )
        return effects.withEffect
    }

    private func reloadFields(revision: UInt64, changed: Bool, effects: IPCReloadEffects, displayUpdated: Bool) -> [(String, IPCJSONValue)] {
        [
            ("revision", integer(revision)),
            ("changed", .boolean(changed)),
            ("effect", .string(effects.effect)),
            ("catalog_changed", .boolean(effects.catalogChanged)),
            ("default_changed", .boolean(effects.defaultChanged)),
            ("current_profile_changed", .boolean(effects.currentProfileChanged)),
            ("current_profile_fallback", .boolean(effects.currentProfileFallback)),
            ("action_changed", .boolean(effects.actionChanged)),
            ("display_changed", .boolean(effects.displayChanged)),
            ("brightness_changed", .boolean(effects.brightnessChanged)),
            ("idle_changed", .boolean(effects.idleChanged)),
            ("display_updated", .boolean(displayUpdated)),
        ]
    }

    private func configurationStatusResult(
        _ request: IPCWireRequest,
        snapshot: RuntimeSnapshot,
        outcome: String,
        reason: String,
        diagnostic: IPCJSONValue?
    ) -> IPCWireResponse {
        return success(request, [
            ("revision", integer(snapshot.revision)),
            ("active", .boolean(snapshot.lifecycle == .running)),
            ("state", .string(snapshot.lifecycle == .running ? "idle" : "closed")),
            ("outcome", .string(outcome)),
            ("reason", .string(snapshot.lifecycle == .running ? reason : "closed")),
            ("diagnostic", diagnostic ?? .null),
        ])
    }

    private func recordReload(outcome: String, reason: String, diagnostic: IPCJSONValue?) {
        lastReloadOutcome = outcome
        lastReloadReason = reason
        lastReloadDiagnostic = diagnostic
    }

    private func executionSummary(_ summary: RuntimeExecutionSummary, services: RuntimeActionServices) -> IPCJSONValue {
        .object([
            ("action_type", .string("execute")),
            ("execution_id", .string(summary.id)),
            ("profile_id", .string(summary.profileID)),
            ("position_id", .string(summary.coordinate)),
            ("state", .string(executionState(summary.state))),
            ("submitted_at", timestamp(summary.submittedAt, services: services)),
            ("started_at", timestamp(summary.startedAt, services: services)),
            ("finished_at", timestamp(summary.finishedAt, services: services)),
            ("duration_ns", integer(durationNanoseconds(summary.duration))),
            ("exit_code", summary.exitCode.map { integer(Int($0)) } ?? .null),
            ("signal", .null),
            ("supervision_error", .boolean(summary.supervisionUncertain)),
        ])
    }

    private func executionRecord(_ record: RuntimeExecutionRecord, services: RuntimeActionServices) -> IPCJSONValue {
        let summary = record.summary
        return .object([
            ("action_type", .string("execute")),
            ("execution_id", .string(summary.id)),
            ("profile_id", .string(summary.profileID)),
            ("position_id", .string(summary.coordinate)),
            ("state", .string(executionState(summary.state))),
            ("submitted_at", timestamp(summary.submittedAt, services: services)),
            ("started_at", timestamp(summary.startedAt, services: services)),
            ("finished_at", timestamp(summary.finishedAt, services: services)),
            ("duration_ns", integer(durationNanoseconds(summary.duration))),
            ("exit_code", summary.exitCode.map { integer(Int($0)) } ?? .null),
            ("signal", .null),
            ("supervision_error", .boolean(summary.supervisionUncertain)),
            ("stdout", .string(record.standardOutput.tail.base64EncodedString())),
            ("stdout_total_bytes", unsignedInteger(record.standardOutput.totalBytes)),
            ("stdout_truncated", .boolean(record.standardOutput.truncated)),
            ("stderr", .string(record.standardError.tail.base64EncodedString())),
            ("stderr_total_bytes", unsignedInteger(record.standardError.totalBytes)),
            ("stderr_truncated", .boolean(record.standardError.truncated)),
        ])
    }

    private func nativeInputSummary(_ summary: RuntimeNativeInputSummary, services: RuntimeActionServices) -> IPCJSONValue {
        .object([
            ("action_type", .string(summary.actionType)),
            ("execution_id", .string(summary.id)),
            ("profile_id", .string(summary.profileID)),
            ("position_id", .string(summary.coordinate)),
            ("state", .string(nativeInputState(summary.state))),
            ("submitted_at", timestamp(summary.submittedAt, services: services)),
            ("started_at", timestamp(summary.startedAt, services: services)),
            ("finished_at", timestamp(summary.finishedAt, services: services)),
            ("duration_ns", integer(durationNanoseconds(summary.duration))),
            ("exit_code", .null),
            ("signal", .null),
            ("supervision_error", .boolean(false)),
        ])
    }

    private func nativeInputRecord(_ summary: RuntimeNativeInputSummary, services: RuntimeActionServices) -> IPCJSONValue {
        .object([
            ("action_type", .string(summary.actionType)),
            ("execution_id", .string(summary.id)),
            ("profile_id", .string(summary.profileID)),
            ("position_id", .string(summary.coordinate)),
            ("state", .string(nativeInputState(summary.state))),
            ("submitted_at", timestamp(summary.submittedAt, services: services)),
            ("started_at", timestamp(summary.startedAt, services: services)),
            ("finished_at", timestamp(summary.finishedAt, services: services)),
            ("duration_ns", integer(durationNanoseconds(summary.duration))),
            ("exit_code", .null),
            ("signal", .null),
            ("supervision_error", .boolean(false)),
            ("stdout", .string("")),
            ("stdout_total_bytes", integer(0)),
            ("stdout_truncated", .boolean(false)),
            ("stderr", .string("")),
            ("stderr_total_bytes", integer(0)),
            ("stderr_truncated", .boolean(false)),
        ])
    }

    private func executionState(_ state: RuntimeExecutionState) -> String {
        switch state {
        case .running: "running"
        case .exited: "exited"
        case .timedOut: "timed_out"
        case .cancelled: "canceled"
        case .startFailed: "start_failed"
        case .cleanupUncertain: "start_failed"
        case .rejectedBusy: "rejected_busy"
        }
    }

    private func nativeInputState(_ state: RuntimeNativeInputState) -> String {
        switch state {
        case .queued: "queued"
        case .running: "running"
        case .posted: "posted"
        case .permissionDenied: "permission_denied"
        case .failed: "failed"
        case .cancelled: "canceled"
        case .rejectedBusy: "rejected_busy"
        case .rejectedQueueFull: "rejected_queue_full"
        }
    }

    private func durationNanoseconds(_ value: Duration?) -> Int64 {
        guard let value else { return 0 }
        let components = value.components
        let nanos = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !nanos.overflow else { return Int64.max }
        let fraction = components.attoseconds / 1_000_000_000
        let total = nanos.partialValue.addingReportingOverflow(fraction)
        return total.overflow ? Int64.max : max(0, total.partialValue)
    }

    private func timestamp(_ instant: RuntimeMonotonicInstant?, services: RuntimeActionServices) -> IPCJSONValue {
        guard let date = services.date(for: instant) else { return .null }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }

    private func unsignedInteger(_ value: UInt64) -> IPCJSONValue {
        integer(value > UInt64(Int64.max) ? Int64.max : Int64(value))
    }

    private func encodeInputStatus(_ status: RuntimeNativeInputStatus) -> IPCJSONValue {
        let backend: String = status.backend == .ready ? "ready" : "closed"
        let permission: String
        switch status.permission {
        case .granted: permission = "granted"
        case .denied: permission = "not_granted"
        case .checkFailed: permission = "check_failed"
        }
        return .object([
            ("backend_state", .string(backend)),
            ("permission", .string(permission)),
            ("ready", .boolean(status.backend == .ready && status.permission == .granted && !status.requestInProgress)),
            ("queue_depth", integer(status.queueDepth)),
            ("queue_capacity", integer(status.queueCapacity)),
            ("request_in_progress", .boolean(status.requestInProgress)),
            ("detail", .string(status.backend == .ready ? "input service status is available" : "input service is closed")),
        ])
    }

    private func doctorCheck(_ name: String, _ state: String, _ detail: String) -> IPCJSONValue {
        .object([
            ("name", .string(name)),
            ("state", .string(state)),
            ("detail", .string(detail)),
        ])
    }

    private func runtimeError(_ request: IPCWireRequest, _ error: Error) -> IPCWireResponse {
        if let error = error as? RuntimeCoordinatorError {
            switch error {
            case .unknownProfile: return failure(request, "profile_not_found", "profile was not found")
            case .physicalWriteFailed: return failure(request, "device_write_failed", "device update failed")
            case .cancelledBeforeAdmission: return failure(request, "busy", "runtime is busy")
            case .storeFailure(.stale): return failure(request, "stale_source", "configuration source changed")
            case .storeFailure(.invalidConfiguration), .storeFailure(.mutationFailed): return failure(request, "edit_invalid", "configuration edit is invalid")
            case .storeFailure(.invalidDestination), .storeFailure(.diskFailure), .storeFailure(.uncertain):
                return failure(request, "file_commit_failed", "configuration file could not be committed")
            default: return failure(request, "shutting_down", "runtime is not ready")
            }
        }
        if let error = error as? ConfigurationEditingError {
            switch error {
            case .profileNotFound: return failure(request, "profile_not_found", "profile was not found")
            default: return failure(request, "edit_invalid", "configuration edit is invalid")
            }
        }
        if let error = error as? RuntimeNotificationError {
            switch error {
            case .invalidRequest: return failure(request, "invalid_notification", "notification is invalid")
            case .busy: return failure(request, "busy", "runtime is busy")
            case .uncertain: return failure(request, "device_write_failed", "device update failed")
            case .closed: return failure(request, "shutting_down", "runtime is not ready")
            }
        }
        if let error = error as? IPCServiceRequestError {
            switch error {
            case .staleSource: return failure(request, "stale_source", "configuration source changed")
            case .invalidRequest: return failure(request, "invalid_envelope", "request envelope is invalid")
            }
        }
        if error is IPCConfigurationReadError { return failure(request, "reload_rejected", "configuration is unavailable") }
        return failure(request, "internal", "internal server error")
    }

    private func string(_ request: IPCWireRequest, _ key: String) -> String? {
        request.params.value(for: key)?.stringValue
    }

    private func success(_ request: IPCWireRequest, _ fields: [(String, IPCJSONValue)], includeInstanceID: Bool = true) -> IPCWireResponse {
        var resultFields = fields
        if includeInstanceID { resultFields.insert(("instance_id", .string(request.instanceID)), at: 0) }
        return IPCWireResponse(requestID: request.requestID, result: .object(resultFields))
    }

    private func failure(_ request: IPCWireRequest, _ code: String, _ message: String) -> IPCWireResponse {
        IPCWireResponse(
            requestID: request.requestID,
            failure: IPCProtocolFailure(code: code, message: message, requestID: request.requestID)
        )
    }
}

private enum IPCServiceRequestError: Error {
    case staleSource
    case invalidRequest
}

private enum IPCConfigurationReadError: Error {
    case notFound
    case denied
    case invalid
    case read
    case decode

    var projection: IPCJSONValue {
        switch self {
        case .notFound: readDiagnostic(.readNotFound)
        case .denied: readDiagnostic(.readDenied)
        case .invalid: readDiagnostic(.readInvalid)
        case .read: readDiagnostic(.read)
        case .decode: readDiagnostic(.decode)
        }
    }
}

private struct IPCConfigurationSource {
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

private struct IPCReloadEffects {
    let catalogChanged: Bool
    let defaultChanged: Bool
    let currentProfileChanged: Bool
    let currentProfileFallback: Bool
    let actionChanged: Bool
    let displayChanged: Bool
    let brightnessChanged: Bool
    let idleChanged: Bool
    var effect: String

    var withEffect: Self {
        let changed = catalogChanged || defaultChanged || currentProfileChanged || currentProfileFallback || actionChanged || displayChanged || brightnessChanged || idleChanged
        if !changed { return with(effect: "unchanged") }
        if actionChanged && !displayChanged && !brightnessChanged && !idleChanged && !defaultChanged && !currentProfileFallback && currentProfileChanged {
            return with(effect: "action-only")
        }
        if displayChanged { return with(effect: "display") }
        if brightnessChanged { return with(effect: "brightness") }
        if idleChanged { return with(effect: "idle") }
        if defaultChanged || currentProfileFallback { return with(effect: "default") }
        return with(effect: "catalog")
    }

    private func with(effect: String) -> Self {
        Self(
            catalogChanged: catalogChanged,
            defaultChanged: defaultChanged,
            currentProfileChanged: currentProfileChanged,
            currentProfileFallback: currentProfileFallback,
            actionChanged: actionChanged,
            displayChanged: displayChanged,
            brightnessChanged: brightnessChanged,
            idleChanged: idleChanged,
            effect: effect
        )
    }
}

private func reloadOutcome(_ outcome: RuntimeConfigurationReloadOutcome) -> String {
    switch outcome {
    case .unchanged: "unchanged"
    case .reloaded: "changed"
    case .rejected: "rejected"
    case .runtimeFailed: "uncertain"
    }
}

private func configurationStatusDiagnostic(_ value: ConfigurationDiagnosticProjection) -> IPCJSONValue {
    diagnosticValue(value)
}

private func diagnosticValue(_ value: ConfigurationDiagnosticProjection) -> IPCJSONValue {
    .object([
        ("category", .string(value.category.rawValue)),
        ("key", value.key.isEmpty ? .null : .string(value.key)),
        ("line", value.line == 0 ? .null : integer(value.line)),
        ("column", value.column == 0 ? .null : integer(value.column)),
        ("detail", .string(value.detail)),
    ])
}

private func readDiagnostic(_ category: ConfigurationDiagnosticCategory) -> IPCJSONValue {
    let diagnostic = ConfigurationDiagnostic.make(category)
    return diagnosticValue(diagnostic.safeProjection())
}

private func integer(_ value: Int) -> IPCJSONValue {
    .number(IPCJSONNumber(integer: Int64(clamping: value)))
}

private func integer(_ value: Int64) -> IPCJSONValue {
    .number(IPCJSONNumber(integer: value))
}

private func integer(_ value: UInt64) -> IPCJSONValue {
    integer(value > UInt64(Int64.max) ? Int64.max : Int64(value))
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
