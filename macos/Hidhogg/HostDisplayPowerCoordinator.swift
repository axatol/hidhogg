import Combine
import Foundation
import HidhoggCore

@MainActor
public final class HostDisplayPowerCoordinator: ObservableObject {
    @Published public private(set) var desiredDisplayAwake: Bool?
    @Published public private(set) var errorText: String?
    @Published public private(set) var runtimeIdentity: String?

    private struct Binding {
        let identity: String
        let operations: any HidhoggDisplayOperations
    }

    private struct StateAttempt: Equatable {
        let identity: String
        let revision: UInt64
    }

    private struct PendingWrite {
        let binding: Binding
        let displayAwake: Bool
        let revision: UInt64

        var attempt: StateAttempt {
            StateAttempt(identity: binding.identity, revision: revision)
        }
    }

    private let observer: any HostDisplayPowerObserving
    private var binding: Binding?
    private var desiredRevision: UInt64 = 0
    private var appliedAttempt: StateAttempt?
    private var failedAttempt: StateAttempt?
    private var workerTask: Task<Void, Never>?
    private var isStarted = false
    private var hasShutdown = false

    public init(observer: any HostDisplayPowerObserving = HostDisplayPowerObserver()) {
        self.observer = observer
    }

    public func start() {
        guard !isStarted, !hasShutdown else { return }
        isStarted = true
        observer.start(
            stateHandler: { [weak self] in self?.receive(displayAwake: $0) },
            errorHandler: { [weak self] in self?.receive(errorText: $0) }
        )
    }

    func setRuntimeOperations(_ handle: RuntimeOperationsHandle?) {
        guard !hasShutdown,
              handle?.identity != runtimeIdentity || (handle != nil && binding == nil) else {
            return
        }
        runtimeIdentity = handle?.identity
        binding = handle.map {
            Binding(identity: $0.identity, operations: $0.operations as any HidhoggDisplayOperations)
        }
        appliedAttempt = nil
        failedAttempt = nil
        if binding != nil, desiredDisplayAwake == nil {
            observer.reconcileIfUnknown()
        }
        startWorkerIfNeeded()
    }

    public func waitForIdle() async {
        while let workerTask {
            await workerTask.value
        }
    }

    public func shutdown() async {
        guard !hasShutdown else {
            await waitForIdle()
            return
        }
        hasShutdown = true
        observer.stop()
        runtimeIdentity = nil
        binding = nil
        await waitForIdle()
        workerTask = nil
    }

    private func receive(displayAwake: Bool) {
        guard !hasShutdown else { return }
        guard desiredDisplayAwake != displayAwake else { return }
        desiredDisplayAwake = displayAwake
        desiredRevision &+= 1
        errorText = nil
        startWorkerIfNeeded()
    }

    private func receive(errorText: String?) {
        guard !hasShutdown else { return }
        self.errorText = errorText
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil, nextWrite() != nil else { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.drainWrites()
            guard let self else { return }
            self.workerTask = nil
            self.startWorkerIfNeeded()
        }
    }

    private func drainWrites() async {
        while let write = nextWrite() {
            do {
                let result = try await write.binding.operations.setHostDisplayAwake(write.displayAwake)
                guard result.displayAwake == write.displayAwake else {
                    throw RuntimeOperationError.deviceWriteFailed
                }
                guard binding?.identity == write.binding.identity,
                      desiredDisplayAwake == write.displayAwake else {
                    continue
                }
                appliedAttempt = StateAttempt(identity: write.binding.identity, revision: desiredRevision)
                errorText = nil
            } catch {
                failedAttempt = write.attempt
                guard binding?.identity == write.binding.identity,
                      desiredRevision == write.revision,
                      desiredDisplayAwake == write.displayAwake else {
                    continue
                }
                errorText = "Could not report macOS display power state to the runtime."
            }
        }
    }

    private func nextWrite() -> PendingWrite? {
        guard !hasShutdown,
              let binding,
              let desiredDisplayAwake else {
            return nil
        }
        let write = PendingWrite(
            binding: binding,
            displayAwake: desiredDisplayAwake,
            revision: desiredRevision
        )
        guard appliedAttempt != write.attempt,
              failedAttempt != write.attempt else {
            return nil
        }
        return write
    }
}
