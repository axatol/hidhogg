import HidhoggDomain
import XCTest
@testable import GenericBluetooth

final class BluetoothDeviceKindTests: XCTestCase {
    func testClassifiesBluetoothSIGMajorAndMinorDeviceClasses() {
        let cases: [(UInt32, UInt32, BluetoothDeviceKind)] = [
            (0x01, 0x03, .computer),
            (0x01, 0x06, .watch),
            (0x02, 0x03, .phone),
            (0x04, 0x01, .headphones),
            (0x04, 0x05, .speaker),
            (0x04, 0x06, .headphones),
            (0x05, 0x10, .keyboard),
            (0x05, 0x20, .mouse),
            (0x05, 0x02, .gameController),
            (0x07, 0x01, .watch),
            (0x07, 0x05, .glasses)
        ]

        for (major, minor, expected) in cases {
            XCTAssertEqual(
                BluetoothDeviceKind.reported(majorDeviceClass: major, minorDeviceClass: minor),
                expected,
                "Bluetooth class major=\(major), minor=\(minor)"
            )
        }
    }

    func testUnknownAndCompoundDeviceClassesStayUnclassified() {
        XCTAssertNil(BluetoothDeviceKind.reported(majorDeviceClass: 0x03, minorDeviceClass: 0x00))
        XCTAssertNil(BluetoothDeviceKind.reported(majorDeviceClass: 0x04, minorDeviceClass: 0x07))
        XCTAssertNil(BluetoothDeviceKind.reported(majorDeviceClass: 0x05, minorDeviceClass: 0x30))
        XCTAssertNil(BluetoothDeviceKind.reported(majorDeviceClass: 0x07, minorDeviceClass: 0x02))
        XCTAssertNil(BluetoothDeviceKind.reported(majorDeviceClass: 0x20, minorDeviceClass: 0x00))
        XCTAssertNil(BluetoothDeviceKind.reported(majorDeviceClass: 0x02, minorDeviceClass: 0x40))
    }

    func testExplicitOverrideThenReportedClassThenGenericChooseIconKind() {
        XCTAssertEqual(BluetoothDeviceKind.preferred(iconOverride: .mouse, reported: .keyboard), .mouse)
        XCTAssertEqual(BluetoothDeviceKind.preferred(iconOverride: nil, reported: .keyboard), .keyboard)
        XCTAssertEqual(BluetoothDeviceKind.preferred(iconOverride: nil, reported: nil), .generic)
    }

    func testGenericKindUsesCustomBluetoothRuneAndConcreteKindsHaveSymbols() {
        XCTAssertNil(BluetoothDeviceKind.generic.optionalSystemSymbol)
        XCTAssertEqual(BluetoothDeviceKind.keyboard.optionalSystemSymbol, "keyboard")
        XCTAssertEqual(BluetoothDeviceKind.headphones.optionalSystemSymbol, "headphones")
        XCTAssertEqual(BluetoothDeviceKind.gameController.optionalSystemSymbol, "gamecontroller")
    }

    func testPairedBluetoothDeviceKeepsOldInitializerAutomatic() {
        let endpoint = BluetoothEndpoint(address: "AA:00:00:00:00:01")!
        let device = PairedBluetoothDevice(endpoint: endpoint, name: "Device", isConnected: false)
        XCTAssertNil(device.reportedKind)
    }
}
