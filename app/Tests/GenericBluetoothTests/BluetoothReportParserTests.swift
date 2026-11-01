import Foundation
import HidhoggDomain
import XCTest
@testable import GenericBluetooth

final class BluetoothReportParserTests: XCTestCase {
    private let first = BluetoothEndpoint(address: "AA:00:00:00:00:01")!
    private let second = BluetoothEndpoint(address: "AA:00:00:00:00:02")!

    func testEndpointNormalizationRejectsMalformedAddresses() throws {
        XCTAssertEqual(BluetoothEndpoint(address: "aa-00-00-00-00-01"), first)
        for address in ["AA:00:00:00:00", "AA:00-00:00:00:01", "AA:00:00:00:00:001", " AA:00:00:00:00:01", "GG:00:00:00:00:01"] {
            XCTAssertNil(BluetoothEndpoint(address: address))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(BluetoothEndpoint.self, from: Data("\"invalid\"".utf8)))
    }

    func testSameNamesJoinOnlyExactPairedEndpoints() throws {
        let data = report([
            entry(first.address, ["device_batteryLevelMain": " 75 % "]),
            entry(second.address, ["device_batteryLevelMain": 20]),
            entry("AA:00:00:00:00:03", ["device_batteryLevelMain": 99])
        ])
        let result = try BluetoothReportParser.batteries(in: data, pairedEndpoints: [first, second])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[first]?.main, 75)
        XCTAssertEqual(result[second]?.main, 20)
    }

    func testComponentsAndZeroAreIndependent() throws {
        let data = report([entry(first.address, ["device_batteryLevelLeft": "0%", "device_batteryLevelRight": 100,
                                                "device_batteryLevelCase": "42", "device_batteryLevelMain": "unknown"])])
        let battery = try XCTUnwrap(BluetoothReportParser.batteries(in: data, pairedEndpoints: [first])[first])
        XCTAssertEqual(battery, BluetoothBattery(left: 0, right: 100, caseLevel: 42))
    }

    func testInvalidPercentagesAreUnavailable() throws {
        for value: Any in [true, false, -1, 101, 0.5, "-1%", "101%", "0.5%", "NaN", "0x10", ""] {
            let result = try BluetoothReportParser.batteries(in: report([entry(first.address, ["device_batteryLevelMain": value])]), pairedEndpoints: [first])
            XCTAssertNil(result[first])
        }
    }

    func testDuplicateEndpointIsAmbiguousEvenWhenValuesAgree() throws {
        let data = report([entry(first.address, ["device_batteryLevelMain": 50]), entry(first.address, ["device_batteryLevelMain": 50])])
        XCTAssertTrue(try BluetoothReportParser.batteries(in: data, pairedEndpoints: [first]).isEmpty)
    }

    func testUnknownShapeIsFailureAndKnownEmptyIsSuccess() throws {
        for value in ["{}", "[]", "{\"SPBluetoothDataType\":[]}", "{\"SPBluetoothDataType\":[{\"new_shape\":[]}]}", "{\"SPBluetoothDataType\":[{\"device_connected\":{}}]}", "{\"SPBluetoothDataType\":[{\"device_connected\":[{\"new_record\":true}]}]}"] {
            XCTAssertThrowsError(try BluetoothReportParser.batteries(in: Data(value.utf8), pairedEndpoints: [first]))
        }
        XCTAssertTrue(try BluetoothReportParser.batteries(in: report([]), pairedEndpoints: [first]).isEmpty)
    }

    func testDisconnectedKnownSectionAndAbsentBattery() throws {
        let data = try JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [["device_not_connected": [entry(first.address, [:]), entry(second.address, ["device_batteryLevelMain": "1%"] )]]]])
        let result = try BluetoothReportParser.batteries(in: data, pairedEndpoints: [first, second])
        XCTAssertNil(result[first])
        XCTAssertEqual(result[second]?.main, 1)
    }

    private func report(_ records: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [["device_connected": records]]])
    }

    private func entry(_ address: String, _ fields: [String: Any]) -> [String: Any] {
        ["Synthetic same-name device": fields.merging(["device_address": address]) { first, _ in first }]
    }
}
