import Foundation
import XCTest
@testable import HidhoggCore

final class IPCDiscoveryTests: XCTestCase {
    func testMetadataRoundTripsOnlyTheClosedRuntimeIdentityShape() throws {
        let bytes = Data("{\"schema_version\":1,\"instance_id\":\"22222222-2222-4222-8222-222222222222\",\"socket_name\":\"runtime.sock\"}".utf8)
        let metadata = try IPCMetadata.decode(bytes)
        XCTAssertEqual(metadata.schemaVersion, 1)
        XCTAssertEqual(metadata.instanceID, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(metadata.socketName, "runtime.sock")
        XCTAssertEqual(try IPCMetadata.decode(metadata.encode()), metadata)
    }

    func testMetadataRejectsDuplicateUnknownAndNoncanonicalFields() {
        let invalid = [
            "{\"schema_version\":1,\"instance_id\":\"22222222-2222-4222-8222-222222222222\",\"socket_name\":\"runtime.sock\",\"extra\":true}",
            "{\"schema_version\":1,\"schema_version\":1,\"instance_id\":\"22222222-2222-4222-8222-222222222222\",\"socket_name\":\"runtime.sock\"}",
            "{\"schema_version\":1.0,\"instance_id\":\"22222222-2222-4222-8222-222222222222\",\"socket_name\":\"runtime.sock\"}",
            "{\"schema_version\":1,\"instance_id\":\"22222222-2222-4222-8222-22222222222Z\",\"socket_name\":\"runtime.sock\"}",
            "{\"schema_version\":1,\"instance_id\":\"22222222-2222-4222-8222-222222222222\",\"socket_name\":\"other.sock\"}",
        ]

        for raw in invalid {
            XCTAssertThrowsError(try IPCMetadata.decode(Data(raw.utf8)))
        }
    }

    func testRuntimePathsNormalizeAndRejectRelativeOrOverlongSocketNames() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let paths = try IPCRuntimePaths(directory: temporary.path)
        XCTAssertEqual(paths.directory, temporary.standardizedFileURL.path)
        XCTAssertEqual(paths.socketPath, temporary.appendingPathComponent("runtime.sock").path)
        XCTAssertThrowsError(try IPCRuntimePaths(directory: "relative/runtime"))

        let overlong = "/" + String(repeating: "x", count: 110)
        XCTAssertThrowsError(try IPCRuntimePaths(directory: overlong))
    }
}
