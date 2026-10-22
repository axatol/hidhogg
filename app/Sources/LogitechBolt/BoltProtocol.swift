import Foundation
import HidhoggDomain

public enum BoltPhase: String, Sendable {
    case idle, discovering, ready, enabling, enabled, stopping, failed
}

public struct BoltWheelStatus: Equatable, Sendable {
    public enum Support: Equatable, Sendable {
        case unknown, unsupported, supported
    }

    public let support: Support
    public let observedInverted: Bool?
    public let observedHighResolution: Bool?
    public let isOwned: Bool
    public let isApplying: Bool
    public let message: String?
    public let captureActive: Bool
    public let captureBlocker: String?
    public let effectiveInverted: Bool?

    public init(support: Support = .unknown, observedInverted: Bool? = nil, isOwned: Bool = false, isApplying: Bool = false, message: String? = nil, observedHighResolution: Bool? = nil, captureActive: Bool = false, captureBlocker: String? = nil, effectiveInverted: Bool? = nil) {
        self.support = support
        self.observedInverted = observedInverted
        self.observedHighResolution = observedHighResolution
        self.isOwned = isOwned
        self.isApplying = isApplying
        self.message = message
        self.captureActive = captureActive
        self.captureBlocker = captureBlocker
        self.effectiveInverted = effectiveInverted
    }
}

public struct BoltThumbwheelStatus: Equatable, Sendable {
    public enum Support: Equatable, Sendable { case unknown, unsupported, supported }

    public let support: Support
    public let observedInverted: Bool?
    public let isOwned: Bool
    public let captureActive: Bool
    public let effectiveInverted: Bool?
    public let captureBlocker: String?
    public let message: String?

    public init(support: Support = .unknown, observedInverted: Bool? = nil, isOwned: Bool = false,
                captureActive: Bool = false, effectiveInverted: Bool? = nil,
                captureBlocker: String? = nil, message: String? = nil) {
        self.support = support
        self.observedInverted = observedInverted
        self.isOwned = isOwned
        self.captureActive = captureActive
        self.effectiveInverted = effectiveInverted
        self.captureBlocker = captureBlocker
        self.message = message
    }
}

public struct BoltStatus: Equatable, Sendable {
    public let phase: BoltPhase
    public let message: String
    public let availableControls: Set<MouseControl>
    public let generation: UInt64
    public let cleanupUncertain: Bool
    public let wheel: BoltWheelStatus
    public let thumbwheel: BoltThumbwheelStatus
    public let failure: BoltFailureContext?

    public init(phase: BoltPhase, message: String, availableControls: Set<MouseControl>, generation: UInt64, cleanupUncertain: Bool, wheel: BoltWheelStatus = .init(), thumbwheel: BoltThumbwheelStatus = .init(), failure: BoltFailureContext? = nil) {
        self.phase = phase
        self.message = message
        self.availableControls = availableControls
        self.generation = generation
        self.cleanupUncertain = cleanupUncertain
        self.wheel = wheel
        self.thumbwheel = thumbwheel
        self.failure = failure
    }
}

public enum BoltFailureCode: String, Equatable, Sendable {
    case endpointUnavailable = "bolt.endpoint.unavailable"
    case endpointAmbiguous = "bolt.endpoint.ambiguous"
    case requestTimeout = "bolt.request.timeout"
    case disconnected = "bolt.disconnected"
    case transportFailed = "bolt.transport.failed"
    case replyMalformed = "bolt.reply.malformed"
    case controlsUnsupported = "bolt.controls.unsupported"
    case externalStateChanged = "bolt.state.external-change"
    case reportStale = "bolt.report.stale"
    case eventsOverflowed = "bolt.events.overflow"
    case operationCancelled = "bolt.operation.cancelled"
    case requestIDsExhausted = "bolt.request-id.exhausted"
}

public enum BoltFailureStage: String, Equatable, Sendable {
    case connectPreflight = "connect-preflight"
    case connectRecoveryWrite = "connect-recovery-write"
    case connectRecoveryReadback = "connect-recovery-readback"
    case capabilities
    case verticalWheel = "vertical-wheel"
    case thumbWheel = "thumb-wheel"
    case buttonBaselineBack = "button-baseline-back"
    case buttonBaselineForward = "button-baseline-forward"
    case buttonWriteBack = "button-write-back"
    case buttonWriteForward = "button-write-forward"
    case buttonReadbackBack = "button-readback-back"
    case buttonReadbackForward = "button-readback-forward"
}

public struct BoltFailureContext: Equatable, Sendable {
    public let code: BoltFailureCode
    public let sourceFileID: String
    public let sourceLine: UInt
    public let stage: BoltFailureStage?

    public init(code: BoltFailureCode, sourceFileID: String, sourceLine: UInt, stage: BoltFailureStage? = nil) {
        self.code = code
        self.sourceFileID = sourceFileID
        self.sourceLine = sourceLine
        self.stage = stage
    }
}

public enum BoltEvent: Sendable {
    case status(BoltStatus)
    case press(MouseControl, generation: UInt64, observedAt: ContinuousClock.Instant)
    case scroll(vertical: Double, horizontal: Double, generation: UInt64, observedAt: ContinuousClock.Instant)
    case thumbwheel(rotation: Double, state: UInt8, generation: UInt64, observedAt: ContinuousClock.Instant)
}

enum BoltFailure: Error, LocalizedError, Equatable {
    case unavailable, ambiguous, timeout, disconnected, transport, malformed, unsupported
    case foreignState, stale, overflow, cancelled, tokenExhausted

    var diagnosticCode: BoltFailureCode {
        switch self {
        case .unavailable: .endpointUnavailable
        case .ambiguous: .endpointAmbiguous
        case .timeout: .requestTimeout
        case .disconnected: .disconnected
        case .transport: .transportFailed
        case .malformed: .replyMalformed
        case .unsupported: .controlsUnsupported
        case .foreignState: .externalStateChanged
        case .stale: .reportStale
        case .overflow: .eventsOverflowed
        case .cancelled: .operationCancelled
        case .tokenExhausted: .requestIDsExhausted
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable: "No eligible Bolt candidate responded."
        case .ambiguous: "Multiple Bolt endpoints or device slots require explicit association."
        case .timeout: "The Bolt request timed out."
        case .disconnected: "The Bolt candidate disconnected. Connect again deliberately."
        case .transport: "The Bolt transport failed."
        case .malformed: "The Bolt candidate returned malformed data."
        case .unsupported: "The candidate does not uniquely advertise eligible Back and Forward controls."
        case .foreignState: "The device state did not match the expected state."
        case .stale: "A stale Bolt report stopped the session."
        case .overflow: "The event consumer fell behind; bindings were stopped."
        case .cancelled: "The operation was stopped."
        case .tokenExhausted: "Too many device requests could not be verified. Reconnect after cleanup."
        }
    }
}

enum BoltTransportEvent: Sendable {
    case report([UInt8], at: ContinuousClock.Instant)
    case failure(BoltFailure)
}

protocol BoltTransport: Sendable {
    var events: AsyncStream<BoltTransportEvent> { get }
    func open() async throws
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int
    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8]
    func close() async
}

enum BoltWire {
    static let controls: [(MouseControl, UInt16, UInt16)] = [(.back, 0x0053, 0x003C), (.forward, 0x0056, 0x003E)]

    static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func cid(_ control: MouseControl) -> UInt16 { control == .back ? 0x0053 : 0x0056 }
    static func bytes(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

    static func reply(_ report: [UInt8], slot: UInt8, feature: UInt8, functionSoftware: UInt8) -> Result<[UInt8], BoltFailure>? {
        guard (report.count == 7 && report[0] == 0x10) || (report.count == 20 && report[0] == 0x11),
              report[1] == slot else { return nil }
        let isError = (report[0] == 0x10 && report[2] == 0x8F) || (report[0] == 0x11 && report[2] == 0xFF)
        if isError {
            guard report[3] == feature, report[4] == functionSoftware else { return nil }
            return .failure(feature == 0 && functionSoftware >> 4 == 1 ? .unavailable : .transport)
        }
        guard report[3] != 0, report[2] == feature, report[3] >> 4 == functionSoftware >> 4 else { return nil }
        guard report[3] == functionSoftware else { return nil }
        return .success(Array(report.dropFirst(4)))
    }

    static func eligible(_ rows: [[UInt8]]) throws -> Set<MouseControl> {
        guard rows.allSatisfy({ $0.count == 16 }) else { throw BoltFailure.malformed }
        var result = Set<MouseControl>()
        for (control, cid, task) in controls {
            let matching = rows.filter { word($0, 0) == cid }
            guard matching.count <= 1 else { throw BoltFailure.ambiguous }
            guard let row = matching.first else { continue }
            let flags = UInt16(row[4]) | UInt16(row[8]) << 8
            if word(row, 2) == task, flags & 0x20 != 0, flags & 0x80 == 0 { result.insert(control) }
        }
        return result
    }

    enum Reporting: Equatable { case baseline, diverted, foreign }

    static func reporting(_ bytes: [UInt8], cid: UInt16) throws -> Reporting {
        guard bytes.count == 16, word(bytes, 0) == cid else { throw BoltFailure.malformed }
        let remap = word(bytes, 3)
        guard remap == 0 || remap == cid else { return .foreign }
        let flags = UInt16(bytes[2]) | UInt16(bytes[5]) << 8
        return flags == 0 ? .baseline : flags == 1 ? .diverted : .foreign
    }

    struct WheelMovement: Equatable {
        let highResolution: Bool
        let period: UInt8
        let vertical: Int16
        let horizontal: Int16
    }

    static func wheelMovement(_ report: [UInt8], slot: UInt8, feature: UInt8) throws -> WheelMovement? {
        guard report.count >= 4, report[1] == slot, report[2] == feature, report[3] == 0 else { return nil }
        guard report[0] == 0x11, report.count == 20 else { throw BoltFailure.malformed }
        return WheelMovement(highResolution: report[4] & 0x10 != 0, period: report[4] & 0x0F,
                             vertical: Int16(bitPattern: word(report, 5)), horizontal: Int16(bitPattern: word(report, 7)))
    }

    struct ThumbwheelMovement: Equatable {
        let rotation: Int16
        let elapsed: UInt16
        let state: UInt8
        let flags: UInt8
    }

    static func thumbwheelMovement(_ report: [UInt8], slot: UInt8, feature: UInt8) throws -> ThumbwheelMovement? {
        guard report.count >= 4, report[1] == slot, report[2] == feature, report[3] == 0 else { return nil }
        guard report[0] == 0x11, report.count == 20, report[8] <= 3 else { throw BoltFailure.malformed }
        return ThumbwheelMovement(rotation: Int16(bitPattern: word(report, 4)), elapsed: word(report, 6), state: report[8], flags: report[9])
    }

    static func snapshot(_ report: [UInt8], slot: UInt8, feature: UInt8) throws -> Set<MouseControl>? {
        guard report.count >= 4, report[0] == 0x11, report[1] == slot,
              report[2] == feature, report[3] == 0 else { return nil }
        guard report.count == 20 else { throw BoltFailure.malformed }
        var seen = Set<UInt16>()
        var empty = false
        for index in 0..<4 {
            let cid = word(report, 4 + index * 2)
            if cid == 0 { empty = true; continue }
            guard !empty, seen.insert(cid).inserted else { throw BoltFailure.malformed }
        }
        return Set(controls.filter { seen.contains($0.1) }.map(\.0))
    }
}
