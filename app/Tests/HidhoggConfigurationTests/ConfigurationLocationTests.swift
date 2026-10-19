import Foundation
import XCTest
@testable import HidhoggConfiguration

final class ConfigurationLocationTests: XCTestCase {
    func testAbsoluteXDGConfigHomeIsUsed() {
        let result = ConfigurationLocation.url(
            xdgConfigHome: "/tmp/hidhogg-test-config",
            home: URL(fileURLWithPath: "/tmp/ignored-home", isDirectory: true)
        )

        XCTAssertEqual(result.path, "/tmp/hidhogg-test-config/hidhogg/config.toml")
    }

    func testUnsetEmptyAndRelativeXDGConfigHomeUseHomeFallback() {
        let home = URL(fileURLWithPath: "/tmp/hidhogg-test-home", isDirectory: true)
        let expected = "/tmp/hidhogg-test-home/.config/hidhogg/config.toml"

        for xdgConfigHome in [nil, "", "relative/path"] {
            XCTAssertEqual(
                ConfigurationLocation.url(xdgConfigHome: xdgConfigHome, home: home).path,
                expected
            )
        }
    }
}
