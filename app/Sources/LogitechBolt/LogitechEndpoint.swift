import Foundation
import HidhoggDomain

public struct LogitechEndpointCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let connection: LogitechConnection
    public let model: LogitechMouseModel
    public let identity: LogitechIdentity
    public let information: BoltDeviceInformation

    public init(id: UUID, connection: LogitechConnection, model: LogitechMouseModel,
                identity: LogitechIdentity, information: BoltDeviceInformation = .init()) {
        self.id = id
        self.connection = connection
        self.model = model
        self.identity = identity
        self.information = information
    }
}

public struct LogitechConnectionTarget: Equatable, Sendable {
    public let model: LogitechMouseModel
    public let association: LogitechAssociation
    public let candidateID: UUID?

    public init(model: LogitechMouseModel, association: LogitechAssociation, candidateID: UUID? = nil) {
        self.model = model
        self.association = association
        self.candidateID = candidateID
    }
}

struct LogitechIdentityProbe: Equatable, Sendable {
    enum TransportField: UInt8, CaseIterable, Hashable, Sendable {
        case bluetooth = 0x01
        case bluetoothLowEnergy = 0x02
        case wirelessProduct = 0x04
        case usbProduct = 0x08
    }

    let identity: LogitechIdentity
    let model: LogitechMouseModel
    let transportIDs: [TransportField: String]
    let featureIndex: UInt8
    let featureVersion: UInt8

    static func decode(_ payload: [UInt8], connection: LogitechConnection,
                       endpointProductID: Int?, featureIndex: UInt8, featureVersion: UInt8) throws -> Self {
        guard payload.count >= 13 else { throw BoltFailure.identityUnavailable }

        let unitID = hex(payload[1...4])
        let transportMask = payload[6]
        let modelIDBytes = Array(payload[7...12])
        let modelID = hex(modelIDBytes)
        let identity: LogitechIdentity
        do {
            identity = try LogitechIdentity(unitID: unitID, modelID: modelID).validated()
        } catch {
            throw BoltFailure.identityUnavailable
        }

        let transportIDs = try parseTransportIDs(mask: transportMask, modelIDBytes: modelIDBytes)
        let knownIDs = Set(transportIDs.values.filter { $0 == "b034" || $0 == "b042" })
        guard knownIDs.count == 1, let knownID = knownIDs.first else { throw BoltFailure.unsupportedModel }
        let model: LogitechMouseModel
        switch knownID {
        case "b034": model = .mxMaster3S
        case "b042": model = .mxMaster4
        default: throw BoltFailure.unsupportedModel
        }

        if connection == .bluetooth {
            guard let endpointProductID,
                  endpointProductID == 0xB034 || endpointProductID == 0xB042,
                  hex([UInt8(endpointProductID >> 8), UInt8(endpointProductID & 0xFF)]) == knownID else {
                throw BoltFailure.identityMismatch
            }
            if let bluetoothLowEnergyID = transportIDs[.bluetoothLowEnergy], bluetoothLowEnergyID != knownID {
                throw BoltFailure.identityMismatch
            }
        }

        return Self(identity: identity, model: model, transportIDs: transportIDs,
                    featureIndex: featureIndex, featureVersion: featureVersion)
    }

    private static func parseTransportIDs(mask: UInt8, modelIDBytes: [UInt8]) throws -> [TransportField: String] {
        guard mask != 0, mask & ~UInt8(0x0F) == 0,
              mask.nonzeroBitCount <= modelIDBytes.count / 2 else { throw BoltFailure.identityUnavailable }

        var offset = 0
        var result: [TransportField: String] = [:]
        for field in TransportField.allCases where mask & field.rawValue != 0 {
            let identifier = hex(modelIDBytes[offset..<(offset + 2)])
            result[field] = identifier
            offset += 2
        }
        guard !result.isEmpty else { throw BoltFailure.identityUnavailable }
        return result
    }

    private static func hex<S: Collection>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

final class LogitechCandidateSnapshotRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [UUID: LogitechEndpointCandidate] = [:]

    func invalidate() {
        lock.withLock {
            candidates.removeAll()
        }
    }

    func replace(with candidates: [LogitechEndpointCandidate]) {
        lock.withLock {
            self.candidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        }
    }

    func validate(_ candidateID: UUID, target: LogitechConnectionTarget) throws {
        try lock.withLock {
            guard let candidate = candidates[candidateID] else { throw BoltFailure.candidateStale }
            guard candidate.model == target.model,
                  candidate.identity == target.association.identity,
                  candidate.connection == target.association.preferredConnection else {
                throw BoltFailure.identityMismatch
            }
        }
    }
}
