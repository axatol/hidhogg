import Foundation

public protocol FlowLite84SessionProtocol: Sendable {
    var events: AsyncStream<FlowLite84Event> { get }
    func connect() async throws
    func refresh() async throws
    func refreshBattery() async throws
    func applyLighting(_ edit: FlowLite84LightingEdit) async throws -> FlowLite84Snapshot
    func restoreOriginalLighting() async throws -> FlowLite84Snapshot
    func applySystemMode(_ mode: FlowLite84SystemMode) async throws -> FlowLite84Snapshot
    func restoreOriginalSystemMode() async throws -> FlowLite84Snapshot
    func disconnect() async
}

public extension FlowLite84SessionProtocol {
    func applyLighting(_ edit: FlowLite84LightingEdit) async throws -> FlowLite84Snapshot { throw FlowLite84Failure.unavailable }
    func restoreOriginalLighting() async throws -> FlowLite84Snapshot { throw FlowLite84Failure.unavailable }
    func applySystemMode(_ mode: FlowLite84SystemMode) async throws -> FlowLite84Snapshot { throw FlowLite84Failure.unavailable }
    func restoreOriginalSystemMode() async throws -> FlowLite84Snapshot { throw FlowLite84Failure.unavailable }
}

public enum FlowLite84SystemMode: UInt8, CaseIterable, Sendable {
    case windows = 0, mac = 1

    public var title: String {
        switch self {
        case .windows: "Windows"
        case .mac: "Mac"
        }
    }
}

public enum FlowLite84LightingEffect: UInt8, CaseIterable, Sendable {
    case trailing = 4, breathing, wave, reactive, ripple, snake, steady

    public var title: String {
        switch self {
        case .trailing: "Trailing"
        case .breathing: "Breathing"
        case .wave: "Wave"
        case .reactive: "Reactive"
        case .ripple: "Ripple"
        case .snake: "Snake"
        case .steady: "Steady"
        }
    }
}

public enum FlowLite84LightingIdleOff: UInt8, CaseIterable, Sendable {
    case tenSeconds = 1, thirtySeconds = 3, oneMinute = 6, twoMinutes = 12
    case fiveMinutes = 30, tenMinutes = 60, fifteenMinutes = 90

    public var title: String {
        switch self {
        case .tenSeconds: "10 seconds"
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .fifteenMinutes: "15 minutes"
        }
    }
}

public struct FlowLite84LightingEdit: Equatable, Sendable {
    public let effect: FlowLite84LightingEffect?
    public let enabled: Bool?
    public let brightnessLevel: UInt8?
    public let speedLevel: UInt8?
    public let idleOff: FlowLite84LightingIdleOff?

    public init(effect: FlowLite84LightingEffect? = nil, enabled: Bool? = nil,
                brightnessLevel: UInt8? = nil, speedLevel: UInt8? = nil,
                idleOff: FlowLite84LightingIdleOff? = nil) {
        self.effect = effect
        self.enabled = enabled
        self.brightnessLevel = brightnessLevel
        self.speedLevel = speedLevel
        self.idleOff = idleOff
    }

    var isValid: Bool {
        (brightnessLevel.map { $0 <= 4 } ?? true) && (speedLevel.map { $0 <= 4 } ?? true)
    }

    var isEmpty: Bool {
        effect == nil && enabled == nil && brightnessLevel == nil && speedLevel == nil && idleOff == nil
    }
}

public protocol FlowLite84Transport: Sendable {
    var reports: AsyncThrowingStream<Data, Error> { get }
    func open() async throws
    func write(_ report: Data) async throws
    func close() async
}

public enum FlowLite84ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(FlowLite84Identity)
    case disconnecting
    case failed(FlowLite84Failure)
}

public enum FlowLite84Event: Equatable, Sendable {
    case status(FlowLite84ConnectionStatus, generation: UInt64)
    case snapshot(FlowLite84Snapshot, generation: UInt64)
}

public struct FlowLite84Identity: Equatable, Sendable {
    public let cid: UInt8
    public let mid: UInt8
    public let connectionType: UInt8

    public init(cid: UInt8, mid: UInt8, connectionType: UInt8) {
        self.cid = cid
        self.mid = mid
        self.connectionType = connectionType
    }

    public var isSupported: Bool { cid == 1 && mid == 1 && connectionType == 0 }
}

public struct FlowLite84Battery: Equatable, Sendable {
    public let reportedLevel: UInt8?
    public let charging: Bool?
    public let voltageMillivolts: UInt16?

    public init(reportedLevel: UInt8? = nil, charging: Bool? = nil, voltageMillivolts: UInt16? = nil) {
        self.reportedLevel = reportedLevel
        self.charging = charging
        self.voltageMillivolts = voltageMillivolts
    }
}

public struct FlowLite84Lighting: Equatable, Sendable {
    public let mode: UInt8
    public let enabled: Bool
    public let idleOffUnits: UInt8
    public let brightnessLevel: UInt8?
    public let speedLevel: UInt8?

    public var effect: FlowLite84LightingEffect? { FlowLite84LightingEffect(rawValue: mode) }
    public var idleOff: FlowLite84LightingIdleOff? { FlowLite84LightingIdleOff(rawValue: idleOffUnits) }

    public static func displayedLevel(_ raw: UInt8?) -> UInt8? {
        guard let raw, raw <= 4 else { return nil }
        return raw + 1
    }

    public static func levelTitle(_ raw: UInt8?) -> String {
        displayedLevel(raw).map(String.init) ?? "Unknown"
    }

    public init(mode: UInt8, enabled: Bool, idleOffUnits: UInt8, brightnessLevel: UInt8? = nil, speedLevel: UInt8? = nil) {
        self.mode = mode
        self.enabled = enabled
        self.idleOffUnits = idleOffUnits
        self.brightnessLevel = brightnessLevel
        self.speedLevel = speedLevel
    }
}

public struct FlowLite84Snapshot: Equatable, Sendable {
    public let identity: FlowLite84Identity
    public let online: Bool
    public let keyboardVersion: String?
    public let receiverVersion: String?
    public let battery: FlowLite84Battery?
    public let lighting: FlowLite84Lighting?
    public let systemMode: UInt8?
    public let readAt: Date
    public let batteryReadAt: Date?
    public let unavailableFields: [String]
    public let canRestoreOriginalLighting: Bool
    public let canRestoreOriginalSystemMode: Bool

    public init(
        identity: FlowLite84Identity, online: Bool, keyboardVersion: String? = nil,
        receiverVersion: String? = nil, battery: FlowLite84Battery? = nil,
        lighting: FlowLite84Lighting? = nil, systemMode: UInt8? = nil,
        readAt: Date = Date(), batteryReadAt: Date? = nil, unavailableFields: [String] = [],
        canRestoreOriginalLighting: Bool = false, canRestoreOriginalSystemMode: Bool = false
    ) {
        self.identity = identity
        self.online = online
        self.keyboardVersion = keyboardVersion
        self.receiverVersion = receiverVersion
        self.battery = battery
        self.lighting = lighting
        self.systemMode = systemMode
        self.readAt = readAt
        self.batteryReadAt = batteryReadAt
        self.unavailableFields = unavailableFields
        self.canRestoreOriginalLighting = canRestoreOriginalLighting
        self.canRestoreOriginalSystemMode = canRestoreOriginalSystemMode
    }
}

public enum FlowLite84ValidationIssue: Equatable, Sendable {
    case shape
    case packetChecksum
    case unsupportedCommand
    case readHeader
    case replyCommand(expected: UInt8, received: UInt8)
    case unexpectedReply(command: UInt8)
    case duplicateReply(command: UInt8)
    case notificationStatus
    case onlineFlag
    case scalarChecksum
    case effectChecksum
    case writeHeader

    public var userMessage: String {
        switch self {
        case .shape: "report shape"
        case .packetChecksum: "packet checksum"
        case .unsupportedCommand: "unsupported response command"
        case .readHeader: "read response header"
        case .replyCommand(let expected, let received): "expected command \(expected), received command \(received)"
        case .unexpectedReply(let command): "unexpected command \(command) reply"
        case .duplicateReply(let command): "duplicate command \(command) reply"
        case .notificationStatus: "notification status"
        case .onlineFlag: "online flag"
        case .scalarChecksum: "setting checksum"
        case .effectChecksum: "lighting header checksum"
        case .writeHeader: "configuration write acknowledgement header"
        }
    }
}

public enum FlowLite84Failure: Error, Equatable, Sendable {
    case unavailable
    case ambiguous
    case unsupportedDevice
    case invalidRequest
    case invalidFrame
    case invalidResponse(FlowLite84ValidationIssue)
    case rejected(command: UInt8, status: UInt8)
    case timeout
    case transport
    case disconnected
    case cancelled
    case busy
    case overflow
    case lightingUnavailable
    case lightingOutcomeUnknown
    case lightingReadbackMismatch
    case noOriginalLighting
    case systemModeOutcomeUnknown
    case systemModeReadbackMismatch
    case noOriginalSystemMode

    public var userMessage: String {
        switch self {
        case .unavailable: "The Flow Lite84 receiver was not found."
        case .ambiguous: "More than one matching receiver was found."
        case .unsupportedDevice: "The receiver did not identify as a supported Flow Lite84."
        case .invalidRequest: "The requested operation is outside the supported status, lighting and system-mode scope."
        case .invalidFrame: "The receiver returned an invalid status response."
        case .invalidResponse(let issue): "The receiver returned an invalid status response (\(issue.userMessage))."
        case .rejected(let command, _): command == 7 ? "The receiver rejected the settings change. Earlier changes may have been applied." : "The receiver rejected a status query."
        case .timeout: "The receiver did not answer in time. Reconnect to try again."
        case .transport: "Communication with the receiver failed."
        case .disconnected: "The receiver is disconnected."
        case .cancelled: "The status query was cancelled."
        case .busy: "A receiver operation is already in progress."
        case .overflow: "The receiver sent more status reports than could be processed."
        case .lightingUnavailable: "Fresh lighting values are unavailable. No lighting write was sent."
        case .lightingOutcomeUnknown: "The lighting operation was interrupted. Some changes may have reached the keyboard. No write was retried. Reconnect or refresh to check the current values."
        case .lightingReadbackMismatch: "Lighting readback did not match the requested values. Some changes may have been applied."
        case .noOriginalLighting: "No original lighting values are available for this connection."
        case .systemModeOutcomeUnknown: "The system-mode operation was interrupted. The change may have reached the keyboard. No write was retried. Reconnect or refresh to check the current value."
        case .systemModeReadbackMismatch: "System-mode readback did not match the requested value. The change may have been applied."
        case .noOriginalSystemMode: "No original system mode is available for this connection."
        }
    }
}

public struct FlowLite84Timing: Sendable {
    public let responseTimeout: Duration
    public let sleep: @Sendable (Duration) async throws -> Void
    public let now: @Sendable () -> Date

    public init(
        responseTimeout: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.responseTimeout = responseTimeout
        self.sleep = sleep
        self.now = now
    }
}
