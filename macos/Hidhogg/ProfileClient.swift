import Foundation

public final class ProfileClient: @unchecked Sendable, RuntimeProfileChecking {
    public let socketPath: String
    public let instanceID: String
    public let phaseTimeoutNanoseconds: UInt64

    private let socketClient: UnixSocketClient

    public init(
        socketPath: String,
        instanceID: String,
        transport: any SocketTransport = DarwinSocketTransport(),
        phaseTimeoutNanoseconds: UInt64 = 1_000_000_000
    ) throws {
        let socketClient = try UnixSocketClient(
            socketPath: socketPath,
            instanceID: instanceID,
            transport: transport,
            phaseTimeoutNanoseconds: phaseTimeoutNanoseconds
        )
        self.socketPath = socketPath
        self.instanceID = instanceID
        self.phaseTimeoutNanoseconds = phaseTimeoutNanoseconds
        self.socketClient = socketClient
    }

    public func listProfiles(requestID: String = UUID().uuidString.lowercased()) throws -> ProfileListResponse {
        try socketClient.listProfiles(requestID: requestID)
    }

    public func activateProfile(
        profileID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ProfileActivationResponse {
        try socketClient.activateProfile(profileID: profileID, requestID: requestID)
    }
}
