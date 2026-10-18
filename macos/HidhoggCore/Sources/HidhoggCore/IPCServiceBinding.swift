import Darwin
import Foundation

public enum IPCServiceBindingError: Error, Sendable, Equatable {
    case invalidConfigurationPath
}

public actor IPCServiceBinding {
    private let operations: RuntimeOperations
    private let coordinator: RuntimeCoordinator
    private let configurationPath: String

    var pendingConfigurationOperations: Int {
        get async { await operations.pendingConfigurationOperations }
    }

    public init(coordinator: RuntimeCoordinator, configurationPath: String) throws {
        do { operations = try RuntimeOperations(coordinator: coordinator, configurationPath: configurationPath) }
        catch { throw IPCServiceBindingError.invalidConfigurationPath }
        self.coordinator = coordinator
        self.configurationPath = operations.configurationPath
    }

    public init(operations: RuntimeOperations) {
        self.operations = operations
        coordinator = operations.coordinator
        configurationPath = operations.configurationPath
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
        do { try await operations.checkAvailability() }
        catch { return failure(request, "shutting_down", "runtime is not ready") }

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
        do {
            let profiles = try await operations.profiles().map { profile in
                IPCJSONValue.object([
                    ("id", .string(profile.id)),
                    ("label", .string(profile.label)),
                    ("is_default", .boolean(profile.isDefault)),
                    ("is_current", .boolean(profile.isCurrent)),
                ])
            }
            return success(request, [("profiles", .array(profiles))])
        } catch { return runtimeError(request, error) }
    }

    private func activateProfile(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let profileID = string(request, "profile_id") else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        do {
            let result = try await operations.activateProfile(profileID)
            return success(request, [("profile_id", .string(result.profileID)), ("changed", .boolean(result.changed))], includeInstanceID: false)
        } catch { return runtimeError(request, error) }
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
        do {
            let result = try await operations.reloadConfiguration()
            return success(request, reloadFields(revision: result.revision, changed: result.changed, effects: result.effects, displayUpdated: result.displayUpdated))
        } catch { return runtimeError(request, error) }
    }

    private func configurationStatus(_ request: IPCWireRequest) async -> IPCWireResponse {
        do {
            let status = try await operations.configurationStatus()
            return success(request, [
                ("revision", integer(status.revision)),
                ("active", .boolean(status.active)),
                ("state", .string(status.state.rawValue)),
                ("outcome", .string(status.outcome.rawValue)),
                ("reason", .string(status.reason.rawValue)),
                ("diagnostic", status.diagnostic.map(diagnosticValue) ?? .null),
            ])
        } catch { return runtimeError(request, error) }
    }

    private func editorSnapshot(_ request: IPCWireRequest) async -> IPCWireResponse {
        do {
            let result = try await operations.editorSnapshot()
            return success(request, [
                ("source_digest", .string(result.sourceDigest)),
                ("revision", integer(result.revision)),
                ("default_profile_id", .string(result.defaultProfileID)),
                ("current_profile_id", .string(result.currentProfileID)),
                ("profile_ids", .array(result.profileIDs.map(IPCJSONValue.string))),
            ])
        } catch { return runtimeError(request, error) }
    }

    private func editorPositions(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let digest = string(request, "source_digest"), let profileID = string(request, "profile_id") else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        do {
            let result = try await operations.editorPositions(sourceDigest: digest, profileID: profileID)
            return success(request, [
                ("source_digest", .string(result.sourceDigest)),
                ("profile_id", .string(result.profileID)),
                ("positions", .array(result.positions.map { .object([("position_id", .string($0.positionID)), ("position", .string($0.position))]) })),
            ])
        } catch { return runtimeError(request, error) }
    }

    private func editorProfile(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let digest = string(request, "source_digest"), let profileID = string(request, "profile_id") else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        do {
            let result = try await operations.editorProfile(sourceDigest: digest, profileID: profileID)
            return success(request, [("source_digest", .string(result.sourceDigest)), ("profile_id", .string(result.profileID)), ("label", .string(result.label))])
        } catch { return runtimeError(request, error) }
    }

    private func editorPosition(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let digest = string(request, "source_digest"), let profileID = string(request, "profile_id"), let positionID = string(request, "position_id") else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        do {
            let result = try await operations.editorPosition(sourceDigest: digest, profileID: profileID, positionID: positionID)
            var fields: [(String, IPCJSONValue)] = [
                ("source_digest", .string(result.sourceDigest)),
                ("profile_id", .string(result.profileID)),
                ("position_id", .string(result.positionID)),
                ("label", .string(result.label)),
                ("background", .string(result.background)),
                ("label_alignment", .string(result.labelAlignment)),
                ("label_size", integer(result.labelSize)),
                ("notification_sources", .array(result.notificationSources.map(IPCJSONValue.string))),
            ]
            if let action = result.action { fields.append(("action", IPCProtocol.encodeAction(action))) }
            return success(request, fields)
        } catch { return runtimeError(request, error) }
    }

    private func editConfiguration(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let expectedDigest = string(request, "expected_digest") else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        do {
            let result: RuntimeOperationEditResult
            if request.method == .editorProfileCreate {
                guard let profileID = string(request, "profile_id"), let label = string(request, "label") else {
                    throw IPCServiceRequestError.invalidRequest
                }
                result = try await operations.cloneProfile(expectedDigest: expectedDigest, sourceProfileID: string(request, "source_profile_id"), profileID: profileID, label: label)
            } else {
                let edit = try makeConfigurationEdit(request)
                result = try await operations.edit(expectedDigest: expectedDigest, edit: edit)
            }
            return success(request, [
                ("source_digest", .string(result.sourceDigest)),
                ("file_commit", .string(result.fileCommit.rawValue)),
                ("reload_outcome", .string(reloadOutcome(result.reloadOutcome))),
                ("revision", integer(result.revision)),
                ("effect", .string(result.effect.rawValue)),
                ("reason", .string(result.reason.rawValue)),
            ])
        } catch { return runtimeError(request, error) }
    }

    private func setDisplayHostState(_ request: IPCWireRequest) async -> IPCWireResponse {
        guard let awake = request.params.value(for: "display_awake")?.booleanValue else {
            return failure(request, "invalid_envelope", "request envelope is invalid")
        }
        do {
            let result = try await operations.setHostDisplayAwake(awake)
            return success(request, [("display_awake", .boolean(result.displayAwake)), ("changed", .boolean(result.changed))])
        } catch { return runtimeError(request, error) }
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
            sourceStatus = ("failed", diagnosticValue(error.projection))
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

    private func makeConfigurationEdit(
        _ request: IPCWireRequest
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

    private func reloadFields(revision: UInt64, changed: Bool, effects: RuntimeOperationReloadEffects, displayUpdated: Bool) -> [(String, IPCJSONValue)] {
        [
            ("revision", integer(revision)),
            ("changed", .boolean(changed)),
            ("effect", .string(effects.effect.rawValue)),
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
        if let error = error as? RuntimeOperationError {
            switch error {
            case .closed: return failure(request, "shutting_down", "runtime is not ready")
            case .cancelledBeforeAdmission: return failure(request, "busy", "runtime is busy")
            case .staleSource: return failure(request, "stale_source", "configuration source changed")
            case .profileNotFound: return failure(request, "profile_not_found", request.method == .editorPositionGet ? "profile or position was not found" : "profile was not found")
            case .editInvalid: return failure(request, "edit_invalid", "configuration edit is invalid")
            case .configurationUnavailable: return failure(request, "reload_rejected", "configuration is unavailable")
            case .fileCommitFailed: return failure(request, "file_commit_failed", "configuration file could not be committed")
            case .deviceWriteFailed: return failure(request, "device_write_failed", "device update failed")
            case .activationFailed: return failure(request, "activation_failed", "profile activation failed")
            case .reloadRejected: return failure(request, "reload_rejected", "configuration reload was rejected")
            case .invalidConfigurationPath: return failure(request, "internal", "internal server error")
            }
        }
        if let error = error as? IPCServiceRequestError {
            switch error {
            case .invalidRequest: return failure(request, "invalid_envelope", "request envelope is invalid")
            }
        }
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
    case invalidRequest
}

private func reloadOutcome(_ outcome: RuntimeConfigurationReloadOutcome) -> String {
    switch outcome {
    case .unchanged: "unchanged"
    case .reloaded: "changed"
    case .rejected: "rejected"
    case .runtimeFailed: "uncertain"
    }
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
