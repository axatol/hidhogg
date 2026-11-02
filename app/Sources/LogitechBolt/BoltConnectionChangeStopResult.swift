public enum BoltConnectionChangeStopResult: Equatable, Sendable {
    case blocked
    case locallyStopped(generation: UInt64, remoteCleanup: BoltRemoteCleanupResult)
}
