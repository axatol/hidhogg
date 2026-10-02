import Foundation

enum RuntimeActionServicesStopOutcome: Sendable, Equatable {
    case closed
    case cleanupUncertain
}

final class RuntimeActionServices: @unchecked Sendable {
    let execution: RuntimeExecutionService
    let nativeInput: RuntimeNativeInputService
    private let monotonicAnchor: RuntimeMonotonicInstant
    private let wallDateAnchor: Date

    init(
        runner: any RuntimeProcessRunner,
        nativeInputBackend: any RuntimeNativeInputBackend,
        clock: any RuntimeMonotonicClock,
        wallDateAnchor: Date
    ) {
        monotonicAnchor = clock.now()
        self.wallDateAnchor = wallDateAnchor
        execution = RuntimeExecutionService(runner: runner, clock: clock)
        nativeInput = RuntimeNativeInputService(backend: nativeInputBackend, clock: clock)
    }

    func date(for instant: RuntimeMonotonicInstant?) -> Date? {
        guard let instant else { return nil }
        let elapsed = monotonicAnchor.duration(to: instant).components
        let interval = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
        return wallDateAnchor.addingTimeInterval(interval)
    }

    static func make(
        selection: RuntimeBackendSelection,
        clock: any RuntimeMonotonicClock,
        wallDateAnchor: Date,
        makeNativeProcessRunner: @escaping @Sendable () -> any RuntimeProcessRunner = { RuntimePosixProcessRunner() },
        makeNativeInputBackend: @escaping @Sendable () -> any RuntimeNativeInputBackend = { RuntimeCoreGraphicsInputBackend() }
    ) -> RuntimeActionServices {
        let runner: any RuntimeProcessRunner
        let inputBackend: any RuntimeNativeInputBackend
        switch selection {
        case .native:
            runner = makeNativeProcessRunner()
            inputBackend = makeNativeInputBackend()
        case .simulated:
            runner = RuntimeDisabledProcessRunner()
            inputBackend = RuntimeDisabledNativeInputBackend()
        }
        return RuntimeActionServices(
            runner: runner,
            nativeInputBackend: inputBackend,
            clock: clock,
            wallDateAnchor: wallDateAnchor
        )
    }

    func admit(_ request: RuntimeStaticActionRequest) {
        switch request.action {
        case .activateProfile:
            break
        case .execute:
            _ = execution.submit(request)
        case .typeText, .keyPress:
            _ = nativeInput.submit(request)
        }
    }

    func stop() {
        execution.stop()
        nativeInput.stop()
    }

    func waitUntilStopped() async -> RuntimeActionServicesStopOutcome {
        async let executionOutcome = execution.waitUntilStopped()
        async let inputOutcome = nativeInput.waitUntilStopped()
        let outcomes = await (executionOutcome, inputOutcome)
        return outcomes.0 == .cleanupUncertain ? .cleanupUncertain : .closed
    }
}

private struct RuntimeDisabledProcessRunner: RuntimeProcessRunner {
    func run(
        _ launch: RuntimeExecutionLaunch,
        cancellation: RuntimeProcessCancellation,
        onStarted: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable (RuntimeExecutionStream, Data) -> Void
    ) -> RuntimeProcessTermination {
        .startFailed
    }
}

private struct RuntimeDisabledNativeInputBackend: RuntimeNativeInputBackend {
    func preflightPermission() -> RuntimeNativePermission { .denied }

    func requestPermission() -> RuntimeNativePermission { .denied }

    func makePair(for payload: RuntimeNativeInputPayload) throws -> any RuntimeNativeKeyboardPair {
        throw RuntimeNativeInputBackendError.eventAllocationFailed
    }
}
