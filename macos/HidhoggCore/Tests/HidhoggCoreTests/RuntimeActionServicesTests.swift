import Foundation
import XCTest
@testable import HidhoggCore

final class RuntimeActionServicesTests: XCTestCase {
    func testSynchronousRouterAdmitsOnlyExecutionAndNativeInputActions() async throws {
        let runner = RuntimeFakeProcessRunner(termination: .exited(0))
        let nativeBackend = RuntimeFakeNativeInputBackend()
        let services = RuntimeActionServices(
            runner: runner,
            nativeInputBackend: nativeBackend,
            clock: SystemRuntimeMonotonicClock(),
            wallDateAnchor: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let execution = services.execution
        let nativeInput = services.nativeInput

        services.admit(RuntimeServiceTestValues.executeRequest(arguments: ["literal value"]))
        services.admit(RuntimeServiceTestValues.textRequest("ordered text"))
        services.admit(RuntimeServiceTestValues.enterRequest())
        services.admit(RuntimeStaticActionRequest(
            profileID: "default",
            coordinate: "0_0",
            action: .activateProfile(profileID: "other", gesture: .release)
        ))

        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        let complete = await RuntimeServiceTestValues.eventually {
            nativeBackend.events.values.count == 4 &&
                (try? nativeInput.listSummaries(limit: 32).count) == 2
        }
        XCTAssertTrue(complete)
        XCTAssertEqual(runner.launches.count, 1)
        XCTAssertEqual(runner.launches.first?.arguments, ["literal value"])
        XCTAssertEqual(nativeBackend.payloads, [.text("ordered text"), .enter])
        XCTAssertEqual(nativeBackend.events.values, ["down", "up", "down", "up"])

        execution.stop()
        nativeInput.stop()
        let executionStopped = await execution.waitUntilStopped()
        let nativeStopped = await nativeInput.waitUntilStopped()
        XCTAssertEqual(executionStopped, .closed)
        XCTAssertEqual(nativeStopped, .closed)
    }

    func testSimulatedSelectionSkipsNativeAdapterFactoriesAndRejectsActionsSafely() async throws {
        let factoryCalls = RuntimeServiceTestRecorder<String>()
        let services = RuntimeActionServices.make(
            selection: .simulated,
            clock: SystemRuntimeMonotonicClock(),
            wallDateAnchor: Date(timeIntervalSince1970: 1_700_000_000),
            makeNativeProcessRunner: {
                factoryCalls.append("process")
                return RuntimeFakeProcessRunner(termination: .exited(0))
            },
            makeNativeInputBackend: {
                factoryCalls.append("input")
                return RuntimeFakeNativeInputBackend(permission: .granted)
            }
        )

        XCTAssertEqual(factoryCalls.values, [])
        XCTAssertEqual(services.nativeInput.status().permission, .denied)
        XCTAssertEqual(services.nativeInput.requestPermission(), .denied)
        services.admit(RuntimeServiceTestValues.executeRequest(arguments: ["literal value"]))

        let executionRecorded = await RuntimeServiceTestValues.eventually {
            (try? services.execution.listSummaries(limit: 32).first?.state) == .startFailed
        }
        XCTAssertTrue(executionRecorded)
        XCTAssertEqual(factoryCalls.values, [])

        services.stop()
        let stopOutcome = await services.waitUntilStopped()
        XCTAssertEqual(stopOutcome, .closed)
    }

    func testDateConversionUsesOneMonotonicAnchorWithSubsecondAndEarlierInstants() {
        let anchor = RuntimeMonotonicInstant(durationFromOrigin: .seconds(20))
        let clock = RuntimeActionServicesTestClock(instant: anchor)
        let wallDate = Date(timeIntervalSince1970: 1_700_000_000.125)
        let services = RuntimeActionServices(
            runner: RuntimeFakeProcessRunner(termination: .exited(0)),
            nativeInputBackend: RuntimeFakeNativeInputBackend(),
            clock: clock,
            wallDateAnchor: wallDate
        )

        XCTAssertNil(services.date(for: nil))
        XCTAssertEqual(services.date(for: anchor)?.timeIntervalSince1970, wallDate.timeIntervalSince1970)
        XCTAssertEqual(
            services.date(for: anchor.advanced(by: .milliseconds(275)))?.timeIntervalSince1970 ?? .nan,
            wallDate.addingTimeInterval(0.275).timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            services.date(for: anchor.advanced(by: .milliseconds(-375)))?.timeIntervalSince1970 ?? .nan,
            wallDate.addingTimeInterval(-0.375).timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }
}

private struct RuntimeActionServicesTestClock: RuntimeMonotonicClock {
    let instant: RuntimeMonotonicInstant

    func now() -> RuntimeMonotonicInstant { instant }

    func sleep(until deadline: RuntimeMonotonicInstant) async throws {
        if deadline > instant { try await Task.sleep(for: deadline.durationFromOrigin - instant.durationFromOrigin) }
    }
}
