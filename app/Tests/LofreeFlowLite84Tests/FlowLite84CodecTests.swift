import Foundation
import Testing
@testable import LofreeFlowLite84

struct FlowLite84CodecTests {
    @Test func requestVectorsAndExactReadAllowlist() throws {
        #expect(try FlowLite84Codec.encode(.online) == Data([8, 3, 0, 0, 0, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xca]))
        let identity = try FlowLite84Codec.encode(.identify([1, 2, 3, 4]))
        #expect(Array(identity[6...13]) == [1, 2, 3, 4, 0, 0, 0, 0])
        for setting in FlowLite84Setting.allCases {
            try FlowLite84Codec.validateOutput(FlowLite84Codec.encode(.setting(setting)))
        }
        for mode in UInt8(0)...15 {
            let bytes = try FlowLite84Codec.encode(.effect(mode: mode))
            #expect(bytes[3] == UInt8((8544 + UInt16(mode) * 32) >> 8))
            #expect(bytes[5] == 0x84)
            try FlowLite84Codec.validateOutput(bytes)
        }
        #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.encode(.effect(mode: 16)) }
        #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.encode(.identify([1])) }
    }

    @Test func outputBoundaryRejectsEveryOtherCommand() throws {
        for command in UInt8.min...UInt8.max where ![1, 3, 4, 8, 18, 29].contains(command) {
            let report = fixturePacket(command: command, count: 0x80)
            #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.validateOutput(report) }
        }
        for address: UInt16 in [0, 512, 1536, 2048, 8495, 8497, 8502, 8545, 9025, 9408, 9418, 10064] {
            #expect(throws: FlowLite84Failure.invalidRequest) {
                try FlowLite84Codec.validateOutput(fixturePacket(command: 8, address: address, count: 0x82))
            }
        }
        for count: UInt8 in [0, 1, 3, 4, 10, 0x80, 0x81, 0x83, 0x84, 0x8a] {
            #expect(throws: FlowLite84Failure.invalidRequest) {
                try FlowLite84Codec.validateOutput(fixturePacket(command: 8, address: 8496, count: count))
            }
        }
        for count: UInt8 in [0x81, 0x82, 0x83, 0x85, 0x8a] {
            #expect(throws: FlowLite84Failure.invalidRequest) {
                try FlowLite84Codec.validateOutput(fixturePacket(command: 8, address: 8544, count: count))
            }
        }
    }

    @Test func outputRejectsHiddenDataBadChecksumAndWrongReportForm() throws {
        let hidden = fixturePacket(command: 3, count: 0x80, fields: [1])
        #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.validateOutput(hidden) }
        var invalid = try FlowLite84Codec.encode(.battery)
        invalid[16] &+= 1
        #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.validateOutput(invalid) }
        #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.validateOutput(Data(invalid.dropFirst())) }
        invalid[0] = 7
        #expect(throws: FlowLite84Failure.invalidRequest) { try FlowLite84Codec.validateOutput(invalid) }
    }

    @Test func inputNormalizationAndCorrelation() throws {
        let full = fixturePacket(command: 8, address: 8496, count: 0x82, fields: [10, 0x4b])
        #expect(try FlowLite84Codec.normalize(full) == FlowLite84Codec.normalize(Data(full.dropFirst())))
        let reply = try FlowLite84Codec.decode(full)
        try reply.validate(for: .setting(.lightingMode))
        #expect(try FlowLite84Codec.scalar(reply) == 10)
        #expect(throws: FlowLite84Failure.invalidResponse(.readHeader)) { try reply.validate(for: .setting(.idleOff)) }
        #expect(throws: FlowLite84Failure.invalidResponse(.replyCommand(expected: 4, received: 8))) { try reply.validate(for: .battery) }
        #expect(throws: FlowLite84Failure.invalidResponse(.readHeader)) {
            try FlowLite84Codec.decode(fixturePacket(command: 8, address: 8496, count: 4, fields: [10, 0x4b]))
        }
        let rejected = try FlowLite84Codec.decode(fixturePacket(command: 4, status: 1))
        #expect(throws: FlowLite84Failure.rejected(command: 4, status: 1)) { try rejected.validate(for: .battery) }
        var corrupt = full
        corrupt[16] &+= 1
        #expect(throws: FlowLite84Failure.invalidResponse(.packetChecksum)) { try FlowLite84Codec.decode(corrupt) }
        #expect(throws: FlowLite84Failure.invalidResponse(.shape)) { try FlowLite84Codec.decode(Data(repeating: 0, count: 18)) }
    }

    @Test func scalarAndEffectChecksumsAreIndependentOfPacketChecksum() throws {
        let badScalar = try FlowLite84Codec.decode(fixturePacket(command: 8, address: 8496, count: 2, fields: [10, 0]))
        #expect(throws: FlowLite84Failure.invalidResponse(.scalarChecksum)) { try FlowLite84Codec.scalar(badScalar) }
    }

    @Test func callbackValidationPreservesSafeFailureCategories() throws {
        var wrongPrefix = fixturePacket(command: 3, fields: [1])
        wrongPrefix[0] = 7
        var badChecksum = fixturePacket(command: 3, fields: [1])
        badChecksum[16] &+= 1
        let cases: [(Data, FlowLite84ValidationIssue)] = [
            (wrongPrefix, .shape), (badChecksum, .packetChecksum),
            (fixturePacket(command: 254), .unsupportedCommand),
            (fixturePacket(command: 8, address: 8496, count: 0), .readHeader),
            (fixturePacket(command: 8, address: 0, count: 2), .readHeader),
        ]
        for (packet, issue) in cases {
            #expect(throws: FlowLite84Failure.invalidResponse(issue)) {
                try Array(packet).withUnsafeBufferPointer { try FlowLite84Codec.sanitizedInput(reportID: 8, bytes: $0) }
            }
        }
        #expect(throws: FlowLite84Failure.invalidResponse(.unsupportedCommand)) {
            try FlowLite84Codec.decode(fixturePacket(command: 254))
        }
        #expect(throws: FlowLite84Failure.invalidResponse(.readHeader)) {
            try FlowLite84Codec.decode(fixturePacket(command: 8, count: 0))
        }
        #expect(FlowLite84Failure.invalidResponse(.unsupportedCommand).userMessage == "The receiver returned an invalid status response (unsupported response command).")
        #expect(FlowLite84Failure.invalidFrame.userMessage == "The receiver returned an invalid status response.")
    }

    @Test func batterySentinelsAndVendorVersionConvention() throws {
        let sentinel = FlowLite84Codec.battery(try FlowLite84Codec.decode(fixturePacket(command: 4, fields: [255, 255, 255, 255])))
        #expect(sentinel == FlowLite84Battery())
        let zero = FlowLite84Codec.battery(try FlowLite84Codec.decode(fixturePacket(command: 4, fields: [0, 0, 0, 0])))
        #expect(zero.reportedLevel == 0)
        #expect(zero.charging == false)
        #expect(zero.voltageMillivolts == nil)
        #expect(FlowLite84Codec.version(try FlowLite84Codec.decode(fixturePacket(command: 18, fields: [1, 0x61]))) == "v1.61")
        #expect(FlowLite84Codec.version(try FlowLite84Codec.decode(fixturePacket(command: 29, fields: [2, 0xab]))) == "v2.ab")
    }

    @Test func callbackProjectionDropsPrivateBytesAndIgnoresNormalReports() throws {
        let packet = Array(fixturePacket(command: 3, fields: [1, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6]).dropFirst())
        let sanitized = try packet.withUnsafeBufferPointer { try FlowLite84Codec.sanitizedInput(reportID: 8, bytes: $0) }
        let bytes = try #require(sanitized)
        #expect(bytes[5] == 1)
        #expect(bytes[6..<15].allSatisfy { $0 == 0 })
        #expect(try FlowLite84Codec.decode(bytes).fields == [1])
        #expect(try packet.withUnsafeBufferPointer { try FlowLite84Codec.sanitizedInput(reportID: 1, bytes: $0) } == nil)
        #expect(try [UInt8](repeating: 0, count: 100).withUnsafeBufferPointer {
            try FlowLite84Codec.sanitizedInput(reportID: 8, bytes: $0)
        } == nil)
    }

    @Test func descriptorRequiresTheObservedReportEightCollection() {
        let descriptor = Data(FlowLite84Codec.configurationCollection)
        #expect(FlowLite84Codec.hasConfigurationCollection(descriptor))
        #expect(FlowLite84Codec.hasConfigurationCollection(Data([0, 1]) + descriptor + Data([0xc0])))
        var wrongReport = descriptor
        wrongReport[8] = 7
        #expect(!FlowLite84Codec.hasConfigurationCollection(wrongReport))
        #expect(!FlowLite84Codec.hasConfigurationCollection(Data(descriptor.dropLast())))
    }
}

func fixturePacket(command: UInt8, status: UInt8 = 0, address: UInt16 = 0, count: UInt8 = 0, fields: [UInt8] = []) -> Data {
    var payload = [UInt8](repeating: 0, count: 16)
    payload[0] = command
    payload[1] = status
    payload[2] = UInt8(address >> 8)
    payload[3] = UInt8(address & 0xff)
    payload[4] = count
    for (index, byte) in fields.prefix(10).enumerated() { payload[5 + index] = byte }
    payload[15] = FlowLite84Codec.checksum(payload)
    return Data([8] + payload)
}
