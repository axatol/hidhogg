import Foundation
import Testing
@testable import LofreeFlowLite84

struct FlowLite84IndependentBoundaryTests {
    @Test func supportedIdentityAndScalarAddressesArePinned() throws {
        #expect(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0).isSupported)
        #expect(!FlowLite84Identity(cid: 0, mid: 1, connectionType: 0).isSupported)
        #expect(!FlowLite84Identity(cid: 1, mid: 0, connectionType: 0).isSupported)
        #expect(!FlowLite84Identity(cid: 1, mid: 1, connectionType: 1).isSupported)

        let expectedAddresses: [UInt16] = [8496, 8498, 8500, 9416]
        #expect(FlowLite84Setting.allCases.map(\.rawValue) == expectedAddresses)

        for (setting, expectedAddress) in zip(FlowLite84Setting.allCases, expectedAddresses) {
            let report = try FlowLite84Codec.encode(.setting(setting))
            let address = UInt16(report[3]) << 8 | UInt16(report[4])
            #expect(report.count == 17)
            #expect(report[0] == 8)
            #expect(report[1] == 8)
            #expect(address == expectedAddress)
            #expect(report[5] == 0x82)
        }
    }

    @Test func activeEffectRequestsStayWithinSixteenModeHeaders() throws {
        var observed = [UInt16]()
        for mode in UInt8(0)...15 {
            let report = try FlowLite84Codec.encode(.effect(mode: mode))
            observed.append(UInt16(report[3]) << 8 | UInt16(report[4]))
            #expect(report[1] == 8)
            #expect(report[5] == 0x84)
        }
        #expect(observed == (0...15).map { UInt16(8544 + $0 * 32) })
        #expect(throws: FlowLite84Failure.invalidRequest) {
            try FlowLite84Codec.encode(.effect(mode: 16))
        }

        let requests: [FlowLite84Request] = [
            .identify([1, 2, 3, 4]), .online, .battery, .keyboardVersion,
            .receiverVersion, .setting(.lightingMode), .effect(mode: 0)
        ]
        let commands = try requests.map { request in
            try FlowLite84Codec.encode(request)[1]
        }
        #expect(Set(commands) == Set([1, 3, 4, 8, 18, 29]))
    }

    @Test func reportedBatteryFieldsRejectOutOfRangeValuesIndependently() throws {
        let maximum = FlowLite84Codec.battery(
            try FlowLite84Codec.decode(independentReply(command: 4, fields: [100, 1, 0x0f, 0xe3]))
        )
        #expect(maximum == FlowLite84Battery(reportedLevel: 100, charging: true, voltageMillivolts: 4067))

        let invalidLevel = FlowLite84Codec.battery(
            try FlowLite84Codec.decode(independentReply(command: 4, fields: [101, 0, 0x0e, 0x74]))
        )
        #expect(invalidLevel.reportedLevel == nil)
        #expect(invalidLevel.charging == false)
        #expect(invalidLevel.voltageMillivolts == 3700)

        let invalidCharging = FlowLite84Codec.battery(
            try FlowLite84Codec.decode(independentReply(command: 4, fields: [0, 2, 0x0e, 0x74]))
        )
        #expect(invalidCharging.reportedLevel == 0)
        #expect(invalidCharging.charging == nil)
        #expect(invalidCharging.voltageMillivolts == 3700)

        for voltage: [UInt8] in [[0, 0], [0xff, 0xff]] {
            let value = FlowLite84Codec.battery(
                try FlowLite84Codec.decode(independentReply(command: 4, fields: [50, 1] + voltage))
            )
            #expect(value.reportedLevel == 50)
            #expect(value.charging == true)
            #expect(value.voltageMillivolts == nil)
        }
    }
}

private func independentReply(command: UInt8, fields: [UInt8]) -> Data {
    var payload = [UInt8](repeating: 0, count: 16)
    payload[0] = command
    for (index, byte) in fields.prefix(10).enumerated() {
        payload[5 + index] = byte
    }
    let sum = payload.prefix(15).reduce(UInt8(8), &+)
    payload[15] = 0x55 &- sum
    return Data([8] + payload)
}
