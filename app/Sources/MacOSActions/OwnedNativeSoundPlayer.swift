import AppKit

@MainActor
final class OwnedNativeSoundPlayer {
    private var sound: NSSound?

    func play(_ url: URL) throws {
        guard let candidate = NSSound(contentsOf: url, byReference: true) else { throw NativeActionFailure.soundUnavailable }
        sound?.stop()
        sound = candidate
        guard candidate.play() else { sound = nil; throw NativeActionFailure.soundUnavailable }
    }

    func stop() {
        sound?.stop()
        sound = nil
    }
}
