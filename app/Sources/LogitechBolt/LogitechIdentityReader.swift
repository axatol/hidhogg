import Foundation

enum LogitechIdentityReader {
    static func read(on channel: any BoltTransport, endpoint: LogitechEndpointLocator,
                     slot: UInt8, nonce: UInt8, deadline: ContinuousClock.Instant,
                     allowCancelled: Bool = false) async throws -> LogitechIdentityProbe {
        try check(deadline: deadline, allowCancelled: allowCancelled)
        let rootProbe: [UInt8]
        do {
            rootProbe = try await channel.request(slot: slot, feature: 0, function: 1,
                                                  parameters: [0, 0, nonce])
        } catch let failure as BoltFailure where failure == .unavailable || failure == .timeout {
            throw BoltFailure.unavailable
        }
        try check(deadline: deadline, allowCancelled: allowCancelled)
        guard rootProbe.count >= 3, rootProbe[2] == nonce else { throw BoltFailure.stale }
        guard rootProbe[0] == 2 || rootProbe[0] == 4 else { throw BoltFailure.unsupportedModel }

        let featureRoot: [UInt8]
        do {
            featureRoot = try await channel.requestDeviceInformation(slot: slot, feature: 0, function: 0,
                                                                      parameters: BoltWire.bytes(0x0003))
        } catch {
            throw BoltFailure.identityUnavailable
        }
        try check(deadline: deadline, allowCancelled: allowCancelled)
        guard featureRoot.count >= 3, featureRoot[0] != 0, featureRoot[1] & 0xE0 == 0 else {
            throw BoltFailure.identityUnavailable
        }

        let featureIndex = featureRoot[0]
        let payload: [UInt8]
        do {
            payload = try await channel.requestDeviceInformation(slot: slot, feature: featureIndex,
                                                                 function: 0, parameters: [])
        } catch {
            throw BoltFailure.identityUnavailable
        }
        try check(deadline: deadline, allowCancelled: allowCancelled)
        return try LogitechIdentityProbe.decode(payload, connection: endpoint.connection,
                                                endpointProductID: endpoint.connection == .bluetooth
                                                    ? endpoint.productID : nil,
                                                featureIndex: featureIndex,
                                                featureVersion: featureRoot[2])
    }

    private static func check(deadline: ContinuousClock.Instant, allowCancelled: Bool) throws {
        guard allowCancelled || !Task.isCancelled, ContinuousClock.now < deadline else {
            throw BoltFailure.timeout
        }
    }
}
