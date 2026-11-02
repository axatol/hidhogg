import Foundation

protocol BoltReceiverTransport: BoltTransport {
    var receiverEvents: AsyncStream<BoltReceiverEvent> { get }
    func registerRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverRegisterReply
    func cancelRequest(_ request: BoltReceiverRegisterRequest) async throws -> BoltReceiverCancellationResult
    func inputDiagnostics() async -> BoltNativeInputDiagnostics
}

extension BoltReceiverTransport {
    func inputDiagnostics() async -> BoltNativeInputDiagnostics { .init() }
}

enum BoltReceiverRegisterOperation: UInt8, Equatable, Sendable {
    case write = 0x80
    case read = 0x81
}

struct BoltReceiverRegisterRequest: Equatable, Sendable {
    let operation: BoltReceiverRegisterOperation
    let register: UInt16
    let payload: [UInt8]

    init(operation: BoltReceiverRegisterOperation, register: UInt16, payload: [UInt8]) throws {
        let bank = register >> 8
        guard (bank == 0 || bank == 2), payload.count <= 16 else {
            throw BoltReceiverTransportFailure.malformed
        }
        if operation == .read, register == 0x02B5, payload.isEmpty {
            throw BoltReceiverTransportFailure.malformed
        }
        self.operation = operation
        self.register = register
        self.payload = payload
    }

    var requestIdentifier: [UInt8] {
        [operation.rawValue | UInt8(register >> 8), UInt8(register & 0xFF)]
    }

    func frame() -> [UInt8] {
        let requiresLongReport = operation == .write && register == 0x02C1
        let reportID: UInt8 = payload.count <= 3 && !requiresLongReport ? 0x10 : 0x11
        let byteCount = reportID == 0x10 ? 7 : 20
        let prefix: [UInt8] = [reportID, 0xFF] + requestIdentifier + payload
        return prefix + Array(repeating: UInt8(0), count: byteCount - prefix.count)
    }
}

struct BoltReceiverRegisterReply: Equatable, Sendable {
    let register: UInt16
    let payload: [UInt8]
}

enum BoltReceiverCancellationResult: Equatable, Sendable {
    case acknowledged(BoltReceiverRegisterReply)
    case dispatchedUnconfirmed
}

struct BoltReceiverCancellationLedger: Sendable {
    private var attemptedRegisters: Set<UInt16> = []

    mutating func claim(_ request: BoltReceiverRegisterRequest) -> Bool {
        guard BoltReceiverProtocol.isCancellation(request) else { return false }
        return attemptedRegisters.insert(request.register).inserted
    }
}

struct BoltReceiverRegisterError: Error, LocalizedError, Equatable, Sendable {
    let register: UInt16
    let code: UInt8

    var errorDescription: String? { "The Bolt receiver rejected a register request." }
}

enum BoltReceiverRegisterResponse: Equatable, Sendable {
    case reply(BoltReceiverRegisterReply)
    case error(BoltReceiverRegisterError)
}

enum BoltReceiverResponseMatch: Equatable, Sendable {
    case unrelated
    case matched(BoltReceiverRegisterResponse)
    case malformed
}

// These validated frames can contain device addresses and pairing challenges; keep them out of diagnostics.
enum BoltReceiverNotification: Equatable, Sendable {
    case discoveryAdvertisement(payload: [UInt8])
    case recoveryAdvertisement(payload: [UInt8])
    case discoveryStatus(state: UInt8, error: UInt8, payload: [UInt8])
    case pairingStatus(state: UInt8, error: UInt8, payload: [UInt8])
    case passkeyDisplayed(payload: [UInt8])
    case passkeyEntry(code: UInt8, payload: [UInt8])
}

enum BoltReceiverEvent: Equatable, Sendable {
    case notification(BoltReceiverNotification, at: ContinuousClock.Instant)
    case failure(BoltReceiverTransportFailure)
}

enum BoltReceiverTransportFailure: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case ambiguous
    case busy
    case malformed
    case timeout
    case disconnected
    case transport
    case registerRejected(code: UInt8)
    case cancellationAlreadyAttempted
    case eventOverflow

    var errorDescription: String? {
        switch self {
        case .unavailable: "The selected Bolt receiver is unavailable."
        case .ambiguous: "More than one Bolt receiver is available."
        case .busy: "The Bolt receiver already has an active request."
        case .malformed: "The Bolt receiver returned an invalid pairing message."
        case .timeout: "The Bolt receiver did not complete the request in time."
        case .disconnected: "The Bolt receiver disconnected."
        case .transport: "Communication with the Bolt receiver failed."
        case .registerRejected: "The Bolt receiver rejected a register request."
        case .cancellationAlreadyAttempted: "The Bolt receiver cancellation was already attempted."
        case .eventOverflow: "The Bolt receiver event stream overflowed."
        }
    }
}

enum BoltReceiverProtocol {
    static let receiverAddress: UInt8 = 0xFF
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let pairingNotificationIDs: Set<UInt8> = [0x4D, 0x4E, 0x4F, 0x52, 0x53, 0x54]

    static func isCancellation(_ request: BoltReceiverRegisterRequest) -> Bool {
        guard request.operation == .write else { return false }
        switch request.register {
        case 0x00C0:
            return request.payload.count >= 2 && request.payload[1] == 2
        case 0x02C1:
            return request.payload.first == 2
        default:
            return false
        }
    }

    static func response(_ report: [UInt8], for request: BoltReceiverRegisterRequest) -> BoltReceiverRegisterResponse? {
        guard case .matched(let response) = responseMatch(report, for: request) else { return nil }
        return response
    }

    static func responseMatch(_ report: [UInt8], for request: BoltReceiverRegisterRequest) -> BoltReceiverResponseMatch {
        guard report.count >= 4, report[1] == receiverAddress else { return .unrelated }
        let identifier = request.requestIdentifier
        if report[2] == 0x8F {
            guard report.count >= 5, report[3] == identifier[0], report[4] == identifier[1] else { return .unrelated }
            guard report.count == 7, report[0] == shortReportID else { return .malformed }
            return .matched(.error(BoltReceiverRegisterError(register: request.register, code: report[5])))
        }

        guard report[2] == identifier[0], report[3] == identifier[1] else { return .unrelated }
        guard isValidFrame(report) else { return .malformed }
        if request.operation == .read, request.register == 0x02B5 {
            guard let requestedSelector = request.payload.first, report[4] == requestedSelector else { return .unrelated }
        }
        return .matched(.reply(BoltReceiverRegisterReply(register: request.register, payload: Array(report.dropFirst(4)))))
    }

    static func response(_ report: [UInt8], for request: BoltReceiverRegisterRequest,
                         now: TimeInterval, deadline: TimeInterval) -> BoltReceiverRegisterResponse? {
        guard now <= deadline else { return nil }
        return response(report, for: request)
    }

    static func notification(_ report: [UInt8]) throws -> BoltReceiverNotification? {
        guard report.count >= 3, report[1] == receiverAddress,
              pairingNotificationIDs.contains(report[2]) else { return nil }
        guard isValidFrame(report) else { throw BoltReceiverTransportFailure.malformed }

        switch report[2] {
        case 0x4D:
            guard report.count >= 14 else { throw BoltReceiverTransportFailure.malformed }
            return .passkeyDisplayed(payload: report)
        case 0x4E:
            guard report.count >= 20 else { throw BoltReceiverTransportFailure.malformed }
            return .passkeyEntry(code: report[3], payload: report)
        case 0x4F:
            return .discoveryAdvertisement(payload: report)
        case 0x52:
            return .recoveryAdvertisement(payload: report)
        case 0x53:
            return .discoveryStatus(state: report[3], error: report[4], payload: report)
        case 0x54:
            return .pairingStatus(state: report[3], error: report[4], payload: report)
        default:
            return nil
        }
    }

    static func isValidFrame(_ report: [UInt8]) -> Bool {
        (report.count == 7 && report[0] == shortReportID)
            || (report.count == 20 && report[0] == longReportID)
    }
}
