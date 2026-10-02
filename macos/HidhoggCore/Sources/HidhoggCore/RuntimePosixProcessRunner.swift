import Darwin
import Foundation

struct RuntimeProcessDrainBudget: Sendable {
    let limit: Int
    let maximumReadAttempts: Int
    private(set) var bytesRead = 0
    private(set) var readAttempts = 0

    var remaining: Int { max(0, limit - bytesRead) }
    var canRead: Bool { remaining > 0 && readAttempts < maximumReadAttempts }

    mutating func recordReadAttempt() {
        readAttempts += 1
    }

    mutating func recordRead(_ byteCount: Int) {
        guard byteCount > 0 else { return }
        bytesRead = min(limit, bytesRead + byteCount)
    }

    static func shouldReturnToSupervisor(afterReadError error: Int32) -> Bool {
        error == EINTR || error == EAGAIN || error == EWOULDBLOCK
    }
}

struct RuntimePosixProcessRunner: RuntimeProcessRunner {
    private static let terminationGraceNanoseconds: UInt64 = 2_000_000_000
    private static let postKillReapNanoseconds: UInt64 = 500_000_000
    private static let inheritedPipeGraceNanoseconds: UInt64 = 500_000_000
    private static let pollIntervalMilliseconds: Int32 = 10
    private static let maximumDrainBytesPerStream = 65_536
    private static let maximumDrainReadAttempts = 64

    func run(
        _ launch: RuntimeExecutionLaunch,
        cancellation: RuntimeProcessCancellation,
        onStarted: @escaping @Sendable () -> Void,
        receive: @escaping @Sendable (RuntimeExecutionStream, Data) -> Void
    ) -> RuntimeProcessTermination {
        guard !cancellation.isRequested else { return .cancelled(nil) }

        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&stdoutPipe) == 0 else { return .startFailed }
        defer {
            closeIfOpen(&stdoutPipe[0])
            closeIfOpen(&stdoutPipe[1])
            closeIfOpen(&stderrPipe[0])
            closeIfOpen(&stderrPipe[1])
        }
        guard Darwin.pipe(&stderrPipe) == 0 else { return .startFailed }
        guard setNonblocking(stdoutPipe[0]), setNonblocking(stderrPipe[0]) else { return .startFailed }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return .startFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return .startFailed }
        defer { posix_spawnattr_destroy(&attributes) }

        guard configure(
            actions: &actions,
            attributes: &attributes,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        ) else {
            return .startFailed
        }

        guard let executable = strdup(launch.executable) else { return .startFailed }
        defer { free(executable) }
        let argumentStrings = [launch.executable] + launch.arguments
        var argumentPointers = argumentStrings.map { $0.withCString { strdup($0) } }
        guard argumentPointers.allSatisfy({ $0 != nil }) else {
            argumentPointers.forEach { if let pointer = $0 { free(pointer) } }
            return .startFailed
        }
        defer { argumentPointers.forEach { if let pointer = $0 { free(pointer) } } }
        argumentPointers.append(nil)

        let environmentString = "PATH=\(RuntimeExecutionLaunch.minimalPath)"
        guard let environmentPointer = strdup(environmentString) else { return .startFailed }
        defer { free(environmentPointer) }
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = [environmentPointer, nil]

        var processID: pid_t = 0
        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { argumentBuffer in
            environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    executable,
                    &actions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        guard spawnResult == 0 else { return .startFailed }

        closeIfOpen(&stdoutPipe[1])
        closeIfOpen(&stderrPipe[1])
        onStarted()
        return supervise(
            processID: processID,
            stdoutFD: &stdoutPipe[0],
            stderrFD: &stderrPipe[0],
            timeoutSeconds: launch.timeoutSeconds,
            cancellation: cancellation,
            receive: receive
        )
    }

    private func configure(
        actions: inout posix_spawn_file_actions_t?,
        attributes: inout posix_spawnattr_t?,
        stdoutPipe: [Int32],
        stderrPipe: [Int32]
    ) -> Bool {
        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[0]),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]),
            posix_spawn_file_actions_addclose(&actions, stderrPipe[1]),
            posix_spawn_file_actions_addchdir(&actions, "/"),
        ]
        guard actionResults.allSatisfy({ $0 == 0 }) else { return false }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        return posix_spawnattr_setflags(&attributes, flags) == 0 &&
            posix_spawnattr_setpgroup(&attributes, 0) == 0
    }

    private func supervise(
        processID: pid_t,
        stdoutFD: inout Int32,
        stderrFD: inout Int32,
        timeoutSeconds: Int,
        cancellation: RuntimeProcessCancellation,
        receive: @escaping @Sendable (RuntimeExecutionStream, Data) -> Void
    ) -> RuntimeProcessTermination {
        enum TerminationCause: Equatable {
            case timedOut
            case cancelled
            case inheritedPipe
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let timeoutDeadline = deadline(startedAt, adding: UInt64(timeoutSeconds) * 1_000_000_000)
        var terminationCause: TerminationCause?
        var terminationStartedAt: UInt64?
        var killSentAt: UInt64?
        var inheritedPipeDeadline: UInt64?
        var processExited = false
        var processStatus: Int32 = 0
        var waitUncertain = false
        var signalUncertain = false
        var pipeUncertain = false

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if !processExited {
                let waitResult = waitpid(processID, &processStatus, WNOHANG)
                if waitResult == processID {
                    processExited = true
                } else if waitResult < 0 && errno != EINTR {
                    processExited = true
                    waitUncertain = true
                }
            }

            if terminationCause == nil && !processExited {
                if cancellation.isRequested {
                    terminationCause = .cancelled
                    terminationStartedAt = now
                    signalUncertain = signalProcessGroup(processID, signal: SIGTERM)
                } else if now >= timeoutDeadline {
                    terminationCause = .timedOut
                    terminationStartedAt = now
                    signalUncertain = signalProcessGroup(processID, signal: SIGTERM)
                }
            }

            if processExited, (stdoutFD >= 0 || stderrFD >= 0), terminationCause == nil {
                if let inheritedPipeDeadline {
                    if now >= inheritedPipeDeadline {
                        terminationCause = .inheritedPipe
                        terminationStartedAt = now
                        signalUncertain = signalProcessGroup(processID, signal: SIGTERM)
                    }
                } else {
                    inheritedPipeDeadline = deadline(now, adding: Self.inheritedPipeGraceNanoseconds)
                }
            }

            if let terminationStartedAt, killSentAt == nil,
               now >= deadline(terminationStartedAt, adding: Self.terminationGraceNanoseconds) {
                if signalProcessGroup(processID, signal: SIGKILL) { signalUncertain = true }
                killSentAt = now
            }

            if let killSentAt, now >= deadline(killSentAt, adding: Self.postKillReapNanoseconds),
               !processExited || stdoutFD >= 0 || stderrFD >= 0 {
                closeIfOpen(&stdoutFD)
                closeIfOpen(&stderrFD)
                return .cleanupUncertain
            }

            if waitUncertain || signalUncertain {
                if terminationCause == nil {
                    terminationCause = .inheritedPipe
                    terminationStartedAt = now
                    _ = signalProcessGroup(processID, signal: SIGTERM)
                }
            }

            if processExited && stdoutFD < 0 && stderrFD < 0 {
                if waitUncertain || signalUncertain || pipeUncertain { return .cleanupUncertain }
                switch terminationCause {
                case .timedOut: return .timedOut(exitCode(from: processStatus))
                case .cancelled: return .cancelled(exitCode(from: processStatus))
                case .inheritedPipe: return .cleanupUncertain
                case nil:
                    return waitUncertain ? .cleanupUncertain : .exited(exitCode(from: processStatus) ?? -1)
                }
            }

            pipeUncertain = drainAvailable(
                stdoutFD: &stdoutFD,
                stderrFD: &stderrFD,
                receive: receive
            ) || pipeUncertain

            var descriptors = [pollfd]()
            if stdoutFD >= 0 { descriptors.append(pollfd(fd: stdoutFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
            if stderrFD >= 0 { descriptors.append(pollfd(fd: stderrFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)) }
            if descriptors.isEmpty {
                usleep(1_000)
            } else {
                descriptors.withUnsafeMutableBufferPointer { buffer in
                    _ = Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), Self.pollIntervalMilliseconds)
                }
                for descriptor in descriptors where (descriptor.revents & Int16(POLLNVAL)) != 0 {
                    if descriptor.fd == stdoutFD { closeIfOpen(&stdoutFD) }
                    if descriptor.fd == stderrFD { closeIfOpen(&stderrFD) }
                    pipeUncertain = true
                }
            }
        }
    }

    private func drainAvailable(
        stdoutFD: inout Int32,
        stderrFD: inout Int32,
        receive: @escaping @Sendable (RuntimeExecutionStream, Data) -> Void
    ) -> Bool {
        let stdoutFailed = drain(fd: &stdoutFD, stream: .standardOutput, receive: receive)
        let stderrFailed = drain(fd: &stderrFD, stream: .standardError, receive: receive)
        return stdoutFailed || stderrFailed
    }

    private func drain(
        fd: inout Int32,
        stream: RuntimeExecutionStream,
        receive: @escaping @Sendable (RuntimeExecutionStream, Data) -> Void
    ) -> Bool {
        guard fd >= 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        var budget = RuntimeProcessDrainBudget(
            limit: Self.maximumDrainBytesPerStream,
            maximumReadAttempts: Self.maximumDrainReadAttempts
        )
        while budget.canRead {
            budget.recordReadAttempt()
            let count = Darwin.read(fd, &buffer, min(buffer.count, budget.remaining))
            if count > 0 {
                receive(stream, Data(buffer.prefix(count)))
                budget.recordRead(count)
                continue
            }
            if count == 0 {
                closeIfOpen(&fd)
                return false
            }
            if RuntimeProcessDrainBudget.shouldReturnToSupervisor(afterReadError: errno) { return false }
            closeIfOpen(&fd)
            return true
        }
        return false
    }

    private func setNonblocking(_ fileDescriptor: Int32) -> Bool {
        let flags = fcntl(fileDescriptor, F_GETFL)
        return flags >= 0 && fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private func signalProcessGroup(_ processID: pid_t, signal: Int32) -> Bool {
        if kill(-processID, signal) == 0 || errno == ESRCH { return false }
        return true
    }

    private func exitCode(from status: Int32) -> Int32? {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        if signal != 0x7f { return 128 + signal }
        return nil
    }

    private func deadline(_ start: UInt64, adding interval: UInt64) -> UInt64 {
        let (value, overflow) = start.addingReportingOverflow(interval)
        return overflow ? UInt64.max : value
    }

    private func closeIfOpen(_ fileDescriptor: inout Int32) {
        guard fileDescriptor >= 0 else { return }
        _ = Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }
}
