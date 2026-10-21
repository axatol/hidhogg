import Combine
import Foundation
import LogitechBolt
import OSLog

struct DiagnosticEntry: Identifiable {
    let id: UUID
    let date: Date
    let code: DiagnosticCode
    let message: String
    let isError: Bool
    let buildID: String
    let source: DiagnosticSource

    fileprivate init(event: DiagnosticEvent, buildID: String) {
        id = event.id
        date = event.date
        code = event.code
        message = event.message
        isError = event.isError
        self.buildID = buildID
        source = event.source
    }

    var consoleMessage: String { "code=\(code.rawValue) id=\(id.uuidString) build=\(buildID) source=\(source.description) message=\(message)" }
}

@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []
    private var subscriptions = Set<AnyCancellable>()
    private let injectedPersist: (@MainActor (String, Bool) -> Void)?
    private let buildID: String
    private var latestStatusByChannel: [StatusChannel: StatusFingerprint] = [:]

    private enum StatusChannel: Hashable {
        case permission
        case bolt
        case wheelMessage
        case wheelCaptureBlocker
        case thumbwheelMessage
        case thumbwheelCaptureBlocker
    }

    private struct StatusFingerprint: Equatable {
        let code: DiagnosticCode
        let message: String
        let isError: Bool
    }

    init(model: AppModel? = nil, persist: (@MainActor (String, Bool) -> Void)? = nil) {
        injectedPersist = persist
        buildID = ApplicationIdentity.current.buildID
        let identity = ApplicationIdentity.current
        record(DiagnosticEvent(code: .applicationStarted, message: "Process \(identity.processID); build \(identity.buildID.prefix(12))."))
        guard let model else { return }
        model.$permissionChecks.removeDuplicates().sink { [weak self] checks in
            self?.recordStatus(DiagnosticEvent(
                code: .permissionStatus,
                message: "Permission checks: accessibilityTrusted=\(checks.accessibilityTrusted), eventPostingAllowed=\(checks.eventPostingAllowed).",
                isError: !checks.eventPostingAllowed
            ), in: .permission)
        }.store(in: &subscriptions)
        model.$boltStatus.removeDuplicates().sink { [weak self] status in
            self?.recordBoltStatus(status)
        }.store(in: &subscriptions)
        model.$diagnosticEvent.compactMap { $0 }.sink { [weak self] event in
            self?.record(event)
        }.store(in: &subscriptions)
    }

    func record(_ event: DiagnosticEvent) {
        let entry = DiagnosticEntry(event: event, buildID: buildID)
        entries.append(entry)
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        let message = event.consoleMessage(buildID: buildID)
        if let injectedPersist {
            injectedPersist(message, event.isError)
        } else {
            Self.persist(message, event.isError)
        }
    }

    func recordBoltStatus(_ status: BoltStatus) {
        let statusCode = status.failure.map { DiagnosticCode.boltFailure($0.code) }
            ?? (status.cleanupUncertain ? .boltCleanupUncertain : .boltStatus)
        let source = status.failure.map { DiagnosticSource(fileID: $0.sourceFileID, line: $0.sourceLine) }
            ?? DiagnosticSource()
        recordStatus(DiagnosticEvent(
            code: statusCode,
            message: status.message,
            isError: status.phase == .failed || status.cleanupUncertain,
            fileID: source.fileID,
            line: source.line
        ), in: .bolt)

        if let message = status.wheel.message {
            recordStatus(DiagnosticEvent(code: .boltWheelStatus, message: "Wheel: \(message)", isError: status.cleanupUncertain), in: .wheelMessage)
        } else {
            clearStatus(in: .wheelMessage)
        }
        if let blocker = status.wheel.captureBlocker {
            recordStatus(DiagnosticEvent(code: .boltWheelCaptureBlocker, message: blocker, isError: true), in: .wheelCaptureBlocker)
        } else {
            clearStatus(in: .wheelCaptureBlocker)
        }
        if let message = status.thumbwheel.message {
            recordStatus(DiagnosticEvent(code: .boltThumbwheelStatus, message: "Thumb-wheel: \(message)", isError: status.cleanupUncertain), in: .thumbwheelMessage)
        } else {
            clearStatus(in: .thumbwheelMessage)
        }
        if let blocker = status.thumbwheel.captureBlocker {
            recordStatus(DiagnosticEvent(code: .boltThumbwheelCaptureBlocker, message: blocker, isError: true), in: .thumbwheelCaptureBlocker)
        } else {
            clearStatus(in: .thumbwheelCaptureBlocker)
        }
    }

    private func recordStatus(_ event: DiagnosticEvent, in channel: StatusChannel) {
        let fingerprint = StatusFingerprint(code: event.code, message: event.message, isError: event.isError)
        guard latestStatusByChannel[channel] != fingerprint else { return }
        latestStatusByChannel[channel] = fingerprint
        record(event)
    }

    private func clearStatus(in channel: StatusChannel) {
        latestStatusByChannel.removeValue(forKey: channel)
    }

    func clear() {
        entries.removeAll()
        latestStatusByChannel.removeAll()
    }

    static func log(_ event: DiagnosticEvent) {
        let buildID = ApplicationIdentity.current.buildID
        persist(event.consoleMessage(buildID: buildID), event.isError)
    }

    private static func persist(_ message: String, _ isError: Bool) {
        let logger = Logger(subsystem: "com.hidhogg.app", category: "diagnostics")
        if isError {
            logger.error("\(message, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
    }
}
