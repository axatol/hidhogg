import AppKit
import GenericBluetooth
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import SwiftUI
import XCTest
@testable import HidhoggApp

@MainActor
final class CardPaddingOfflineLayoutTests: XCTestCase {
    func testRepresentativeCardsRenderOfflineAtNarrowAndWideWidths() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let configurationURL = temporaryRoot.appendingPathComponent("config.toml")
        let artifactDirectory = URL(fileURLWithPath: "/Volumes/Data/tmp/hidhogg-padding-offscreen", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)

        let activity = OfflineActivityCounter()
        let sender = ShortcutSender(
            preflight: { false },
            request: {
                activity.record()
                return false
            },
            postPair: { _ in activity.record() }
        )
        let inventory = OfflineBluetoothInventory()
        let report = OfflineBluetoothReport()
        let bluetooth = GenericBluetoothModel(inventory: inventory, report: report)
        let flowLite = FlowLite84Model(session: nil, keyboardActivityMonitor: NoopKeyboardActivityMonitor())
        let d200x = D200XModel(
            session: nil,
            sender: sender,
            frontmostApplication: { nil },
            sampleMetrics: { D200XMetricsSnapshot() },
            iconResolver: OfflineD200XIconResolver(),
            observeScreenLock: false
        )
        let binding = PairingBindingSession()
        let appModel = AppModel(
            configurationURL: configurationURL,
            store: ConfigurationStore(url: configurationURL),
            bolt: binding,
            sender: sender,
            d200x: d200x,
            flowLite: flowLite,
            bluetooth: bluetooth,
            loadImmediately: false,
            observeSleep: false,
            frontmostApplication: { nil }
        )

        let preset = D200XTilePreset(
            name: "Lock Screen",
            appearance: D200XTileAppearance(label: "Lock Screen", titlePlacement: .bottom)
        )
        let configuration = D200XConfiguration(tilePresets: ["lock-screen": preset])
        d200x.synchronize(configuration, canEdit: true)
        d200x.selectedControl = .dial0Left
        var d200xEditCount = 0
        d200x.onEdit = { _ in d200xEditCount += 1 }
        let initialDraft = appModel.document.draft

        let chooser = D200XPresetChooserView(
            model: d200x,
            context: .init(control: .key0, applicationID: nil),
            onApply: { XCTFail("Rendering a preset chooser must not apply a preset.") }
        )
        let chooserMeasurement = NSHostingView(rootView: chooser.environmentObject(appModel))
        XCTAssertLessThanOrEqual(chooserMeasurement.fittingSize.width, 780)
        XCTAssertLessThanOrEqual(chooserMeasurement.fittingSize.height, 660)

        let fixtures: [(String, AnyView, NSSize)] = [
            ("logitech-setup-600", AnyView(LogitechSetupView().environmentObject(appModel)), NSSize(width: 600, height: 700)),
            ("logitech-setup-1000", AnyView(LogitechSetupView().environmentObject(appModel)), NSSize(width: 1000, height: 700)),
            ("device-information-380", AnyView(DeviceInformationView().environmentObject(appModel)), NSSize(width: 380, height: 420)),
            ("device-information-720", AnyView(DeviceInformationView().environmentObject(appModel)), NSSize(width: 720, height: 420)),
            ("flow-lite-360", AnyView(FlowLite84DeviceView(model: flowLite)), NSSize(width: 360, height: 900)),
            ("flow-lite-840", AnyView(FlowLite84DeviceView(model: flowLite)), NSSize(width: 840, height: 900)),
            ("d200x-inspector-320", AnyView(D200XControlInspectorView(model: d200x)), NSSize(width: 320, height: 760)),
            ("d200x-inspector-480", AnyView(D200XControlInspectorView(model: d200x)), NSSize(width: 480, height: 760)),
            ("d200x-preset-chooser-780", AnyView(chooser), NSSize(width: 780, height: 660)),
            ("d200x-preset-chooser-1000", AnyView(chooser), NSSize(width: 1000, height: 760)),
            ("d200x-tile-preset-editor-580", tilePresetEditor(model: d200x), NSSize(width: 580, height: 880)),
            ("d200x-tile-preset-editor-760", tilePresetEditor(model: d200x), NSSize(width: 760, height: 880))
        ]

        for (name, rootView, size) in fixtures {
            try await capture(rootView, named: name, size: size, in: artifactDirectory, appModel: appModel)
        }

        XCTAssertEqual(binding.catalogReads, 0, "Rendering must not read adapter inventory.")
        XCTAssertEqual(binding.writeCount, 0, "Rendering must not enable or disable Logitech bindings.")
        XCTAssertTrue(binding.targets.isEmpty, "Rendering must not start a Logitech connection.")
        XCTAssertEqual(inventory.accessRequestCount, 0)
        XCTAssertEqual(inventory.enumerationCount, 0)
        XCTAssertEqual(inventory.observationStartCount, 0)
        XCTAssertEqual(report.readCount, 0, "Rendering must not run a Bluetooth report command.")
        XCTAssertEqual(activity.count, 0, "Rendering must not request input permission or post input.")
        XCTAssertEqual(d200xEditCount, 0, "Rendering must not edit the D200X configuration.")
        XCTAssertEqual(d200x.configuration, configuration)
        XCTAssertEqual(appModel.document.draft, initialDraft)
        XCTAssertFalse(appModel.isSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurationURL.path), "Rendering must not save a configuration.")

        await d200x.stop()
        await flowLite.stop()
        bluetooth.stop()
        await binding.stop()
    }

    private func tilePresetEditor(model: D200XModel) -> AnyView {
        AnyView(ScrollView {
            TilePresetEditorView(
                model: model,
                selectedID: .constant(nil),
                draftID: .constant(UUID()),
                onSaved: { _ in XCTFail("Rendering a preset editor must not save.") },
                initialTemplate: .lockScreen
            )
            .padding(16)
        })
    }

    private func capture(
        _ rootView: AnyView,
        named name: String,
        size: NSSize,
        in directory: URL,
        appModel: AppModel
    ) async throws {
        let view = NSHostingView(rootView: rootView
            .environmentObject(appModel)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)

        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(window.isVisible, "Offscreen fixture \(name) must never show a window.")
        XCTAssertFalse(window.isKeyWindow, "Offscreen fixture \(name) must never become key.")
        XCTAssertEqual(view.bounds.width, size.width, "Fixture \(name) must retain its supported width.")
        XCTAssertEqual(view.bounds.height, size.height, "Fixture \(name) must retain its capture height.")

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 100, "Fixture \(name) should contain a rendered view.")
        try png.write(to: directory.appendingPathComponent("\(name).png"))

        window.contentView = nil
        window.close()
        XCTAssertFalse(window.isVisible, "Offscreen fixture \(name) must remain hidden after capture.")
        XCTAssertFalse(window.isKeyWindow, "Offscreen fixture \(name) must remain non-key after capture.")
    }
}

@MainActor
private final class OfflineBluetoothInventory: PairedBluetoothInventory {
    let access: BluetoothAccess = .denied
    private(set) var accessRequestCount = 0
    private(set) var enumerationCount = 0
    private(set) var observationStartCount = 0

    func requestAccess() async -> BluetoothAccess {
        accessRequestCount += 1
        return .denied
    }

    func pairedDevices() throws -> [PairedBluetoothDevice] {
        enumerationCount += 1
        return []
    }

    func observeChanges(for endpoints: Set<BluetoothEndpoint>, _ changed: @escaping @MainActor @Sendable () -> Void) {
        observationStartCount += 1
    }

    func stopObserving() {}
}

private final class OfflineBluetoothReport: BluetoothReportReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var readCount: Int { lock.withLock { reads } }

    func read() async throws -> Data {
        lock.withLock { reads += 1 }
        return Data()
    }
}

@MainActor
private final class OfflineD200XIconResolver: D200XApplicationIconResolving {
    func pngData(for bundleIdentifier: String) -> Data? { nil }
}

private final class OfflineActivityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func record() {
        lock.withLock { value += 1 }
    }
}
