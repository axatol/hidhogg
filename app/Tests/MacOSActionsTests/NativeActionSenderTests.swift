import AppKit
import HidhoggDomain
import Testing
@testable import MacOSActions

@MainActor
struct NativeActionSenderTests {
    @Test func mediaAndVolumeKeyActionsRequirePermissionAndPostMappedPairs() throws {
        var permissionChecks = 0
        var posted = [SystemMediaKey]()
        let sender = NativeActionSender(
            shortcuts: shortcutSender(),
            permissionCheck: { permissionChecks += 1; return true },
            postMediaPair: { posted.append($0) },
            setVolume: { _ in },
            openTarget: { _ in true },
            playSound: { _ in },
            bell: {},
            stopSound: {}
        )
        let mediaActions: [(NativeAction, SystemMediaKey)] = [
            (.init(kind: .media, media: .playPause), .playPause),
            (.init(kind: .media, media: .nextTrack), .nextTrack),
            (.init(kind: .media, media: .previousTrack), .previousTrack),
            (.init(kind: .volume, volume: .up), .volumeUp),
            (.init(kind: .volume, volume: .down), .volumeDown),
            (.init(kind: .volume, volume: .mute), .mute)
        ]

        for (action, key) in mediaActions {
            try sender.perform(action)
            #expect(posted.last == key)
        }

        #expect(permissionChecks == mediaActions.count)
        #expect(posted == mediaActions.map(\.1))
    }

    @Test func deniedMediaPermissionStopsBeforePostingPair() {
        var permissionChecks = 0
        var posted = [SystemMediaKey]()
        let sender = NativeActionSender(
            shortcuts: shortcutSender(),
            permissionCheck: { permissionChecks += 1; return false },
            postMediaPair: { posted.append($0) },
            setVolume: { _ in },
            openTarget: { _ in true },
            playSound: { _ in },
            bell: {},
            stopSound: {}
        )

        #expect(throws: NativeActionFailure.self) {
            try sender.perform(.init(kind: .media, media: .playPause))
        }
        #expect(permissionChecks == 1)
        #expect(posted.isEmpty)
    }

    @Test func lockScreenUsesFixedControlCommandQShortcut() throws {
        let shortcutRecorder = RecordingShortcutSender()
        var mediaPermissionChecks = 0
        let sender = NativeActionSender(
            shortcuts: shortcutRecorder.make(),
            permissionCheck: { mediaPermissionChecks += 1; return false },
            postMediaPair: { _ in Issue.record("Lock Screen must use the permission-checked shortcut sender.") },
            setVolume: { _ in },
            openTarget: { _ in true },
            playSound: { _ in },
            bell: {},
            stopSound: {}
        )

        try sender.perform(.init(kind: .lockScreen))

        #expect(shortcutRecorder.posted == [KeyboardShortcut(keyCode: 12, modifiers: [.control, .command])])
        #expect(mediaPermissionChecks == 0)
    }

    @Test func deniedOrCancelledLockScreenDoesNotPostShortcut() async {
        var posted = [KeyboardShortcut]()
        let shortcuts = ShortcutSender(
            preflight: { false },
            request: { Issue.record("Lock Screen must not request permission automatically."); return false },
            postPair: { posted.append($0) }
        )
        let sender = NativeActionSender(
            shortcuts: shortcuts,
            permissionCheck: { false },
            postMediaPair: { _ in Issue.record("Lock Screen must not post media keys.") },
            setVolume: { _ in },
            openTarget: { _ in true },
            playSound: { _ in },
            bell: {},
            stopSound: {}
        )
        let action = NativeAction(kind: .lockScreen)

        #expect(throws: ShortcutDeliveryError.self) { try sender.perform(action) }
        #expect(posted.isEmpty)

        let cancelledTask = Task { @MainActor in
            withUnsafeCurrentTask { task in task?.cancel() }
            try sender.perform(action)
        }
        await #expect(throws: CancellationError.self) { try await cancelledTask.value }
        #expect(posted.isEmpty)
    }

    @Test func fileApplicationURLSoundBellAndSetVolumeUseOnlyInjectedClosures() throws {
        var opened = [URL]()
        var played = [URL]()
        var setPercents = [Int]()
        var bellCount = 0
        var mediaPermissionChecks = 0
        let shortcutRecorder = RecordingShortcutSender()
        let sender = NativeActionSender(
            shortcuts: shortcutRecorder.make(),
            permissionCheck: { mediaPermissionChecks += 1; return false },
            postMediaPair: { _ in Issue.record("Non-media actions must not post media keys.") },
            setVolume: { setPercents.append($0) },
            openTarget: { opened.append($0); return true },
            playSound: { played.append($0) },
            bell: { bellCount += 1 },
            stopSound: {}
        )

        let file = NativeAction(kind: .openFile, target: "/synthetic/document.txt")
        let application = NativeAction(kind: .openApplication, target: "/Applications/Synthetic.app")
        let url = NativeAction(kind: .openURL, target: "https://example.test/path")
        let sound = NativeAction(kind: .playSound, target: "/synthetic/chime.aiff")
        let volume = NativeAction(kind: .volume, volume: .set, percent: 37)
        let bell = NativeAction(kind: .bell)
        let shortcut = NativeAction(kind: .shortcut, shortcut: KeyboardShortcut(keyCode: 4, modifiers: [.command]))

        try sender.perform(file)
        try sender.perform(application)
        try sender.perform(url)
        try sender.perform(sound)
        try sender.perform(volume)
        try sender.perform(bell)
        try sender.perform(shortcut)

        #expect(opened == [URL(fileURLWithPath: "/synthetic/document.txt"),
            URL(fileURLWithPath: "/Applications/Synthetic.app"), URL(string: "https://example.test/path")!])
        #expect(played == [URL(fileURLWithPath: "/synthetic/chime.aiff")])
        #expect(setPercents == [37])
        #expect(bellCount == 1)
        #expect(mediaPermissionChecks == 0)
        #expect(shortcutRecorder.posted == [KeyboardShortcut(keyCode: 4, modifiers: [.command])])
    }

    @Test func invalidNativeParametersAreRejectedBeforeAnyEffectClosure() {
        var effectCount = 0
        let sender = NativeActionSender(
            shortcuts: shortcutSender(),
            permissionCheck: { effectCount += 1; return true },
            postMediaPair: { _ in effectCount += 1 },
            setVolume: { _ in effectCount += 1 },
            openTarget: { _ in effectCount += 1; return true },
            playSound: { _ in effectCount += 1 },
            bell: { effectCount += 1 },
            stopSound: { effectCount += 1 }
        )
        let invalidActions = [
            NativeAction(kind: .media),
            NativeAction(kind: .volume, volume: .set),
            NativeAction(kind: .openURL, target: "file:///synthetic/document"),
            NativeAction(kind: .deckNotification, topic: "build.*", text: "Never sent")
        ]

        for action in invalidActions {
            #expect(throws: (any Error).self) { try sender.perform(action) }
        }

        #expect(effectCount == 0)
    }

    @Test func systemMediaKeyDataIsPairedAndOutputBalancePreservesChannelRatios() throws {
        let expectedPairs: [(SystemMediaKey, [Int])] = [
            (.volumeUp, [0xA00, 0xB00]),
            (.volumeDown, [(1 << 16) | 0xA00, (1 << 16) | 0xB00]),
            (.mute, [(7 << 16) | 0xA00, (7 << 16) | 0xB00]),
            (.playPause, [(16 << 16) | 0xA00, (16 << 16) | 0xB00]),
            (.nextTrack, [(17 << 16) | 0xA00, (17 << 16) | 0xB00]),
            (.previousTrack, [(18 << 16) | 0xA00, (18 << 16) | 0xB00])
        ]
        for (key, data) in expectedPairs {
            #expect(key.pairedData == data)
        }

        #expect(try SystemOutputVolume.balancedValues([0.4, 0.2], percent: 50) == [0.5, 0.25])
        #expect(try SystemOutputVolume.balancedValues([0, 0], percent: 100) == [1, 1])
        #expect(try SystemOutputVolume.balancedValues([0.4, 0.2], percent: 0) == [0, 0])
        #expect(throws: NativeActionFailure.self) { try SystemOutputVolume.balancedValues([], percent: 50) }
        #expect(throws: NativeActionFailure.self) { try SystemOutputVolume.balancedValues([.nan], percent: 50) }
        #expect(throws: NativeActionFailure.self) { try SystemOutputVolume.balancedValues([1.1], percent: 50) }
        #expect(throws: NativeActionFailure.self) { try SystemOutputVolume.balancedValues([0.5], percent: 101) }
    }

    private func shortcutSender() -> ShortcutSender {
        ShortcutSender(preflight: { true }, request: { Issue.record("Shortcut permission must not be requested."); return false },
            postPair: { _ in })
    }
}

@MainActor
private final class RecordingShortcutSender {
    private(set) var posted = [KeyboardShortcut]()

    func make() -> ShortcutSender {
        ShortcutSender(preflight: { true }, request: { Issue.record("Shortcut delivery must not request permission."); return false },
            postPair: { [weak self] in self?.posted.append($0) })
    }
}
