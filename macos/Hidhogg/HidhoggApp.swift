import AppKit
import SwiftUI

@main
struct HidhoggApp: App {
    @NSApplicationDelegateAdaptor(HidhoggApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        MenuBarExtra("Hidhogg", systemImage: "shield") {
            HidhoggMenu(model: applicationDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private struct HidhoggMenu: View {
    @ObservedObject var model: HidhoggAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.lifecycleText)
                .font(.headline)
            Text(model.healthText)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }
}

@MainActor
final class HidhoggApplicationDelegate: NSObject, NSApplicationDelegate {
    let model: HidhoggAppModel
    private var terminationTask: Task<Void, Never>?
    private var terminationReplySent = false

    override init() {
        self.model = HidhoggAppModel()
        super.init()
    }

    init(model: HidhoggAppModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if !HIDHOGG_TEST_HOST
        model.start()
#endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplySent, terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.quit()
            self.terminationReplySent = true
            sender.reply(toApplicationShouldTerminate: true)
            self.terminationTask = nil
        }
        return .terminateLater
    }
}

@MainActor
final class HidhoggAppModel: ObservableObject {
    @Published private(set) var lifecycleText = LifecycleState.idle.description
    @Published private(set) var healthText = "Health has not been observed"

    private let supervisor: ProcessSupervisor
    private var runTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var hasQuit = false

    init(
        supervisor: ProcessSupervisor? = nil,
        executablePath: String? = nil
    ) {
        let resolvedExecutable: String
        if let executablePath {
            resolvedExecutable = executablePath
        } else {
            guard let bundledExecutable = Bundle.main.url(forAuxiliaryExecutable: "hidhogg-runtime") else {
                preconditionFailure("Hidhogg.app is missing its bundled hidhogg runtime")
            }
            resolvedExecutable = bundledExecutable.path
        }
        self.supervisor = supervisor ?? ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(executablePath: resolvedExecutable)
        )
    }

    func start() {
        guard runTask == nil, !hasQuit else { return }
        runTask = Task { [supervisor] in
            await supervisor.run()
        }
        observationTask = Task { [weak self, supervisor] in
            while !Task.isCancelled {
                let snapshot = await supervisor.snapshot()
                await MainActor.run {
                    self?.lifecycleText = snapshot.state.description
                    self?.healthText = snapshot.state == .ready
                        ? "Health: ready"
                        : "Health: waiting for runtime"
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func quit() async {
        if hasQuit {
            if let quitTask {
                await quitTask.value
            }
            return
        }
        hasQuit = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.observationTask?.cancel()
            await self.supervisor.quit()
            self.runTask?.cancel()
            self.runTask = nil
            self.observationTask = nil
            let snapshot = await self.supervisor.snapshot()
            self.lifecycleText = snapshot.state.description
            self.healthText = "Health: stopped"
        }
        quitTask = task
        await task.value
        quitTask = nil
    }
}
