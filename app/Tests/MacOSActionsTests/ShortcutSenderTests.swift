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
        #expect(sender.permissionChecks.accessibilityTrusted == false)
        let shortcut = KeyboardShortcut(keyCode: 0, modifiers: [.command])
        try sender.send(shortcut)
        allowed = false
        #expect(throws: ShortcutDeliveryError.self) { try sender.send(shortcut) }
        #expect(posted == [shortcut])
        #expect(sender.permission == .denied)
    }

    @Test func permissionSnapshotSeparatesAccessibilityAndEventPosting() throws {
        let shortcut = KeyboardShortcut(keyCode: 0, modifiers: [.command])
        var posted = [KeyboardShortcut]()
        let postingDenied = ShortcutSender(
            accessibilityPreflight: { true },
            preflight: { false },
            request: { false },
            postPair: { posted.append($0) }
        )

        #expect(postingDenied.refreshPermission() == .denied)
        #expect(postingDenied.permissionChecks == PermissionChecks(accessibilityTrusted: true, eventPostingAllowed: false))
        #expect(throws: ShortcutDeliveryError.self) { try postingDenied.send(shortcut) }
        #expect(posted.isEmpty)

        let accessibilityUntrusted = ShortcutSender(
            accessibilityPreflight: { false },
            preflight: { true },
            request: { true },
            postPair: { posted.append($0) }
        )

        #expect(accessibilityUntrusted.refreshPermission() == .granted)
        #expect(accessibilityUntrusted.permissionChecks == PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: true))
        try accessibilityUntrusted.send(shortcut)
        #expect(posted == [shortcut])
    }

    @Test func requestAndRefreshUpdateBothPermissionChecks() {
        var accessibilityTrusted = false
        var eventPostingAllowed = true
        var requested = false
        let sender = ShortcutSender(
            accessibilityPreflight: { accessibilityTrusted },
            preflight: { eventPostingAllowed },
            request: { requested = true; return true },
            postPair: { _ in }
        )

        #expect(sender.requestPermission() == .granted)
        #expect(requested)
        #expect(sender.permissionChecks == PermissionChecks(accessibilityTrusted: false, eventPostingAllowed: true))

        accessibilityTrusted = true
        eventPostingAllowed = false
        #expect(sender.refreshPermission() == .denied)
        #expect(sender.permissionChecks == PermissionChecks(accessibilityTrusted: true, eventPostingAllowed: false))
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
