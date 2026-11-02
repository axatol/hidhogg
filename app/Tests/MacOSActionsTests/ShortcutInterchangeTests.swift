import AppKit
import CoreGraphics
import HidhoggDomain
import MacOSActions
import Testing

@MainActor
struct ShortcutInterchangeTests {
    @Test func canonicalKeyboardAndMouseExamplesRoundTrip() throws {
        let mouse = InputShortcut.mouseClick(MouseShortcut(button: .left, modifiers: [.command]))
        let keyboard = InputShortcut.keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.control, .shift]))
        let noncanonicalOrder = InputShortcut.keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.shift, .command]))

        #expect(try ShortcutSender.format(mouse) == "${cmd}+${mouse.left}")
        #expect(try ShortcutSender.format(keyboard) == "${ctrl}+${shift}+C")
        #expect(try ShortcutSender.parse("${cmd}+${mouse.left}") == mouse)
        #expect(try ShortcutSender.parse("${ctrl}+${shift}+C") == keyboard)
        let canonicalText = try ShortcutSender.format(noncanonicalOrder)
        #expect(canonicalText == "${cmd}+${shift}+C")
        #expect(try ShortcutSender.parse(canonicalText) == noncanonicalOrder)
        #expect(ShortcutSender.label(for: mouse) == "⌘ Left click")
    }

    @Test func parserRejectsInvalidModifiersTriggersAndSequences() {
        let invalidInputs = [
            "${hyper}+C",
            "${cmd}+${cmd}+C",
            "${ctrl}+${shift}",
            "ctrl+C",
            "C+D",
            "C,D",
            "C D",
            "${mouse.left}+${mouse.right}",
            "${mouse.side}",
            "${cmd}+${unknown}",
            "C+",
            "${cmd+C",
            "${keycode.054}",
            "${keycode.54}",
            String(repeating: "C", count: 257)
        ]

        for input in invalidInputs {
            #expect(throws: InputShortcutCodecError.self) { try ShortcutSender.parse(input) }
        }
    }

    @Test func everySupportedPhysicalKeyCodeRoundTripsCanonically() throws {
        let expectedKeyCodes = (UInt16(0)...UInt16(127)).filter { !(54...63).contains($0) }
        let options = ShortcutSender.keyOptions
        #expect(options.map(\.keyCode) == expectedKeyCodes)
        #expect(Set(options.map(\.name)).count == options.count)

        for key in options {
            let shortcut = InputShortcut.keyboard(
                KeyboardShortcut(keyCode: key.keyCode, modifiers: [.control, .shift])
            )
            let text = try ShortcutSender.format(shortcut)
            #expect(try ShortcutSender.parse(text) == shortcut)
        }
    }

    @Test func punctuationAndUnknownPhysicalKeysUseStableTokens() throws {
        let canonicalNames: [UInt16: String] = [
            8: "C",
            24: "Equal",
            42: "Backslash",
            69: "KeypadPlus",
            127: "${keycode.127}"
        ]

        for (keyCode, expectedName) in canonicalNames {
            let shortcut = InputShortcut.keyboard(KeyboardShortcut(keyCode: keyCode))
            let text = try ShortcutSender.format(shortcut)
            #expect(text == expectedName)
            #expect(try ShortcutSender.parse(text) == shortcut)
        }
    }

    @Test func mouseEventsUseCurrentPointerAndMatchingModifierFlagsWithoutPosting() throws {
        let location = CGPoint(x: 312, y: 208)
        let cases: [(MouseButton, CGEventType, CGEventType)] = [
            (.left, .leftMouseDown, .leftMouseUp),
            (.right, .rightMouseDown, .rightMouseUp),
            (.middle, .otherMouseDown, .otherMouseUp)
        ]

        for (button, downType, upType) in cases {
            var events = [CGEvent]()
            let sender = ShortcutSender(
                accessibilityPreflight: { true },
                preflight: { true },
                request: { false },
                currentMouseLocation: { location },
                postEvent: { events.append($0) }
            )

            try sender.send(.mouseClick(MouseShortcut(button: button, modifiers: [.command, .control, .shift])))

            #expect(events.count == 2)
            let down = try #require(events.first)
            let up = try #require(events.last)
            #expect(down.type == downType)
            #expect(up.type == upType)
            #expect(down.location == location)
            #expect(up.location == location)
            #expect(down.flags == up.flags)
            #expect(down.flags.contains(.maskCommand))
            #expect(down.flags.contains(.maskControl))
            #expect(down.flags.contains(.maskShift))
            #expect(down.getIntegerValueField(.mouseEventClickState) == 1)
            #expect(up.getIntegerValueField(.mouseEventClickState) == 1)
            if button == .middle {
                #expect(down.getIntegerValueField(.mouseEventButtonNumber) == 2)
                #expect(up.getIntegerValueField(.mouseEventButtonNumber) == 2)
            }
        }
    }

    @Test func permissionPreflightPreventsMouseEventCreationAndPosting() {
        var locationRequested = false
        var postedEvents = 0
        let sender = ShortcutSender(
            accessibilityPreflight: { false },
            preflight: { false },
            request: { Issue.record("Sending must not request permission."); return false },
            currentMouseLocation: { locationRequested = true; return .zero },
            postEvent: { _ in postedEvents += 1 }
        )

        #expect(throws: ShortcutDeliveryError.self) {
            try sender.send(.mouseClick(MouseShortcut(button: .left)))
        }
        #expect(!locationRequested)
        #expect(postedEvents == 0)
    }

    @Test func legacyKeyboardOnlyTestBackendCannotSendMouseClicks() {
        var keyboardPosts = 0
        let sender = ShortcutSender(preflight: { true }, request: { false }, postPair: { _ in keyboardPosts += 1 })

        #expect(throws: ShortcutDeliveryError.self) {
            try sender.send(.mouseClick(MouseShortcut(button: .left)))
        }
        #expect(keyboardPosts == 0)
    }

    @Test func legacyKeyboardBindingDecodesAndMouseBindingRoundTrips() throws {
        let legacyJSON = Data(#"{"kind":"shortcut","shortcut":{"keyCode":8,"modifiers":["command"]}}"#.utf8)
        let legacy = try JSONDecoder().decode(ControlBinding.self, from: legacyJSON)
        #expect(legacy.inputShortcut == .keyboard(KeyboardShortcut(keyCode: 8, modifiers: [.command])))

        let mouse = ControlBinding.mouse(MouseShortcut(button: .middle, modifiers: [.option, .shift]))
        let encoded = try JSONEncoder().encode(mouse)
        #expect(try JSONDecoder().decode(ControlBinding.self, from: encoded) == mouse)
        #expect(mouse.inputShortcut == .mouseClick(MouseShortcut(button: .middle, modifiers: [.option, .shift])))
    }

    @Test func configurationValidationAcceptsMouseBindingsAndRejectsHybridPayloads() throws {
        let valid = AppConfiguration(devices: [DeviceBindings(
            id: AppConfiguration.logitechProfileID,
            defaults: [
                "back": .mouse(MouseShortcut(button: .left, modifiers: [.command])),
                "forward": .key(KeyboardShortcut(keyCode: 8, modifiers: [.control]))
            ]
        )])
        #expect(try valid.validated() == valid)

        let hybrid = ControlBinding(
            kind: .mouseShortcut,
            shortcut: KeyboardShortcut(keyCode: 8),
            mouseShortcut: MouseShortcut(button: .right)
        )
        let invalid = AppConfiguration(devices: [DeviceBindings(
            id: AppConfiguration.logitechProfileID,
            defaults: ["back": hybrid, "forward": .disabled]
        )])
        #expect(throws: ConfigurationValidationError.self) { try invalid.validated() }
    }
}
