import Foundation
import HidhoggDomain

public enum BoltPhase: String, Sendable {
    case idle, discovering, ready, enabling, enabled, stopping, failed
}

public struct BoltStatus: Equatable, Sendable {
    public let phase: BoltPhase
    public let message: String
    public let availableControls: Set<MouseControl>
    public let generation: UInt64
    public let cleanupUncertain: Bool

    public init(phase: BoltPhase, message: String, availableControls: Set<MouseControl>, generation: UInt64, cleanupUncertain: Bool) {
        self.phase = phase
        self.message = message
        self.availableControls = availableControls
        self.generation = generation
        self.cleanupUncertain = cleanupUncertain
    }
}

public enum BoltEvent: Sendable {
    case status(BoltStatus)
    case press(MouseControl, generation: UInt64, observedAt: ContinuousClock.Instant)
}

enum BoltFailure: Error, LocalizedError, Equatable {
    case unavailable, ambiguous, timeout, disconnected, transport, malformed, unsupported
    case foreignState, stale, overflow, cancelled, tokenExhausted

    var errorDescription: String? {
        switch self {
        case .unavailable: "No eligible Bolt candidate responded."
        case .ambiguous: "Multiple Bolt endpoints or device slots require explicit association."
        case .timeout: "The Bolt request timed out."
        case .disconnected: "The Bolt candidate disconnected. Connect again deliberately."
        case .transport: "The Bolt transport failed."
        case .malformed: "The Bolt candidate returned malformed data."
        case .unsupported: "The candidate does not uniquely advertise eligible Back and Forward controls."
        case .foreignState: "Button reporting or remapping changed outside this session."
        case .stale: "A stale Bolt report stopped the session."
        case .overflow: "The event consumer fell behind; bindings were stopped."
        case .cancelled: "The operation was stopped."
        case .tokenExhausted: "The bounded request token budget was exhausted. Connect again."
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
        guard report[3] == functionSoftware else { return .failure(.stale) }
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
