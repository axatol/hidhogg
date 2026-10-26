public enum SystemMediaKey: Int, CaseIterable, Sendable {
    case volumeUp = 0, volumeDown = 1, mute = 7, playPause = 16, nextTrack = 17, previousTrack = 18

    public var pairedData: [Int] {
        [(rawValue << 16) | 0xA00, (rawValue << 16) | 0xB00]
    }
}
