import XCTest
import LogitechBolt
@testable import HidhoggApp

@MainActor
final class DiagnosticsStoreTests: XCTestCase {
    func testRecentHistoryIsBoundedAndPersistentSinkReceivesEveryEntry() {
        var persisted = [String]()
        let store = DiagnosticsStore(persist: { message, _ in persisted.append(message) })
        XCTAssertEqual(
            store.entries.first?.message,
            "Process \(ApplicationIdentity.current.processID); build \(ApplicationIdentity.current.buildID.prefix(12))."
        )
        let initialEntryCount = store.entries.count
        let initialPersistedCount = persisted.count
        XCTAssertEqual(initialPersistedCount, initialEntryCount)
        for index in 0..<125 {
            store.record(DiagnosticEvent(code: .applicationStarted, message: "Event \(index)"))
        }
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertEqual(store.entries.first?.message, "Event 25")
        XCTAssertEqual(store.entries.last?.message, "Event 124")
        XCTAssertEqual(persisted.count - initialPersistedCount, 125)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testVisibleEntryAndPersistentRecordShareStableIdentityAndSafeSource() throws {
        var persisted = [(String, Bool)]()
        let store = DiagnosticsStore(persist: { message, isError in persisted.append((message, isError)) })
        persisted.removeAll()
        let id = UUID(uuidString: "D2E42C75-91E1-4E1F-8A2F-61EAB31D9E14")!
        let event = DiagnosticEvent(
            id: id,
            code: .configurationSaveFailed,
            message: "Configuration could not be saved.",
            isError: true,
            fileID: "/private/build/HidhoggApp/AppModel.swift",
            line: 42
        )

        store.record(event)

        let entry = try XCTUnwrap(store.entries.last)
        let persistedRecord = try XCTUnwrap(persisted.last)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.code, .configurationSaveFailed)
        XCTAssertEqual(entry.message, "Configuration could not be saved.")
        XCTAssertEqual(entry.source.description, "HidhoggApp/AppModel.swift:42")
        XCTAssertEqual(persistedRecord.0, entry.consoleMessage)
        XCTAssertTrue(persistedRecord.0.contains("id=\(id.uuidString)"))
        XCTAssertTrue(persistedRecord.0.contains("code=configuration.save.failed"))
        XCTAssertTrue(persistedRecord.0.contains("build=\(ApplicationIdentity.current.buildID)"))
        XCTAssertTrue(persistedRecord.0.contains("source=HidhoggApp/AppModel.swift:42"))
        XCTAssertTrue(persistedRecord.1)
        XCTAssertFalse(persistedRecord.0.contains("/private/build"))
    }

    func testDiagnosticCodeCatalogIsUniqueAndBoltTokenFailureStaysDistinctFromAmbiguity() {
        let codes = DiagnosticCode.allCases.map(\.rawValue)
        XCTAssertEqual(Set(codes).count, codes.count)

        let ambiguous = DiagnosticCode.boltFailure(.endpointAmbiguous)
        let exhausted = DiagnosticCode.boltFailure(.requestIDsExhausted)
        XCTAssertNotEqual(ambiguous, exhausted)
        XCTAssertEqual(ambiguous.rawValue, "bolt.endpoint.ambiguous")
        XCTAssertEqual(exhausted.rawValue, "bolt.request-id.exhausted")
    }

    func testBoltStatusTransitionsDeduplicateByChannelAndReturnAfterAbsence() {
        let store = DiagnosticsStore(persist: { _, _ in })
        let timeout = BoltStatus(
            phase: .failed,
            message: "The Bolt request timed out.",
            availableControls: [],
            generation: 1,
            cleanupUncertain: false,
            failure: BoltFailureContext(
                code: .requestTimeout,
                sourceFileID: "LogitechBolt/BoltController.swift",
                sourceLine: 1083
            )
        )
        let connectedWithReadyWheels = BoltStatus(
            phase: .ready,
            message: "Connected.",
            availableControls: [],
            generation: 2,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(message: "Wheel ready."),
            thumbwheel: BoltThumbwheelStatus(message: "Thumb-wheel ready.")
        )
        let connectedWithUpdatedWheel = BoltStatus(
            phase: .ready,
            message: "Connected.",
            availableControls: [],
            generation: 2,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(message: "Wheel calibrated."),
            thumbwheel: BoltThumbwheelStatus(message: "Thumb-wheel ready.")
        )

        store.recordBoltStatus(timeout)
        XCTAssertEqual(store.entries.first(where: { $0.code == .boltRequestTimeout })?.message, "The Bolt request timed out.")
        store.recordBoltStatus(connectedWithReadyWheels)
        store.recordBoltStatus(connectedWithUpdatedWheel)

        XCTAssertEqual(store.entries.filter { $0.code == .boltStatus }.count, 1)
        XCTAssertEqual(store.entries.filter { $0.code == .boltWheelStatus }.count, 2)
        XCTAssertEqual(store.entries.filter { $0.code == .boltThumbwheelStatus }.count, 1)

        store.recordBoltStatus(timeout)
        let timeouts = store.entries.filter { $0.code == .boltRequestTimeout }
        XCTAssertEqual(timeouts.count, 2)
        XCTAssertNotEqual(timeouts[0].id, timeouts[1].id)

        let blockedWheel = BoltStatus(
            phase: .ready,
            message: "Connected.",
            availableControls: [],
            generation: 2,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(message: "Wheel calibrated.", captureBlocker: "Posting permission is required."),
            thumbwheel: BoltThumbwheelStatus(message: "Thumb-wheel ready.")
        )
        let clearedBlocker = BoltStatus(
            phase: .ready,
            message: "Connected.",
            availableControls: [],
            generation: 2,
            cleanupUncertain: false,
            wheel: BoltWheelStatus(message: "Wheel calibrated."),
            thumbwheel: BoltThumbwheelStatus(message: "Thumb-wheel ready.")
        )
        store.recordBoltStatus(blockedWheel)
        store.recordBoltStatus(clearedBlocker)
        store.recordBoltStatus(blockedWheel)

        let blockers = store.entries.filter { $0.code == .boltWheelCaptureBlocker }
        XCTAssertEqual(blockers.count, 2)
        XCTAssertNotEqual(blockers[0].id, blockers[1].id)
        XCTAssertEqual(store.entries.filter { $0.code == .boltStatus }.count, 2)
    }

    func testBoltFailureStageAppearsInMessageAndPersistentLog() throws {
        var persisted = [String]()
        let store = DiagnosticsStore(persist: { message, _ in persisted.append(message) })
        persisted.removeAll()
        let status = BoltStatus(
            phase: .failed,
            message: "The Bolt transport failed.",
            availableControls: [],
            generation: 1,
            cleanupUncertain: false,
            failure: BoltFailureContext(
                code: .transportFailed,
                sourceFileID: "LogitechBolt/BoltController.swift",
                sourceLine: 1083,
                stage: .buttonReadbackForward
            )
        )

        store.recordBoltStatus(status)

        let entry = try XCTUnwrap(store.entries.last)
        let logLine = try XCTUnwrap(persisted.last)
        XCTAssertEqual(entry.message, "The Bolt transport failed. Failure stage: button-readback-forward.")
        XCTAssertEqual(logLine, entry.consoleMessage)
        XCTAssertNil(BoltFailureContext(code: .transportFailed, sourceFileID: "test", sourceLine: 1).stage)
    }
}
