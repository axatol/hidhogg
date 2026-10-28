import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class D200XDisplayConfigurationTests: XCTestCase {
    func testOldDocumentDefaultsToCustomAndTwentyFourHours() throws {
        let data = ConfigurationFixtures.data(ConfigurationFixtures.toml + "\n[d200x]\n")
        let decoded = try ConfigurationCodec.decode(data)
        XCTAssertEqual(decoded.d200x?.wideDisplayMode, .custom)
        XCTAssertEqual(decoded.d200x?.clockFormat, .twentyFourHour)
    }

    func testEveryModeAndClockFormatRoundTripsAndRemainsDeviceWide() throws {
        for mode in D200XWideDisplayMode.allCases {
            for format in D200XClockFormat.allCases {
                var configuration = ConfigurationFixtures.configuration
                configuration.d200x = D200XConfiguration(applications: ["com.example.Editor": [:]],
                    wideDisplayMode: mode, clockFormat: format)
                let decoded = try ConfigurationCodec.decode(ConfigurationCodec.encode(configuration))
                XCTAssertEqual(decoded, configuration)
                XCTAssertEqual(decoded.d200x?.resolved(application: "com.example.Editor").wideDisplayMode, mode)
            }
        }
    }

    func testUnsupportedModeAndFormatAreRejected() {
        for entry in ["wide_display_mode = '100'", "wide_display_mode = 'encoder'", "clock_format = 'AM/PM'"] {
            XCTAssertThrowsError(try ConfigurationCodec.decode(ConfigurationFixtures.data(
                ConfigurationFixtures.toml + "\n[d200x]\n" + entry)))
        }
    }
}
