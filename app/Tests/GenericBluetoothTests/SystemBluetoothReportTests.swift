import Foundation
import XCTest
@testable import GenericBluetooth

final class SystemBluetoothReportTests: XCTestCase {
    func testReadsSyntheticOutputWithoutShell() async throws {
        let report = SystemBluetoothReport(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "synthetic fixture"])
        let data = try await report.read()
        XCTAssertEqual(data, Data("synthetic fixture".utf8))
    }

    func testIORegistryReportUsesTheBoundedSyntheticProcessReader() async throws {
        let report = SystemIORegistryBatteryReport(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                                  arguments: ["%s", "synthetic plist"], timeout: 1, maximumBytes: 128)
        let data = try await report.read()
        XCTAssertEqual(data, Data("synthetic plist".utf8))
    }

    func testTimeoutIsBounded() async {
        let report = SystemBluetoothReport(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.03)
        let start = ContinuousClock.now
        do { _ = try await report.read(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? BluetoothObservationFailure, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testOutputLimitIsBounded() async {
        let report = SystemBluetoothReport(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: ["synthetic"], maximumBytes: 100)
        do { _ = try await report.read(); XCTFail("Expected output limit") }
        catch { XCTAssertEqual(error as? BluetoothObservationFailure, .outputLimit) }
    }

    func testCancellationStopsOperation() async {
        let report = SystemBluetoothReport(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        let task = Task { try await report.read() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? BluetoothObservationFailure, .cancelled) }
    }

    func testCancellationStopsAlreadyStartedChild() async {
        let started = expectation(description: "Synthetic child started")
        let report = SystemBluetoothReport(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], started: { started.fulfill() })
        let task = Task { try await report.read() }
        await fulfillment(of: [started], timeout: 2)
        let cancellation = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? BluetoothObservationFailure, .cancelled) }
        XCTAssertLessThan(cancellation.duration(to: .now), .seconds(2))
    }

    func testLaunchAndNonzeroFailureAreTyped() async {
        for report in [SystemBluetoothReport(executable: URL(fileURLWithPath: "/synthetic/no-executable")),
                       SystemBluetoothReport(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])] {
            do { _ = try await report.read(); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? BluetoothObservationFailure, .reportFailed) }
        }
    }
}
