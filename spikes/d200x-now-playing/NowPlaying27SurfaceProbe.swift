import Foundation
import NowPlaying
import Observation

@MainActor
@Observable
final class SyntheticNowPlayingSession: MediaSessionRepresentable {
    let id = "synthetic-preview"
    var content: (any MediaContentRepresentable)? { nil }
    var playbackSnapshot: MediaPlaybackSnapshot? {
        MediaPlaybackSnapshot(state: .paused, elapsedTime: 91, timestamp: .now)
    }
    var commands: [MediaCommand] { [] }
}

@MainActor
func makeSyntheticNowPlayingSession() -> MediaSession<SyntheticNowPlayingSession> {
    MediaSession(SyntheticNowPlayingSession())
}
