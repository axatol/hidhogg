import CoreAudio
import MediaPlayer

struct PublishedPlayerSnapshot {
    let information: [String: Any]?
    let playbackState: MPNowPlayingPlaybackState
}

func ownApplicationNowPlayingSnapshot() -> PublishedPlayerSnapshot {
    let center = MPNowPlayingInfoCenter.default()
    return PublishedPlayerSnapshot(information: center.nowPlayingInfo, playbackState: center.playbackState)
}

func hasOutputMuteProperty(device: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectHasProperty(device, &address)
}
