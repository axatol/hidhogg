import XCTest
import LogitechBolt
@testable import HidhoggApp

final class DeviceInformationFirmwarePresentationTests: XCTestCase {
    func testFirmwareNumbersUseUnpaddedDecimalBCDComponents() {
        let presentation = makePresentation([
            entity(type: 0, rawVersion: 0x1002, rawBuild: 0x0006),
            entity(type: 0x10, rawVersion: 0x9909, rawBuild: 0x9999),
            entity(type: 0, rawVersion: 0x1234, rawBuild: 0x0567),
            entity(type: 0, rawVersion: 0x2201, rawBuild: 0x0006)
        ])

        XCTAssertEqual(presentation.firmwareRows.map(\.value), ["10.2.6", "99.9.9999", "12.34.567", "22.1.6"])
    }

    func testInvalidPackedBCDNibblesDoNotBecomeDecimalVersionGuesses() {
        let presentation = makePresentation([
            entity(type: 0, rawVersion: 0x1A34, rawBuild: 0x0001),
            entity(type: 0, rawVersion: 0x12FA, rawBuild: 0x0001),
            entity(type: 0, rawVersion: 0x1234, rawBuild: 0x12F4)
        ])

        XCTAssertEqual(presentation.firmwareRows.map(\.value), [
            "Version unavailable",
            "Version unavailable",
            "Version unavailable"
        ])
    }

    func testTypedRowsPreserveMultipleMainEntitiesHardwareUnknownTypesAndActiveFlags() {
        let presentation = makePresentation([
            entity(type: 0x10, prefix: "M3A", rawVersion: 0x1201, rawBuild: 0x0006),
            entity(type: 0x20, prefix: "M3B", rawVersion: 0x1301, rawBuild: 0x0007, flags: 0x01),
            entity(type: 0x31, prefix: "BOOT", rawVersion: 0x0102, rawBuild: 0x0003),
            entity(type: 0x42, prefix: "", rawVersion: 0xFACE, rawBuild: 0xBEEF, flags: 0x01, hardwareRevision: 0xFA),
            entity(type: 0x5F, prefix: "AUX", rawVersion: 0x9999, rawBuild: 0x9999)
        ])
        let rows = presentation.firmwareRows

        XCTAssertEqual(rows.map(\.label), [
            "MX Master 3S firmware",
            "MX Master 3S firmware",
            "Bootloader",
            "Hardware revision",
            "Other component"
        ])
        XCTAssertEqual(rows.filter(\.isPrimary).count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 5)
        XCTAssertEqual(rows.map(\.isActive), [false, true, false, true, false])
        XCTAssertEqual(rows.map(\.value), ["12.1.6", "13.1.7", "1.2.3", "250", "Version unavailable"])
        XCTAssertEqual(rows[0].caption, "Firmware class M3A")
        XCTAssertEqual(rows[4].caption, "Firmware class AUX · Unrecognized type 95")
    }

    func testNoFirmwareInventoryProducesNoRows() {
        XCTAssertTrue(makePresentation([]).firmwareRows.isEmpty)
    }

    private func makePresentation(_ firmware: [BoltDeviceInformation.FirmwareEntity]) -> DeviceInformationPresentation {
        let information = BoltDeviceInformation(firmwareState: .available, firmware: firmware)
        let status = BoltStatus(
            phase: .ready,
            message: "Fixture status",
            availableControls: [],
            generation: 1,
            cleanupUncertain: false,
            deviceInformation: information
        )
        return DeviceInformationPresentation(status: status)
    }

    private func entity(
        type: UInt8,
        prefix: String = "",
        rawVersion: UInt16,
        rawBuild: UInt16,
        flags: UInt8 = 0,
        hardwareRevision: UInt8? = nil
    ) -> BoltDeviceInformation.FirmwareEntity {
        .init(
            type: type,
            prefix: prefix,
            rawVersion: rawVersion,
            rawBuild: rawBuild,
            flags: flags,
            hardwareRevision: hardwareRevision
        )
    }
}
