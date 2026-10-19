import AppKit
import HidhoggDomain
import MacOSActions
import Testing

@MainActor
struct ShortcutSenderTests {
    @Test func permissionCheckedBeforeEveryDelivery() throws {
        var allowed = true
        var posted = [KeyboardShortcut]()
        let sender = ShortcutSender(preflight: { allowed }, request: { allowed }, postPair: { posted.append($0) })
        let shortcut = KeyboardShortcut(keyCode: 0, modifiers: [.command])
        try sender.send(shortcut)
        allowed = false
        #expect(throws: ShortcutDeliveryError.self) { try sender.send(shortcut) }
        #expect(posted == [shortcut])
        #expect(sender.permission == .denied)
    }

    @Test func invalidShortcutNeverReachesBackend() {
        var count = 0
        let sender = ShortcutSender(preflight: { true }, request: { true }, postPair: { _ in count += 1 })
        #expect(throws: ShortcutDeliveryError.self) { try sender.send(.init(keyCode: 55)) }
        #expect(throws: ShortcutDeliveryError.self) { try sender.send(.init(keyCode: 0, modifiers: [.command, .command])) }
        #expect(count == 0)
    }

    @Test func requestRequiresSuccessfulPreflight() {
        var requested = false
        let sender = ShortcutSender(preflight: { false }, request: { requested = true; return true }, postPair: { _ in })
        #expect(sender.requestPermission() == .denied)
        #expect(requested)
    }

    @Test func recordingRejectsRepeatsAndUsesSemanticModifiers() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0, windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        #expect(ShortcutSender.from(event: event) == .init(keyCode: 7, modifiers: [.option, .command]))
        let repeated = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: true, keyCode: 7))
        #expect(ShortcutSender.from(event: repeated) == nil)
    }
}
