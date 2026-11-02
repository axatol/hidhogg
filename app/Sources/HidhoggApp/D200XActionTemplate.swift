import HidhoggDomain

enum D200XActionTemplate: String, CaseIterable, Identifiable, Hashable {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case volumeMute
    case volumeSet
    case bell
    case playSound
    case openApplication
    case openFile
    case openURL
    case deckNotification
    case shortcut
    case lockScreen
    case customExecutable

    var id: Self { self }

    var defaultTilePresetAppearance: D200XTileAppearance {
        let label = title.replacingOccurrences(of: "…", with: "")
        return D200XTileAppearance(label: label, backgroundHex: "000000", showTitle: false)
    }

    var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .volumeMute: "Mute"
        case .volumeSet: "Set Volume"
        case .bell: "Bell"
        case .playSound: "Play Sound…"
        case .openApplication: "Open Application…"
        case .openFile: "Open File…"
        case .openURL: "Open URL"
        case .deckNotification: "Deck Notification"
        case .shortcut: "Keyboard Shortcut"
        case .lockScreen: "Lock Screen"
        case .customExecutable: "Custom Executable"
        }
    }

    var systemSymbol: String {
        switch self {
        case .playPause: "playpause.fill"
        case .nextTrack: "forward.end.fill"
        case .previousTrack: "backward.end.fill"
        case .volumeUp, .volumeSet: "speaker.wave.2.fill"
        case .volumeDown: "speaker.wave.1.fill"
        case .volumeMute: "speaker.slash.fill"
        case .bell: "bell.fill"
        case .playSound: "waveform"
        case .openApplication: "app.badge"
        case .openFile: "doc"
        case .openURL: "link"
        case .deckNotification: "bell.badge"
        case .shortcut: "keyboard"
        case .lockScreen: "lock.fill"
        case .customExecutable: "terminal"
        }
    }

    var requiresConfiguration: Bool {
        switch self {
        case .playSound, .openApplication, .openFile, .openURL, .deckNotification, .shortcut, .customExecutable:
            true
        case .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .volumeMute, .volumeSet, .bell, .lockScreen:
            false
        }
    }

    var defaultNativeAction: NativeAction? {
        switch self {
        case .playPause: .init(kind: .media, media: .playPause)
        case .nextTrack: .init(kind: .media, media: .nextTrack)
        case .previousTrack: .init(kind: .media, media: .previousTrack)
        case .volumeUp: .init(kind: .volume, volume: .up)
        case .volumeDown: .init(kind: .volume, volume: .down)
        case .volumeMute: .init(kind: .volume, volume: .mute)
        case .volumeSet: .init(kind: .volume, volume: .set, percent: 50)
        case .bell: .init(kind: .bell)
        case .playSound: .init(kind: .playSound)
        case .openApplication: .init(kind: .openApplication)
        case .openFile: .init(kind: .openFile)
        case .openURL: .init(kind: .openURL)
        case .deckNotification: .init(kind: .deckNotification)
        case .shortcut: .init(kind: .shortcut)
        case .lockScreen: .init(kind: .lockScreen)
        case .customExecutable: nil
        }
    }
}
