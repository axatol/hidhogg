import Foundation
import XCTest
@testable import Hidhogg

@MainActor
final class DefaultConfigurationBootstrapTests: XCTestCase {
    func testFirstLaunchCreatesBundledTemplateAtAbsoluteXDGPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        let templateData = try bundledTemplateData()
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: xdgConfigHome.path,
            homeDirectory: root,
            templateData: templateData
        )
        let expectedPath = xdgConfigHome
            .appendingPathComponent("hidhogg", isDirectory: true)
            .appendingPathComponent("config.toml")
            .path
        let target = bootstrap.resolve(persistedSelectedPath: nil)

        XCTAssertEqual(target, .defaultConfiguration(path: expectedPath))
        try bootstrap.prepare(target)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: expectedPath)), templateData)
    }

    func testRelativeXDGConfigHomeFallsBackToInjectedHomeDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: "relative/config",
            homeDirectory: root,
            templateData: try bundledTemplateData()
        )
        let expectedPath = root
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("hidhogg", isDirectory: true)
            .appendingPathComponent("config.toml")
            .path
        let target = bootstrap.resolve(persistedSelectedPath: nil)

        XCTAssertEqual(target, .defaultConfiguration(path: expectedPath))
        try bootstrap.prepare(target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath))
    }

    func testExistingEmptyAndInvalidFilesArePreservedByteForByte() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let templateData = try bundledTemplateData()

        for (index, originalData) in [Data(), Data("schema_version = [".utf8)].enumerated() {
            let xdgConfigHome = root.appendingPathComponent("xdg-\(index)", isDirectory: true)
            let configDirectory = xdgConfigHome.appendingPathComponent("hidhogg", isDirectory: true)
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let configURL = configDirectory.appendingPathComponent("config.toml")
            try originalData.write(to: configURL)
            let bootstrap = DefaultConfigurationBootstrap(
                xdgConfigHome: xdgConfigHome.path,
                homeDirectory: root,
                templateData: templateData
            )

            try bootstrap.prepare(bootstrap.resolve(persistedSelectedPath: nil))

            XCTAssertEqual(try Data(contentsOf: configURL), originalData)
        }
    }

    func testConcurrentPreparationPublishesOnlyCompleteTemplate() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var templateData = try bundledTemplateData()
        templateData.append(Data(repeating: 0x20, count: 2 * 1024 * 1024))
        let expectedTemplateData = templateData
        let xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: xdgConfigHome.path,
            homeDirectory: root,
            templateData: templateData
        )
        let target = bootstrap.resolve(persistedSelectedPath: nil)
        let configURL = URL(fileURLWithPath: target.path)
        let observer = Task.detached(priority: .userInitiated) { [configURL, expectedTemplateData] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while true {
                if FileManager.default.fileExists(atPath: configURL.path) {
                    return try Data(contentsOf: configURL) == expectedTemplateData
                }
                if clock.now >= deadline { return false }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { observer.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try bootstrap.prepare(target)
                }
            }
            try await group.waitForAll()
        }

        let observedCompleteTemplate = try await observer.value
        XCTAssertTrue(observedCompleteTemplate)
        XCTAssertEqual(try Data(contentsOf: configURL), expectedTemplateData)
    }

    func testDanglingSymlinkAtDefaultPathFailsWithoutReplacingEntry() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        let configDirectory = xdgConfigHome.appendingPathComponent("hidhogg", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("config.toml")
        let missingTarget = root.appendingPathComponent("missing-target.toml")
        try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: missingTarget)
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: xdgConfigHome.path,
            homeDirectory: root,
            templateData: try bundledTemplateData()
        )
        let target = bootstrap.resolve(persistedSelectedPath: nil)

        XCTAssertThrowsError(try bootstrap.prepare(target)) { error in
            let bootstrapError = error as? DefaultConfigurationBootstrapError
            XCTAssertEqual(bootstrapError?.path, target.path)
            XCTAssertTrue(
                bootstrapError?.localizedDescription.contains("dangling symbolic link") == true
            )
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: configURL.path),
            missingTarget.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }

    func testExplicitSelectedPathOverridesXDGAndRemainsUntouched() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        let selectedURL = root.appendingPathComponent("selected.toml")
        let selectedContents = Data("existing selected config".utf8)
        try selectedContents.write(to: selectedURL)
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: xdgConfigHome.path,
            homeDirectory: root,
            templateData: try bundledTemplateData()
        )
        let target = bootstrap.resolve(persistedSelectedPath: selectedURL.path)

        XCTAssertEqual(target, .selected(path: selectedURL.path))
        try bootstrap.prepare(target)

        XCTAssertEqual(try Data(contentsOf: selectedURL), selectedContents)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: xdgConfigHome.appendingPathComponent("hidhogg/config.toml").path
        ))
    }

    func testInvalidSavedPathDoesNotFallBackToDefault() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: xdgConfigHome.path,
            homeDirectory: root,
            templateData: try bundledTemplateData()
        )
        let target = bootstrap.resolve(persistedSelectedPath: "relative.toml")

        XCTAssertEqual(target, .invalidSelectedPath(path: "relative.toml"))
        XCTAssertThrowsError(try bootstrap.prepare(target)) { error in
            XCTAssertEqual(
                error as? DefaultConfigurationBootstrapError,
                .invalidSelectedPath(path: "relative.toml")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: xdgConfigHome.appendingPathComponent("hidhogg/config.toml").path
        ))
    }

    func testCreationFailureIncludesResolvedPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeBlocker = root.appendingPathComponent("home-is-a-file")
        try Data("blocking file".utf8).write(to: homeBlocker)
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: nil,
            homeDirectory: homeBlocker,
            templateData: try bundledTemplateData()
        )
        let target = bootstrap.resolve(persistedSelectedPath: nil)

        XCTAssertThrowsError(try bootstrap.prepare(target)) { error in
            XCTAssertEqual(
                (error as? DefaultConfigurationBootstrapError)?.path,
                target.path
            )
        }
    }

    func testStartupDoesNotStartRuntimeWhenDefaultCreationFails() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeBlocker = root.appendingPathComponent("home-is-a-file")
        try Data("blocking file".utf8).write(to: homeBlocker)
        let templateData = try bundledTemplateData()
        let bootstrap = DefaultConfigurationBootstrap(
            xdgConfigHome: nil,
            homeDirectory: homeBlocker,
            templateData: templateData
        )
        let target = bootstrap.resolve(persistedSelectedPath: nil)
        let runtimeSession = RuntimeSessionController()
        let model = HidhoggAppModel(
            preferencesStore: TestPreferencesStore(),
            runtimeSession: runtimeSession,
            profileMappingStore: TestProfileMappingStore(),
            displayPowerCoordinator: HostDisplayPowerCoordinator(
                observer: InertHostDisplayPowerObserver()
            ),
            foregroundObserver: EmptyForegroundObserver(),
            configurationBootstrapFactory: { bootstrap }
        )

        model.start()
        await runtimeSession.waitForTransition()

        XCTAssertNil(runtimeSession.configurationPath)
        XCTAssertEqual(model.selectedConfigurationPath, target.path)
        XCTAssertTrue(model.healthText.contains(target.path))
        XCTAssertEqual(runtimeSession.lifecycleState, .configurationRequired)

        await model.quit()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidhogg-config-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func bundledTemplateData() throws -> Data {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let templateURL = testDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Hidhogg", isDirectory: true)
            .appendingPathComponent("DefaultConfig.toml")
        return try Data(contentsOf: templateURL)
    }
}

@MainActor
private final class EmptyForegroundObserver: ForegroundApplicationObserving {
    func start(handler: @escaping ForegroundApplicationHandler) {}

    func stop() {}
}

private final class TestPreferencesStore: @unchecked Sendable, AppPreferencesStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

private final class TestProfileMappingStore: @unchecked Sendable, ProfileMappingPreferencesStore {
    func dictionary(forKey key: String) -> [String: String]? { nil }

    func set(_ value: [String: String]?, forKey key: String) {}
}

@MainActor
private final class InertHostDisplayPowerObserver: HostDisplayPowerObserving {
    var lastKnownDisplayAwake: Bool? { nil }

    func start(
        stateHandler: @escaping HostDisplayPowerStateHandler,
        errorHandler: @escaping HostDisplayPowerErrorHandler
    ) {}

    func reconcileIfUnknown() {}

    func stop() {}
}
