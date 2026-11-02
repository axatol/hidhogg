public enum BoltRemoteCleanupResult: Equatable, Sendable {
    case verified
    case unverified(target: LogitechConnectionTarget?)
}
