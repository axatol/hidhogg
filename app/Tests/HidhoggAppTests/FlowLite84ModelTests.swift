import Foundation
import HidhoggDomain
import LofreeFlowLite84
import MacOSActions
import XCTest
@testable import HidhoggApp

@MainActor
final class FlowLite84ModelTests: XCTestCase {
    func testDefaultModelDoesNotCreateLiveSessionForConnect() {
        let model = FlowLite84Model()

        XCTAssertEqual(model.status, .disconnected)
        XCTAssertNil(model.snapshot)
        XCTAssertFalse(model.connectionRequested)
        XCTAssertFalse(model.isBusy)

        model.connect()

        XCTAssertEqual(model.status, .failed(.unavailable))
        XCTAssertEqual(model.errorMessage, "Flow Lite84 receiver session is unavailable.")
        XCTAssertFalse(model.connectionRequested)
        XCTAssertFalse(model.isConnected)
    }

    func testExplicitConnectAndManualRefreshNeedNoConfigurationOrInputPermission() async {
        let firstRead = snapshot(battery: FlowLite84Battery(reportedLevel: 52, charging: false, voltageMillivolts: 3975))
        let refreshedRead = snapshot(battery: FlowLite84Battery(reportedLevel: 51, charging: true, voltageMillivolts: 3960))
        let session = FixtureFlowLite84Session(snapshot: firstRead, refreshedSnapshot: refreshedRead)
        let model = FlowLite84Model(session: session)

        model.connect()

        let connected = await eventually { model.isConnected && model.snapshot == firstRead && !model.isBusy }
        XCTAssertTrue(connected)
        let connectionCount = await session.connectionCount()
        let initialRefreshCount = await session.refreshCount()
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(initialRefreshCount, 0)
        XCTAssertTrue(model.isKeyboardOnline)
        XCTAssertEqual(model.batteryText, "Reported level 52 · Not charging")

        model.refresh()

        let refreshed = await eventually { model.snapshot == refreshedRead && !model.isRefreshing }
        XCTAssertTrue(refreshed)
        let refreshCount = await session.refreshCount()
        XCTAssertEqual(refreshCount, 1)
        let batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)
        await model.stop()
    }

    func testManualLightingApplyAdoptsConfirmedReadback() async {
        let initialRead = snapshot(
            online: false,
            lighting: FlowLite84Lighting(mode: 10, enabled: false, idleOffUnits: 6, brightnessLevel: 0, speedLevel: 4)
        )
        let confirmedRead = snapshot(
            online: false,
            lighting: FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 3, brightnessLevel: 2, speedLevel: 4),
            canRestoreOriginalLighting: true,
            at: Date(timeIntervalSince1970: 200)
        )
        let session = FixtureFlowLite84Session(
            snapshot: initialRead,
            lightingWriteSnapshot: confirmedRead,
            lightingRestoreSnapshot: confirmedRead
        )
        let model = FlowLite84Model(session: session)
        model.connect()

        let connected = await eventually {
            model.isConnected && model.snapshot == initialRead && !model.isBusy
        }
        XCTAssertTrue(connected)
        XCTAssertTrue(model.canEditLighting)
        XCTAssertFalse(model.canRestorePreviousLighting)
        XCTAssertEqual(model.draftLightingEffect, .steady)
        XCTAssertEqual(model.draftLightingEnabled, false)
        XCTAssertEqual(model.draftLightingBrightnessLevel, 1)
        XCTAssertEqual(model.draftLightingSpeedLevel, 5)
        XCTAssertEqual(model.draftLightingIdleOff, .oneMinute)

        model.draftLightingEffect = .breathing
        model.draftLightingEnabled = true
        model.draftLightingBrightnessLevel = 3
        model.draftLightingIdleOff = .thirtySeconds

        let writesBeforeApply = await session.lightingEditCount()
        XCTAssertEqual(writesBeforeApply, 0)
        XCTAssertTrue(model.canApplyLightingDraft)

        model.applyLightingDraft()
        let applied = await eventually {
            model.snapshot == confirmedRead && !model.isBusy
        }
        XCTAssertTrue(applied)

        let edit = await session.lastLightingEdit()
        XCTAssertEqual(edit?.effect, .breathing)
        XCTAssertEqual(edit?.enabled, true)
        XCTAssertEqual(edit?.brightnessLevel, 2)
        XCTAssertNil(edit?.speedLevel)
        XCTAssertEqual(edit?.idleOff, .thirtySeconds)
        XCTAssertEqual(model.draftLightingEffect, .breathing)
        XCTAssertEqual(model.draftLightingBrightnessLevel, 3)
        XCTAssertFalse(model.isLightingDraftDirty)
        XCTAssertTrue(model.canRestorePreviousLighting)

        model.restorePreviousLighting()
        let restored = await eventually { !model.isBusy && !model.isRestoringLighting }
        XCTAssertTrue(restored)
        let restoreCount = await session.lightingRestoreCount()
        XCTAssertEqual(restoreCount, 1)
        await model.stop()
    }

    func testLightingEditsDebounceFromLastAdjustmentAndApplyOnce() async {
        let initialRead = snapshot(
            lighting: FlowLite84Lighting(mode: 10, enabled: false, idleOffUnits: 6, brightnessLevel: 0)
        )
        let confirmedRead = snapshot(
            lighting: FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 6, brightnessLevel: 0),
            at: Date(timeIntervalSince1970: 200)
        )
        let session = FixtureFlowLite84Session(snapshot: initialRead, lightingWriteSnapshot: confirmedRead)
        let model = FlowLite84Model(session: session, lightingAutoApplyDelay: .milliseconds(100))
        model.connect()

        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)

        model.draftLightingEffect = .breathing
        try? await Task.sleep(for: .milliseconds(60))
        model.draftLightingEnabled = true
        try? await Task.sleep(for: .milliseconds(70))

        let writesBeforeLastDelay = await session.lightingEditCount()
        XCTAssertEqual(writesBeforeLastDelay, 0)

        let applied = await eventually {
            await session.lightingEditCount() == 1 && model.snapshot == confirmedRead && !model.isBusy
        }
        XCTAssertTrue(applied)
        let edit = await session.lastLightingEdit()
        XCTAssertEqual(edit?.effect, .breathing)
        XCTAssertEqual(edit?.enabled, true)

        try? await Task.sleep(for: .milliseconds(120))
        let writesAfterQuietPeriod = await session.lightingEditCount()
        XCTAssertEqual(writesAfterQuietPeriod, 1)
        await model.stop()
    }

    func testLightingEditDuringWriteCoalescesAndRebasesOnlyNewIntent() async {
        let initialRead = snapshot(
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 1, speedLevel: 3)
        )
        let confirmedRead = snapshot(
            lighting: FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 6, brightnessLevel: 1, speedLevel: 4),
            at: Date(timeIntervalSince1970: 200)
        )
        let session = FixtureFlowLite84Session(
            snapshot: initialRead,
            lightingWriteSnapshot: confirmedRead,
            lightingWriteDelay: .milliseconds(90)
        )
        let model = FlowLite84Model(session: session, lightingAutoApplyDelay: .milliseconds(10))
        model.connect()

        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        let firstWriteStarted = await eventually { model.isApplyingLighting }
        XCTAssertTrue(firstWriteStarted)
        XCTAssertTrue(model.canEditLighting)

        model.draftLightingBrightnessLevel = 4
        let appliedTwice = await eventually {
            await session.lightingEditCount() == 2 && !model.isBusy
        }
        XCTAssertTrue(appliedTwice)

        let firstEdit = await session.lightingEdit(at: 0)
        XCTAssertEqual(firstEdit?.effect, .breathing)
        XCTAssertNil(firstEdit?.brightnessLevel)
        XCTAssertNil(firstEdit?.speedLevel)

        let latestEdit = await session.lastLightingEdit()
        XCTAssertNil(latestEdit?.effect)
        XCTAssertEqual(latestEdit?.brightnessLevel, 3)
        XCTAssertNil(latestEdit?.speedLevel)
        XCTAssertEqual(model.draftLightingSpeedLevel, 5)
        XCTAssertFalse(model.isLightingDraftDirty)
        await model.stop()
    }

    func testLightingFailureDiscardsQueuedAutoApplyUntilRetryOrNewAdjustment() async {
        let initialRead = snapshot(
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0)
        )
        let session = FixtureFlowLite84Session(
            snapshot: initialRead,
            lightingWriteDelay: .milliseconds(30)
        )
        let model = FlowLite84Model(session: session, lightingAutoApplyDelay: .milliseconds(10))
        model.connect()

        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        let writeStarted = await eventually { model.isApplyingLighting }
        XCTAssertTrue(writeStarted)
        model.draftLightingBrightnessLevel = 3

        let failed = await eventually {
            await session.lightingEditCount() == 1 && !model.isBusy && model.hasLightingWriteError
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(model.isLightingDraftDirty)
        try? await Task.sleep(for: .milliseconds(50))
        let noAutomaticRetry = await session.lightingEditCount()
        XCTAssertEqual(noAutomaticRetry, 1)

        model.draftLightingIdleOff = .thirtySeconds
        let newAdjustmentApplied = await eventually {
            await session.lightingEditCount() == 2 && !model.isBusy
        }
        XCTAssertTrue(newAdjustmentApplied)
        let latestEdit = await session.lastLightingEdit()
        XCTAssertEqual(latestEdit?.brightnessLevel, 2)
        await model.stop()
    }

    func testPartialLightingEditPreservesUnknownReadbackFields() async {
        let initialLighting = FlowLite84Lighting(mode: 15, enabled: true, idleOffUnits: 0, brightnessLevel: 9)
        let initialRead = snapshot(online: false, lighting: initialLighting)
        let confirmedLighting = FlowLite84Lighting(mode: 4, enabled: true, idleOffUnits: 0, brightnessLevel: 9)
        let confirmedRead = snapshot(
            online: false,
            lighting: confirmedLighting,
            canRestoreOriginalLighting: true,
            at: Date(timeIntervalSince1970: 200)
        )
        let session = FixtureFlowLite84Session(snapshot: initialRead, lightingWriteSnapshot: confirmedRead)
        let model = FlowLite84Model(session: session)
        model.connect()

        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)
        XCTAssertNil(model.draftLightingEffect)
        XCTAssertNil(model.draftLightingIdleOff)
        XCTAssertEqual(model.lightingDraftEffectPlaceholder, "Keep unknown mode (reported 15)")
        XCTAssertEqual(model.lightingDraftIdleOffPlaceholder, "Keep default / unknown (reported 0)")
        XCTAssertFalse(model.canEditLightingEffectDependentFields)
        model.draftLightingBrightnessLevel = 5
        XCTAssertNil(model.draftLightingBrightnessLevel)

        model.draftLightingEffect = .trailing
        XCTAssertTrue(model.canEditLightingEffectDependentFields)
        model.applyLightingDraft()
        let applied = await eventually { model.snapshot == confirmedRead && !model.isBusy }
        XCTAssertTrue(applied)

        let edit = await session.lastLightingEdit()
        XCTAssertEqual(edit?.effect, .trailing)
        XCTAssertNil(edit?.enabled)
        XCTAssertNil(edit?.brightnessLevel)
        XCTAssertNil(edit?.speedLevel)
        XCTAssertNil(edit?.idleOff)
        XCTAssertEqual(model.snapshot?.lighting?.idleOffUnits, 0)
        XCTAssertEqual(model.snapshot?.lighting?.brightnessLevel, 9)
        await model.stop()
    }

    func testKnownLightingFieldsCanBeChosenWhenCurrentLightingReadbackIsUnavailable() async {
        let initialRead = snapshot(online: false)
        let confirmedRead = snapshot(
            online: false,
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 1, brightnessLevel: 4),
            canRestoreOriginalLighting: true,
            at: Date(timeIntervalSince1970: 200)
        )
        let session = FixtureFlowLite84Session(snapshot: initialRead, lightingWriteSnapshot: confirmedRead)
        let model = FlowLite84Model(session: session)
        model.connect()

        let connected = await eventually { model.isConnected && model.snapshot == initialRead && !model.isBusy }
        XCTAssertTrue(connected)
        XCTAssertTrue(model.canEditLighting)
        XCTAssertNil(model.draftLightingEffect)
        XCTAssertNil(model.draftLightingEnabled)
        XCTAssertNil(model.draftLightingBrightnessLevel)
        XCTAssertNil(model.draftLightingIdleOff)

        model.draftLightingEffect = .steady
        model.draftLightingEnabled = true
        model.draftLightingBrightnessLevel = 5
        model.applyLightingDraft()
        let applied = await eventually { model.snapshot == confirmedRead && !model.isBusy }
        XCTAssertTrue(applied)

        let edit = await session.lastLightingEdit()
        XCTAssertEqual(edit?.effect, .steady)
        XCTAssertEqual(edit?.enabled, true)
        XCTAssertEqual(edit?.brightnessLevel, 4)
        XCTAssertNil(edit?.speedLevel)
        XCTAssertNil(edit?.idleOff)
        await model.stop()
    }

    func testLightingApplyPreservesNewerBatteryReceipt() async {
        let initialRead = snapshot(
            online: false,
            battery: FlowLite84Battery(reportedLevel: 30),
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 1, brightnessLevel: 0),
            batteryReadAt: Date(timeIntervalSince1970: 110)
        )
        let newerBatteryRead = snapshot(
            online: false,
            battery: FlowLite84Battery(reportedLevel: 45),
            lighting: initialRead.lighting,
            batteryReadAt: Date(timeIntervalSince1970: 300)
        )
        let confirmedRead = snapshot(
            online: false,
            battery: initialRead.battery,
            lighting: FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 1, brightnessLevel: 0),
            canRestoreOriginalSystemMode: true,
            batteryReadAt: Date(timeIntervalSince1970: 110),
            at: Date(timeIntervalSince1970: 200)
        )
        let session = FixtureFlowLite84Session(
            snapshot: initialRead,
            lightingWriteSnapshot: confirmedRead,
            lightingProgressSnapshot: newerBatteryRead,
            lightingWriteDelay: .milliseconds(20)
        )
        let model = FlowLite84Model(session: session)
        model.connect()
        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)

        model.draftLightingEffect = .breathing
        model.applyLightingDraft()
        let batteryReceived = await eventually {
            model.snapshot?.battery?.reportedLevel == 45 && model.isBusy
        }
        XCTAssertTrue(batteryReceived)
        let applied = await eventually { !model.isBusy && model.snapshot?.lighting?.mode == 5 }
        XCTAssertTrue(applied)
        XCTAssertEqual(model.snapshot?.battery?.reportedLevel, 45)
        XCTAssertEqual(model.snapshot?.batteryReadAt, Date(timeIntervalSince1970: 300))
        XCTAssertTrue(model.snapshot?.canRestoreOriginalSystemMode == true)
        await model.stop()
    }

    func testDisconnectInvalidatesPendingLightingCompletion() async {
        let initialRead = snapshot(
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 1, brightnessLevel: 0)
        )
        let confirmedRead = snapshot(
            lighting: FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 1, brightnessLevel: 0),
            at: Date(timeIntervalSince1970: 200)
        )
        let session = FixtureFlowLite84Session(
            snapshot: initialRead,
            lightingWriteSnapshot: confirmedRead,
            lightingWriteDelay: .seconds(5)
        )
        let model = FlowLite84Model(session: session)
        model.connect()
        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)

        model.draftLightingEffect = .breathing
        model.applyLightingDraft()
        let writeStarted = await eventually { model.isApplyingLighting }
        XCTAssertTrue(writeStarted)
        model.disconnect()

        let disconnected = await eventually { model.connectionTitle == "Disconnected" }
        XCTAssertTrue(disconnected)
        let cancelledWrites = await session.cancelledLightingWriteCount()
        XCTAssertEqual(cancelledWrites, 1)
        XCTAssertEqual(model.snapshot, initialRead)
        XCTAssertFalse(model.isBusy)
        await model.stop()
    }

    func testLifecycleDiscardsPendingLightingAutoApplyAndReconnectDoesNotReplayIt() async {
        let initialRead = snapshot(
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0)
        )
        let session = FixtureFlowLite84Session(snapshot: initialRead)
        let model = FlowLite84Model(session: session, lightingAutoApplyDelay: .milliseconds(100))
        model.connect()

        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        model.sleep()

        let disconnected = await eventually { model.connectionTitle == "Disconnected" }
        XCTAssertTrue(disconnected)
        try? await Task.sleep(for: .milliseconds(120))
        let writesBeforeReconnect = await session.lightingEditCount()
        XCTAssertEqual(writesBeforeReconnect, 0)

        model.wake()
        let reconnected = await eventually {
            await session.connectionCount() == 2 && model.isConnected && !model.isBusy
        }
        XCTAssertTrue(reconnected)
        try? await Task.sleep(for: .milliseconds(120))
        let writesAfterReconnect = await session.lightingEditCount()
        XCTAssertEqual(writesAfterReconnect, 0)
        await model.stop()
    }

    func testExplicitLightingRestoreCancelsPendingAutoApply() async {
        let initialRead = snapshot(
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0),
            canRestoreOriginalLighting: true
        )
        let restoredRead = snapshot(
            lighting: initialRead.lighting,
            canRestoreOriginalLighting: false,
            at: Date(timeIntervalSince1970: 200)
        )
        let session = FixtureFlowLite84Session(snapshot: initialRead, lightingRestoreSnapshot: restoredRead)
        let model = FlowLite84Model(session: session, lightingAutoApplyDelay: .milliseconds(100))
        model.connect()

        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        model.restorePreviousLighting()

        let restored = await eventually { await session.lightingRestoreCount() == 1 && !model.isBusy }
        XCTAssertTrue(restored)
        try? await Task.sleep(for: .milliseconds(120))
        let edits = await session.lightingEditCount()
        XCTAssertEqual(edits, 0)
        XCTAssertEqual(model.draftLightingEffect, .steady)
        await model.stop()
    }

    func testSystemModeAutomaticallyAppliesAndSerializesDueLightingEdit() async {
        let initialRead = snapshot(
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0, speedLevel: 3),
            systemMode: 2,
            canRestoreOriginalSystemMode: true
        )
        let systemModeRead = snapshot(
            lighting: initialRead.lighting,
            systemMode: 0,
            canRestoreOriginalSystemMode: true,
            at: Date(timeIntervalSince1970: 200)
        )
        let lightingRead = snapshot(
            lighting: FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 6, brightnessLevel: 0, speedLevel: 4),
            systemMode: 0,
            canRestoreOriginalSystemMode: true,
            at: Date(timeIntervalSince1970: 300)
        )
        let originalSystemModeRead = snapshot(
            lighting: lightingRead.lighting,
            systemMode: 2,
            canRestoreOriginalSystemMode: false,
            at: Date(timeIntervalSince1970: 400)
        )
        let session = FixtureFlowLite84Session(
            snapshot: initialRead,
            lightingWriteSnapshot: lightingRead,
            systemModeWriteSnapshot: systemModeRead,
            systemModeRestoreSnapshot: originalSystemModeRead,
            systemModeWriteDelay: .milliseconds(60)
        )
        let model = FlowLite84Model(
            session: session,
            lightingAutoApplyDelay: .milliseconds(10),
            systemModeAutoApplyDelay: .milliseconds(10)
        )
        model.connect()

        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)
        XCTAssertNil(model.draftSystemMode)
        XCTAssertEqual(model.systemModeDraftPlaceholder, "Reported Android (read-only)")

        model.draftSystemMode = .windows
        let modeStarted = await eventually { model.isApplyingSystemMode }
        XCTAssertTrue(modeStarted)
        XCTAssertTrue(model.canEditLighting)
        model.draftLightingEffect = .breathing
        let serializedEditsCompleted = await eventually {
            let systemModeWrites = await session.systemModeApplyCount()
            let lightingWrites = await session.lightingEditCount()
            return systemModeWrites == 1 && lightingWrites == 1 && !model.isBusy
        }
        XCTAssertTrue(serializedEditsCompleted)
        XCTAssertEqual(model.snapshot?.systemMode, 0)
        XCTAssertEqual(model.draftLightingSpeedLevel, 5)
        XCTAssertFalse(model.isLightingDraftDirty)

        model.draftSystemMode = .mac
        model.restoreOriginalSystemMode()
        let restored = await eventually {
            await session.systemModeRestoreCount() == 1 && !model.isBusy
        }
        XCTAssertTrue(restored)
        XCTAssertEqual(model.snapshot?.systemMode, 2)
        try? await Task.sleep(for: .milliseconds(30))
        let systemWritesAfterUndo = await session.systemModeApplyCount()
        XCTAssertEqual(systemWritesAfterUndo, 1)
        let maxWrites = await session.maximumConcurrentWriteCount()
        XCTAssertEqual(maxWrites, 1)
        await model.stop()
    }

    func testRejectedSystemModeWriteDiscardsDueLightingIntentAndKeepsErrorVisible() async {
        let initialRead = snapshot(
            lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0),
            systemMode: 1,
            canRestoreOriginalSystemMode: true
        )
        let session = FixtureFlowLite84Session(
            snapshot: initialRead,
            failSystemModeWrite: true,
            systemModeWriteDelay: .milliseconds(40)
        )
        let model = FlowLite84Model(session: session, lightingAutoApplyDelay: .milliseconds(10))
        model.connect()

        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)
        model.draftSystemMode = .windows
        model.draftLightingEffect = .breathing
        model.applySystemModeDraft()

        let failed = await eventually {
            !model.isBusy && model.errorMessage == "The receiver rejected the settings change. Earlier changes may have been applied."
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(model.isConnected)
        XCTAssertTrue(model.isLightingDraftDirty)
        try? await Task.sleep(for: .milliseconds(60))

        let lightingWrites = await session.lightingEditCount()
        XCTAssertEqual(lightingWrites, 0)
        XCTAssertEqual(
            model.errorMessage,
            "The receiver rejected the settings change. Earlier changes may have been applied."
        )
        await model.stop()
    }

    func testSystemModeUsesDefaultTwoHundredMillisecondDebounceFromLatestSelection() async {
        let session = FixtureFlowLite84Session(
            snapshot: snapshot(systemMode: 2),
            systemModeWriteSnapshot: snapshot(systemMode: 1)
        )
        let model = FlowLite84Model(session: session)
        model.connect()
        let connected = await eventually { model.canEditSystemMode }
        XCTAssertTrue(connected)

        model.draftSystemMode = .windows
        try? await Task.sleep(for: .milliseconds(110))
        model.draftSystemMode = .mac
        try? await Task.sleep(for: .milliseconds(130))
        let beforeDue = await session.systemModeApplyCount()
        XCTAssertEqual(beforeDue, 0)
        let applied = await eventually { await session.systemModeApplyCount() == 1 && !model.isBusy }
        XCTAssertTrue(applied)
        let modes = await session.recordedSystemModes()
        XCTAssertEqual(modes, [.mac])
        XCTAssertEqual(model.draftSystemMode, .mac)
        XCTAssertFalse(model.isSystemModeDraftDirty)
        await model.stop()
    }

    func testLightingUsesDefaultTwoHundredMillisecondDebounceFromLatestAdjustment() async {
        let session = FixtureFlowLite84Session(
            snapshot: snapshot(lighting: FlowLite84Lighting(mode: 10, enabled: false, idleOffUnits: 6, brightnessLevel: 0)),
            lightingWriteSnapshot: snapshot(lighting: FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 6, brightnessLevel: 0))
        )
        let model = FlowLite84Model(session: session)
        model.connect()
        let connected = await eventually { model.canEditLighting }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        try? await Task.sleep(for: .milliseconds(110))
        model.draftLightingEnabled = true
        try? await Task.sleep(for: .milliseconds(130))
        let beforeDue = await session.lightingEditCount()
        XCTAssertEqual(beforeDue, 0)
        let settled = await eventually { await session.lightingEditCount() == 1 && !model.isBusy }
        XCTAssertTrue(settled)
        let edit = await session.lastLightingEdit()
        XCTAssertEqual(edit?.effect, .breathing)
        XCTAssertEqual(edit?.enabled, true)
        await model.stop()
    }

    func testModeRevertDuringWriteSurvivesOlderConfirmationBeforeOrAfterDebounce() async {
        for delay in [Duration.milliseconds(10), .milliseconds(100)] {
            let session = FixtureFlowLite84Session(
                snapshot: snapshot(systemMode: 1),
                systemModeWriteSnapshots: [snapshot(systemMode: 0), snapshot(systemMode: 1)],
                systemModeWriteDelay: .milliseconds(40)
            )
            let model = FlowLite84Model(session: session, systemModeAutoApplyDelay: delay)
            model.connect()
            let connected = await eventually { model.canEditSystemMode }
            XCTAssertTrue(connected)
            model.draftSystemMode = .windows
            model.applySystemModeDraft()
            let firstStarted = await eventually { await session.systemModeApplyCount() == 1 }
            XCTAssertTrue(firstStarted)
            XCTAssertTrue(model.canEditSystemMode)
            model.draftSystemMode = .mac

            let settled = await eventually {
                await session.systemModeApplyCount() == 2 && !model.isBusy
            }
            XCTAssertTrue(settled)
            let modes = await session.recordedSystemModes()
            XCTAssertEqual(modes, [.windows, .mac])
            XCTAssertEqual(model.snapshot?.systemMode, 1)
            XCTAssertEqual(model.draftSystemMode, .mac)
            XCTAssertFalse(model.isSystemModeDraftDirty)
            let maximumWrites = await session.maximumConcurrentWriteCount()
            XCTAssertEqual(maximumWrites, 1)
            await model.stop()
        }
    }

    func testBothDueKindsDrainInDueOrderWithoutOverlappingTransportWrites() async {
        let initialLighting = FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0)
        let changedLighting = FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 6, brightnessLevel: 0)
        let session = FixtureFlowLite84Session(
            snapshot: snapshot(lighting: initialLighting, systemMode: 1),
            lightingWriteSnapshot: snapshot(lighting: changedLighting, systemMode: 0),
            systemModeWriteSnapshots: [
                snapshot(lighting: initialLighting, systemMode: 0),
                snapshot(lighting: changedLighting, systemMode: 1)
            ],
            lightingWriteDelay: .milliseconds(40),
            systemModeWriteDelay: .milliseconds(80)
        )
        let model = FlowLite84Model(
            session: session,
            lightingAutoApplyDelay: .milliseconds(10),
            systemModeAutoApplyDelay: .milliseconds(10)
        )
        model.connect()
        let connected = await eventually { model.canEditSystemMode }
        XCTAssertTrue(connected)
        model.draftSystemMode = .windows
        let modeStarted = await eventually { model.isApplyingSystemMode }
        XCTAssertTrue(modeStarted)
        model.draftLightingEffect = .breathing
        try? await Task.sleep(for: .milliseconds(20))
        model.draftSystemMode = .mac
        let settled = await eventually {
            await session.systemModeApplyCount() == 2 && !model.isBusy
        }
        XCTAssertTrue(settled)
        let order = await session.recordedWriteOrder()
        XCTAssertEqual(order, ["systemMode", "lighting", "systemMode"])
        let maximumWrites = await session.maximumConcurrentWriteCount()
        XCTAssertEqual(maximumWrites, 1)
        XCTAssertEqual(model.draftLightingEffect, .breathing)
        XCTAssertEqual(model.draftSystemMode, .mac)
        await model.stop()
    }

    func testLightingFailureCancelsDueModeAndModeFailureCanBeExplicitlyRetried() async {
        let session = FixtureFlowLite84Session(
            snapshot: snapshot(
                lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0),
                systemMode: 1
            ),
            systemModeWriteSnapshot: snapshot(systemMode: 0),
            lightingWriteDelay: .milliseconds(40)
        )
        let model = FlowLite84Model(
            session: session,
            lightingAutoApplyDelay: .milliseconds(10),
            systemModeAutoApplyDelay: .milliseconds(10)
        )
        model.connect()
        let connected = await eventually { model.canEditLighting }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        let started = await eventually { model.isApplyingLighting }
        XCTAssertTrue(started)
        model.draftSystemMode = .windows
        let failed = await eventually { model.hasLightingWriteError && !model.isBusy }
        XCTAssertTrue(failed)
        try? await Task.sleep(for: .milliseconds(30))
        let cancelledModes = await session.systemModeApplyCount()
        XCTAssertEqual(cancelledModes, 0)
        XCTAssertTrue(model.isSystemModeDraftDirty)
        XCTAssertNotNil(model.errorMessage)
        model.applySystemModeDraft()
        let explicitlyApplied = await eventually { await session.systemModeApplyCount() == 1 && !model.isBusy }
        XCTAssertTrue(explicitlyApplied)
        await model.stop()

        let rejectedSession = FixtureFlowLite84Session(snapshot: snapshot(systemMode: 1), failSystemModeWrite: true)
        let rejectedModel = FlowLite84Model(session: rejectedSession, systemModeAutoApplyDelay: .milliseconds(10))
        rejectedModel.connect()
        let retryConnected = await eventually { rejectedModel.canEditSystemMode }
        XCTAssertTrue(retryConnected)
        rejectedModel.draftSystemMode = .windows
        let rejected = await eventually { rejectedModel.hasSystemModeWriteError && !rejectedModel.isBusy }
        XCTAssertTrue(rejected)
        try? await Task.sleep(for: .milliseconds(30))
        let beforeRetry = await rejectedSession.systemModeApplyCount()
        XCTAssertEqual(beforeRetry, 1)
        rejectedModel.retrySystemModeDraft()
        let retried = await eventually { await rejectedSession.systemModeApplyCount() == 2 && !rejectedModel.isBusy }
        XCTAssertTrue(retried)
        await rejectedModel.stop()
    }

    func testRefreshFailureCancelsBothUnsentKindsAndKeepsItsError() async {
        let session = FixtureFlowLite84Session(
            snapshot: snapshot(
                lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0),
                systemMode: 1
            ),
            failRefresh: true,
            refreshDelay: .milliseconds(20)
        )
        let model = FlowLite84Model(
            session: session,
            lightingAutoApplyDelay: .milliseconds(60),
            systemModeAutoApplyDelay: .milliseconds(60)
        )
        model.connect()
        let connected = await eventually { model.canEditSystemMode }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        model.draftSystemMode = .windows
        model.refresh()
        let failed = await eventually { !model.isBusy && model.errorMessage != nil }
        XCTAssertTrue(failed)
        try? await Task.sleep(for: .milliseconds(90))
        let order = await session.recordedWriteOrder()
        XCTAssertTrue(order.isEmpty)
        XCTAssertEqual(model.errorMessage, "The Flow Lite84 status could not be refreshed.")
        XCTAssertTrue(model.isLightingDraftDirty)
        XCTAssertTrue(model.isSystemModeDraftDirty)
        await model.stop()
    }

    func testEveryLifecycleExitDiscardsBothAutoIntentsWithoutReconnectReplay() async {
        for exit in 0..<4 {
            let initial = snapshot(
                lighting: FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0),
                systemMode: 1
            )
            let session = FixtureFlowLite84Session(snapshot: initial)
            let model = FlowLite84Model(
                session: session,
                lightingAutoApplyDelay: .milliseconds(40),
                systemModeAutoApplyDelay: .milliseconds(40)
            )
            model.connect()
            let connected = await eventually { model.canEditSystemMode }
            XCTAssertTrue(connected)
            model.draftLightingEffect = .breathing
            model.draftSystemMode = .windows
            switch exit {
            case 0: model.sleep()
            case 1: model.disconnect()
            case 2: model.setSuspended(true)
            default: await model.stop()
            }
            let disconnected = await eventually { !model.isConnected && !model.isBusy }
            XCTAssertTrue(disconnected)
            try? await Task.sleep(for: .milliseconds(60))
            switch exit {
            case 0: model.wake()
            case 1: model.connect()
            case 2: model.setSuspended(false)
            default: model.connect()
            }
            if exit != 3 {
                let reconnected = await eventually { model.canEditSystemMode }
                XCTAssertTrue(reconnected)
                XCTAssertEqual(model.draftSystemMode, .mac)
            }
            try? await Task.sleep(for: .milliseconds(60))
            let order = await session.recordedWriteOrder()
            XCTAssertTrue(order.isEmpty)
            await model.stop()
        }
    }

    func testReadbackAndRefreshOfKnownOrUnknownSystemModeNeverScheduleWrites() async {
        for mode in [UInt8(0), 1, 2, 3, 255] {
            let read = snapshot(systemMode: mode)
            let session = FixtureFlowLite84Session(snapshot: read, refreshedSnapshot: read)
            let model = FlowLite84Model(session: session, systemModeAutoApplyDelay: .milliseconds(10))
            model.connect()
            let connected = await eventually { model.canEditSystemMode }
            XCTAssertTrue(connected)
            _ = model.draftSystemMode
            _ = model.systemModeDraftPlaceholder
            model.refresh()
            let refreshed = await eventually { await session.refreshCount() == 1 && !model.isBusy }
            XCTAssertTrue(refreshed)
            try? await Task.sleep(for: .milliseconds(20))
            let writes = await session.systemModeApplyCount()
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(model.snapshot?.systemMode, mode)
            XCTAssertEqual(model.draftSystemMode, FlowLite84SystemMode(rawValue: mode))
            await model.stop()
        }
    }

    func testModeUndoCancelsOnlyModeIntentAndKeepsIndependentLightingIntent() async {
        let lighting = FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0)
        let session = FixtureFlowLite84Session(
            snapshot: snapshot(lighting: lighting, systemMode: 0, canRestoreOriginalLighting: true, canRestoreOriginalSystemMode: true),
            lightingWriteSnapshot: snapshot(
                lighting: FlowLite84Lighting(mode: 5, enabled: true, idleOffUnits: 6, brightnessLevel: 0),
                systemMode: 2,
                canRestoreOriginalLighting: true
            ),
            systemModeRestoreSnapshot: snapshot(lighting: lighting, systemMode: 2, canRestoreOriginalLighting: true)
        )
        let model = FlowLite84Model(
            session: session,
            lightingAutoApplyDelay: .milliseconds(30),
            systemModeAutoApplyDelay: .milliseconds(30)
        )
        model.connect()
        let connected = await eventually { model.canEditSystemMode }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        model.draftSystemMode = .mac
        model.restoreOriginalSystemMode()
        let settled = await eventually { await session.lightingEditCount() == 1 && !model.isBusy }
        XCTAssertTrue(settled)
        let order = await session.recordedWriteOrder()
        XCTAssertEqual(order, ["restoreSystemMode", "lighting"])
        XCTAssertEqual(model.snapshot?.systemMode, 2)
        XCTAssertNil(model.draftSystemMode)
        XCTAssertTrue(model.canRestorePreviousLighting)
        XCTAssertFalse(model.canRestoreOriginalSystemMode)
        await model.stop()
    }

    func testFailedUndoCancelsUnrelatedPendingModeRatherThanMaskingItsError() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot(systemMode: 0, canRestoreOriginalLighting: true))
        let model = FlowLite84Model(session: session, systemModeAutoApplyDelay: .milliseconds(10))
        model.connect()
        let connected = await eventually { model.canEditSystemMode }
        XCTAssertTrue(connected)
        model.draftSystemMode = .mac
        model.restorePreviousLighting()
        let failed = await eventually { !model.isBusy && model.errorMessage != nil }
        XCTAssertTrue(failed)
        try? await Task.sleep(for: .milliseconds(30))
        let order = await session.recordedWriteOrder()
        XCTAssertEqual(order, ["restoreLighting"])
        XCTAssertTrue(model.isSystemModeDraftDirty)
        XCTAssertNotNil(model.errorMessage)
        await model.stop()
    }

    func testLightingUndoCancelsOnlyLightingIntentAndKeepsIndependentModeIntent() async {
        let lighting = FlowLite84Lighting(mode: 10, enabled: true, idleOffUnits: 6, brightnessLevel: 0)
        let session = FixtureFlowLite84Session(
            snapshot: snapshot(lighting: lighting, systemMode: 0, canRestoreOriginalLighting: true, canRestoreOriginalSystemMode: true),
            lightingRestoreSnapshot: snapshot(lighting: lighting, systemMode: 0, canRestoreOriginalSystemMode: true),
            systemModeWriteSnapshot: snapshot(lighting: lighting, systemMode: 1, canRestoreOriginalSystemMode: true)
        )
        let model = FlowLite84Model(
            session: session,
            lightingAutoApplyDelay: .milliseconds(30),
            systemModeAutoApplyDelay: .milliseconds(30)
        )
        model.connect()
        let connected = await eventually { model.canEditSystemMode }
        XCTAssertTrue(connected)
        model.draftLightingEffect = .breathing
        model.draftSystemMode = .mac
        model.restorePreviousLighting()
        let settled = await eventually { await session.systemModeApplyCount() == 1 && !model.isBusy }
        XCTAssertTrue(settled)
        let order = await session.recordedWriteOrder()
        XCTAssertEqual(order, ["restoreLighting", "systemMode"])
        XCTAssertEqual(model.draftLightingEffect, .steady)
        XCTAssertFalse(model.canRestorePreviousLighting)
        XCTAssertTrue(model.canRestoreOriginalSystemMode)
        await model.stop()
    }

    func testConnectOnLaunchSkipsUnavailableSessionAndRespectsExplicitDisconnect() async {
        let unavailableModel = FlowLite84Model()
        unavailableModel.connectOnLaunch()
        XCTAssertEqual(unavailableModel.status, .disconnected)
        XCTAssertFalse(unavailableModel.connectionRequested)

        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let model = FlowLite84Model(session: session)
        model.disconnect()
        model.connectOnLaunch()

        XCTAssertFalse(model.connectionRequested)
        let connectionCount = await session.connectionCount()
        XCTAssertEqual(connectionCount, 0)
        await model.stop()
    }

    func testKeyboardActivityRefreshesBatteryOnlyAfterAnHourWithoutIdlePolling() async {
        let initialRead = snapshot(battery: FlowLite84Battery(reportedLevel: 62, charging: false, voltageMillivolts: 3990))
        let refreshedRead = snapshot(battery: FlowLite84Battery(reportedLevel: 61, charging: true, voltageMillivolts: 3970))
        let session = FixtureFlowLite84Session(snapshot: initialRead, refreshedSnapshot: refreshedRead)
        let monitor = FixtureKeyboardActivityMonitor()
        var now = ContinuousClock().now
        let model = FlowLite84Model(
            session: session,
            keyboardActivityMonitor: monitor,
            monotonicNow: { now }
        )
        model.connect()

        let connected = await eventually {
            model.isConnected && model.snapshot == initialRead && monitor.startCount == 1
        }
        XCTAssertTrue(connected)

        try? await Task.sleep(for: .milliseconds(10))
        var batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)

        monitor.sendActivity()
        batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)

        now = now.advanced(by: .seconds(3_599))
        monitor.sendActivity()
        batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)

        now = now.advanced(by: .seconds(1))
        monitor.sendActivity()
        let refreshed = await eventually {
            let batteryRefreshCount = await session.batteryRefreshCount()
            return batteryRefreshCount == 1 && !model.isBusy
        }
        XCTAssertTrue(refreshed)
        let refreshCount = await session.refreshCount()
        XCTAssertEqual(refreshCount, 0)

        monitor.sendActivity()
        batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 1)
        await model.stop()
    }

    func testFailedAutomaticBatteryRefreshIsClaimedForAnHour() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot(), failBatteryRefresh: true)
        let monitor = FixtureKeyboardActivityMonitor()
        var now = ContinuousClock().now
        let model = FlowLite84Model(
            session: session,
            keyboardActivityMonitor: monitor,
            monotonicNow: { now }
        )
        model.connect()
        let connected = await eventually { model.isConnected && !model.isBusy }
        XCTAssertTrue(connected)

        now = now.advanced(by: .seconds(3_600))
        monitor.sendActivity()
        let failedAttempt = await eventually {
            let batteryRefreshCount = await session.batteryRefreshCount()
            return batteryRefreshCount == 1 && !model.isBusy && model.errorMessage != nil
        }
        XCTAssertTrue(failedAttempt)

        monitor.sendActivity()
        var batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 1)
        now = now.advanced(by: .seconds(3_599))
        monitor.sendActivity()
        batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 1)
        now = now.advanced(by: .seconds(1))
        monitor.sendActivity()
        let secondAttempt = await eventually {
            await session.batteryRefreshCount() == 2 && !model.isBusy
        }
        XCTAssertTrue(secondAttempt)
        await model.stop()
    }

    func testKeyboardActivityMonitorFollowsConnectionLifecycle() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let monitor = FixtureKeyboardActivityMonitor()
        let model = FlowLite84Model(session: session, keyboardActivityMonitor: monitor)
        model.connect()

        let initiallyMonitoring = await eventually { model.isConnected && monitor.startCount == 1 }
        XCTAssertTrue(initiallyMonitoring)

        model.sleep()
        let stoppedForSleep = await eventually { monitor.stopCount == 1 && !model.isConnected }
        XCTAssertTrue(stoppedForSleep)
        monitor.sendActivity()
        let batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)

        model.wake()
        let resumedAfterWake = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 2 && model.isConnected && monitor.startCount == 2
        }
        XCTAssertTrue(resumedAfterWake)

        model.setSuspended(true)
        let stoppedForSuspension = await eventually { monitor.stopCount == 2 && !model.isConnected }
        XCTAssertTrue(stoppedForSuspension)
        model.setSuspended(false)
        let resumedAfterSuspension = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 3 && model.isConnected && monitor.startCount == 3
        }
        XCTAssertTrue(resumedAfterSuspension)

        model.disconnect()
        let stoppedForDisconnect = await eventually { monitor.stopCount == 3 && !model.isConnected }
        XCTAssertTrue(stoppedForDisconnect)
        await model.stop()
    }

    func testDeinitRemovesKeyboardActivityMonitor() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let monitor = FixtureKeyboardActivityMonitor()
        var model: FlowLite84Model? = FlowLite84Model(
            session: session,
            keyboardActivityMonitor: monitor
        )
        model?.connect()

        let connected = await eventually {
            model?.isConnected == true && monitor.startCount == 1
        }
        XCTAssertTrue(connected)

        model = nil

        XCTAssertEqual(monitor.stopCount, 1)
    }

    func testOlderGenerationCannotReplaceCurrentStatusOrSnapshot() async {
        let originalRead = snapshot(online: true, at: Date(timeIntervalSince1970: 100))
        let session = FixtureFlowLite84Session(snapshot: originalRead)
        let model = FlowLite84Model(session: session)
        model.connect()

        let connected = await eventually { model.isConnected && model.snapshot == originalRead }
        XCTAssertTrue(connected)

        await session.emit(.status(.connecting, generation: 2))
        let reconnecting = await eventually {
            if case .connecting = model.status { true } else { false }
        }
        XCTAssertTrue(reconnecting)

        let staleRead = snapshot(online: false, at: Date(timeIntervalSince1970: 200))
        await session.emit(.status(.disconnected, generation: 1))
        await session.emit(.snapshot(staleRead, generation: 1))
        await session.emit(.status(.connected(identity()), generation: 2))

        let currentGenerationAccepted = await eventually {
            model.isConnected && model.snapshot == originalRead
        }
        XCTAssertTrue(currentGenerationAccepted)
        XCTAssertNotEqual(model.snapshot, staleRead)
        await model.stop()
    }

    func testOfflineKeyboardAndUnavailableFieldsRemainExplicit() async {
        let offlineRead = snapshot(online: false)
        let session = FixtureFlowLite84Session(snapshot: offlineRead)
        let model = FlowLite84Model(session: session)
        model.connect()

        let readArrived = await eventually { model.isConnected && model.snapshot == offlineRead }
        XCTAssertTrue(readArrived)
        XCTAssertFalse(model.isKeyboardOnline)
        XCTAssertEqual(model.batteryText, "Unavailable")
        await model.stop()
    }

    func testSleepReleasesHandleAndWakeReconnectsOnlyWhileRequested() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let model = FlowLite84Model(session: session)
        model.connect()

        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)

        model.sleep()
        XCTAssertTrue(model.connectionRequested)
        let released = await eventually {
            let disconnectCount = await session.disconnectCount()
            return disconnectCount == 1 && !model.isConnected
        }
        XCTAssertTrue(released)

        model.wake()
        let reconnected = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 2 && model.isConnected
        }
        XCTAssertTrue(reconnected)

        model.disconnect()
        let disconnected = await eventually { !model.connectionRequested && !model.isConnected }
        XCTAssertTrue(disconnected)
        model.sleep()
        model.wake()
        let connectionCountAfterWake = await session.connectionCount()
        XCTAssertEqual(connectionCountAfterWake, 2)
        await model.stop()
    }

    func testSleepCancelsPendingConnectAndRefreshBeforeDisconnecting() async {
        let pausedConnectSession = FixtureFlowLite84Session(snapshot: snapshot(), pauseConnect: true)
        let connectingModel = FlowLite84Model(session: pausedConnectSession)
        connectingModel.connect()

        let connectStarted = await eventually {
            let connectionCount = await pausedConnectSession.connectionCount()
            return connectionCount == 1 && connectingModel.connectionTitle == "Connecting"
        }
        XCTAssertTrue(connectStarted)
        connectingModel.sleep()
        let connectReleased = await eventually {
            let disconnectCount = await pausedConnectSession.disconnectCount()
            let cancelledCount = await pausedConnectSession.cancelledConnectCount()
            return disconnectCount == 1 && cancelledCount == 1 && !connectingModel.isConnected
        }
        XCTAssertTrue(connectReleased)

        let pausedRefreshSession = FixtureFlowLite84Session(snapshot: snapshot(), pauseRefresh: true)
        let monitor = FixtureKeyboardActivityMonitor()
        var now = ContinuousClock().now
        let refreshingModel = FlowLite84Model(
            session: pausedRefreshSession,
            keyboardActivityMonitor: monitor,
            monotonicNow: { now }
        )
        refreshingModel.connect()
        let connected = await eventually { refreshingModel.isConnected && !refreshingModel.isBusy }
        XCTAssertTrue(connected)
        now = now.advanced(by: .seconds(3_600))
        refreshingModel.refresh()
        let refreshStarted = await eventually {
            let refreshCount = await pausedRefreshSession.refreshCount()
            return refreshCount == 1 && refreshingModel.isRefreshing
        }
        XCTAssertTrue(refreshStarted)
        monitor.sendActivity()
        let batteryRefreshCount = await pausedRefreshSession.batteryRefreshCount()
        XCTAssertEqual(batteryRefreshCount, 0)
        refreshingModel.sleep()
        let refreshReleased = await eventually {
            let disconnectCount = await pausedRefreshSession.disconnectCount()
            let cancelledCount = await pausedRefreshSession.cancelledRefreshCount()
            return disconnectCount == 1 && cancelledCount == 1 && !refreshingModel.isConnected && monitor.stopCount == 1
        }
        XCTAssertTrue(refreshReleased)
        await connectingModel.stop()
        await refreshingModel.stop()
    }

    func testSuspensionReleasesAndResumesOnlyAnRequestedConnection() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let model = FlowLite84Model(session: session)
        model.connect()
        let connected = await eventually { model.isConnected }
        XCTAssertTrue(connected)

        model.setSuspended(true)
        XCTAssertTrue(model.connectionRequested)
        let released = await eventually {
            let disconnectCount = await session.disconnectCount()
            return disconnectCount == 1 && !model.isConnected
        }
        XCTAssertTrue(released)

        model.setSuspended(false)
        let resumed = await eventually {
            let connectionCount = await session.connectionCount()
            return connectionCount == 2 && model.isConnected
        }
        XCTAssertTrue(resumed)
        await model.stop()
    }

    func testStopClearsConnectionIntentAndPreventsWakeReconnect() async {
        let session = FixtureFlowLite84Session(snapshot: snapshot())
        let monitor = FixtureKeyboardActivityMonitor()
        let model = FlowLite84Model(session: session, keyboardActivityMonitor: monitor)
        model.connect()

        let connected = await eventually { model.isConnected && monitor.startCount == 1 }
        XCTAssertTrue(connected)
        await model.stop()
        XCTAssertEqual(monitor.stopCount, 1)
        monitor.sendActivity()
        model.wake()

        let connectionCount = await session.connectionCount()
        let batteryRefreshCount = await session.batteryRefreshCount()
        XCTAssertFalse(model.connectionRequested)
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(batteryRefreshCount, 0)
    }

    private func snapshot(
        online: Bool = true,
        battery: FlowLite84Battery? = nil,
        lighting: FlowLite84Lighting? = nil,
        systemMode: UInt8? = nil,
        canRestoreOriginalLighting: Bool = false,
        canRestoreOriginalSystemMode: Bool = false,
        batteryReadAt: Date? = nil,
        at readAt: Date = Date(timeIntervalSince1970: 100)
    ) -> FlowLite84Snapshot {
        FlowLite84Snapshot(
            identity: identity(),
            online: online,
            battery: battery,
            lighting: lighting,
            systemMode: systemMode,
            readAt: readAt,
            batteryReadAt: batteryReadAt,
            canRestoreOriginalLighting: canRestoreOriginalLighting,
            canRestoreOriginalSystemMode: canRestoreOriginalSystemMode
        )
    }

    private func identity() -> FlowLite84Identity {
        FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)
    }

    private func eventually(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<500 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await predicate()
    }
}

private actor FixtureFlowLite84Session: FlowLite84SessionProtocol {
    nonisolated let events: AsyncStream<FlowLite84Event>
    private let continuation: AsyncStream<FlowLite84Event>.Continuation
    private let snapshot: FlowLite84Snapshot?
    private let refreshedSnapshot: FlowLite84Snapshot?
    private let pauseConnect: Bool
    private let pauseRefresh: Bool
    private let failBatteryRefresh: Bool
    private let failRefresh: Bool
    private let refreshDelay: Duration?
    private let lightingWriteSnapshot: FlowLite84Snapshot?
    private let lightingRestoreSnapshot: FlowLite84Snapshot?
    private let systemModeWriteSnapshot: FlowLite84Snapshot?
    private let systemModeWriteSnapshots: [FlowLite84Snapshot]
    private let systemModeRestoreSnapshot: FlowLite84Snapshot?
    private let failSystemModeWrite: Bool
    private let lightingProgressSnapshot: FlowLite84Snapshot?
    private let lightingWriteDelay: Duration?
    private let systemModeWriteDelay: Duration?
    private var generation: UInt64 = 0
    private var connects = 0
    private var disconnects = 0
    private var refreshes = 0
    private var batteryRefreshes = 0
    private var cancelledConnects = 0
    private var cancelledRefreshes = 0
    private var lightingEdits: [FlowLite84LightingEdit] = []
    private var lightingRestores = 0
    private var cancelledLightingWrites = 0
    private var systemModeEdits: [FlowLite84SystemMode] = []
    private var systemModeRestores = 0
    private var activeWrites = 0
    private var maximumConcurrentWrites = 0
    private var writeOrder: [String] = []

    init(
        snapshot: FlowLite84Snapshot?,
        refreshedSnapshot: FlowLite84Snapshot? = nil,
        pauseConnect: Bool = false,
        pauseRefresh: Bool = false,
        failBatteryRefresh: Bool = false,
        failRefresh: Bool = false,
        refreshDelay: Duration? = nil,
        lightingWriteSnapshot: FlowLite84Snapshot? = nil,
        lightingRestoreSnapshot: FlowLite84Snapshot? = nil,
        systemModeWriteSnapshot: FlowLite84Snapshot? = nil,
        systemModeWriteSnapshots: [FlowLite84Snapshot] = [],
        systemModeRestoreSnapshot: FlowLite84Snapshot? = nil,
        failSystemModeWrite: Bool = false,
        lightingProgressSnapshot: FlowLite84Snapshot? = nil,
        lightingWriteDelay: Duration? = nil,
        systemModeWriteDelay: Duration? = nil
    ) {
        let stream = AsyncStream<FlowLite84Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        self.snapshot = snapshot
        self.refreshedSnapshot = refreshedSnapshot
        self.pauseConnect = pauseConnect
        self.pauseRefresh = pauseRefresh
        self.failBatteryRefresh = failBatteryRefresh
        self.failRefresh = failRefresh
        self.refreshDelay = refreshDelay
        self.lightingWriteSnapshot = lightingWriteSnapshot
        self.lightingRestoreSnapshot = lightingRestoreSnapshot
        self.systemModeWriteSnapshot = systemModeWriteSnapshot
        self.systemModeWriteSnapshots = systemModeWriteSnapshots
        self.systemModeRestoreSnapshot = systemModeRestoreSnapshot
        self.failSystemModeWrite = failSystemModeWrite
        self.lightingProgressSnapshot = lightingProgressSnapshot
        self.lightingWriteDelay = lightingWriteDelay
        self.systemModeWriteDelay = systemModeWriteDelay
    }

    func connect() async throws {
        connects += 1
        generation &+= 1
        continuation.yield(.status(.connecting, generation: generation))
        if pauseConnect {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancelledConnects += 1
                throw error
            }
        }
        continuation.yield(.status(.connected(FlowLite84Identity(cid: 1, mid: 1, connectionType: 0)), generation: generation))
        if let snapshot {
            continuation.yield(.snapshot(snapshot, generation: generation))
        }
    }

    func refresh() async throws {
        refreshes += 1
        if let refreshDelay { try await Task.sleep(for: refreshDelay) }
        if failRefresh { throw FixtureFailure.failed }
        if pauseRefresh {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                cancelledRefreshes += 1
                throw error
            }
        }
        if let refreshedSnapshot {
            continuation.yield(.snapshot(refreshedSnapshot, generation: generation))
        }
    }

    func refreshBattery() async throws {
        batteryRefreshes += 1
        if failBatteryRefresh { throw FixtureFailure.failed }
        if let refreshedSnapshot {
            continuation.yield(.snapshot(refreshedSnapshot, generation: generation))
        }
    }

    func applyLighting(_ edit: FlowLite84LightingEdit) async throws -> FlowLite84Snapshot {
        beginWrite("lighting")
        defer { activeWrites -= 1 }
        lightingEdits.append(edit)
        if let lightingProgressSnapshot {
            continuation.yield(.snapshot(lightingProgressSnapshot, generation: generation))
        }
        if let lightingWriteDelay {
            do {
                try await Task.sleep(for: lightingWriteDelay)
            } catch {
                cancelledLightingWrites += 1
                throw error
            }
        }
        guard let lightingWriteSnapshot else { throw FixtureFailure.failed }
        continuation.yield(.snapshot(lightingWriteSnapshot, generation: generation))
        return lightingWriteSnapshot
    }

    func restoreOriginalLighting() async throws -> FlowLite84Snapshot {
        beginWrite("restoreLighting")
        defer { activeWrites -= 1 }
        lightingRestores += 1
        guard let lightingRestoreSnapshot else { throw FlowLite84Failure.noOriginalLighting }
        continuation.yield(.snapshot(lightingRestoreSnapshot, generation: generation))
        return lightingRestoreSnapshot
    }

    func applySystemMode(_ mode: FlowLite84SystemMode) async throws -> FlowLite84Snapshot {
        beginWrite("systemMode")
        defer { activeWrites -= 1 }
        systemModeEdits.append(mode)
        if let systemModeWriteDelay {
            try await Task.sleep(for: systemModeWriteDelay)
        }
        if failSystemModeWrite {
            throw FlowLite84Failure.rejected(command: 7, status: 1)
        }
        let index = systemModeEdits.count - 1
        let confirmed = systemModeWriteSnapshots.indices.contains(index)
            ? systemModeWriteSnapshots[index] : systemModeWriteSnapshot
        guard let confirmed else { throw FixtureFailure.failed }
        continuation.yield(.snapshot(confirmed, generation: generation))
        return confirmed
    }

    func restoreOriginalSystemMode() async throws -> FlowLite84Snapshot {
        beginWrite("restoreSystemMode")
        defer { activeWrites -= 1 }
        systemModeRestores += 1
        guard let systemModeRestoreSnapshot else { throw FlowLite84Failure.noOriginalSystemMode }
        continuation.yield(.snapshot(systemModeRestoreSnapshot, generation: generation))
        return systemModeRestoreSnapshot
    }

    func disconnect() async {
        disconnects += 1
        continuation.yield(.status(.disconnected, generation: generation))
    }

    func emit(_ event: FlowLite84Event) {
        continuation.yield(event)
    }

    private func beginWrite(_ kind: String) {
        activeWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, activeWrites)
        writeOrder.append(kind)
    }

    func maximumConcurrentWriteCount() -> Int { maximumConcurrentWrites }
    func recordedWriteOrder() -> [String] { writeOrder }
    func recordedSystemModes() -> [FlowLite84SystemMode] { systemModeEdits }
    func connectionCount() -> Int { connects }
    func disconnectCount() -> Int { disconnects }
    func refreshCount() -> Int { refreshes }
    func batteryRefreshCount() -> Int { batteryRefreshes }
    func lightingEditCount() -> Int { lightingEdits.count }
    func lastLightingEdit() -> FlowLite84LightingEdit? { lightingEdits.last }
    func lightingEdit(at index: Int) -> FlowLite84LightingEdit? {
        guard lightingEdits.indices.contains(index) else { return nil }
        return lightingEdits[index]
    }
    func lightingRestoreCount() -> Int { lightingRestores }
    func cancelledLightingWriteCount() -> Int { cancelledLightingWrites }
    func systemModeApplyCount() -> Int { systemModeEdits.count }
    func systemModeRestoreCount() -> Int { systemModeRestores }
    func cancelledConnectCount() -> Int { cancelledConnects }
    func cancelledRefreshCount() -> Int { cancelledRefreshes }
}

@MainActor
private final class FixtureKeyboardActivityMonitor: KeyboardActivityMonitoring {
    private var onActivity: (@MainActor () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onActivity: @escaping @MainActor () -> Void) {
        startCount += 1
        self.onActivity = onActivity
    }

    func stop() {
        guard onActivity != nil else { return }
        stopCount += 1
        onActivity = nil
    }

    func sendActivity() {
        onActivity?()
    }
}

private enum FixtureFailure: Error {
    case failed
}
