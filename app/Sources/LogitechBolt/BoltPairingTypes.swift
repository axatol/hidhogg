import Foundation
import HidhoggDomain

public enum BoltPairingPhase: String, Equatable, Sendable {
    case idle
    case discovering
    case awaitingSelection
    case authenticating
    case verifying
    case verified
    case pairedButNotAdded
    case cancelled
    case failed
}

public struct BoltReceiverCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String

    public init(id: UUID, label: String) {
        self.id = id
        self.label = label
    }
}

public struct BoltPairingCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let model: LogitechMouseModel?

    public init(id: UUID, name: String?, model: LogitechMouseModel?) {
        self.id = id
        self.name = name
        self.model = model
    }
}

public enum BoltPairingClickDirection: String, Equatable, Sendable {
    case left
    case right
    case both
}

public struct BoltPairingChallenge: Equatable, Sendable {
    public let directions: [BoltPairingClickDirection]
    public let confirmationDirection: BoltPairingClickDirection
    public let completedClicks: Int
    public let requiredClicks: Int
    public let entryComplete: Bool

    public init(directions: [BoltPairingClickDirection],
                confirmationDirection: BoltPairingClickDirection = .both,
                completedClicks: Int, requiredClicks: Int, entryComplete: Bool = false) {
        self.directions = directions
        self.confirmationDirection = confirmationDirection
        self.completedClicks = completedClicks
        self.requiredClicks = requiredClicks
        self.entryComplete = entryComplete
    }
}

public struct BoltPairingStatus: Equatable, Sendable {
    public let phase: BoltPairingPhase
    public let message: String
    public let candidates: [BoltPairingCandidate]
    public let challenge: BoltPairingChallenge?
    public let verifiedCandidate: LogitechEndpointCandidate?
    public let pairingMayHaveSucceeded: Bool
    public let discoveryDiagnostics: BoltDiscoveryDiagnostics
    public let nativeInputDiagnostics: BoltNativeInputDiagnostics
    public let notificationSetupMessage: String?
    public let notificationCleanupMessage: String?
    public let notificationCleanupRequiresAttention: Bool

    public init(phase: BoltPairingPhase, message: String,
                candidates: [BoltPairingCandidate] = [],
                challenge: BoltPairingChallenge? = nil,
                verifiedCandidate: LogitechEndpointCandidate? = nil,
                pairingMayHaveSucceeded: Bool = false,
                discoveryDiagnostics: BoltDiscoveryDiagnostics = .init(),
                nativeInputDiagnostics: BoltNativeInputDiagnostics = .init(),
                notificationSetupMessage: String? = nil,
                notificationCleanupMessage: String? = nil,
                notificationCleanupRequiresAttention: Bool = false) {
        self.phase = phase
        self.message = message
        self.candidates = candidates
        self.challenge = challenge
        self.verifiedCandidate = verifiedCandidate
        self.pairingMayHaveSucceeded = pairingMayHaveSucceeded
        self.discoveryDiagnostics = discoveryDiagnostics
        self.nativeInputDiagnostics = nativeInputDiagnostics
        self.notificationSetupMessage = notificationSetupMessage
        self.notificationCleanupMessage = notificationCleanupMessage
        self.notificationCleanupRequiresAttention = notificationCleanupRequiresAttention
    }
}

public protocol BoltPairingManaging: Sendable {
    var events: AsyncStream<BoltPairingStatus> { get }
    func currentStatus() async -> BoltPairingStatus
    func receivers() async throws -> [BoltReceiverCandidate]
    func start(receiverID: UUID) async
    func select(candidateID: UUID) async
    func cancel() async
    func close() async
}
