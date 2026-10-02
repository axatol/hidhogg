import Foundation
import Darwin
import XCTest
@testable import Hidhogg

final class LiveIntegrationTests: XCTestCase {
    private let runtimePath = "/private/tmp/hidhogg-m01-runtime"
    private var configurationPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("deploy/hidhogg.toml")
            .path
    }

    func testLiveRuntimeReadinessAndCleanup() async throws {
        guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
            throw XCTSkip("live runtime is not installed at the fixed integration path")
        }
        guard FileManager.default.isReadableFile(atPath: configurationPath) else {
            throw XCTSkip("live integration configuration is not available at the repository deploy path")
        }

        let supervisor = ProcessSupervisor(
            configuration: ProcessSupervisorConfiguration(
                executablePath: runtimePath,
                configurationPath: configurationPath
            )
        )
        let runTask = Task { await supervisor.run() }

        do {
            for _ in 0..<80 {
                let snapshot = await supervisor.snapshot()
                if snapshot.state == .ready || isTerminalFailure(snapshot.state) {
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            await supervisor.quit()
            await runTask.value
            throw error
        }

        let readySnapshot = await supervisor.snapshot()
        guard readySnapshot.state == .ready,
              let instanceID = readySnapshot.instanceID,
              let socketPath = readySnapshot.socketPath,
              !instanceID.isEmpty,
              !socketPath.isEmpty else {
            await supervisor.quit()
            await runTask.value
            XCTFail("live runtime did not become ready")
            return
        }

        let generationPath = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        let generationName = URL(fileURLWithPath: generationPath).lastPathComponent
        let generationPrefix = "hidhogg-\(geteuid())-"
        XCTAssertTrue(UUIDValidation.isCanonical(instanceID))
        XCTAssertTrue(socketPath.hasPrefix("/private/tmp/hidhogg-"))
        XCTAssertTrue(generationName.hasPrefix(generationPrefix))
        let generationUUID = generationName.hasPrefix(generationPrefix)
            ? String(generationName.dropFirst(generationPrefix.count))
            : ""
        XCTAssertTrue(UUIDValidation.isCanonical(generationUUID))
        XCTAssertEqual(URL(fileURLWithPath: socketPath).lastPathComponent, "runtime.sock")
        XCTAssertLessThanOrEqual(socketPath.utf8.count + 1, PathSecurity.unixPathBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        await supervisor.quit()
        await runTask.value

        let stoppedSnapshot = await supervisor.snapshot()
        XCTAssertEqual(stoppedSnapshot.state, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: generationPath))
    }

    private func isTerminalFailure(_ state: LifecycleState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
