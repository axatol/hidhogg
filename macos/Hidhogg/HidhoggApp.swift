import AppKit
import SwiftUI

@main
struct HidhoggApp: App {
    @StateObject private var model = HidhoggAppModel()

    var body: some Scene {
        MenuBarExtra("Hidhogg", systemImage: "shield") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.lifecycleText)
                    .font(.headline)
                Text(model.healthText)
                    .foregroundStyle(.secondary)
                Divider()
                Button("Quit") {
                    Task {
                        await model.quit()
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(12)
            .frame(minWidth: 220)
            .task {
                await model.start()
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class HidhoggAppModel: ObservableObject {
    @Published private(set) var lifecycleText = LifecycleState.idle.description
    @Published private(set) var healthText = "Health has not been observed"

    private let supervisor: ProcessSupervisor
    private var runTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?

    init(
        supervisor: ProcessSupervisor? = nil,
        executablePath: String? = nil
    ) {
        let resolvedExecutable = executablePath
            ?? Bundle.main.url(forAuxiliaryExecutable: "hidhogg")?.path
            ?? "/usr/local/bin/hidhogg"
        self.supervisor = supervisor ?? ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(executablePath: resolvedExecutable)
        )
    }

    func start() async {
        guard runTask == nil else { return }
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
        observationTask?.cancel()
        await supervisor.quit()
        runTask?.cancel()
        runTask = nil
        observationTask = nil
        let snapshot = await supervisor.snapshot()
        lifecycleText = snapshot.state.description
        healthText = "Health: stopped"
    }
}
