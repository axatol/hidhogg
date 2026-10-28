import CoreGraphics
import Foundation
import HidhoggDomain
import ImageIO
import MacOSActions
import UniformTypeIdentifiers
import UlanziD200X
import XCTest
@testable import HidhoggApp

@MainActor
final class D200XDisplayModelTests: XCTestCase {
    func testAutomaticReconnectStartsFreshMetricsAndDiscardsOldTimer() async throws {
        let clock = UncancellableDisplayTickClock()
        let session = DisplayModelSession()
        var samples = 0
        let model = D200XModel(session: session,
            sender: ShortcutSender(preflight: { true }, request: { false }, postPair: { _ in }),
            frontmostApplication: { nil }, delay: { _ in }, sampleMetrics: {
                samples += 1
                return D200XMetricsSnapshot(cpu: Double(samples), memory: 63, gpu: 26)
            }, displayDelay: { try await clock.sleep($0) })
        model.synchronize(D200XConfiguration(wideDisplayMode: .systemStatus), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [0] })
        displayAssertTrue(await eventually { await clock.count() == 1 })
        await session.failConnection()
        displayAssertTrue(await eventually { await session.modes() == [0, 0] })
        displayAssertEqual(samples, 2)
        displayAssertTrue(await eventually { await clock.count() == 2 })
        await clock.advance(0)
        try await Task.sleep(for: .milliseconds(20))
        displayAssertEqual(await clock.count(), 2)
        displayAssertEqual(samples, 2)
        await model.stop()
        await clock.releaseAll()
    }

    func testLeavingSystemStatusPreservesNumericWireFieldsForEveryMode() async throws {
        let session = DisplayModelSession()
        let model = makeModel(session, metrics: D200XMetricsSnapshot(cpu: 12, memory: 63, gpu: 26))
        model.synchronize(D200XConfiguration(wideDisplayMode: .systemStatus), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [0] })
        let modes: [D200XWideDisplayMode] = [.clockFace, .background, .dateTimeWeekday, .timeWeekday, .timeDate, .time, .custom]
        for (index, mode) in modes.enumerated() {
            model.synchronize(D200XConfiguration(wideDisplayMode: mode), canEdit: true)
            displayAssertTrue(await eventually { await session.statuses().count == index + 2 })
        }
        displayAssertEqual(await session.modes(), [0, 1, 2, 200, 201, 202, 203, 2])
        let statuses = await session.statuses()
        for status in statuses {
            let fields = String(decoding: try status.payload(), as: UTF8.self)
                .split(separator: "|", omittingEmptySubsequences: false)
            displayAssertEqual(fields.count, 7)
            for index in [1, 2, 4] { XCTAssertNotNil(Int(fields[index])) }
            if status.mode != 0 {
                XCTAssertNil(status.cpu)
                XCTAssertNil(status.memory)
                XCTAssertNil(status.gpu)
            }
        }
        await model.stop()
    }

    func testClockToSystemStatusSamplesImmediatelyAndOldTimerCannotResume() async throws {
        let clock = UncancellableDisplayTickClock()
        let session = DisplayModelSession()
        var samples = 0
        let model = D200XModel(session: session,
            sender: ShortcutSender(preflight: { true }, request: { false }, postPair: { _ in }),
            frontmostApplication: { nil }, sampleMetrics: {
                samples += 1
                return D200XMetricsSnapshot(cpu: Double(samples), memory: 63, gpu: 26)
            }, displayDelay: { try await clock.sleep($0) })
        model.synchronize(D200XConfiguration(wideDisplayMode: .time), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [203] })
        displayAssertTrue(await eventually { await clock.count() == 1 })
        model.synchronize(D200XConfiguration(wideDisplayMode: .systemStatus), canEdit: true)
        displayAssertTrue(await eventually { await session.modes() == [203, 0] })
        displayAssertEqual(samples, 1)
        displayAssertTrue(await eventually { await clock.count() == 2 })
        await clock.advance(0)
        try await Task.sleep(for: .milliseconds(20))
        displayAssertEqual(await clock.count(), 2)
        displayAssertEqual(samples, 1)
        model.synchronize(.empty, canEdit: true)
        displayAssertTrue(await eventually { await session.modes() == [203, 0, 2] })
        await clock.advance(1)
        try await Task.sleep(for: .milliseconds(20))
        displayAssertEqual(await clock.count(), 2)
        displayAssertEqual(samples, 1)
        await model.stop()
        await clock.releaseAll()
    }

    func testRapidCropRevisionsCoalesceBeforeDecoding() async throws {
        let clock = DisplayTickClock()
        let preview = D200XScreensaverPreview(delay: { try await clock.sleep($0) }, render: { $0.source })
        for index in 0..<100 {
            preview.update(D200XScreensaverCropRequest(source: Data([UInt8(index)]), zoom: 1, horizontal: 0, vertical: 0))
        }
        displayAssertTrue(await eventually { await clock.isWaiting() })
        await clock.advance()
        displayAssertTrue(await eventually { preview.image == Data([99]) && !preview.isLoading })
        preview.cancel()
    }

    func testObsoleteCropIsCancelledAndNextCropWaitsForItsWorker() async throws {
        let renderer = BlockingPreviewRenderer()
        let preview = D200XScreensaverPreview(delay: { _ in }, render: { try renderer.render($0) })
        preview.update(D200XScreensaverCropRequest(source: Data([0]), zoom: 1, horizontal: 0, vertical: 0))
        displayAssertTrue(await eventually { renderer.started() == [0] })
        for index in 1...10 {
            preview.update(D200XScreensaverCropRequest(source: Data([UInt8(index)]), zoom: 1, horizontal: 0, vertical: 0))
        }
        displayAssertEqual(renderer.started(), [0])
        renderer.release()
        displayAssertTrue(await eventually { preview.image == Data([10]) && !preview.isLoading })
        displayAssertEqual(renderer.started(), [0, 10])
        displayAssertEqual(renderer.maximumActive(), 1)
        preview.update(D200XScreensaverCropRequest(source: Data([11]), zoom: 1, horizontal: 0, vertical: 0))
        preview.cancel()
        try await Task.sleep(for: .milliseconds(10))
        displayAssertEqual(preview.image, Data([10]))
        displayAssertFalse(preview.isLoading)
    }

    func testClockTickSendsOnlyStatusWithoutSamplingMetricsOrRedrawingPage() async throws {
        let clock = DisplayTickClock()
        let session = DisplayModelSession()
        var sampleCount = 0
        let model = D200XModel(session: session,
            sender: ShortcutSender(preflight: { true }, request: { false }, postPair: { _ in }),
            frontmostApplication: { nil }, sampleMetrics: { sampleCount += 1; return D200XMetricsSnapshot() },
            displayDelay: { try await clock.sleep($0) })
        model.synchronize(D200XConfiguration(wideDisplayMode: .time), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [203] })
        for _ in 0..<5 {
            displayAssertTrue(await eventually { await clock.isWaiting() })
            await clock.advance()
        }
        displayAssertTrue(await eventually { await session.modes() == [203, 203] })
        displayAssertEqual(await session.entries().filter { $0 == "page" }.count, 1)
        displayAssertEqual(sampleCount, 0)
        await model.stop()
    }

    func testFreshUnavailableGPUReplacesPreviouslyValidStatusWithoutInventedZero() async throws {
        let clock = DisplayTickClock()
        let session = DisplayModelSession()
        var sampleCount = 0
        let model = D200XModel(session: session,
            sender: ShortcutSender(preflight: { true }, request: { false }, postPair: { _ in }),
            frontmostApplication: { nil }, sampleMetrics: {
                sampleCount += 1
                return D200XMetricsSnapshot(cpu: 12, memory: 63, gpu: sampleCount == 1 ? 26 : nil)
            }, displayDelay: { try await clock.sleep($0) })
        model.synchronize(D200XConfiguration(wideDisplayMode: .systemStatus), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [0] })
        for _ in 0..<5 {
            displayAssertTrue(await eventually { await clock.isWaiting() })
            await clock.advance()
        }
        displayAssertTrue(await eventually { await session.modes() == [0, 2] })
        displayAssertEqual(sampleCount, 3)
        let latestGPU = await session.statuses().last?.gpu
        XCTAssertNil(latestGPU)
        displayAssertEqual(await session.entries().filter { $0 == "page" }.count, 1)
        await model.stop()
    }

    func testCustomDefaultLeavesExistingPageBehaviorUnchanged() async throws {
        let session = DisplayModelSession()
        let model = makeModel(session)
        model.synchronize(.empty, canEdit: true)
        model.connect()
        let sent = await eventually { await session.entries().contains("page") }
        displayAssertTrue(sent)
        displayAssertEqual(await session.modes(), [])
        let page = try displayUnwrap(await session.pages().first)
        XCTAssertNil(page.slots["3_2"]?.smallViewMode)
        await model.stop()
    }

    func testWideNotificationTemporarilyUsesCustomThenRestoresChosenMode() async throws {
        let session = DisplayModelSession()
        let model = makeModel(session)
        model.synchronize(D200XConfiguration(wideDisplayMode: .time, clockFormat: .twelveHour), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [203] })
        try await model.applyNotificationLabels(["key13": "Temporary"])
        try await model.applyNotificationLabels([:])
        displayAssertEqual(await session.modes(), [203, 2, 203])
        displayAssertEqual(model.configuration?.wideDisplayMode, .time)
        let pages = await session.pages()
        displayAssertEqual(pages.count, 3)
        displayAssertTrue(pages.allSatisfy { $0.slots["3_2"]?.smallViewMode == 2 })
        displayAssertTrue(pages.allSatisfy { $0.slots.filter { $0.key != "3_2" }.allSatisfy { $0.value.smallViewMode == nil } })
        let entries = await session.entries()
        displayAssertEqual(Array(entries.prefix(6)), ["page", "mode203", "page", "mode2", "page", "mode203"])
        do {
            try await model.applyNotificationLabels(["key13": "Rejected"], authorize: { false })
            XCTFail("unauthorized notification applied")
        } catch {}
        displayAssertEqual(await session.modes(), [203, 2, 203])
        await model.stop()
    }

    func testSelectingBuiltInFromCustomAddsOnlyWideBackgroundFieldBeforeModeCommand() async throws {
        let session = DisplayModelSession()
        let model = makeModel(session)
        model.synchronize(.empty, canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.pages().count == 1 })
        model.synchronize(D200XConfiguration(wideDisplayMode: .time), canEdit: true)
        displayAssertTrue(await eventually { await session.modes() == [203] })
        let pages = await session.pages()
        displayAssertEqual(pages.count, 2)
        displayAssertEqual(Set(pages[1].slots.keys), ["3_2"])
        displayAssertEqual(pages[1].slots["3_2"]?.smallViewMode, 2)
        displayAssertEqual(await session.entries(), ["page", "page", "mode203"])
        model.synchronize(.empty, canEdit: true)
        displayAssertTrue(await eventually { await session.modes() == [203, 2] })
        displayAssertEqual(await session.pages().count, 2)
        await model.stop()
    }

    func testSystemStatusUsesRealInjectedMetricsAndFallsBackWhenAnyReadingIsMissing() async throws {
        for metrics in [D200XMetricsSnapshot(cpu: 12, memory: 63, gpu: 26),
                        D200XMetricsSnapshot(cpu: 12, memory: 63, gpu: nil),
                        D200XMetricsSnapshot(cpu: nil, memory: 63, gpu: 26)] {
            let session = DisplayModelSession()
            let model = makeModel(session, metrics: metrics)
            model.synchronize(D200XConfiguration(wideDisplayMode: .systemStatus), canEdit: true)
            model.connect()
            displayAssertTrue(await eventually { await session.modes().count == 1 })
            displayAssertEqual(await session.modes(), [metrics.isComplete ? 0 : 2])
            let status = try displayUnwrap(await session.statuses().first)
            displayAssertEqual(status.gpu, metrics.isComplete ? metrics.gpu : nil)
            displayAssertEqual(model.configuration?.wideDisplayMode, .systemStatus)
            displayAssertEqual(model.wideDisplayMessage != nil, !metrics.isComplete)
            await model.stop()
        }
    }

    func testSleepPausesDisplayAndWakeReappliesSelectionAfterPowerRestore() async throws {
        let session = DisplayModelSession()
        let model = makeModel(session)
        model.synchronize(D200XConfiguration(wideDisplayMode: .dateTimeWeekday), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [200] })
        model.sleep()
        displayAssertTrue(await eventually { await session.entries().contains("brightness0") })
        let asleep = await session.entries()
        try await Task.sleep(for: .milliseconds(200))
        displayAssertEqual(await session.entries(), asleep)
        model.wake()
        displayAssertTrue(await eventually { await session.modes().count == 2 })
        let entries = await session.entries()
        XCTAssertLessThan(try displayUnwrap(entries.firstIndex(of: "pause")), try displayUnwrap(entries.firstIndex(of: "brightness0")))
        XCTAssertLessThan(try displayUnwrap(entries.firstIndex(of: "resume")), try displayUnwrap(entries.firstIndex(of: "brightness100")))
        displayAssertEqual(entries.last, "mode200")
        await model.stop()
    }

    func testScreensaverNeedsExplicitConfirmationAndIsNeverReappliedOnReconnect() async throws {
        let session = DisplayModelSession()
        let model = makeModel(session)
        model.synchronize(D200XConfiguration(wideDisplayMode: .timeDate), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [202] })
        let jpeg = try D200XScreensaverImage.crop(Self.sourceImage())
        do {
            try await model.applyScreensaver(jpeg, confirmedPersistentOverwrite: false)
            XCTFail("unconfirmed overwrite applied")
        } catch {}
        displayAssertFalse(await session.entries().contains("screensaver"))
        try await model.applyScreensaver(jpeg, confirmedPersistentOverwrite: true)
        model.disconnect()
        displayAssertTrue(await eventually { model.connectionTitle == "Disconnected" })
        model.connect()
        displayAssertTrue(await eventually { await session.modes().count == 2 })
        displayAssertEqual(await session.entries().filter { $0 == "screensaver" }.count, 1)
        displayAssertEqual(await session.modes(), [202, 202])
        await model.stop()
    }

    func testIdenticalCropBytesStillPublishSuccessfulCompletion() async throws {
        let clock = DisplayTickClock()
        let preview = D200XScreensaverPreview(delay: { try await clock.sleep($0) }, render: { _ in Data([1]) })
        for revision in 1...2 {
            preview.update(D200XScreensaverCropRequest(source: Data([UInt8(revision)]), zoom: 1, horizontal: 0, vertical: 0))
            displayAssertTrue(await eventually { await clock.isWaiting() })
            await clock.advance()
            displayAssertTrue(await eventually { preview.renderedRevision == UInt64(revision) })
            displayAssertEqual(preview.image, Data([1]))
        }
        preview.cancel()
    }

    func testScreensaverTimerStartsAfterDisplayAndRestoresFullLatestPageAndMode() async throws {
        let clock = DisplayTickClock()
        let session = DisplayModelSession(holdFirstUpload: true)
        let model = makePreviewModel(session, clock: clock)
        model.synchronize(D200XConfiguration(notificationTopics: ["key13": ["preview.*"]], wideDisplayMode: .timeDate), canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.modes() == [202] })
        let jpeg = try D200XScreensaverImage.crop(Self.sourceImage())
        let send = Task { try await model.applyScreensaver(jpeg, confirmedPersistentOverwrite: true) }
        displayAssertTrue(await eventually { await session.entries().contains("screensaver") })
        displayAssertFalse(await clock.isWaiting())
        displayAssertEqual(Array(await session.entries().suffix(2)), ["pause", "screensaver"])
        await session.releaseUpload()
        try await send.value
        displayAssertTrue(await eventually { await clock.isWaiting() })
        displayAssertEqual(await clock.durations(), [.seconds(5)])
        displayAssertEqual(await session.entries().last, "show")
        let currentConfiguration = D200XConfiguration(notificationTopics: ["key13": ["preview.*"]], wideDisplayMode: .time)
        model.synchronize(currentConfiguration, canEdit: true)
        let notification = await model.publishNotification(topic: "preview.updated", text: "Deferred", ttlSeconds: 30)
        XCTAssertNil(notification.error)
        displayAssertEqual(model.notificationLabels["key13"], "Deferred")
        displayAssertEqual(await session.modes(), [202])
        displayAssertEqual(await session.pages().count, 1)
        await clock.advance()
        displayAssertTrue(await eventually { await session.entries().last == "resume" })
        displayAssertEqual(await session.modes(), [202, 2])
        let pages = await session.pages()
        displayAssertEqual(pages.count, 2)
        displayAssertEqual(pages.last?.slots.count, 14)
        let expected = try D200XPageRenderer.page(configuration: currentConfiguration, labelOverrides: ["key13": "Deferred"])
        displayAssertEqual(pages.last?.slots["3_2"]?.image, expected.slots["3_2"]?.image)
        displayAssertFalse(model.isPreviewingScreensaver)
        await model.stop()
    }

    func testCropEditCancelsOldDeadlineAndRestartsAfterLatestImageEvenWhenUnchanged() async throws {
        let clock = DisplayTickClock()
        let session = DisplayModelSession()
        let model = makePreviewModel(session, clock: clock)
        model.synchronize(.empty, canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.pages().count == 1 })
        let jpeg = try D200XScreensaverImage.crop(Self.sourceImage())
        try await model.applyScreensaver(jpeg, confirmedPersistentOverwrite: true)
        displayAssertTrue(await eventually { await clock.isWaiting() })
        model.holdScreensaverPreview()
        await clock.advance()
        displayAssertTrue(model.isPreviewingScreensaver)
        displayAssertEqual(await session.pages().count, 1)
        try await model.applyScreensaver(jpeg, confirmedPersistentOverwrite: true)
        displayAssertTrue(await eventually { await clock.isWaiting() })
        displayAssertEqual(await session.entries().filter { $0 == "show" }.count, 2)
        await clock.advance()
        displayAssertTrue(await eventually { await session.entries().last == "resume" })
        displayAssertEqual(await session.pages().last?.slots.count, 14)
        displayAssertEqual(await session.modes(), [2])
        await model.stop()
    }

    func testQueuedScreensaverCropsSkipObsoleteUploadAndActivation() async throws {
        let clock = DisplayTickClock()
        let session = DisplayModelSession(holdFirstUpload: true)
        let model = makePreviewModel(session, clock: clock)
        model.synchronize(.empty, canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.pages().count == 1 })
        let jpeg = try D200XScreensaverImage.crop(Self.sourceImage())
        let first = Task { try? await model.applyScreensaver(jpeg, confirmedPersistentOverwrite: true) }
        displayAssertTrue(await eventually { await session.entries().contains("screensaver") })
        var pending = [Task<Void, Never>]()
        for _ in 0..<10 {
            pending.append(Task { _ = try? await model.applyScreensaver(jpeg, confirmedPersistentOverwrite: true) })
            await Task.yield()
        }
        await session.releaseUpload()
        await first.value
        for update in pending { await update.value }
        displayAssertEqual(await session.entries().filter { $0 == "screensaver" }.count, 2)
        displayAssertEqual(await session.entries().filter { $0 == "show" }.count, 1)
        displayAssertTrue(await eventually { await clock.isWaiting() })
        displayAssertEqual(await clock.durations(), [.seconds(5)])
        await model.stop()
    }

    func testScreensaverLockDefersRestorationUntilUnlock() async throws {
        let clock = DisplayTickClock()
        let session = DisplayModelSession()
        let model = makePreviewModel(session, clock: clock)
        model.synchronize(.empty, canEdit: true)
        model.connect()
        displayAssertTrue(await eventually { await session.pages().count == 1 })
        try await model.applyScreensaver(D200XScreensaverImage.crop(Self.sourceImage()), confirmedPersistentOverwrite: true)
        displayAssertTrue(await eventually { await clock.isWaiting() })
        model.setScreensaverPreviewLocked(true)
        await clock.advance()
        try await Task.sleep(for: .milliseconds(200))
        displayAssertEqual(await session.pages().count, 1)
        displayAssertFalse(await session.entries().contains("resume"))
        model.setScreensaverPreviewLocked(false)
        displayAssertTrue(await eventually { await session.entries().last == "resume" })
        displayAssertEqual(await session.pages().count, 2)
        await model.stop()
    }

    func testSleepOrDisconnectDuringUploadNeverActivatesOrRestoresPreview() async throws {
        for disconnect in [false, true] {
            let clock = DisplayTickClock()
            let session = DisplayModelSession(holdFirstUpload: true)
            let model = makePreviewModel(session, clock: clock)
            model.synchronize(.empty, canEdit: true)
            model.connect()
            displayAssertTrue(await eventually { await session.pages().count == 1 })
            let jpeg = try D200XScreensaverImage.crop(Self.sourceImage())
            let send = Task { try? await model.applyScreensaver(jpeg, confirmedPersistentOverwrite: true) }
            displayAssertTrue(await eventually { await session.entries().contains("screensaver") })
            if disconnect { model.disconnect() } else { model.sleep() }
            await session.releaseUpload()
            await send.value
            displayAssertTrue(await eventually {
                if disconnect { return model.connectionTitle == "Disconnected" }
                return await session.entries().last == "brightness0"
            })
            displayAssertFalse(await session.entries().contains("show"))
            displayAssertFalse(await session.entries().contains("resume"))
            displayAssertFalse(await clock.isWaiting())
            displayAssertEqual(await session.pages().count, 1)
            await model.stop()
        }
    }

    func testCPUWarmupZeroDeltaResetAndWrapHandling() {
        XCTAssertNil(D200XHostMetrics.cpuPercentage(previous: nil, current: [10, 10, 10, 70]))
        XCTAssertNil(D200XHostMetrics.cpuPercentage(previous: [10, 10, 10, 70], current: [10, 10, 10, 70]))
        XCTAssertNil(D200XHostMetrics.cpuPercentage(previous: [100, 100, 100, 100], current: [1, 1, 1, 1]))
        XCTAssertEqual(D200XHostMetrics.cpuPercentage(previous: [10, 10, 70, 10], current: [20, 20, 140, 20]) ?? -1, 30, accuracy: 0.001)
        XCTAssertNotNil(D200XHostMetrics.cpuPercentage(previous: [.max - 1, 10, 10, 10], current: [2, 11, 11, 11]))
    }

    func testDateWeekSelectionAndTrailingField() throws {
        let date = Date(timeIntervalSince1970: 0)
        let metrics = D200XMetricsSnapshot()
        let expected = [200: "1970-01-01 Thursday", 201: "Thursday", 202: "1970-01-01", 203: "", 1: "", 2: ""]
        for (mode, text) in expected {
            let status = D200XDisplayStatus.make(mode: mode, format: .twelveHour, date: date, metrics: metrics,
                timeZone: try displayUnwrap(TimeZone(secondsFromGMT: 0)))
            displayAssertEqual(status.dateWeekText, text)
            displayAssertEqual(status.time, "00:00:00")
            displayAssertEqual(status.clockFormat, "12H")
            displayAssertEqual(String(decoding: try status.payload(), as: UTF8.self).components(separatedBy: "|").count, 7)
        }
    }

    func testCropProducesBoundedJPEGAndDistinctHorizontalCrops() throws {
        let source = try Self.sourceImage()
        let left = try D200XScreensaverImage.crop(source, zoom: 3, horizontal: -1)
        let right = try D200XScreensaverImage.crop(source, zoom: 3, horizontal: 1)
        XCTAssertNotEqual(left, right)
        _ = try D200XScreensaver(jpeg: left).archive()
        _ = try D200XScreensaver(jpeg: right).archive()
        XCTAssertThrowsError(try D200XScreensaverImage.crop(source, zoom: .nan))
        XCTAssertThrowsError(try D200XScreensaverImage.crop(Data("invalid".utf8)))
    }

    private func makePreviewModel(_ session: DisplayModelSession, clock: DisplayTickClock) -> D200XModel {
        D200XModel(session: session, sender: ShortcutSender(preflight: { true }, request: { false }, postPair: { _ in }),
            frontmostApplication: { nil }, sampleMetrics: { D200XMetricsSnapshot() },
            screensaverDelay: { try await clock.sleep($0) })
    }

    private func makeModel(_ session: DisplayModelSession, metrics: D200XMetricsSnapshot = D200XMetricsSnapshot()) -> D200XModel {
        D200XModel(session: session, sender: ShortcutSender(preflight: { true }, request: { false }, postPair: { _ in }),
            frontmostApplication: { nil }, sampleMetrics: { metrics }, displayNow: { Date(timeIntervalSince1970: 0) })
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private static func sourceImage() throws -> Data {
        let context = try displayUnwrap(CGContext(data: nil, width: 240, height: 120, bitsPerComponent: 8,
            bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 120, y: 0, width: 120, height: 120))
        let image = try displayUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try displayUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        displayAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}

private actor DisplayModelSession: D200XSessionProtocol {
    nonisolated let events: AsyncStream<D200XSessionEvent>
    private let continuation: AsyncStream<D200XSessionEvent>.Continuation
    private var generation: UInt64 = 0
    private var recorded = [String]()
    private var sentStatuses = [D200XWideStatus]()
    private var sentPages = [D200XPage]()
    private var holdFirstUpload: Bool
    private var uploadWaiter: CheckedContinuation<Void, Never>?

    init(holdFirstUpload: Bool = false) {
        self.holdFirstUpload = holdFirstUpload
        let stream = AsyncStream<D200XSessionEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws {
        generation += 1
        let identity = try D200XIdentity(payload: Data(#"{"SerialNumber":"02123A04512345678"}"#.utf8))
        continuation.yield(.status(.connected(identity), generation: generation))
    }

    func disconnect() async { continuation.yield(.status(.disconnected, generation: generation)) }
    func failConnection() { continuation.yield(.status(.failed(.transport), generation: generation)) }
    func applyPage(_ page: D200XPage, update: D200XPageUpdate) async throws {
        recorded.append("page")
        sentPages.append(page)
    }
    func setBrightness(_ percent: Int) async throws { recorded.append("brightness\(percent)") }
    func setKeepAwakeEnabled(_ enabled: Bool) async throws { recorded.append(enabled ? "resume" : "pause") }
    func setWideDisplay(_ status: D200XWideStatus) async throws {
        _ = try status.payload()
        sentStatuses.append(status)
        recorded.append("mode\(status.mode)")
    }
    func applyScreensaver(_ screensaver: D200XScreensaver) async throws {
        _ = try screensaver.archive()
        recorded.append("screensaver")
        if holdFirstUpload {
            holdFirstUpload = false
            await withCheckedContinuation { uploadWaiter = $0 }
        }
    }
    func releaseUpload() { uploadWaiter?.resume(); uploadWaiter = nil }
    func showScreensaver() async throws { recorded.append("show") }
    func entries() -> [String] { recorded }
    func modes() -> [Int] { sentStatuses.map(\.mode) }
    func statuses() -> [D200XWideStatus] { sentStatuses }
    func pages() -> [D200XPage] { sentPages }
}

private actor DisplayTickClock {
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []
    private var requestedDurations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        requestedDurations.append(duration)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = continuation
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: UUID) {
        if let continuation = sleepers.removeValue(forKey: id) { continuation.resume(throwing: CancellationError()) }
        else { cancelled.insert(id) }
    }

    func durations() -> [Duration] { requestedDurations }
    func isWaiting() -> Bool { !sleepers.isEmpty }

    func advance() {
        let current = sleepers
        sleepers.removeAll()
        for continuation in current.values { continuation.resume() }
    }
}

private actor UncancellableDisplayTickClock {
    private var sleepers = [CheckedContinuation<Void, Never>?]()

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { sleepers.append($0) }
    }

    func count() -> Int { sleepers.count }

    func advance(_ index: Int) {
        guard sleepers.indices.contains(index), let sleeper = sleepers[index] else { return }
        sleepers[index] = nil
        sleeper.resume()
    }

    func releaseAll() {
        for index in sleepers.indices { advance(index) }
    }
}

private final class BlockingPreviewRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var identifiers = [UInt8]()
    private var active = 0
    private var peak = 0

    func render(_ request: D200XScreensaverCropRequest) throws -> Data {
        let identifier = request.source.first ?? 0
        lock.withLock {
            identifiers.append(identifier)
            active += 1
            peak = max(peak, active)
        }
        defer { lock.withLock { active -= 1 } }
        if identifier == 0 { gate.wait() }
        try Task.checkCancellation()
        return request.source
    }

    func started() -> [UInt8] { lock.withLock { identifiers } }
    func maximumActive() -> Int { lock.withLock { peak } }
    func release() { gate.signal() }
}

private func displayAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, file: file, line: line)
}

private func displayAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value, file: file, line: line)
}

private func displayAssertEqual<Value: Equatable>(_ actual: Value, _ expected: Value, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}

private func displayUnwrap<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) throws -> Value {
    try XCTUnwrap(value, file: file, line: line)
}
