import AppKit
import HidhoggConfiguration
import HidhoggDomain
import LogitechBolt
import MacOSActions
import SwiftUI
import XCTest
@testable import HidhoggApp

@MainActor
final class NativeWorkspaceWindowTests: XCTestCase {
    func testWorkspaceWindowRendersAllInspectorsAtMinimumSizeAndReopens() throws {
        try requireExplicitSelection()
        try exerciseWorkspace(contentSize: NSSize(width: 820, height: 560))
    }

    func testWorkspaceWindowRendersAllInspectorsAtOriginalSizeAndReopens() throws {
        try requireExplicitSelection()
        try exerciseWorkspace(contentSize: NSSize(width: 980, height: 680))
    }

    private func exerciseWorkspace(contentSize: NSSize) throws {
        let environment = NativeWorkspaceEnvironment()
        let rootView = environment.injectingEnvironmentObjects(
            WorkspaceView(presentationCoordinator: environment.presentationCoordinator)
        )
        .frame(minWidth: 820, minHeight: 560)
        let harness = NativeWindowHarness(rootView: rootView, contentSize: contentSize)
        defer { harness.close() }

        harness.open()

        XCTAssertTrue(harness.window.isVisible)
        XCTAssertFalse(harness.window.isKeyWindow)
        XCTAssertGreaterThanOrEqual(harness.hostingView.bounds.width, contentSize.width)
        XCTAssertGreaterThanOrEqual(harness.hostingView.bounds.height, contentSize.height)

        for target in DeviceEditorTarget.allCases {
            environment.model.selectTarget(target)
            harness.driveLayout(seconds: 0.2)
            XCTAssertEqual(environment.model.selectedTarget, target)
            if let control = target.control {
                XCTAssertEqual(environment.model.selectedControl, control)
            }
            XCTAssertTrue(harness.window.isVisible)
            XCTAssertGreaterThanOrEqual(harness.hostingView.bounds.width, contentSize.width)
            XCTAssertGreaterThanOrEqual(harness.hostingView.bounds.height, contentSize.height)
        }

        for canvasWidth: CGFloat in [240, 600] {
            let screenshotURL = try harness.captureCanvas(
                model: environment.model,
                width: canvasWidth,
                named: "hidhogg-device-control-canvas-synthetic-\(Int(canvasWidth))w.png"
            )
            print("Synthetic native canvas snapshot at \(canvasWidth) points: \(screenshotURL.path)")
        }

        environment.model.selectedSettingsCategory = .diagnostics
        environment.model.navigate(to: .settings)
        harness.driveLayout(seconds: 0.25)
        XCTAssertEqual(environment.model.selectedSettingsCategory, .diagnostics)
        XCTAssertTrue(harness.window.isVisible)

        for category in SettingsCategory.allCases {
            environment.model.selectedSettingsCategory = category
            harness.driveLayout(seconds: 0.1)
            XCTAssertEqual(environment.model.selectedSettingsCategory, category)
            XCTAssertTrue(harness.window.isVisible)
            XCTAssertGreaterThan(harness.hostingView.bounds.width, 0)
            XCTAssertGreaterThan(harness.hostingView.bounds.height, 0)
        }

        environment.model.navigate(to: .devices)
        harness.driveLayout(seconds: 0.25)
        XCTAssertEqual(environment.model.navigation.current.route, .devices)
        XCTAssertEqual(environment.model.selectedTarget, .thumbWheel)

        environment.model.openPermissions()
        harness.driveLayout(seconds: 0.25)
        XCTAssertEqual(environment.model.navigation.current.route, .settings)
        XCTAssertEqual(environment.model.selectedSettingsCategory, .permissions)
        XCTAssertTrue(harness.window.isVisible)

        let initialFrame = harness.window.frame
        harness.window.setFrame(
            NSRect(
                x: initialFrame.origin.x,
                y: initialFrame.origin.y,
                width: initialFrame.width + 120,
                height: initialFrame.height + 80
            ),
            display: true,
            animate: false
        )
        harness.driveLayout(seconds: 0.5)

        XCTAssertTrue(harness.window.isVisible)
        XCTAssertGreaterThan(harness.hostingView.bounds.width, 0)
        XCTAssertGreaterThan(harness.hostingView.bounds.height, 0)

        harness.window.close()
        XCTAssertFalse(harness.window.isVisible)
        harness.window.orderBack(nil)
        harness.driveLayout(seconds: 0.75)

        XCTAssertTrue(harness.window.isVisible)
        XCTAssertFalse(harness.window.isKeyWindow)
        XCTAssertGreaterThan(harness.hostingView.bounds.width, 0)
        XCTAssertGreaterThan(harness.hostingView.bounds.height, 0)
        XCTAssertEqual(environment.model.navigation.current.route, .settings)
        XCTAssertEqual(environment.model.selectedSettingsCategory, .permissions)
    }

    private func requireExplicitSelection() throws {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.contains("NativeWorkspaceWindowTests") }) else {
            throw XCTSkip("Select this test class explicitly to open a native workspace window.")
        }
    }
}

@MainActor
private final class NativeWorkspaceEnvironment {
    let model: AppModel
    let presentationCoordinator = WorkspacePresentationCoordinator()
    let restartCoordinator = RestartCoordinator(
        cleanup: { true },
        launch: {},
        terminate: {},
        reportError: { _ in }
    )
    let loginItemController = LoginItemController(service: NativeWindowNoopLoginItemService())
    let diagnostics: DiagnosticsStore

    init() {
        let configurationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HidhoggNativeWindowRepro-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config.toml")
        let model = AppModel(
            configurationURL: configurationURL,
            store: ConfigurationStore(url: configurationURL),
            bolt: NativeWindowNoopBindingSession(),
            sender: ShortcutSender(preflight: { false }, request: { false }, postPair: { _ in
                XCTFail("The native window reproduction must not post keyboard events.")
            }),
            lowBatteryNotifications: LowBatteryNotificationController(
                notificationCenter: NativeWindowNoopNotificationCenter(authorizationState: .notDetermined),
                latchStore: NativeWindowNoopAlertLatchStore()
            ),
            loadImmediately: false,
            observeSleep: false
        )
        self.model = model
        diagnostics = DiagnosticsStore(model: model, persist: { _, _ in })
    }

    func injectingEnvironmentObjects<Content: View>(_ content: Content) -> some View {
        content
            .environmentObject(model)
            .environmentObject(diagnostics)
            .environmentObject(loginItemController)
            .environmentObject(restartCoordinator)
    }
}

@MainActor
private final class NativeWindowHarness<RootView: View> {
    let application: NSApplication
    let hostingView: NSHostingView<RootView>
    let window: NSWindow

    init(rootView: RootView, contentSize: NSSize = NSSize(width: 980, height: 680)) {
        application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        hostingView = NSHostingView(rootView: rootView)
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hidhogg Workspace Regression"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
    }

    func open() {
        window.orderBack(nil)
        driveLayout(seconds: 0.75)
    }

    func close() {
        window.close()
        application.setActivationPolicy(.accessory)
    }

    func driveLayout(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    func captureCanvas(model: AppModel, width: CGFloat, named filename: String) throws -> URL {
        let rootView = DeviceControlCanvas(isInspectorPresented: .constant(true))
            .environmentObject(model)
            .frame(width: width, height: 1_200)
        let canvasHostingView = NSHostingView(rootView: rootView)
        canvasHostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1_200))
        canvasHostingView.appearance = hostingView.appearance
        canvasHostingView.layoutSubtreeIfNeeded()
        canvasHostingView.displayIfNeeded()

        let bounds = canvasHostingView.bounds
        let bitmap = try XCTUnwrap(canvasHostingView.bitmapImageRepForCachingDisplay(in: bounds))
        canvasHostingView.cacheDisplay(in: bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/Volumes/Data/tmp", isDirectory: true).appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}

private struct NativeWindowNoopBindingSession: BindingSession {
    let events = AsyncStream<BoltEvent> { $0.finish() }

    func discover() async {}
    func enable() async {}
    func disable() async {}
    func stop() async {}

    func withPressAdmission(
        generation: UInt64,
        observedAt: ContinuousClock.Instant,
        _ operation: () -> Void
    ) -> Bool {
        false
    }
}

@MainActor
private final class NativeWindowNoopNotificationCenter: LowBatteryNotificationCenterAdapter {
    private let authorizationState: LowBatteryNotificationAuthorizationState

    init(authorizationState: LowBatteryNotificationAuthorizationState) {
        self.authorizationState = authorizationState
    }

    func authorizationStatus() async -> LowBatteryNotificationAuthorizationState {
        authorizationState
    }

    func requestAlertAuthorization() async throws -> Bool {
        XCTFail("The native workspace test must not request notification permission.")
        return false
    }

    func enqueue(_ request: LowBatteryNotificationRequest) async throws {
        XCTFail("The native workspace test must not enqueue notifications.")
    }

    func removePendingRequest(identifier: String) {}
}

@MainActor
private final class NativeWindowNoopAlertLatchStore: LowBatteryAlertLatchStore {
    var isLatched: Bool { false }

    func setLatched(_ value: Bool) {}
}

@MainActor
private final class NativeWindowNoopLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus { .notRegistered }

    func register() async throws {}
    func unregister() async throws {}
    func openLoginItemsSettings() {}
}
