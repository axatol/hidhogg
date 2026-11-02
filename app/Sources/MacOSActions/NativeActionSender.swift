import AppKit
import CoreGraphics
import HidhoggDomain

@MainActor
public final class NativeActionSender: NativeActionPerforming {
    private let shortcuts: ShortcutSender
    private let permissionCheck: () -> Bool
    private let postMediaPair: (SystemMediaKey) throws -> Void
    private let setVolume: (Int) throws -> Void
    private let openTarget: (URL) -> Bool
    private let playSound: (URL) throws -> Void
    private let bell: () -> Void
    private let stopSound: () -> Void
    private static let lockScreenShortcut = KeyboardShortcut(keyCode: 12, modifiers: [.control, .command])

    public convenience init(shortcuts: ShortcutSender = ShortcutSender()) {
        let player = OwnedNativeSoundPlayer()
        self.init(shortcuts: shortcuts, permissionCheck: { CGPreflightPostEventAccess() },
            postMediaPair: Self.postNativeMediaPair, setVolume: SystemOutputVolume.set,
            openTarget: { NSWorkspace.shared.open($0) }, playSound: { try player.play($0) },
            bell: { NSSound.beep() }, stopSound: { player.stop() })
    }

    public init(shortcuts: ShortcutSender, permissionCheck: @escaping () -> Bool,
                postMediaPair: @escaping (SystemMediaKey) throws -> Void,
                setVolume: @escaping (Int) throws -> Void, openTarget: @escaping (URL) -> Bool,
                playSound: @escaping (URL) throws -> Void, bell: @escaping () -> Void,
                stopSound: @escaping () -> Void) {
        self.shortcuts = shortcuts
        self.permissionCheck = permissionCheck
        self.postMediaPair = postMediaPair
        self.setVolume = setVolume
        self.openTarget = openTarget
        self.playSound = playSound
        self.bell = bell
        self.stopSound = stopSound
    }

    public func perform(_ action: NativeAction) throws {
        _ = try action.validated()
        try Task.checkCancellation()
        switch action.kind {
        case .media:
            let key: SystemMediaKey = switch action.media! {
            case .playPause: .playPause
            case .nextTrack: .nextTrack
            case .previousTrack: .previousTrack
            }
            try sendMedia(key)
        case .volume:
            switch action.volume! {
            case .up: try sendMedia(.volumeUp)
            case .down: try sendMedia(.volumeDown)
            case .mute: try sendMedia(.mute)
            case .set: try setVolume(action.percent!)
            }
        case .bell: bell()
        case .playSound: try playSound(URL(fileURLWithPath: action.target!))
        case .openApplication, .openFile:
            guard openTarget(URL(fileURLWithPath: action.target!)) else { throw NativeActionFailure.targetUnavailable }
        case .openURL:
            guard let url = URL(string: action.target!), openTarget(url) else { throw NativeActionFailure.targetUnavailable }
        case .shortcut: try shortcuts.send(action.shortcut!)
        case .lockScreen: try shortcuts.send(Self.lockScreenShortcut)
        case .deckNotification: throw NativeActionFailure.unsupported
        }
    }

    public func stop() { stopSound() }

    private func sendMedia(_ key: SystemMediaKey) throws {
        guard permissionCheck() else { throw NativeActionFailure.inputPermission }
        try postMediaPair(key)
    }

    private static func postNativeMediaPair(_ key: SystemMediaKey) throws {
        let events = key.pairedData.compactMap { data in
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: data, data2: -1)?.cgEvent
        }
        guard events.count == 2 else { throw NativeActionFailure.eventUnavailable }
        for event in events { event.post(tap: .cghidEventTap) }
    }
}
