import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class NavigationPresetApplicationTests: XCTestCase {
    func testPresetChangesOnlySelectedApplicationBindingAndCancelsRecording() {
        let model = makeModel()
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults["back"] = .key(KeyboardShortcut(keyCode: 12))
        configuration.devices[0].defaults["forward"] = .key(KeyboardShortcut(keyCode: 13))
        configuration.devices[0].applications = [
            "com.example.browser": [
                "back": .disabled,
                "forward": .key(KeyboardShortcut(keyCode: 14))
            ],
            "com.example.editor": ["back": .key(KeyboardShortcut(keyCode: 15))]
        ]
        model.updateDraft(configuration)
        model.selectApplication("com.example.browser")
        model.selectControl(.back)
        model.beginRecording(for: .back, applicationID: "com.example.browser")

        model.applyNavigationPreset(.pageBack)

        XCTAssertNil(model.recordingTarget)
        XCTAssertEqual(model.document.draft.devices[0].defaults, configuration.devices[0].defaults)
        XCTAssertEqual(
            model.document.draft.mouse?.applications["com.example.browser"]?["back"],
            .key(NavigationPreset.pageBack.shortcut)
        )
        XCTAssertEqual(
            model.document.draft.mouse?.applications["com.example.browser"]?["forward"],
            configuration.devices[0].applications["com.example.browser"]?["forward"]
        )
        XCTAssertEqual(
            model.document.draft.mouse?.applications["com.example.editor"],
            configuration.devices[0].applications["com.example.editor"]
        )
    }

    func testPresetChangesOnlySelectedDefaultAndPreservesApplicationOverrides() {
        let model = makeModel()
        var configuration = AppConfiguration.empty
        configuration.devices[0].defaults["back"] = .key(KeyboardShortcut(keyCode: 12))
        configuration.devices[0].defaults["forward"] = .key(KeyboardShortcut(keyCode: 13))
        configuration.devices[0].applications = [
            "com.example.browser": ["back": .disabled],
            "com.example.editor": ["forward": .key(KeyboardShortcut(keyCode: 15))]
        ]
        model.updateDraft(configuration)
        model.selectApplication(nil)
        model.selectControl(.forward)

        model.applyNavigationPreset(.pageForward)

        XCTAssertEqual(
            model.document.draft.devices[0].defaults["back"],
            configuration.devices[0].defaults["back"]
        )
        XCTAssertEqual(
            model.document.draft.devices[0].defaults["forward"],
            .key(NavigationPreset.pageForward.shortcut)
        )
        XCTAssertEqual(model.document.draft.devices[0].applications, configuration.devices[0].applications)
    }

    private func makeModel() -> AppModel {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("config.toml")
        return AppModel(
            configurationURL: url,
            store: ConfigurationStore(url: url),
            bolt: PresetTestBindingSession(),
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in }),
            loadImmediately: false,
            observeSleep: false
        )
    }
}

private struct PresetTestBindingSession: BindingSession {
    let events = AsyncStream<BoltEvent> { $0.finish() }

    func discover() async {}
    func enable() async {}
    func disable() async {}
    func stop() async {}

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }
}
