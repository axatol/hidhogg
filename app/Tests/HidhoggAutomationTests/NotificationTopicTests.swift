import XCTest
import HidhoggDomain

final class NotificationTopicTests: XCTestCase {
    func testTopicsAndFiltersUseBoundedASCIINames() {
        XCTAssertTrue(NotificationTopic.isValidTopic("build.finished"))
        XCTAssertTrue(NotificationTopic.isValidTopic("A0_build-done"))
        XCTAssertTrue(NotificationTopic.isValidTopic(String(repeating: "a", count: 64)))
        XCTAssertFalse(NotificationTopic.isValidTopic(""))
        XCTAssertFalse(NotificationTopic.isValidTopic("-invalid"))
        XCTAssertFalse(NotificationTopic.isValidTopic(".invalid"))
        XCTAssertFalse(NotificationTopic.isValidTopic("build.*"))
        XCTAssertFalse(NotificationTopic.isValidTopic("café"))
        XCTAssertFalse(NotificationTopic.isValidTopic(String(repeating: "a", count: 65)))

        XCTAssertTrue(NotificationTopic.isValidFilter("*"))
        XCTAssertTrue(NotificationTopic.isValidFilter("build.*"))
        XCTAssertTrue(NotificationTopic.isValidFilter("*.finished"))
        XCTAssertTrue(NotificationTopic.isValidFilter(String(repeating: "a", count: 64)))
        XCTAssertFalse(NotificationTopic.isValidFilter(""))
        XCTAssertFalse(NotificationTopic.isValidFilter(".invalid"))
        XCTAssertFalse(NotificationTopic.isValidFilter("café"))
        XCTAssertFalse(NotificationTopic.isValidFilter(String(repeating: "a", count: 65)))
    }

    func testWildcardMatchesAnySequenceAcrossDotsAndRemainsCaseSensitive() {
        XCTAssertTrue(NotificationTopic.matches("build.finished", filter: "build.*"))
        XCTAssertTrue(NotificationTopic.matches("build.project.finished", filter: "build.*"))
        XCTAssertTrue(NotificationTopic.matches("build.", filter: "build.*"))
        XCTAssertTrue(NotificationTopic.matches("build.project.finished.done", filter: "build.*.done"))
        XCTAssertTrue(NotificationTopic.matches("build.finished", filter: "*"))
        XCTAssertTrue(NotificationTopic.matches("build.finished", filter: "build.finished"))
        XCTAssertFalse(NotificationTopic.matches("build", filter: "build.*"))
        XCTAssertFalse(NotificationTopic.matches("Build.finished", filter: "build.*"))
        XCTAssertFalse(NotificationTopic.matches("build.finished", filter: "build.finishes"))
    }

    func testMatcherRejectsInvalidTopicsAndFilters() {
        XCTAssertFalse(NotificationTopic.matches("build.*", filter: "*"))
        XCTAssertFalse(NotificationTopic.matches("build.finished", filter: ".*"))
        XCTAssertFalse(NotificationTopic.matches("café", filter: "*"))
        XCTAssertFalse(NotificationTopic.matches("build.finished", filter: String(repeating: "*", count: 65)))
    }
}
