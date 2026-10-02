import Foundation
import XCTest
@testable import HidhoggCore

final class RuntimeCoordinatorTests: XCTestCase {
    func testStartupUnknownAndCurrentActivationAndSuccessfulProfilePublication() async throws {
        let configuration = try decode(runtimeSource())
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: configuration, session: session, clock: RuntimeTestClock())

        try await runtime.start()
        let started = await runtime.snapshot()
        XCTAssertEqual(started.lifecycle, .running)
        XCTAssertEqual(started.profileID, "default")
        XCTAssertEqual(started.revision, 1)
        let view = await runtime.configurationView()
        XCTAssertEqual(view.configuration, configuration)
        XCTAssertEqual(view.snapshot, started)
        XCTAssertEqual(session.batches.count, 1)
        if case .startup = session.batches[0] {} else { XCTFail("startup batch was not first") }

        let current = try await runtime.activateProfile("default")
        XCTAssertFalse(current.changed)
        XCTAssertEqual(session.batches.count, 1)

        do {
            _ = try await runtime.activateProfile("unknown")
            XCTFail("unknown profile activation succeeded")
        } catch let error as RuntimeCoordinatorError {
            XCTAssertEqual(error, .unknownProfile)
        }
        XCTAssertEqual(session.batches.count, 1)

        let activated = try await runtime.activateProfile("alternate")
        XCTAssertTrue(activated.changed)
        XCTAssertEqual(activated.revision, 2)
        let activatedSnapshot = await runtime.snapshot()
        XCTAssertEqual(activatedSnapshot.profileID, "alternate")
        XCTAssertEqual(session.batches.count, 2)
        if case .redraw = session.batches[1] {} else { XCTFail("profile activation did not redraw") }
        let stopOutcome = await runtime.stop()
        XCTAssertEqual(stopOutcome, .closed)
    }

    func testNotificationValidationMatchesASCIIAndVisibleTextContract() {
        let valid = [
            RuntimeNotificationRequest(source: "a", text: "notice"),
            RuntimeNotificationRequest(source: String(repeating: "a", count: 64), text: String(repeating: "x", count: 64), ttlSeconds: 1),
            RuntimeNotificationRequest(source: "alerts.v2_test-1", text: String(repeating: "😀", count: 64), ttlSeconds: 86_400),
            RuntimeNotificationRequest(source: "accent", text: "e\u{0301}"),
            RuntimeNotificationRequest(source: "mixed", text: "A\u{0378}\u{E000}"),
        ]
        for request in valid {
            XCTAssertTrue(RuntimeNotificationValidation.isValid(request), "unexpected rejection: \(request.source)")
        }

        let invalid = [
            RuntimeNotificationRequest(source: "", text: "visible"),
            RuntimeNotificationRequest(source: "_alerts", text: "visible"),
            RuntimeNotificationRequest(source: "é", text: "visible"),
            RuntimeNotificationRequest(source: String(repeating: "a", count: 65), text: "visible"),
            RuntimeNotificationRequest(source: "alerts", text: ""),
            RuntimeNotificationRequest(source: "alerts", text: "   "),
            RuntimeNotificationRequest(source: "alerts", text: "\u{0301}"),
            RuntimeNotificationRequest(source: "alerts", text: "\u{0378}"),
            RuntimeNotificationRequest(source: "alerts", text: "\u{E000}"),
            RuntimeNotificationRequest(source: "alerts", text: "a\n"),
            RuntimeNotificationRequest(source: "alerts", text: "a\u{200E}"),
            RuntimeNotificationRequest(source: "alerts", text: "a\u{2028}"),
            RuntimeNotificationRequest(source: "alerts", text: String(repeating: "x", count: 65)),
            RuntimeNotificationRequest(source: "alerts", text: String(repeating: "😀", count: 65)),
            RuntimeNotificationRequest(source: "alerts", text: "visible", ttlSeconds: 0),
            RuntimeNotificationRequest(source: "alerts", text: "visible", ttlSeconds: 86_401),
        ]
        for request in invalid {
            XCTAssertFalse(RuntimeNotificationValidation.isValid(request), "unexpected acceptance: \(request.source)")
        }

        XCTAssertTrue(RuntimeNotificationValidation.isValidID("00000000-0000-0000-0000-000000000000"))
        XCTAssertFalse(RuntimeNotificationValidation.isValidID("00000000-0000-0000-0000-00000000000A"))
        XCTAssertFalse(RuntimeNotificationValidation.isValidID("000000000000000000000000000000000000"))
    }

    func testNotificationEmissionMatchesSourcesReplacesTilesAndClearsByExactID() async throws {
        let source = runtimeSource(
            defaultAction: nil,
            idleTimeout: 0,
            defaultNotificationSources: ["Alerts", "alerts.v2"],
            additionalPositionSources: ["alerts.v2"]
        )
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: decode(source), session: session, clock: RuntimeTestClock())
        try await runtime.start()

        let wrongCase = try await runtime.emitNotification(RuntimeNotificationRequest(source: "ALERTS.V2", text: "ignored"))
        XCTAssertEqual(wrongCase.matchedCount, 0)
        XCTAssertEqual(session.batches.count, 1)

        let exactOtherSource = try await runtime.emitNotification(RuntimeNotificationRequest(source: "Alerts", text: "One tile"))
        XCTAssertEqual(exactOtherSource.matchedCount, 1)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "One tile")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[1].label, "Additional button")

        let first = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts.v2", text: "First", ttlSeconds: 20))
        XCTAssertEqual(first.matchedCount, 2)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "First")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[1].label, "First")

        let replacement = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts.v2", text: "Replacement"))
        XCTAssertEqual(replacement.matchedCount, 2)
        XCTAssertNotEqual(replacement.notificationID, first.notificationID)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Replacement")

        let oldClear = try await runtime.clearNotification(id: first.notificationID)
        XCTAssertEqual(oldClear.clearedCount, 0)
        let newClear = try await runtime.clearNotification(id: replacement.notificationID)
        XCTAssertEqual(newClear.clearedCount, 2)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Default button")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[1].label, "Additional button")
        let repeatedClear = try await runtime.clearNotification(id: replacement.notificationID)
        XCTAssertEqual(repeatedClear.clearedCount, 0)
        _ = await runtime.stop()
    }

    func testNotificationTTLStartsAfterPageCommitExpiresAtEqualityAndDoesNotBrighten() async throws {
        let clock = RuntimeTestClock()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: nil, idleTimeout: 5, defaultNotificationSources: ["alerts"])),
            session: session,
            clock: clock
        )
        try await runtime.start()
        session.pauseNextPerform()

        let emit = Task {
            try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Timed", ttlSeconds: 5))
        }
        await session.waitForPausedPerform()
        clock.advanceWithoutWaking(by: .seconds(100))
        await session.resumePausedPerform()
        let result = try await emit.value
        XCTAssertEqual(result.matchedCount, 1)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Timed")

        let didDim = await waitForDimmed(runtime)
        XCTAssertTrue(didDim)
        clock.advance(by: .seconds(4))
        for _ in 0..<100 { await Task.yield() }
        let stillDimmed = await runtime.snapshot()
        XCTAssertTrue(stillDimmed.dimmed)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Timed")

        clock.advance(by: .seconds(1))
        let expired = await waitForLastPageLabel("Default button", on: session)
        XCTAssertTrue(expired)
        let laterBatches = Array(session.batches.dropFirst(2))
        XCTAssertFalse(laterBatches.contains { batch in
            if case .setBrightness(72) = batch { return true }
            return false
        }, "notification expiry must not restore configured brightness")
        _ = await runtime.stop()
    }

    func testNotificationExpiryCatchesUpAdjacentDeadlineDuringPausedRedraw() async throws {
        let clock = RuntimeTestClock()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(
                defaultAction: nil,
                idleTimeout: 0,
                defaultNotificationSources: ["first"],
                additionalPositionSources: ["second"]
            )),
            session: session,
            clock: clock
        )
        try await runtime.start()
        _ = try await runtime.emitNotification(RuntimeNotificationRequest(source: "first", text: "A", ttlSeconds: 1))
        clock.advanceWithoutWaking(by: .milliseconds(500))
        let second = try await runtime.emitNotification(RuntimeNotificationRequest(source: "second", text: "B", ttlSeconds: 1))
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "A")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[1].label, "B")

        session.pauseNextPerform()
        clock.advance(by: .milliseconds(500))
        await session.waitForPausedPerform()
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Default button")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[1].label, "B")
        clock.advanceWithoutWaking(by: .milliseconds(500))

        let clear = Task {
            try await runtime.clearNotification(id: second.notificationID)
        }
        let clearIsQueued = await waitForNotificationRequests(1, on: runtime)
        XCTAssertTrue(clearIsQueued)
        await session.resumePausedPerform()
        let cleared = try await clear.value
        XCTAssertEqual(cleared.clearedCount, 0, "the active expiry admission must remove B at deadline equality")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Default button")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[1].label, "Additional button")
        _ = await runtime.stop()
    }

    func testExpiredCapturedNotificationSelectionDoesNotDispatchOrDismiss() async throws {
        let clock = RuntimeTestClock()
        let actions = RuntimeActionRecorder()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(
                defaultAction: "type_text_release",
                idleTimeout: 0,
                defaultNotificationSources: ["alerts"],
                additionalPositionAction: "type_text"
            )),
            session: session,
            clock: clock,
            staticActionHandler: { actions.append($0) }
        )
        try await runtime.start()
        _ = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Expires", ttlSeconds: 1))

        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(1, action: 0x01))
        let selectionCaptured = await waitForActionCount(1, on: actions)
        XCTAssertTrue(selectionCaptured)
        let timerIsSleeping = await waitForSleeper(on: clock)
        XCTAssertTrue(timerIsSleeping)
        clock.advanceWithoutWaking(by: .seconds(2))
        session.sendInput(button(0, action: 0x00))
        let releaseWasProcessedBeforeTimerWake = await waitForNoSleeper(on: clock)
        XCTAssertTrue(releaseWasProcessedBeforeTimerWake)
        XCTAssertEqual(actions.values.count, 1, "the expired selected overlay must not admit its configured action")
        session.sendInput(button(1, action: 0x00))

        clock.advance(by: .milliseconds(1))
        let expired = await waitForLastPageLabel("Default button", on: session)
        XCTAssertTrue(expired)
        _ = await runtime.stop()
    }

    func testReplacingCapturedNotificationSelectionDoesNotDispatchOrDismissReplacement() async throws {
        let actions = RuntimeActionRecorder()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(
                defaultAction: "type_text_release",
                idleTimeout: 0,
                defaultNotificationSources: ["alerts"],
                additionalPositionAction: "type_text"
            )),
            session: session,
            clock: RuntimeTestClock(),
            staticActionHandler: { actions.append($0) }
        )
        try await runtime.start()
        _ = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Old"))

        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(1, action: 0x01))
        let initialActionDispatched = await waitForActionCount(1, on: actions)
        XCTAssertTrue(initialActionDispatched)
        _ = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Replacement"))
        session.sendInput(button(0, action: 0x00))
        session.sendInput(button(1, action: 0x00))
        session.sendInput(button(1, action: 0x01))
        let secondActionDispatched = await waitForActionCount(2, on: actions)
        XCTAssertTrue(secondActionDispatched)
        XCTAssertEqual(actions.values.count, 2, "replacing the selected overlay must not admit its configured action")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Replacement")
        _ = await runtime.stop()
    }

    func testNotificationDismissalWriteFailureDoesNotDispatchConfiguredAction() async throws {
        let actions = RuntimeActionRecorder()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(
                defaultAction: "type_text_release",
                idleTimeout: 0,
                defaultNotificationSources: ["alerts"]
            )),
            session: session,
            clock: RuntimeTestClock(),
            staticActionHandler: { actions.append($0) }
        )
        try await runtime.start()
        _ = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Cannot dismiss"))
        session.failNextPerform()
        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(0, action: 0x00))

        for _ in 0..<2_000 {
            if (await runtime.snapshot()).lifecycle == .failed { break }
            await Task.yield()
        }
        let failedSnapshot = await runtime.snapshot()
        XCTAssertEqual(failedSnapshot.lifecycle, .failed)
        XCTAssertEqual(actions.values.count, 0)
        XCTAssertEqual(session.stopCount, 1)
        _ = await runtime.stop()
    }

    func testReloadResultCarriesAtomicViewsAndRenderedDisplayDecisions() async throws {
        let source = runtimeSource(defaultAction: nil, idleTimeout: 0, defaultNotificationSources: ["alerts"])
        let sourceConfiguration = try decode(source)
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: sourceConfiguration, session: session, clock: RuntimeTestClock())
        try await runtime.start()

        let unchanged = try await runtime.reload(source: source)
        XCTAssertFalse(unchanged.changed)
        XCTAssertEqual(unchanged.previous.configuration, sourceConfiguration)
        XCTAssertEqual(unchanged.current.configuration, sourceConfiguration)
        XCTAssertFalse(unchanged.displayChanged)
        XCTAssertFalse(unchanged.displayUpdated)

        let metadataSource = runtimeSource(defaultLabel: "Metadata only", defaultAction: nil, idleTimeout: 0, defaultNotificationSources: ["alerts"])
        let metadataConfiguration = try decode(metadataSource)
        let metadata = try await runtime.reload(source: metadataSource)
        XCTAssertTrue(metadata.changed)
        XCTAssertEqual(metadata.previous.configuration, sourceConfiguration)
        XCTAssertEqual(metadata.current.configuration, metadataConfiguration)
        XCTAssertFalse(metadata.displayChanged)
        XCTAssertFalse(metadata.displayUpdated)

        _ = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Overlay"))
        let brightnessText = String(decoding: metadataSource, as: UTF8.self)
            .replacingOccurrences(of: "brightness = 72", with: "brightness = 71")
        let brightnessSource = Data(brightnessText.utf8)
        let clearedOverlay = try await runtime.reload(source: brightnessSource)
        XCTAssertTrue(clearedOverlay.displayChanged)
        XCTAssertTrue(clearedOverlay.displayUpdated)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Default button")

        try await runtime.setHostDisplayAwake(false)
        let writesWhileOff = session.batches.count
        let offText = brightnessText.replacingOccurrences(of: "label = \"Default button\"", with: "label = \"Changed while off\"")
        let offResult = try await runtime.reload(source: Data(offText.utf8))
        XCTAssertTrue(offResult.displayChanged)
        XCTAssertFalse(offResult.displayUpdated)
        XCTAssertEqual(session.batches.count, writesWhileOff, "host-off reload must not send a page redraw")
        XCTAssertFalse(offResult.current.snapshot.displayAwake)
        _ = await runtime.stop()
    }

    func testRejectedAndUnchangedReloadRetainOverlayWhileChangedConfigurationAndProfileClearIt() async throws {
        let source = runtimeSource(defaultAction: nil, idleTimeout: 0, defaultNotificationSources: ["alerts"])
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: decode(source), session: session, clock: RuntimeTestClock())
        try await runtime.start()
        let first = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Keep me"))

        do {
            _ = try await runtime.reload(source: Data("schema_version = 3".utf8))
            XCTFail("invalid reload succeeded")
        } catch is ConfigurationDiagnostic {
        }
        let unchanged = try await runtime.reload(source: source)
        XCTAssertFalse(unchanged.changed)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Keep me")

        let changed = try await runtime.reload(source: runtimeSource(
            defaultLabel: "Updated profile metadata",
            defaultAction: nil,
            idleTimeout: 0,
            defaultNotificationSources: ["alerts"]
        ))
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Default button")
        let firstClear = try await runtime.clearNotification(id: first.notificationID)
        XCTAssertEqual(firstClear.clearedCount, 0)

        let second = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Profile scoped"))
        _ = try await runtime.activateProfile("alternate")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Alternate button")
        _ = try await runtime.activateProfile("default")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Default button")
        let secondClear = try await runtime.clearNotification(id: second.notificationID)
        XCTAssertEqual(secondClear.clearedCount, 0)
        _ = await runtime.stop()
    }

    func testReleaseSelectionDismissesBeforeStaticActionAdmission() async throws {
        let session = RuntimeTestSession()
        let actions = RuntimeActionRecorder()
        let admissionBatchCounts = RuntimeServiceTestRecorder<Int>()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: "type_text_release", idleTimeout: 0, defaultNotificationSources: ["alerts"])),
            session: session,
            clock: RuntimeTestClock(),
            staticActionHandler: { request in
                actions.append(request)
                admissionBatchCounts.append(session.batches.count)
            }
        )
        try await runtime.start()
        let notification = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Select me"))

        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(0, action: 0x00))
        let admitted = await waitForActionCount(1, on: actions)
        XCTAssertTrue(admitted)
        XCTAssertEqual(actions.values.count, 1)
        XCTAssertEqual(admissionBatchCounts.values, [3], "static admission must follow the dismissal redraw")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Default button")
        let clearAfterSelection = try await runtime.clearNotification(id: notification.notificationID)
        XCTAssertEqual(clearAfterSelection.clearedCount, 0)
        _ = await runtime.stop()
    }

    func testBusyExecutionAdmissionDoesNotRestoreDismissedOverlay() async throws {
        let gate = RuntimeServiceTestGate()
        let runner = RuntimeFakeProcessRunner(termination: .exited(0), gate: gate)
        let clock = RuntimeTestClock()
        let actionServices = RuntimeActionServices(
            runner: runner,
            nativeInputBackend: RuntimeFakeNativeInputBackend(),
            clock: clock,
            wallDateAnchor: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(
                defaultAction: "execute",
                idleTimeout: 0,
                defaultNotificationSources: ["alerts"],
                additionalPositionSources: ["alerts"],
                additionalPositionAction: "execute"
            )),
            session: session,
            clock: clock,
            actionServices: actionServices
        )
        try await runtime.start()
        let notification = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Dismiss both"))
        XCTAssertEqual(notification.matchedCount, 2)

        session.sendInput(button(0, action: 0x01))
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)
        let firstDismissed = await waitForBatchCount(3, on: session)
        XCTAssertTrue(firstDismissed)
        session.sendInput(button(1, action: 0x01))
        let secondDismissed = await waitForBatchCount(4, on: session)
        XCTAssertTrue(secondDismissed)
        let cleared = try await runtime.clearNotification(id: notification.notificationID)
        XCTAssertEqual(cleared.clearedCount, 0, "a rejected busy action cannot restore the dismissed tile")
        let states = try actionServices.execution.listSummaries(limit: 32).map(\.state)
        XCTAssertEqual(states, [.rejectedBusy, .running])

        gate.open()
        _ = await runtime.stop()
    }

    func testActionlessNotificationSelectionDefaultsToReleaseAndRemovesOnlyItsTile() async throws {
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(
                defaultAction: nil,
                idleTimeout: 0,
                defaultNotificationSources: ["alerts"],
                additionalPositionSources: ["alerts"]
            )),
            session: session,
            clock: RuntimeTestClock()
        )
        try await runtime.start()
        let notification = try await runtime.emitNotification(RuntimeNotificationRequest(source: "alerts", text: "Select one"))
        XCTAssertEqual(notification.matchedCount, 2)

        session.pauseNextPerform()
        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(0, action: 0x00))
        await session.waitForPausedPerform()
        XCTAssertEqual(session.batches.count, 3)
        XCTAssertEqual(lastPage(in: session.batches)?.positions[0].label, "Default button")
        XCTAssertEqual(lastPage(in: session.batches)?.positions[1].label, "Select one")
        await session.resumePausedPerform()
        let remaining = try await runtime.clearNotification(id: notification.notificationID)
        XCTAssertEqual(remaining.clearedCount, 1)
        _ = await runtime.stop()
    }

    func testCoordinatorStopWaitsForAdmittedExecutionCleanup() async throws {
        let gate = RuntimeServiceTestGate()
        let runner = RuntimeFakeProcessRunner(termination: .exited(0), gate: gate)
        let clock = RuntimeTestClock()
        let actionServices = RuntimeActionServices(
            runner: runner,
            nativeInputBackend: RuntimeFakeNativeInputBackend(),
            clock: clock,
            wallDateAnchor: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: "execute", idleTimeout: 0)),
            session: session,
            clock: clock,
            actionServices: actionServices
        )
        try await runtime.start()
        session.sendInput(button(0, action: 0x01))
        XCTAssertEqual(runner.invocation.wait(timeout: .now() + .seconds(3)), .success)

        let stopCompletions = RuntimeServiceTestRecorder<RuntimeStopOutcome>()
        let stop = Task {
            let outcome = await runtime.stop()
            stopCompletions.append(outcome)
            return outcome
        }
        var enteredStopping = false
        for _ in 0..<2_000 {
            if await runtime.snapshot().lifecycle == .stopping {
                enteredStopping = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(enteredStopping)
        XCTAssertEqual(stopCompletions.values, [])

        gate.open()
        let outcome = await stop.value
        XCTAssertEqual(outcome, .closed)
        XCTAssertEqual(stopCompletions.values, [.closed])
        XCTAssertEqual(session.stopCount, 1)
    }

    func testInvalidAndSemanticNoOpReloadKeepLastKnownGoodRevision() async throws {
        let source = runtimeSource()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: decode(source), session: session, clock: RuntimeTestClock())
        try await runtime.start()
        let started = await runtime.snapshot()

        do {
            _ = try await runtime.reload(source: Data("schema_version = 3".utf8))
            XCTFail("invalid reload succeeded")
        } catch is ConfigurationDiagnostic {
        }
        let afterInvalid = await runtime.snapshot()
        XCTAssertEqual(afterInvalid, started)

        let result = try await runtime.reload(source: source)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.revision, started.revision)
        let afterNoOp = await runtime.snapshot()
        XCTAssertEqual(afterNoOp.profileID, "default")
        XCTAssertEqual(session.batches.count, 1)
        _ = await runtime.stop()
    }

    func testMetadataOnlyReloadPublishesWithoutDeviceWriteWhenWriteWouldFail() async throws {
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource()),
            session: session,
            clock: RuntimeTestClock()
        )
        try await runtime.start()
        session.failNextPerform()
        let renamedSource = runtimeSource(defaultLabel: "Renamed default")

        let changed = try await runtime.reload(source: renamedSource)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.revision, 2)
        XCTAssertEqual(session.batches.count, 1, "profile metadata must not trigger a display write")
        let running = await runtime.snapshot()
        XCTAssertEqual(running.lifecycle, .running)
        XCTAssertEqual(running.revision, 2)

        let repeated = try await runtime.reload(source: renamedSource)
        XCTAssertFalse(repeated.changed, "the metadata-only candidate must still become the committed catalog")
        XCTAssertEqual(repeated.revision, 2)
        XCTAssertEqual(session.batches.count, 1)
        _ = await runtime.stop()
    }

    func testReloadKeepsCurrentProfileAndFallsBackToNewDefaultWhenRemoved() async throws {
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: decode(runtimeSource()), session: session, clock: RuntimeTestClock())
        try await runtime.start()
        _ = try await runtime.activateProfile("alternate")

        let changedCurrent = try await runtime.reload(source: runtimeSource(defaultLabel: "New default"))
        XCTAssertEqual(changedCurrent.profileID, "alternate")
        XCTAssertTrue(changedCurrent.changed)
        let afterFirstReload = await runtime.snapshot()
        XCTAssertEqual(afterFirstReload.profileID, "alternate")
        XCTAssertEqual(afterFirstReload.revision, 3)

        let removedCurrent = try await runtime.reload(source: runtimeSource(includeAlternate: false))
        XCTAssertEqual(removedCurrent.profileID, "default")
        XCTAssertTrue(removedCurrent.changed)
        let afterFallback = await runtime.snapshot()
        XCTAssertEqual(afterFallback.profileID, "default")
        _ = await runtime.stop()
    }

    func testTransitionAdmissionSerializesConcurrentHostWritesAndConsumesStaleInput() async throws {
        let actions = RuntimeActionRecorder()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: nil, alternateAction: "type_text")),
            session: session,
            clock: RuntimeTestClock(),
            staticActionHandler: { actions.append($0) }
        )
        try await runtime.start()
        session.pauseNextPerform()

        let activation = Task { try await runtime.activateProfile("alternate") }
        await session.waitForPausedPerform()
        let hostOff = Task { try await runtime.setHostDisplayAwake(false) }
        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(0, action: 0x00))

        XCTAssertEqual(session.batches.count, 2)
        await session.resumePausedPerform()
        _ = try await activation.value
        try await hostOff.value

        let asleep = await runtime.snapshot()
        XCTAssertFalse(asleep.displayAwake)
        XCTAssertTrue(asleep.dimmed)
        XCTAssertEqual(session.batches.count, 3)
        if case .setBrightness(0) = session.batches[2] {} else { XCTFail("host-off brightness was not serialized after redraw") }
        XCTAssertEqual(actions.values.count, 0)

        try await runtime.setHostDisplayAwake(false)
        XCTAssertEqual(session.batches.count, 3)
        try await runtime.setHostDisplayAwake(true)
        let awake = await runtime.snapshot()
        XCTAssertTrue(awake.displayAwake)
        XCTAssertFalse(awake.dimmed)
        XCTAssertEqual(session.batches.count, 4)
        if case .startup = session.batches[3] {} else { XCTFail("host wake did not redraw the current profile") }
        try await runtime.setHostDisplayAwake(true)
        XCTAssertEqual(session.batches.count, 4)

        session.sendInput(button(0, action: 0x01))
        let receivedAction = await waitForActionCount(1, on: actions)
        XCTAssertTrue(receivedAction)
        XCTAssertEqual(actions.values.count, 1)
        XCTAssertEqual(actions.values[0].profileID, "alternate")
        _ = await runtime.stop()
    }

    func testProfileActivationBindingPublishesOnlyAfterRedraw() async throws {
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: "activate_alternate")),
            session: session,
            clock: RuntimeTestClock()
        )
        try await runtime.start()
        session.pauseNextPerform()

        session.sendInput(button(0, action: 0x01))
        await session.waitForPausedPerform()
        let beforePublication = await runtime.snapshot()
        XCTAssertEqual(beforePublication.profileID, "default")
        await session.resumePausedPerform()

        let profilePublished = await waitForProfile("alternate", on: runtime)
        XCTAssertTrue(profilePublished)
        let afterPublication = await runtime.snapshot()
        XCTAssertEqual(afterPublication.profileID, "alternate")
        _ = await runtime.stop()
    }

    func testFailedPhysicalWritePreservesPublishedProfileAndFailStops() async throws {
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: decode(runtimeSource()), session: session, clock: RuntimeTestClock())
        try await runtime.start()
        let before = await runtime.snapshot()
        session.failNextPerform()

        do {
            _ = try await runtime.activateProfile("alternate")
            XCTFail("failed physical write was accepted")
        } catch let error as RuntimeCoordinatorError {
            XCTAssertEqual(error, .physicalWriteFailed)
        }

        let failed = await runtime.snapshot()
        XCTAssertEqual(failed.lifecycle, .failed)
        XCTAssertEqual(failed.profileID, before.profileID)
        XCTAssertEqual(failed.revision, before.revision)
        do {
            _ = try await runtime.activateProfile("alternate")
            XCTFail("fail-stopped runtime accepted activation")
        } catch let error as RuntimeCoordinatorError {
            XCTAssertEqual(error, .physicalWriteFailed)
        }
        _ = await runtime.stop()
    }

    func testCancelledCallerAfterAdmissionDoesNotUndoSuccessfulVisibleReloadWrite() async throws {
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: decode(runtimeSource()), session: session, clock: RuntimeTestClock())
        try await runtime.start()
        session.pauseNextPerform()

        let reload = Task { try await runtime.reload(source: runtimeSource(defaultPositionLabel: "Updated button")) }
        await session.waitForPausedPerform()
        reload.cancel()
        await session.resumePausedPerform()

        let result = try await reload.value
        XCTAssertTrue(result.changed)
        let published = await runtime.snapshot()
        XCTAssertEqual(published.profileID, "default")
        XCTAssertEqual(published.revision, 2)
        XCTAssertEqual(session.batches.count, 2)
        _ = await runtime.stop()
    }

    func testRuntimeFileCommitAndVisibleReloadFailureHaveSeparateOutcomes() async throws {
        let source = runtimeSource(defaultLabel: "Before")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-runtime-failed-reload-\(UUID().uuidString).toml")
        try source.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: decode(source), session: session, clock: RuntimeTestClock())
        try await runtime.start()
        let before = await runtime.snapshot()
        session.failNextPerform()

        let result = try await runtime.applyConfigurationEdit(
            at: fileURL.path,
            expectedDigest: ConfigurationStore.digest(source),
            edit: .patchPosition(
                profileID: "default",
                coordinate: "0_0",
                patch: ConfigurationPositionPatch(label: .set("After visible edit"))
            )
        )
        XCTAssertEqual(result.fileOutcome, .committed)
        XCTAssertEqual(result.reloadOutcome, .runtimeFailed)
        XCTAssertEqual(result.snapshot.lifecycle, .failed)
        XCTAssertEqual(result.snapshot.profileID, before.profileID)
        XCTAssertEqual(result.snapshot.revision, before.revision)
        XCTAssertNil(result.reloadResult, "a failed physical redraw cannot publish a successful reload result")
        _ = await runtime.stop()
    }

    func testBoundedInputOverflowFailStopsInsteadOfDroppingPressReleaseState() async throws {
        let actions = RuntimeActionRecorder()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource()),
            session: session,
            clock: RuntimeTestClock(),
            staticActionHandler: { actions.append($0) }
        )
        try await runtime.start()
        session.pauseNextPerform()
        let activation = Task { try await runtime.activateProfile("alternate") }
        await session.waitForPausedPerform()

        for index in 0..<10_000 {
            let action: UInt8 = index.isMultiple(of: 2) ? 0x01 : 0x00
            session.sendInput(button(0, action: action, marker: 0x02))
        }
        session.sendFailure(.writeFailed)
        await session.resumePausedPerform()

        do {
            _ = try await activation.value
            XCTFail("input mailbox overflow allowed profile publication")
        } catch let error as RuntimeCoordinatorError {
            XCTAssertEqual(error, .physicalWriteFailed)
        }
        let failed = await runtime.snapshot()
        XCTAssertEqual(failed.lifecycle, .failed)
        XCTAssertEqual(failed.profileID, "default")
        XCTAssertEqual(session.stopCount, 1)

        let writesAfterFailure = session.batches.count
        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(0, action: 0x00))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(actions.values.count, 0, "input after terminal failure cannot dispatch configured actions")
        XCTAssertEqual(session.batches.count, writesAfterFailure, "input after terminal failure cannot add device writes")
        XCTAssertEqual(session.stopCount, 1, "terminal failure cleanup remains one-shot")
        _ = await runtime.stop()
    }

    func testTerminalFailureLatchAdmitsExactlyOneConcurrentCause() {
        let latch = RuntimeFailureLatch()
        let winners = RuntimeFailureWinnerRecorder()

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let sessionFailure = index.isMultiple(of: 2)
            let admitted = sessionFailure
                ? latch.record(.writeFailed)
                : latch.recordInputOverflow()
            if admitted { winners.append(sessionFailure: sessionFailure) }
        }

        let admittedCauses = winners.values
        XCTAssertEqual(admittedCauses.count, 1)
        XCTAssertTrue(latch.isFailed)
        guard let firstCause = admittedCauses.first else { return }
        if firstCause {
            XCTAssertEqual(latch.failure, .writeFailed)
        } else {
            XCTAssertNil(latch.failure)
        }
    }

    func testEncoderRotationWakesWithoutDispatchAndHeldStateUsesMarkerAndIndex() async throws {
        let clock = RuntimeTestClock()
        let actions = RuntimeActionRecorder()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: "type_text_release", idleTimeout: 5)),
            session: session,
            clock: clock,
            staticActionHandler: { actions.append($0) }
        )
        try await runtime.start()

        session.sendInput(button(0, action: 0x01, marker: 0x02))
        session.sendInput(button(0, action: 0x00, marker: 0x01))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(actions.values.count, 0, "a button release cannot release an encoder press")
        session.sendInput(button(0, action: 0x00, marker: 0x02))
        let releaseDispatched = await waitForActionCount(1, on: actions)
        XCTAssertTrue(releaseDispatched)

        clock.advance(by: .seconds(5))
        let didDim = await waitForDimmed(runtime)
        XCTAssertTrue(didDim)
        session.sendInput(button(0, action: 0x03, marker: 0x02))
        for _ in 0..<2_000 {
            if !(await runtime.snapshot()).dimmed { break }
            await Task.yield()
        }
        let afterRotation = await runtime.snapshot()
        XCTAssertFalse(afterRotation.dimmed)
        XCTAssertEqual(actions.values.count, 1, "encoder rotation wakes the display without a binding dispatch")
        _ = await runtime.stop()
    }

    func testInputAtIdleDeadlineDispatchesBeforeTheDimTransition() async throws {
        let clock = RuntimeTestClock()
        let actions = RuntimeActionRecorder()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: "type_text", idleTimeout: 5)),
            session: session,
            clock: clock,
            staticActionHandler: { actions.append($0) }
        )
        try await runtime.start()
        let timerIsSleeping = await waitForSleeper(on: clock)
        XCTAssertTrue(timerIsSleeping)
        clock.advanceWithoutWaking(by: .seconds(5))

        session.sendInput(button(0, action: 0x01))
        let receivedAction = await waitForActionCount(1, on: actions)
        XCTAssertTrue(receivedAction)
        let atDeadline = await runtime.snapshot()
        XCTAssertFalse(atDeadline.dimmed)
        XCTAssertEqual(actions.values.count, 1)
        _ = await runtime.stop()
    }

    func testAlreadyDimmedWakeConsumesPressAndMatchingRelease() async throws {
        let clock = RuntimeTestClock()
        let actions = RuntimeActionRecorder()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: "type_text_release", idleTimeout: 5)),
            session: session,
            clock: clock,
            staticActionHandler: { actions.append($0) }
        )
        try await runtime.start()
        clock.advance(by: .seconds(5))
        let didDim = await waitForDimmed(runtime)
        XCTAssertTrue(didDim)
        let dimmedSnapshot = await runtime.snapshot()

        session.sendInput(button(0, action: 0x01))
        let awakeSnapshot = await waitForRevision(after: dimmedSnapshot.revision, on: runtime)
        XCTAssertGreaterThan(awakeSnapshot.revision, dimmedSnapshot.revision)
        XCTAssertFalse(awakeSnapshot.dimmed)
        XCTAssertEqual(actions.values.count, 0, "an already-dimmed wake press is consumed")

        session.sendInput(button(0, action: 0x00))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(actions.values.count, 0, "the matching wake release is suppressed")
        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(0, action: 0x00))
        let nextPressDispatched = await waitForActionCount(1, on: actions)
        XCTAssertTrue(nextPressDispatched)
        XCTAssertEqual(actions.values.count, 1)
        _ = await runtime.stop()
    }

    func testZeroIdleTimeoutDisablesDim() async throws {
        let zeroClock = RuntimeTestClock()
        let zeroSession = RuntimeTestSession()
        let zeroRuntime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: nil, idleTimeout: 0)),
            session: zeroSession,
            clock: zeroClock
        )
        try await zeroRuntime.start()
        zeroClock.advance(by: .seconds(49))
        await Task.yield()
        let zeroSnapshot = await zeroRuntime.snapshot()
        XCTAssertFalse(zeroSnapshot.dimmed)
        XCTAssertEqual(zeroSession.batches.count, 1)
        _ = await zeroRuntime.stop()
    }

    func testKeepaliveUsesFiftySecondCadenceAndSkipsMissedBursts() async throws {
        let clock = RuntimeTestClock()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: nil, idleTimeout: 0)),
            session: session,
            clock: clock
        )
        try await runtime.start()
        session.pauseNextPerform()

        clock.advance(by: .seconds(49))
        await Task.yield()
        XCTAssertEqual(session.batches.count, 1)

        clock.advance(by: .seconds(1))
        await session.waitForPausedPerform()
        clock.advance(by: .seconds(200))
        await session.resumePausedPerform()
        let firstKeepAlive = await waitForBatchCount(2, on: session)
        XCTAssertTrue(firstKeepAlive)
        if case .keepAlive = session.batches[1] {} else { XCTFail("50 second deadline did not issue keepalive") }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(session.batches.count, 2, "a delayed write must not cause an immediate catch-up heartbeat")

        clock.advance(by: .seconds(49))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(session.batches.count, 2)
        clock.advance(by: .seconds(1))
        let secondKeepAlive = await waitForBatchCount(3, on: session)
        XCTAssertTrue(secondKeepAlive)
        clock.advance(by: .seconds(500))
        let thirdKeepAlive = await waitForBatchCount(4, on: session)
        XCTAssertTrue(thirdKeepAlive)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(session.batches.count, 4, "missed intervals must not burst")
        _ = await runtime.stop()
    }

    func testKeepaliveContinuesWhileHostDisplayIsOff() async throws {
        let clock = RuntimeTestClock()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: nil, idleTimeout: 0)),
            session: session,
            clock: clock
        )
        try await runtime.start()
        try await runtime.setHostDisplayAwake(false)
        clock.advance(by: .seconds(50))

        let heartbeatSent = await waitForBatchCount(3, on: session)
        XCTAssertTrue(heartbeatSent)
        if case .keepAlive = session.batches[2] {} else { XCTFail("host-off state suppressed the stream heartbeat") }
        let sleeping = await runtime.snapshot()
        XCTAssertFalse(sleeping.displayAwake)
        _ = await runtime.stop()
    }

    func testReloadWaitsForAdmittedKeepaliveWrite() async throws {
        let clock = RuntimeTestClock()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: nil, idleTimeout: 0)),
            session: session,
            clock: clock
        )
        try await runtime.start()
        session.pauseNextPerform()
        clock.advance(by: .seconds(50))
        await session.waitForPausedPerform()

        let reload = Task {
            try await runtime.reload(source: runtimeSource(defaultPositionLabel: "Reloaded button", defaultAction: nil, idleTimeout: 0))
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(session.batches.count, 2, "reload must not write across the paused keepalive")

        await session.resumePausedPerform()
        let result = try await reload.value
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.profileID, "default")
        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(session.batches.count, 3)
        if case .keepAlive = session.batches[1] {} else { XCTFail("keepalive was not admitted before reload") }
        if case .redraw = session.batches[2] {} else { XCTFail("reload redraw did not follow keepalive") }
        _ = await runtime.stop()
    }

    func testIdleDimWaitsForAdmittedProfileRedraw() async throws {
        let clock = RuntimeTestClock()
        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(
            configuration: decode(runtimeSource(defaultAction: nil, idleTimeout: 5)),
            session: session,
            clock: clock
        )
        try await runtime.start()
        session.pauseNextPerform()

        let activation = Task { try await runtime.activateProfile("alternate") }
        await session.waitForPausedPerform()
        clock.advance(by: .seconds(5))
        session.sendInput(button(0, action: 0x01))
        session.sendInput(button(0, action: 0x00))
        XCTAssertEqual(session.batches.count, 2, "dim cannot write across the paused redraw")

        await session.resumePausedPerform()
        _ = try await activation.value
        let dimmed = await waitForDimmed(runtime)
        XCTAssertTrue(dimmed)
        XCTAssertEqual(session.batches.count, 3)
        if case .redraw = session.batches[1] {} else { XCTFail("activation redraw was not first") }
        if case .setBrightness(0) = session.batches[2] {} else { XCTFail("idle dim did not follow the admitted redraw") }
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.profileID, "alternate")
        XCTAssertTrue(snapshot.dimmed)
        _ = await runtime.stop()
    }

    func testCommittedFileEditReloadsDespiteCallerCancellation() async throws {
        let source = runtimeSource(defaultLabel: "Before")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-runtime-edit-\(UUID().uuidString).toml")
        try source.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let session = RuntimeTestSession()
        let runtime = try RuntimeCoordinator(configuration: decode(source), session: session, clock: RuntimeTestClock())
        try await runtime.start()
        session.pauseNextPerform()
        let task = Task {
            try await runtime.applyConfigurationEdit(
                at: fileURL.path,
                expectedDigest: ConfigurationStore.digest(source),
                edit: .patchPosition(
                    profileID: "default",
                    coordinate: "0_0",
                    patch: ConfigurationPositionPatch(label: .set("After visible edit"))
                )
            )
        }

        await session.waitForPausedPerform()
        task.cancel()
        await session.resumePausedPerform()
        let result = try await task.value
        XCTAssertEqual(result.fileOutcome, .committed)
        XCTAssertEqual(result.reloadOutcome, .reloaded)
        XCTAssertEqual(result.snapshot.profileID, "default")
        XCTAssertGreaterThan(result.snapshot.revision, 1)
        XCTAssertNotNil(result.reloadResult)
        XCTAssertEqual(result.reloadResult?.previous.configuration.brightness, 72)
        XCTAssertTrue(result.reloadResult?.displayChanged == true)
        XCTAssertTrue(result.reloadResult?.displayUpdated == true)
        _ = await runtime.stop()
    }

    func testStopReturnsCleanupUncertaintyWithoutClaimingClosed() async throws {
        let session = RuntimeTestSession(stopOutcome: .cleanupUncertain)
        let runtime = try RuntimeCoordinator(configuration: decode(runtimeSource()), session: session, clock: RuntimeTestClock())
        try await runtime.start()

        let outcome = await runtime.stop()
        XCTAssertEqual(outcome, .cleanupUncertain)
        let stopped = await runtime.snapshot()
        XCTAssertEqual(stopped.lifecycle, .failed)
        XCTAssertTrue(stopped.cleanupUncertain)
    }

    private func decode(_ source: Data) throws -> HidhoggConfiguration {
        try HidhoggConfigurationDecoder.decode(source)
    }

    private func button(_ wireIndex: UInt8, action: UInt8, marker: UInt8 = 0x01) -> D200XInputEvent {
        D200XInputEvent(deviceState: 0, wireIndex: wireIndex, marker: marker, action: action, rawPayload: Data([0, wireIndex, marker, action]))
    }

    private func waitForProfile(_ profileID: String, on runtime: RuntimeCoordinator) async -> Bool {
        for _ in 0..<2_000 {
            if await runtime.snapshot().profileID == profileID { return true }
            await Task.yield()
        }
        return await runtime.snapshot().profileID == profileID
    }

    private func waitForDimmed(_ runtime: RuntimeCoordinator) async -> Bool {
        for _ in 0..<2_000 {
            if await runtime.snapshot().dimmed { return true }
            await Task.yield()
        }
        return await runtime.snapshot().dimmed
    }

    private func waitForActionCount(_ count: Int, on recorder: RuntimeActionRecorder) async -> Bool {
        for _ in 0..<2_000 {
            if recorder.values.count >= count { return true }
            await Task.yield()
        }
        return recorder.values.count >= count
    }

    private func waitForBatchCount(_ count: Int, on session: RuntimeTestSession) async -> Bool {
        for _ in 0..<2_000 {
            if session.batches.count >= count { return true }
            await Task.yield()
        }
        return session.batches.count >= count
    }

    private func waitForNotificationRequests(_ count: Int, on runtime: RuntimeCoordinator) async -> Bool {
        for _ in 0..<2_000 {
            if await runtime.notificationRequestsInFlight() >= count { return true }
            await Task.yield()
        }
        return await runtime.notificationRequestsInFlight() >= count
    }

    private func waitForLastPageLabel(_ label: String, on session: RuntimeTestSession) async -> Bool {
        for _ in 0..<2_000 {
            if lastPage(in: session.batches)?.positions.first?.label == label { return true }
            await Task.yield()
        }
        return lastPage(in: session.batches)?.positions.first?.label == label
    }

    private func waitForSleeper(on clock: RuntimeTestClock) async -> Bool {
        for _ in 0..<2_000 {
            if clock.sleepingCount > 0 { return true }
            await Task.yield()
        }
        return clock.sleepingCount > 0
    }

    private func waitForNoSleeper(on clock: RuntimeTestClock) async -> Bool {
        for _ in 0..<2_000 {
            if clock.sleepingCount == 0 { return true }
            await Task.yield()
        }
        return clock.sleepingCount == 0
    }

    private func waitForRevision(after revision: UInt64, on runtime: RuntimeCoordinator) async -> RuntimeSnapshot {
        for _ in 0..<2_000 {
            let snapshot = await runtime.snapshot()
            if snapshot.revision > revision { return snapshot }
            await Task.yield()
        }
        return await runtime.snapshot()
    }
}

private func runtimeSource(
    defaultLabel: String = "Default",
    defaultPositionLabel: String = "Default button",
    includeAlternate: Bool = true,
    defaultAction: String? = "type_text",
    alternateAction: String? = nil,
    idleTimeout: Int = 30,
    defaultNotificationSources: [String] = [],
    additionalPositionSources: [String] = [],
    additionalPositionAction: String? = nil
) -> Data {
    let defaultBinding = actionBinding(defaultAction)
    let defaultSources = notificationSources(defaultNotificationSources)
    let alternateTable: String
    if includeAlternate {
        let actionLine = alternateAction == "type_text"
            ? "action = { type = \"type_text\", text = \"alternate-action\", gesture = \"press\" }"
            : ""
        alternateTable = """

            [profiles.alternate]
            label = "Alternate"

            [profiles.alternate.positions."0_0"]
            label = "Alternate button"
            \(actionLine)
            """
    } else {
        alternateTable = ""
    }
    let additionalPositionTable: String
    if additionalPositionSources.isEmpty && additionalPositionAction == nil {
        additionalPositionTable = ""
    } else {
        additionalPositionTable = """

            [profiles.default.positions."1_0"]
            label = "Additional button"
            \(notificationSources(additionalPositionSources))
            \(actionBinding(additionalPositionAction))
            """
    }
    return Data("""
        schema_version = 4
        adapter = "ulanzi.d200x"
        brightness = 72
        idle_timeout_seconds = \(idleTimeout)
        default_profile_id = "default"

        [profiles.default]
        label = "\(defaultLabel)"

        [profiles.default.positions."0_0"]
        label = "\(defaultPositionLabel)"
        \(defaultSources)
        \(defaultBinding)
        \(additionalPositionTable)
        \(alternateTable)
        """.utf8)
}

private func actionBinding(_ kind: String?) -> String {
    switch kind {
    case "activate_alternate":
        return "action = { type = \"activate_profile\", profile_id = \"alternate\", gesture = \"press\" }"
    case "type_text":
        return "action = { type = \"type_text\", text = \"default-action\", gesture = \"press\" }"
    case "type_text_release":
        return "action = { type = \"type_text\", text = \"default-action\", gesture = \"release\" }"
    case "execute":
        return "action = { type = \"execute\", executable = \"/synthetic/tool\", arguments = [\"literal\"], timeout_seconds = 10, gesture = \"press\" }"
    default:
        return ""
    }
}

private func notificationSources(_ sources: [String]) -> String {
    guard !sources.isEmpty else { return "" }
    return "notification_sources = [\(sources.map { "\"\($0)\"" }.joined(separator: ", "))]"
}

private func lastPage(in batches: [D200XOutboundBatch]) -> D200XLivePageUpdate? {
    for batch in batches.reversed() {
        switch batch {
        case let .startup(page, _), let .redraw(page): return page
        case .setBrightness, .keepAlive: continue
        }
    }
    return nil
}

private final class RuntimeActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedActions = [RuntimeStaticActionRequest]()

    var values: [RuntimeStaticActionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedActions
    }

    func append(_ action: RuntimeStaticActionRequest) {
        lock.lock()
        storedActions.append(action)
        lock.unlock()
    }
}

private final class RuntimeTestSession: D200XDeviceSession, @unchecked Sendable {
    private let candidate = D200XDeviceCandidate(
        registryID: 9,
        vendorID: 0x2207,
        productID: 0x0019,
        interfaceNumber: 0,
        usagePage: 0x000c,
        usage: 0x0001,
        maximumOutputReportSize: D200XFrameCodec.packetSize
    )
    private let lock = NSLock()
    private var inputHandler: (@Sendable (D200XInputEvent) -> Void)?
    private var failureHandler: (@Sendable (D200XSessionFailure) -> Void)?
    private var storedBatches = [D200XOutboundBatch]()
    private var pauseOnNextPerform = false
    private var pausedGate: RuntimeAsyncTestGate?
    private var failOnNextPerform = false
    private var storedStopCount = 0
    private let stopOutcome: D200XSessionStopOutcome

    init(stopOutcome: D200XSessionStopOutcome = .closed) {
        self.stopOutcome = stopOutcome
    }

    var batches: [D200XOutboundBatch] {
        lock.lock()
        defer { lock.unlock() }
        return storedBatches
    }

    var stopCount: Int { withLock { storedStopCount } }

    func candidates() async throws -> [D200XDeviceCandidate] { [candidate] }

    func open(
        _ candidate: D200XDeviceCandidate,
        onInput: @escaping @Sendable (D200XInputEvent) -> Void,
        onFailure: @escaping @Sendable (D200XSessionFailure) -> Void
    ) async throws {
        guard candidate == self.candidate else { throw D200XSessionError.selectedDeviceChanged }
        withLock {
            inputHandler = onInput
            failureHandler = onFailure
        }
    }

    func perform(_ batch: D200XOutboundBatch) async throws {
        let gate = withLock { () -> RuntimeAsyncTestGate? in
            storedBatches.append(batch)
            guard pauseOnNextPerform, let gate = pausedGate else { return nil }
            pauseOnNextPerform = false
            return gate
        }
        if let gate { await gate.pause() }
        let (shouldFail, failureCallback) = withLock { () -> (Bool, (@Sendable (D200XSessionFailure) -> Void)?) in
            let shouldFail = failOnNextPerform
            if shouldFail { failOnNextPerform = false }
            return (shouldFail, failureHandler)
        }
        if shouldFail {
            failureCallback?(.writeFailed)
            throw D200XSessionError.writeFailed
        }
    }

    func stop() { withLock { storedStopCount += 1 } }

    func waitUntilStopped() async -> D200XSessionStopOutcome { stopOutcome }

    func pauseNextPerform() {
        lock.lock()
        pausedGate = RuntimeAsyncTestGate()
        pauseOnNextPerform = true
        lock.unlock()
    }

    func waitForPausedPerform() async {
        let gate = withLock { pausedGate }
        await gate?.waitUntilEntered()
    }

    func resumePausedPerform() async {
        let gate = withLock { pausedGate }
        await gate?.resume()
    }

    func failNextPerform() {
        lock.lock()
        failOnNextPerform = true
        lock.unlock()
    }

    func sendInput(_ event: D200XInputEvent) {
        lock.lock()
        let callback = inputHandler
        lock.unlock()
        callback?(event)
    }

    func sendFailure(_ failure: D200XSessionFailure) {
        lock.lock()
        let callback = failureHandler
        lock.unlock()
        callback?(failure)
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class RuntimeFailureWinnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues = [Bool]()

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(sessionFailure: Bool) {
        lock.lock()
        storedValues.append(sessionFailure)
        lock.unlock()
    }
}

private actor RuntimeAsyncTestGate {
    private var entered = false
    private var resumed = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters = [CheckedContinuation<Void, Never>]()

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !resumed else { return }
        await withCheckedContinuation { blockedContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func resume() {
        resumed = true
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private final class RuntimeTestClock: RuntimeMonotonicClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: RuntimeMonotonicInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var instant = RuntimeMonotonicInstant(durationFromOrigin: .zero)
    private var sleepers = [UUID: Sleeper]()

    func now() -> RuntimeMonotonicInstant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    var sleepingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(until deadline: RuntimeMonotonicInstant) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard deadline > instant else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[identifier] = Sleeper(deadline: deadline, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            self.cancel(identifier)
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        let ready = sleepers.filter { $0.value.deadline <= instant }
        for identifier in ready.keys { sleepers.removeValue(forKey: identifier) }
        lock.unlock()
        for sleeper in ready.values { sleeper.continuation.resume() }
    }

    func advanceWithoutWaking(by duration: Duration) {
        lock.lock()
        instant = instant.advanced(by: duration)
        lock.unlock()
    }

    private func cancel(_ identifier: UUID) {
        lock.lock()
        let sleeper = sleepers.removeValue(forKey: identifier)
        lock.unlock()
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}
