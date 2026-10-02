import Foundation

public final class ConfigEditorClient: @unchecked Sendable, RuntimeConfigEditorChecking {
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

    public func configEditorSnapshot(
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ConfigEditorSnapshotResponse {
        try socketClient.configEditorSnapshot(requestID: requestID)
    }

    public func configEditorProfile(
        profileID: String,
        sourceDigest: String,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ConfigEditorProfileResponse {
        try socketClient.configEditorProfile(
            profileID: profileID,
            sourceDigest: sourceDigest,
            requestID: requestID
        )
    }

    public func configEditorPositions(
        profileID: String,
        sourceDigest: String,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ConfigEditorPositionsResponse {
        try socketClient.configEditorPositions(
            profileID: profileID,
            sourceDigest: sourceDigest,
            requestID: requestID
        )
    }

    public func configEditorPosition(
        profileID: String,
        positionID: String,
        sourceDigest: String,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ConfigEditorPositionResponse {
        try socketClient.configEditorPosition(
            profileID: profileID,
            positionID: positionID,
            sourceDigest: sourceDigest,
            requestID: requestID
        )
    }

    public func setConfigEditorProfileLabel(
        profileID: String,
        label: String,
        expectedDigest: String,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ConfigEditorMutationResponse {
        try socketClient.setConfigEditorProfileLabel(
            profileID: profileID,
            label: label,
            expectedDigest: expectedDigest,
            requestID: requestID
        )
    }

    public func createConfigEditorProfile(
        profileID: String,
        label: String,
        expectedDigest: String,
        sourceProfileID: String? = nil,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ConfigEditorMutationResponse {
        try socketClient.createConfigEditorProfile(
            profileID: profileID,
            label: label,
            expectedDigest: expectedDigest,
            sourceProfileID: sourceProfileID,
            requestID: requestID
        )
    }

    public func deleteConfigEditorProfile(
        profileID: String,
        expectedDigest: String,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ConfigEditorMutationResponse {
        try socketClient.deleteConfigEditorProfile(
            profileID: profileID,
            expectedDigest: expectedDigest,
            requestID: requestID
        )
    }

    public func setConfigEditorPositionLabel(
        profileID: String,
        positionID: String,
        label: String,
        expectedDigest: String,
        requestID: String = UUID().uuidString.lowercased()
    ) throws -> ConfigEditorMutationResponse {
        try socketClient.setConfigEditorPositionLabel(
            profileID: profileID,
            positionID: positionID,
            label: label,
            expectedDigest: expectedDigest,
            requestID: requestID
        )
    }
}
