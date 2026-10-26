import Foundation
import XCTest
@testable import HidhoggApp
import HidhoggDomain
import LogitechBolt
import MacOSActions
import UlanziD200X

@MainActor
final class D200XDialBrightnessTests: XCTestCase {
    func testUnboundRotationBurstReappliesConfiguredBrightnessOnce() async throws {
        let session = DialBrightnessSession()
        let model = D200XModel(session: session, sender: makeSender())
        let configuration = D200XConfiguration(brightnessPercent: 62)
        model.synchronize(configuration, canEdit: true)
        model.connect()

        let initialWriteCompleted = await eventually {
            let writes = await session.brightnessWrites()
            return model.isConnected && writes == [62]
        }
        XCTAssertTrue(initialWriteCompleted)

        var rotations = [D200XInput]()
        for index in [17, 18, 19] {
            for state in [2, 3, 4, 5] {
                rotations.append(try input(index: UInt8(index), family: 2, state: UInt8(state)))
            }
        }
        await session.emit(rotations, generation: 1)

        let rotationWriteCompleted = await eventually {
            await session.brightnessWrites().count == 2
        }
        XCTAssertTrue(rotationWriteCompleted)
        try await Task.sleep(for: .milliseconds(200))

        let writes = await session.brightnessWrites()
        XCTAssertEqual(writes, [62, 62])
        XCTAssertEqual(model.configuration?.brightnessPercent, 62)
    }

    func testKeyPressDialPressAndReleaseDoNotReapplyBrightness() async throws {
        let session = DialBrightnessSession()
        let model = D200XModel(session: session, sender: makeSender())
        model.synchronize(D200XConfiguration(brightnessPercent: 70), canEdit: true)
        model.connect()

        let initialWriteCompleted = await eventually {
            let writes = await session.brightnessWrites()
            return model.isConnected && writes == [70]
        }
        XCTAssertTrue(initialWriteCompleted)

        let nonRotations = [
            try input(index: 0, family: 1, state: 1),
            try input(index: 17, family: 2, state: 1),
            try input(index: 17, family: 2, state: 0)
        ]
        await session.emit(nonRotations, generation: 1)
        try await Task.sleep(for: .milliseconds(200))

        let writes = await session.brightnessWrites()
        XCTAssertEqual(writes, [70])
    }

    func testRotationsWithoutBrightnessOverrideDoNotWrite() async throws {
        let session = DialBrightnessSession()
        let model = D200XModel(session: session, sender: makeSender())
        model.synchronize(.empty, canEdit: true)
        model.connect()

        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)
        try await Task.sleep(for: .milliseconds(200))
        await session.emit([
            try input(index: 17, family: 2, state: 2),
            try input(index: 17, family: 2, state: 4)
        ], generation: 1)
        try await Task.sleep(for: .milliseconds(200))

        let writes = await session.brightnessWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    func testDisconnectCancelsPendingRotationBrightnessWrite() async throws {
        let session = DialBrightnessSession()
        let shortcut = KeyboardShortcut(keyCode: 12)
        var posted = [KeyboardShortcut]()
        let model = D200XModel(session: session, sender: makeSender { posted.append($0) })
        model.synchronize(
            D200XConfiguration(
                defaults: [D200XControl.dial0Left.rawValue: .key(shortcut)],
                brightnessPercent: 55
            ),
            canEdit: true
        )
        model.connect()

        let initialWriteCompleted = await eventually {
            let writes = await session.brightnessWrites()
            return model.isConnected && writes == [55]
        }
        XCTAssertTrue(initialWriteCompleted)

        await session.emit([try input(index: 17, family: 2, state: 2)], generation: 1)
        let rotationWasDispatched = await eventually { posted == [shortcut] }
        XCTAssertTrue(rotationWasDispatched)
        model.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        let writes = await session.brightnessWrites()
        XCTAssertEqual(writes, [55])
    }

    func testSpontaneousDisconnectCancelsPendingRotationBrightnessWrite() async throws {
        let session = DialBrightnessSession()
        let shortcut = KeyboardShortcut(keyCode: 12)
        var posted = [KeyboardShortcut]()
        let model = D200XModel(session: session, sender: makeSender { posted.append($0) })
        model.synchronize(
            D200XConfiguration(
                defaults: [D200XControl.dial0Left.rawValue: .key(shortcut)],
                brightnessPercent: 55
            ),
            canEdit: true
        )
        model.connect()

        let initialWriteCompleted = await eventually {
            let writes = await session.brightnessWrites()
            return model.isConnected && writes == [55]
        }
        XCTAssertTrue(initialWriteCompleted)

        await session.emit([try input(index: 17, family: 2, state: 2)], generation: 1)
        let rotationWasDispatched = await eventually { posted == [shortcut] }
        XCTAssertTrue(rotationWasDispatched)
        await session.emitStatus(.disconnected, generation: 1)
        let disconnected = await eventually { !model.isConnected }
        XCTAssertTrue(disconnected)
        try await Task.sleep(for: .milliseconds(200))

        let writes = await session.brightnessWrites()
        XCTAssertEqual(writes, [55])
    }

    private func makeSender(postPair: @escaping (KeyboardShortcut) -> Void = { _ in }) -> ShortcutSender {
        ShortcutSender(preflight: { true }, request: { false }, postPair: postPair)
    }

    private func input(index: UInt8, family: UInt8, state: UInt8) throws -> D200XInput {
        try D200XInput(payload: Data([1, index, family, state]))
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private actor DialBrightnessSession: D200XSessionProtocol {
    nonisolated let events: AsyncStream<D200XSessionEvent>
    private let continuation: AsyncStream<D200XSessionEvent>.Continuation
    private var generation: UInt64 = 0
    private var writes = [Int]()

    init() {
        let stream = AsyncStream<D200XSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws {
        generation &+= 1
        continuation.yield(.status(.connecting, generation: generation))
        continuation.yield(.status(.connected(try identity()), generation: generation))
    }

    func disconnect() async {
        continuation.yield(.status(.disconnected, generation: generation))
    }

    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws {}

    func setBrightness(_ percent: Int) async throws {
        writes.append(percent)
    }

    func emit(_ inputs: [D200XInput], generation: UInt64) {
        for input in inputs {
            continuation.yield(.input(input, generation: generation))
        }
    }

    func emitStatus(_ status: D200XStatus, generation: UInt64) {
        continuation.yield(.status(status, generation: generation))
    }

    func brightnessWrites() -> [Int] { writes }

    private func identity() throws -> D200XIdentity {
        try D200XIdentity(payload: Data(
            #"{"SerialNumber":"02123A04512345678","Dversion":"1.0","HardwareVersion":"1.0"}"#.utf8
        ))
    }
}
