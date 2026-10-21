import HidhoggDomain
import XCTest

final class NavigationPresetTests: XCTestCase {
    func testNamedPresetsUseCommandWithANSIPhysicalBracketKeyCodes() {
        XCTAssertEqual(NavigationPreset.pageBack.title, "Page Back")
        XCTAssertEqual(NavigationPreset.pageForward.title, "Page Forward")
        XCTAssertEqual(
            NavigationPreset.pageBack.shortcut,
            KeyboardShortcut(keyCode: 33, modifiers: [.command])
        )
        XCTAssertEqual(
            NavigationPreset.pageForward.shortcut,
            KeyboardShortcut(keyCode: 30, modifiers: [.command])
        )
    }

    func testDefaultAndEmptyConfigurationsRemainDistinct() {
        XCTAssertEqual(
            AppConfiguration.defaultConfiguration.mouse?.binding(for: .back, application: nil),
            .key(NavigationPreset.pageBack.shortcut)
        )
        XCTAssertEqual(
            AppConfiguration.defaultConfiguration.mouse?.binding(for: .forward, application: nil),
            .key(NavigationPreset.pageForward.shortcut)
        )
        XCTAssertEqual(AppConfiguration.empty.mouse?.binding(for: .back, application: nil), .disabled)
        XCTAssertEqual(AppConfiguration.empty.mouse?.binding(for: .forward, application: nil), .disabled)
    }
}
