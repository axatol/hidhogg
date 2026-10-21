import LogitechBolt

enum DiagnosticCode: String, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case applicationStarted = "app.process.started"
    case applicationError = "app.error"
    case instanceOwnershipFailed = "app.instance.ownership-failed"
    case restartFailed = "app.restart.failed"
    case systemSleep = "app.lifecycle.sleep"
    case systemWake = "app.lifecycle.wake"
    case wakeReconnectAttempt = "app.wake-reconnect.attempt"
    case wakeReconnectSucceeded = "app.wake-reconnect.succeeded"
    case wakeReconnectExhausted = "app.wake-reconnect.exhausted"
    case wakeReconnectCancelled = "app.wake-reconnect.cancelled"
    case permissionStatus = "app.permission.status"
    case configurationValidationFailed = "configuration.validation.failed"
    case configurationLoadFailed = "configuration.load.failed"
    case configurationSaveFailed = "configuration.save.failed"
    case keyboardDeliverySucceeded = "input.keyboard.succeeded"
    case keyboardDeliveryFailed = "input.keyboard.failed"
    case scrollDeliveryFailed = "input.scroll.failed"
    case thumbwheelDeliveryFailed = "input.thumbwheel.failed"
    case boltStatus = "bolt.status"
    case boltCleanupUncertain = "bolt.cleanup.uncertain"
    case boltWheelStatus = "bolt.wheel.status"
    case boltWheelCaptureBlocker = "bolt.wheel.capture-blocked"
    case boltThumbwheelStatus = "bolt.thumbwheel.status"
    case boltThumbwheelCaptureBlocker = "bolt.thumbwheel.capture-blocked"
    case boltEndpointUnavailable = "bolt.endpoint.unavailable"
    case boltEndpointAmbiguous = "bolt.endpoint.ambiguous"
    case boltRequestTimeout = "bolt.request.timeout"
    case boltDisconnected = "bolt.disconnected"
    case boltTransportFailed = "bolt.transport.failed"
    case boltReplyMalformed = "bolt.reply.malformed"
    case boltControlsUnsupported = "bolt.controls.unsupported"
    case boltExternalStateChanged = "bolt.state.external-change"
    case boltReportStale = "bolt.report.stale"
    case boltEventsOverflowed = "bolt.events.overflow"
    case boltOperationCancelled = "bolt.operation.cancelled"
    case boltRequestIDsExhausted = "bolt.request-id.exhausted"

    var id: String { rawValue }

    static func boltFailure(_ failure: BoltFailureCode) -> Self {
        switch failure {
        case .endpointUnavailable: .boltEndpointUnavailable
        case .endpointAmbiguous: .boltEndpointAmbiguous
        case .requestTimeout: .boltRequestTimeout
        case .disconnected: .boltDisconnected
        case .transportFailed: .boltTransportFailed
        case .replyMalformed: .boltReplyMalformed
        case .controlsUnsupported: .boltControlsUnsupported
        case .externalStateChanged: .boltExternalStateChanged
        case .reportStale: .boltReportStale
        case .eventsOverflowed: .boltEventsOverflowed
        case .operationCancelled: .boltOperationCancelled
        case .requestIDsExhausted: .boltRequestIDsExhausted
        }
    }
}
