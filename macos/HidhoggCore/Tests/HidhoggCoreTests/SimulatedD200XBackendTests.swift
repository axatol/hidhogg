import Foundation
import XCTest
@testable import HidhoggCore

final class SimulatedD200XBackendTests: XCTestCase {
    func testSimulationFactoryNeverConstructsNativeBackendAndModelsTypedOperations() async throws {
        let nativeConstructions = D200XTestCounter()
        let control = D200XSimulatorControl()
        let factory = D200XDeviceSessionFactory(
            makeNativeBackend: {
                nativeConstructions.increment()
                return D200XFakeSessionBackend()
            },
            makeSimulatedBackend: { SimulatedD200XBackend(control: control) }
        )
        let session = factory.make(selection: .simulated)
        let candidates = try await session.candidates()
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertTrue(candidate.isEligible)
        XCTAssertEqual(nativeConstructions.value, 0)

        let inputs = D200XTestRecorder<D200XInputEvent>()
        let failures = D200XTestRecorder<D200XSessionFailure>()
        try await session.open(candidate, onInput: { inputs.append($0) }, onFailure: { failures.append($0) })

        let initialPage = try D200XPageRenderer.render(profile: decodeD200XProfile())
        let replacementPage = try D200XPageRenderer.render(profile: decodeD200XProfile(positionFields: [
            "0_0": "label = \"Replacement\"",
        ]))
        try await session.perform(.startup(page: initialPage, brightness: 37))

        XCTAssertTrue(control.isScreenUnlocked)
        XCTAssertEqual(control.displayArchive, initialPage.archive.data)
        XCTAssertEqual(control.brightness, 37)
        XCTAssertTrue(control.isInputStreamEnabled)
        XCTAssertEqual(control.inputStreamEnableCountValue, 1)

        try await session.perform(.redraw(page: replacementPage))
        try await session.perform(.setBrightness(6))
        try await session.perform(.keepAlive)

        XCTAssertEqual(control.displayArchive, replacementPage.archive.data)
        XCTAssertEqual(control.brightness, 6)
        XCTAssertTrue(control.isInputStreamEnabled)
        XCTAssertEqual(control.inputStreamEnableCountValue, 2)
        XCTAssertEqual(
            control.receivedFrames.map(\.command),
            [0x0010, 0x0001, 0x000a, 0x0002, 0x0001, 0x000a, 0x0002]
        )
        XCTAssertEqual(nativeConstructions.value, 0)

        let expectedInput = D200XInputEvent(
            deviceState: 0xa7,
            wireIndex: 13,
            marker: 0xf2,
            action: 0xf3,
            rawPayload: Data([0xa7, 13, 0xf2, 0xf3, 0x44])
        )
        control.emitInputReport(inputReport(expectedInput.rawPayload))
        XCTAssertEqual(inputs.received.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(inputs.values, [expectedInput])
        XCTAssertTrue(failures.values.isEmpty)

        session.stop()
        let stopOutcome = await session.waitUntilStopped()
        XCTAssertEqual(stopOutcome, .closed)
        control.emitInputReport(inputReport(expectedInput.rawPayload))
        XCTAssertEqual(inputs.values, [expectedInput])
    }

    func testStartupWriteFaultStopsBeforeBrightnessAndInputEnable() async throws {
        let control = D200XSimulatorControl()
        control.failReportWrite(at: 4)
        let session = D200XSession(backend: SimulatedD200XBackend(control: control))
        let failures = D200XTestRecorder<D200XSessionFailure>()
        let candidates = try await session.candidates()
        let candidate = try XCTUnwrap(candidates.first)
        try await session.open(candidate, onInput: { _ in }, onFailure: { failures.append($0) })
        let page = try D200XPageRenderer.render(profile: decodeD200XProfile())

        do {
            try await session.perform(.startup(page: page, brightness: 55))
            XCTFail("expected the simulated report write to fail")
        } catch {
            XCTAssertEqual(error as? D200XSessionError, .writeFailed)
        }

        XCTAssertEqual(failures.values, [.writeFailed])
        XCTAssertEqual(control.reportWriteAttempts, 4)
        XCTAssertEqual(control.receivedFrames.map(\.command), [0x0010, 0x0001])
        XCTAssertTrue(control.isScreenUnlocked)
        XCTAssertEqual(control.displayArchive, page.archive.data)
        XCTAssertNil(control.brightness)
        XCTAssertFalse(control.isInputStreamEnabled)
        let stopOutcome = await session.waitUntilStopped()
        XCTAssertEqual(stopOutcome, .closed)
        XCTAssertEqual(control.reportWriteAttempts, 4)
    }

    func testSimulatedRemovalFailsSessionAndPreventsLaterWrites() async throws {
        let control = D200XSimulatorControl()
        let session = D200XSession(backend: SimulatedD200XBackend(control: control))
        let failures = D200XTestRecorder<D200XSessionFailure>()
        let candidates = try await session.candidates()
        let candidate = try XCTUnwrap(candidates.first)
        try await session.open(candidate, onInput: { _ in }, onFailure: { failures.append($0) })

        control.removeDevice()

        XCTAssertEqual(failures.received.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(failures.values, [.deviceRemoved])
        XCTAssertTrue(control.deviceRemoved)
        do {
            try await session.perform(.keepAlive)
            XCTFail("expected a removed simulated device to reject writes")
        } catch {
            XCTAssertTrue(error is D200XSessionError)
        }
        XCTAssertEqual(control.reportWriteAttempts, 0)
        let stopOutcome = await session.waitUntilStopped()
        XCTAssertEqual(stopOutcome, .closed)
    }

    private func inputReport(_ payload: Data) -> Data {
        var report = Data(repeating: 0, count: D200XFrameCodec.packetSize)
        report[0] = 0x7c
        report[1] = 0x7c
        report[2] = 0x01
        report[3] = 0x01
        report[4] = UInt8(payload.count & 0xff)
        report[5] = UInt8((payload.count >> 8) & 0xff)
        report[6] = UInt8((payload.count >> 16) & 0xff)
        report[7] = UInt8((payload.count >> 24) & 0xff)
        report.replaceSubrange(8..<(8 + payload.count), with: payload)
        return report
    }
}
