import Foundation
@testable import HidhoggCore

final class RuntimeServiceTestGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func pause() {
        entered.signal()
        _ = release.wait(timeout: .now() + .seconds(10))
    }

    func open() {
        release.signal()
    }
}

final class RuntimeServiceTestRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues = [Value]()

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Value) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}

final class RuntimeFakeProcessRunner: RuntimeProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var configuredTermination: RuntimeProcessTermination
    private var configuredOutput: [(RuntimeExecutionStream, Data)]
    private var executionGate: RuntimeServiceTestGate?
    private var storedLaunches = [RuntimeExecutionLaunch]()
    private var cancellationFlags = [RuntimeProcessCancellation]()
    let invocation = DispatchSemaphore(value: 0)

    init(
        termination: RuntimeProcessTermination = .exited(0),
        output: [(RuntimeExecutionStream, Data)] = [],
        gate: RuntimeServiceTestGate? = nil
    ) {
        configuredTermination = termination
        configuredOutput = output
        executionGate = gate
    }

    var launches: [RuntimeExecutionLaunch] {
        lock.lock()
        defer { lock.unlock() }
        return storedLaunches
    }

    var cancellationRequests: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return cancellationFlags.map(\.isRequested)
    }

    func configure(
        termination: RuntimeProcessTermination,
        output: [(RuntimeExecutionStream, Data)] = [],
        gate: RuntimeServiceTestGate? = nil
    ) {
        lock.lock()
        configuredTermination = termination
        configuredOutput = output
        executionGate = gate
        lock.unlock()
    }

    func run(
        _ launch: RuntimeExecutionLaunch,
        cancellation: RuntimeProcessCancellation,
        onStarted: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable (RuntimeExecutionStream, Data) -> Void
    ) -> RuntimeProcessTermination {
        lock.lock()
        storedLaunches.append(launch)
        cancellationFlags.append(cancellation)
        let gate = executionGate
        let output = configuredOutput
        let termination = configuredTermination
        lock.unlock()

        invocation.signal()
        if !cancellation.isRequested && termination != .startFailed { onStarted() }
        gate?.pause()
        output.forEach { receive($0.0, $0.1) }
        return termination
    }
}

final class RuntimeFakeNativeInputBackend: RuntimeNativeInputBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var currentPermission: RuntimeNativePermission
    private var permissionAfterRequest: RuntimeNativePermission
    private var makeFailure = false
    private var makeGate: RuntimeServiceTestGate?
    private var downGate: RuntimeServiceTestGate?
    private var storedPreflightCount = 0
    private var storedRequestCount = 0
    private var storedPayloads = [RuntimeNativeInputPayload]()
    let events = RuntimeServiceTestRecorder<String>()

    init(
        permission: RuntimeNativePermission = .granted,
        permissionAfterRequest: RuntimeNativePermission = .granted
    ) {
        currentPermission = permission
        self.permissionAfterRequest = permissionAfterRequest
    }

    var preflightCount: Int { withLock { storedPreflightCount } }
    var requestCount: Int { withLock { storedRequestCount } }
    var payloads: [RuntimeNativeInputPayload] { withLock { storedPayloads } }

    func setPermission(_ permission: RuntimeNativePermission) {
        withLock { currentPermission = permission }
    }

    func setPermissionAfterRequest(_ permission: RuntimeNativePermission) {
        withLock { permissionAfterRequest = permission }
    }

    func failPairCreation(_ value: Bool = true) {
        withLock { makeFailure = value }
    }

    func pausePairCreation(using gate: RuntimeServiceTestGate?) {
        withLock { makeGate = gate }
    }

    func pauseAfterDown(using gate: RuntimeServiceTestGate?) {
        withLock { downGate = gate }
    }

    func preflightPermission() -> RuntimeNativePermission {
        withLock {
            storedPreflightCount += 1
            return currentPermission
        }
    }

    func requestPermission() -> RuntimeNativePermission {
        withLock {
            storedRequestCount += 1
            currentPermission = permissionAfterRequest
            return currentPermission
        }
    }

    func makePair(for payload: RuntimeNativeInputPayload) throws -> any RuntimeNativeKeyboardPair {
        let values = withLock { () -> (RuntimeServiceTestGate?, RuntimeServiceTestGate?, Bool) in
            storedPayloads.append(payload)
            let values = (makeGate, downGate, makeFailure)
            downGate = nil
            return values
        }
        values.0?.pause()
        guard !values.2 else { throw RuntimeNativeInputBackendError.eventAllocationFailed }
        return RuntimeFakeKeyboardPair(events: events, downGate: values.1)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private final class RuntimeFakeKeyboardPair: RuntimeNativeKeyboardPair, @unchecked Sendable {
    private let events: RuntimeServiceTestRecorder<String>
    private let downGate: RuntimeServiceTestGate?

    init(events: RuntimeServiceTestRecorder<String>, downGate: RuntimeServiceTestGate?) {
        self.events = events
        self.downGate = downGate
    }

    func postDown() {
        events.append("down")
        downGate?.pause()
    }

    func postUp() {
        events.append("up")
    }
}

enum RuntimeServiceTestValues {
    static func executeRequest(
        executable: String = "/usr/bin/true",
        arguments: [String] = [],
        timeoutSeconds: Int = 10,
        profileID: String = "default",
        coordinate: String = "0_0"
    ) -> RuntimeStaticActionRequest {
        RuntimeStaticActionRequest(
            profileID: profileID,
            coordinate: coordinate,
            action: .execute(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                gesture: .release
            )
        )
    }

    static func textRequest(
        _ text: String = "hello",
        profileID: String = "default",
        coordinate: String = "0_0"
    ) -> RuntimeStaticActionRequest {
        RuntimeStaticActionRequest(
            profileID: profileID,
            coordinate: coordinate,
            action: .typeText(text: text, gesture: .release)
        )
    }

    static func enterRequest(
        profileID: String = "default",
        coordinate: String = "0_0"
    ) -> RuntimeStaticActionRequest {
        RuntimeStaticActionRequest(
            profileID: profileID,
            coordinate: coordinate,
            action: .keyPress(key: "enter", gesture: .release)
        )
    }

    static func eventually(
        attempts: Int = 100,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
