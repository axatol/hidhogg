import Combine
import Foundation

@MainActor
public final class HostDisplayPowerCoordinator: ObservableObject {
    public typealias RuntimeEndpoint = RuntimeSessionController.RuntimeEndpoint

    @Published public private(set) var desiredDisplayAwake: Bool?
    @Published public private(set) var errorText: String?
    @Published public private(set) var runtimeEndpoint: RuntimeEndpoint?

    private struct StateAttempt: Equatable {
        let endpoint: RuntimeEndpoint
        let revision: UInt64
    }

    private struct PendingWrite {
        let endpoint: RuntimeEndpoint
        let displayAwake: Bool
        let revision: UInt64

        var attempt: StateAttempt {
            StateAttempt(endpoint: endpoint, revision: revision)
        }
    }

    private let observer: any HostDisplayPowerObserving
    private let clientFactory: any RuntimeDisplayHostStateClientCreating
    private let requestIDProvider: any RequestIDProviding
    private var desiredRevision: UInt64 = 0
    private var appliedAttempt: StateAttempt?
    private var failedAttempt: StateAttempt?
    private var workerTask: Task<Void, Never>?
    private var isStarted = false
    private var hasShutdown = false

    public init(
        observer: any HostDisplayPowerObserving = HostDisplayPowerObserver(),
        clientFactory: any RuntimeDisplayHostStateClientCreating = UnixSocketDisplayHostStateClientFactory(),
        requestIDProvider: any RequestIDProviding = SystemRequestIDProvider()
    ) {
        self.observer = observer
        self.clientFactory = clientFactory
        self.requestIDProvider = requestIDProvider
    }

    public func start() {
        guard !isStarted, !hasShutdown else { return }
        isStarted = true
        observer.start(
            stateHandler: { [weak self] in self?.receive(displayAwake: $0) },
            errorHandler: { [weak self] in self?.receive(errorText: $0) }
        )
    }

    public func setRuntimeEndpoint(_ endpoint: RuntimeEndpoint?) {
        guard !hasShutdown, endpoint != runtimeEndpoint else { return }
        runtimeEndpoint = endpoint
        appliedAttempt = nil
        failedAttempt = nil
        if endpoint != nil, desiredDisplayAwake == nil {
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
        runtimeEndpoint = nil
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
            let requestID = requestIDProvider.makeRequestID()
            do {
                let response = try await Task.detached(priority: .utility) { [clientFactory] in
                    let client = try clientFactory.make(
                        socketPath: write.endpoint.socketPath,
                        instanceID: write.endpoint.instanceID
                    )
                    return try client.setDisplayHostState(
                        displayAwake: write.displayAwake,
                        requestID: requestID
                    )
                }.value
                guard response.requestID == requestID,
                      response.instanceID == write.endpoint.instanceID,
                      response.displayAwake == write.displayAwake else {
                    throw UnixSocketClientError.response(.invalidResult)
                }
                guard runtimeEndpoint == write.endpoint,
                      desiredDisplayAwake == write.displayAwake else {
                    continue
                }
                appliedAttempt = StateAttempt(endpoint: write.endpoint, revision: desiredRevision)
                errorText = nil
            } catch {
                failedAttempt = write.attempt
                guard runtimeEndpoint == write.endpoint,
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
              let runtimeEndpoint,
              let desiredDisplayAwake else {
            return nil
        }
        let write = PendingWrite(
            endpoint: runtimeEndpoint,
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
