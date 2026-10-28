import Foundation

public protocol FlowLite84SessionProtocol: Sendable {
    var events: AsyncStream<FlowLite84Event> { get }
    func connect() async throws
    func refresh() async throws
    func refreshBattery() async throws
    func disconnect() async
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

    public init(
        identity: FlowLite84Identity, online: Bool, keyboardVersion: String? = nil,
        receiverVersion: String? = nil, battery: FlowLite84Battery? = nil,
        lighting: FlowLite84Lighting? = nil, systemMode: UInt8? = nil,
        readAt: Date = Date(), batteryReadAt: Date? = nil, unavailableFields: [String] = []
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

    public var userMessage: String {
        switch self {
        case .unavailable: "The Flow Lite84 receiver was not found."
        case .ambiguous: "More than one matching receiver was found."
        case .unsupportedDevice: "The receiver did not identify as a supported Flow Lite84."
        case .invalidRequest: "The requested operation is outside the read-only status scope."
        case .invalidFrame: "The receiver returned an invalid status response."
        case .invalidResponse(let issue): "The receiver returned an invalid status response (\(issue.userMessage))."
        case .rejected: "The receiver rejected a status query."
        case .timeout: "The receiver did not answer in time. Reconnect to try again."
        case .transport: "Communication with the receiver failed."
        case .disconnected: "The receiver is disconnected."
        case .cancelled: "The status query was cancelled."
        case .busy: "A receiver connection is already in progress."
        case .overflow: "The receiver sent more status reports than could be processed."
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
