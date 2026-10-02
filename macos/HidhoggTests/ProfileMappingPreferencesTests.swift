import Foundation
import XCTest
@testable import Hidhogg

final class ProfileMappingPreferencesTests: XCTestCase {
    func testStoredMappingsExposeOnlySyntacticallyValidEntries() {
        let preferences = ProfileMappingPreferences(mappings: [
            "com.example.valid": "Work.Profile",
            "": "Default",
            "com.example.invalid": ""
        ])

        XCTAssertEqual(preferences.mappings, ["com.example.valid": "Work.Profile"])
        XCTAssertEqual(preferences.invalidMappings.count, 2)
        XCTAssertEqual(preferences.persistedMappings.count, 3)
    }

    func testMappingEditsReplaceByExactBundleIdentifierAndPersistSnapshot() throws {
        let store = TestProfileMappingStore()
        let initial = ProfileMappingPreferences(mappings: ["com.example.app": "Default"])
        let replaced = try initial.setting(
            profileID: "Work.Profile",
            forBundleIdentifier: "com.example.app"
        )
        replaced.saving(to: store)

        XCTAssertEqual(replaced.profileID(for: "com.example.app"), "Work.Profile")
        XCTAssertEqual(store.values, ["com.example.app": "Work.Profile"])
        XCTAssertEqual(replaced.sortedMappings, [
            ProfileMapping(bundleIdentifier: "com.example.app", profileID: "Work.Profile")
        ])
    }

    func testRemovingMappingLeavesOtherEntriesUnchanged() throws {
        let preferences = ProfileMappingPreferences(mappings: [
            "com.example.a": "A",
            "com.example.b": "B"
        ])

        let updated = preferences.removing(bundleIdentifier: "com.example.a")

        XCTAssertEqual(updated.mappings, ["com.example.b": "B"])
        XCTAssertEqual(updated.persistedMappings, ["com.example.b": "B"])
    }

    func testIdentifierValidationRejectsControlsAndBoundsUTF8Bytes() {
        XCTAssertFalse(ProfileMappingPreferences.isValidIdentifier("com.example\u{0}.app"))
        XCTAssertFalse(ProfileMappingPreferences.isValidIdentifier(String(repeating: "é", count: 128)))
        XCTAssertTrue(ProfileMappingPreferences.isValidIdentifier(String(repeating: "a", count: 255)))
    }

    func testMappingLimitRejectsNewEntriesAndRetainsOversizedStoredSnapshot() throws {
        let mappings = Dictionary(uniqueKeysWithValues: (0..<ProfileMappingPreferences.maximumMappingCount).map {
            ("com.example.\($0)", "Profile\($0)")
        })
        let preferences = ProfileMappingPreferences(mappings: mappings)

        XCTAssertThrowsError(
            try preferences.setting(
                profileID: "New",
                forBundleIdentifier: "com.example.new"
            )
        ) { error in
            XCTAssertEqual(error as? ProfileMappingPreferencesError, .mappingLimitExceeded)
        }

        let oversized = ProfileMappingPreferences(
            mappings: mappings.merging(["com.example.extra": "Extra"]) { current, _ in current }
        )
        XCTAssertEqual(oversized.persistedMappings.count, 129)
        XCTAssertTrue(oversized.mappings.isEmpty)
        XCTAssertEqual(oversized.invalidMappings.count, 129)
    }

    func testStoreInitializationRoundTripsMappings() {
        let store = TestProfileMappingStore(values: ["com.example.app": "Default"])

        let preferences = ProfileMappingPreferences(store: store)

        XCTAssertEqual(preferences.mappings, ["com.example.app": "Default"])
    }
}

private final class TestProfileMappingStore: @unchecked Sendable, ProfileMappingPreferencesStore {
    private(set) var values: [String: String]?

    init(values: [String: String]? = nil) {
        self.values = values
    }

    func dictionary(forKey key: String) -> [String: String]? {
        values
    }

    func set(_ value: [String: String]?, forKey key: String) {
        values = value
    }
}
