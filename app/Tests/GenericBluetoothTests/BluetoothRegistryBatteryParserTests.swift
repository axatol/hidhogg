import Foundation
import HidhoggDomain
import XCTest
@testable import GenericBluetooth

final class BluetoothRegistryBatteryParserTests: XCTestCase {
    private let first = BluetoothEndpoint(address: "AA:00:00:00:00:01")!
    private let second = BluetoothEndpoint(address: "AA:00:00:00:00:02")!

    func testJoinsNormalizedDeviceAddressAndIgnoresUnverifiedIdentityKeys() throws {
        let nodes = [
            ["DeviceAddress": "aa-00-00-00-00-01", "BD_ADDR": Data([1, 2, 3, 4, 5, 6]), "BatteryPercent": 0] as [String: Any],
            ["BluetoothAddress": second.address, "BatteryPercent": 100],
            ["BluetoothDeviceAddress": second.address, "BatteryPercent": 90],
            ["BD_ADDR": Data([6, 5, 4, 3, 2, 1]), "BatteryPercent": 80],
            ["BluetoothAddress": "AA:00:00:00:00:03", "BatteryPercent": 44],
            ["SerialNumber": first.address, "BatteryPercent": 55],
            ["DeviceName": "AA:00:00:00:00:01", "BatteryPercent": 66]
        ]
        let result = try BluetoothRegistryBatteryParser.batteries(in: plist(nodes), pairedEndpoints: [first, second])
        XCTAssertEqual(result, [first: BluetoothBattery(main: 0)])
    }

    func testRejectsInvalidBooleanFractionAndOutOfRangePercentages() throws {
        for value: Any in [true, false, NSNumber(value: 0.5), -1, 101, "50"] {
            let result = try BluetoothRegistryBatteryParser.batteries(
                in: plist([node(first.address, value)]),
                pairedEndpoints: [first]
            )
            XCTAssertNil(result[first])
        }
    }

    func testEqualDuplicateValuesDeduplicateAndConflictingValuesAreDiscarded() throws {
        let duplicateNodes = [
            node(first.address, 40), node(first.address, 40),
            node(second.address, 30), node(second.address, 31)
        ]
        let result = try BluetoothRegistryBatteryParser.batteries(in: plist(duplicateNodes), pairedEndpoints: [first, second])
        XCTAssertEqual(result, [first: BluetoothBattery(main: 40)])
    }

    func testRequiresPlistArrayOfDictionaryNodes() throws {
        for value: Any in ["not an array", ["not a node"], [42]] {
            XCTAssertThrowsError(try BluetoothRegistryBatteryParser.batteries(in: plist(value), pairedEndpoints: [first]))
        }
        XCTAssertTrue(try BluetoothRegistryBatteryParser.batteries(in: plist([]), pairedEndpoints: [first]).isEmpty)
    }

    private func node(_ address: String, _ percent: Any) -> [String: Any] {
        ["DeviceAddress": address, "BatteryPercent": percent]
    }

    private func plist(_ value: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}
