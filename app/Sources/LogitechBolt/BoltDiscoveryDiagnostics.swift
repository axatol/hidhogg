import Foundation

public struct BoltDiscoveryDiagnostics: Equatable, Sendable {
    public private(set) var advertisementEvents: Int
    public private(set) var decodedAdvertisements: Int
    public private(set) var rejectedAdvertisements: Int
    public private(set) var unsupportedModelAdvertisements: Int
    public private(set) var discoveryStatusEvents: Int
    public private(set) var recoveryEvents: Int
    public private(set) var transportFailures: Int

    public init(advertisementEvents: Int = 0,
                decodedAdvertisements: Int = 0,
                rejectedAdvertisements: Int = 0,
                unsupportedModelAdvertisements: Int = 0,
                discoveryStatusEvents: Int = 0,
                recoveryEvents: Int = 0,
                transportFailures: Int = 0) {
        self.advertisementEvents = max(0, advertisementEvents)
        self.decodedAdvertisements = max(0, decodedAdvertisements)
        self.rejectedAdvertisements = max(0, rejectedAdvertisements)
        self.unsupportedModelAdvertisements = max(0, unsupportedModelAdvertisements)
        self.discoveryStatusEvents = max(0, discoveryStatusEvents)
        self.recoveryEvents = max(0, recoveryEvents)
        self.transportFailures = max(0, transportFailures)
    }

    mutating func recordAdvertisementEvent() {
        Self.increment(&advertisementEvents)
    }

    mutating func recordDecodedAdvertisement() {
        Self.increment(&decodedAdvertisements)
    }

    mutating func recordRejectedAdvertisement() {
        Self.increment(&rejectedAdvertisements)
    }

    mutating func recordUnsupportedModelAdvertisement() {
        Self.increment(&unsupportedModelAdvertisements)
    }

    mutating func recordDiscoveryStatusEvent() {
        Self.increment(&discoveryStatusEvents)
    }

    mutating func recordRecoveryEvent() {
        Self.increment(&recoveryEvents)
    }

    mutating func recordTransportFailure() {
        Self.increment(&transportFailures)
    }

    private static func increment(_ counter: inout Int) {
        guard counter < Int.max else { return }
        counter += 1
    }
}
