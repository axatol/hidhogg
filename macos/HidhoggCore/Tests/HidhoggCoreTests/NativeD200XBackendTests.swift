import Foundation
import XCTest
@testable import HidhoggCore

final class NativeD200XBackendTests: XCTestCase {
    func testCandidateMetadataRequiresExactIdentityUSBInterfaceReportSizeAndUsagePair() {
        let valid = deviceProperties()
        let usb = [["bInterfaceNumber": NSNumber(value: 0)]]
        XCTAssertNotNil(candidate(properties: valid, parents: usb))

        for key in ["VendorID", "ProductID", "DeviceUsagePairs", "MaxOutputReportSize"] {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertNil(candidate(properties: missing, parents: usb), "missing \(key)")
        }

        let wrongTypes: [(String, Any)] = [
            ("VendorID", "8711"),
            ("VendorID", NSNumber(value: true)),
            ("VendorID", NSNumber(value: 8711.0)),
            ("ProductID", "25"),
            ("ProductID", NSNumber(value: true)),
            ("ProductID", NSNumber(value: 25.0)),
            ("MaxOutputReportSize", "1024"),
            ("MaxOutputReportSize", NSNumber(value: true)),
            ("MaxOutputReportSize", NSNumber(value: 1024.0)),
            ("DeviceUsagePairs", "usage pair"),
            ("DeviceUsagePairs", [["DeviceUsagePage": "12", "DeviceUsage": NSNumber(value: 1)]]),
            ("DeviceUsagePairs", [["DeviceUsagePage": NSNumber(value: 12.0), "DeviceUsage": NSNumber(value: 1)]]),
            ("DeviceUsagePairs", [["DeviceUsagePage": NSNumber(value: 12), "DeviceUsage": NSNumber(value: 1.0)]]),
        ]
        for (key, value) in wrongTypes {
            var invalid = valid
            invalid[key] = value
            XCTAssertNil(candidate(properties: invalid, parents: usb), "wrong type for \(key)")
        }

        let wrongValues: [(String, Any)] = [
            ("VendorID", NSNumber(value: -1)),
            ("VendorID", NSNumber(value: 0x2208)),
            ("ProductID", NSNumber(value: -1)),
            ("ProductID", NSNumber(value: 0x0020)),
            ("MaxOutputReportSize", NSNumber(value: -1)),
            ("MaxOutputReportSize", NSNumber(value: 1025)),
            ("MaxOutputReportSize", NSNumber(value: UInt64.max)),
            ("DeviceUsagePairs", [["DeviceUsagePage": NSNumber(value: -1), "DeviceUsage": NSNumber(value: 1)]]),
            ("DeviceUsagePairs", [["DeviceUsagePage": NSNumber(value: 0x000c), "DeviceUsage": NSNumber(value: -1)]]),
            ("DeviceUsagePairs", [usagePair(page: 0x000c, usage: 0x0002)]),
            ("DeviceUsagePairs", [usagePair(page: 0x000b, usage: 0x0001)]),
        ]
        for (key, value) in wrongValues {
            var invalid = valid
            invalid[key] = value
            XCTAssertNil(candidate(properties: invalid, parents: usb), "wrong value for \(key)")
        }

        XCTAssertNil(candidate(properties: valid, parents: []), "USB interface parent is absent")
        XCTAssertNil(candidate(properties: valid, parents: [["ProductID": NSNumber(value: 25)]]), "USB interface property is absent")
        XCTAssertNil(candidate(properties: valid, parents: [["bInterfaceNumber": "0"]]), "USB interface property is not numeric")
        XCTAssertNil(candidate(properties: valid, parents: [["bInterfaceNumber": NSNumber(value: true)]]), "USB interface property is boolean")
        XCTAssertNil(candidate(properties: valid, parents: [["bInterfaceNumber": NSNumber(value: 0.0)]]), "USB interface property is an integral float")
        XCTAssertNil(candidate(properties: valid, parents: [["bInterfaceNumber": NSNumber(value: -1)]]), "USB interface property is negative")
        XCTAssertNil(candidate(properties: valid, parents: [["bInterfaceNumber": NSNumber(value: 1)]]), "wrong USB interface")
    }

    func testTargetUsagePairIsAuthoritativeWhenScalarUsagePropertiesAreAbsentOrDiffer() throws {
        var missingScalars = deviceProperties()
        missingScalars.removeValue(forKey: "DeviceUsagePage")
        missingScalars.removeValue(forKey: "DeviceUsage")
        let missing = try XCTUnwrap(candidate(properties: missingScalars, parents: [["bInterfaceNumber": NSNumber(value: 0)]]))
        XCTAssertEqual(missing.usagePage, 0x000c)
        XCTAssertEqual(missing.usage, 0x0001)

        var mismatchedScalars = deviceProperties()
        mismatchedScalars["DeviceUsagePage"] = NSNumber(value: 0x000b)
        mismatchedScalars["DeviceUsage"] = NSNumber(value: 0x0002)
        mismatchedScalars["DeviceUsagePairs"] = [
            usagePair(page: 0x000b, usage: 0x0002),
            usagePair(page: 0x000c, usage: 0x0001),
        ]
        let multiple = try XCTUnwrap(candidate(properties: mismatchedScalars, parents: [["bInterfaceNumber": NSNumber(value: 0)]]))
        XCTAssertEqual(multiple.usagePage, 0x000c)
        XCTAssertEqual(multiple.usage, 0x0001)
    }

    func testNativeCloseFailureIsReportedAsCleanupUncertain() {
        XCTAssertEqual(D200XNativeCloseResult.stopOutcome(status: 0), .closed)
        XCTAssertEqual(D200XNativeCloseResult.stopOutcome(status: -1), .cleanupUncertain)
    }

    func testTimedOutDelayedInputLoopStartupCancelsAndDrainsWithoutInstallingSource() {
        let delay = D200XTestGate()
        let threadExited = DispatchSemaphore(value: 0)
        let stopCompleted = DispatchSemaphore(value: 0)
        let cleanupCalls = D200XTestCounter()
        let outcomes = D200XTestRecorder<D200XSessionStopOutcome>()
        let loop = D200XNativeInputLoop(
            startupTimeout: 0.03,
            beforeRunLoopStart: { delay.pause() },
            onThreadExit: { threadExited.signal() }
        )

        XCTAssertEqual(delay.entered.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertFalse(loop.isReady)
        loop.stop(
            cleanup: {
                cleanupCalls.increment()
                return .closed
            },
            completion: { outcome in
                outcomes.append(outcome)
                stopCompleted.signal()
            }
        )

        XCTAssertEqual(stopCompleted.wait(timeout: .now() + .milliseconds(50)), .timedOut)
        delay.open()

        XCTAssertEqual(threadExited.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(stopCompleted.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(cleanupCalls.value, 0)
        XCTAssertEqual(outcomes.values, [.closed])
        XCTAssertFalse(loop.isReady)
    }

    func testConcurrentStopsJoinCleanupOutcomeAfterCallbackResourcesAreReleased() async {
        let callbackReleaseGate = D200XTestGate()
        let secondWaiterRegistered = DispatchSemaphore(value: 0)
        let cleanupCalls = D200XTestCounter()
        let firstOutcome = D200XTestRecorder<D200XSessionStopOutcome>()
        let secondOutcome = D200XTestRecorder<D200XSessionStopOutcome>()
        let backend = NativeD200XBackend(
            inputLoopForTesting: D200XNativeInputLoop(),
            stopCleanupForTesting: {
                cleanupCalls.increment()
                return .cleanupUncertain
            },
            afterCallbackResourceReleaseForTesting: { callbackReleaseGate.pause() },
            stopWaiterObserverForTesting: { count in
                if count == 2 { secondWaiterRegistered.signal() }
            }
        )

        let first = Task { firstOutcome.append(await backend.stop()) }
        XCTAssertEqual(callbackReleaseGate.entered.wait(timeout: .now() + .seconds(2)), .success)
        let second = Task { secondOutcome.append(await backend.stop()) }
        XCTAssertEqual(secondWaiterRegistered.wait(timeout: .now() + .seconds(1)), .success)

        XCTAssertEqual(firstOutcome.received.wait(timeout: .now() + .milliseconds(50)), .timedOut)
        XCTAssertEqual(secondOutcome.received.wait(timeout: .now() + .milliseconds(50)), .timedOut)
        callbackReleaseGate.open()

        XCTAssertEqual(firstOutcome.received.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(secondOutcome.received.wait(timeout: .now() + .seconds(1)), .success)
        await first.value
        await second.value
        XCTAssertEqual(firstOutcome.values, [.cleanupUncertain])
        XCTAssertEqual(secondOutcome.values, [.cleanupUncertain])
        let repeatedOutcome = await backend.stop()
        XCTAssertEqual(repeatedOutcome, .cleanupUncertain)
        XCTAssertEqual(cleanupCalls.value, 1)
    }

    private func candidate(properties: [String: Any], parents: [[String: Any]]) -> D200XDeviceCandidate? {
        D200XNativeCandidateValidator.candidate(registryID: 91, deviceProperties: properties, usbParentProperties: parents)
    }

    private func deviceProperties() -> [String: Any] {
        [
            "VendorID": NSNumber(value: 0x2207),
            "ProductID": NSNumber(value: 0x0019),
            "DeviceUsagePage": NSNumber(value: 0x000c),
            "DeviceUsage": NSNumber(value: 0x0001),
            "DeviceUsagePairs": [usagePair(page: 0x000c, usage: 0x0001)],
            "MaxOutputReportSize": NSNumber(value: 1024),
        ]
    }

    private func usagePair(page: UInt16, usage: UInt16) -> [String: NSNumber] {
        ["DeviceUsagePage": NSNumber(value: page), "DeviceUsage": NSNumber(value: usage)]
    }
}
