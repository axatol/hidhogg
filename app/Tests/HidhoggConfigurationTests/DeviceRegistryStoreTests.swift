import Foundation
import HidhoggDomain
import XCTest
@testable import HidhoggConfiguration

final class DeviceRegistryStoreTests: XCTestCase {
    func testGenericPreferencesRoundTripPreserveNativeProjectionAndCollectSupersededHash() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let endpoint = BluetoothEndpoint(address: "AA:00:00:00:00:01")!
        var workspace = WorkspaceConfiguration(legacy: ConfigurationFixtures.configuration)
        let device = RegisteredDevice(configuration: .genericBluetooth(endpoint))
        workspace.devices.append(device)
        let first = try await store.save(workspace, expecting: .missing)
        let reference = try XCTUnwrap(RegistryCodec.manifest(Data(contentsOf: url)).devices.last)
        workspace.devices[workspace.devices.count - 1].configuration = .genericBluetooth(GenericBluetoothConfiguration(
            endpoint: endpoint, lowBatteryAlertsEnabled: true, lowBatteryThreshold: 25, iconOverride: .glasses))
        let second = try await store.save(workspace, expecting: first.revision)
        let changed = try XCTUnwrap(RegistryCodec.manifest(Data(contentsOf: url)).devices.last)
        XCTAssertNotEqual(reference.relativePath, changed.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(reference.relativePath).path))
        XCTAssertEqual(second.workspace, workspace)
        XCTAssertEqual(second.configuration, first.configuration)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.workspace, workspace)
        XCTAssertEqual(loaded.workspace.applying(first.configuration).devices.last?.bluetoothConfiguration?.iconOverride, .glasses)
        let duplicate = RegisteredDevice(configuration: .genericBluetooth(GenericBluetoothConfiguration(endpoint: endpoint, lowBatteryAlertsEnabled: true)))
        workspace.devices.append(duplicate)
        XCTAssertThrowsError(try workspace.validated())
    }

    func testLegacyGenericPayloadDefaultsAndStrictPreferenceValidation() throws {
        let device = RegisteredDevice(configuration: .genericBluetooth(BluetoothEndpoint(address: "AA:00:00:00:00:01")!))
        let old = """
        schema_version = 1
        id = "\(device.id.uuidString)"
        family = "bluetooth.generic"
        bluetooth_endpoint = "AA:00:00:00:00:01"
        """
        let reference = RegistryReference(device: device, contentHash: "012345abcdef")
        XCTAssertEqual(try RegistryCodec.device(Data(old.utf8), reference: reference), device)
        for field in ["bluetooth_low_battery_threshold = -1", "bluetooth_low_battery_threshold = 0", "bluetooth_low_battery_threshold = 101",
                      "bluetooth_low_battery_threshold = 9.5", "bluetooth_low_battery_alerts_enabled = 1",
                      "bluetooth_icon_override = \"unknown-kind\"", "bluetooth_unrecognized = true"] {
            XCTAssertThrowsError(try RegistryCodec.device(Data((old + "\n" + field).utf8), reference: reference), field)
        }
        let flow = RegisteredDevice(configuration: .flowLite84)
        let invalidNative = """
        schema_version = 1
        id = "\(flow.id.uuidString)"
        family = "lofree.flow-lite84"
        bluetooth_low_battery_alerts_enabled = true
        """
        XCTAssertThrowsError(try RegistryCodec.device(Data(invalidNative.utf8), reference: RegistryReference(device: flow, contentHash: "012345abcdef")))
        let invalid = RegisteredDevice(configuration: .genericBluetooth(GenericBluetoothConfiguration(endpoint: device.bluetoothConfiguration!.endpoint, lowBatteryThreshold: 101)))
        XCTAssertThrowsError(try WorkspaceConfiguration(devices: [invalid]).validated())
        let zero = RegisteredDevice(configuration: .genericBluetooth(GenericBluetoothConfiguration(endpoint: device.bluetoothConfiguration!.endpoint, lowBatteryThreshold: 0)))
        XCTAssertThrowsError(try WorkspaceConfiguration(devices: [zero]).validated())
    }

    func testMultipleGenericBluetoothReferencesSurviveNativeEditsAndCollectRemovedPayload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let endpoints = [BluetoothEndpoint(address: "AA:00:00:00:00:01")!, BluetoothEndpoint(address: "AA:00:00:00:00:02")!]
        var workspace = WorkspaceConfiguration(legacy: ConfigurationFixtures.configuration)
        workspace.devices += endpoints.map { RegisteredDevice(displayName: "Same Name", configuration: .genericBluetooth($0)) }
        let first = try await store.save(workspace, expecting: .missing)
        let firstReferences = try RegistryCodec.manifest(Data(contentsOf: url)).devices.filter { $0.family == .genericBluetooth }
        XCTAssertEqual(firstReferences.count, 2)
        XCTAssertTrue(firstReferences.allSatisfy { !$0.usesLegacyPath && $0.relativePath.split(separator: "/").count == 2 })
        var native = first.configuration
        native.devices[0].defaults["back"] = .key(KeyboardShortcut(keyCode: 12))
        let second = try await store.save(first.workspace.applying(native), expecting: first.revision)
        let secondReferences = try RegistryCodec.manifest(Data(contentsOf: url)).devices.filter { $0.family == .genericBluetooth }
        XCTAssertEqual(firstReferences.map(\.relativePath), secondReferences.map(\.relativePath))
        let loaded = try await store.load()
        XCTAssertEqual(loaded.workspace.devices.filter { $0.family == .genericBluetooth }, workspace.devices.filter { $0.family == .genericBluetooth })
        XCTAssertEqual(loaded.configuration, native)
        var removed = second.workspace
        removed.devices.removeAll { $0.id == firstReferences[0].id }
        _ = try await store.save(removed, expecting: second.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(firstReferences[0].relativePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(firstReferences[1].relativePath).path))
    }

    func testGenericRegistryRejectsDuplicateEndpointsNativeFamiliesAndMoreThan256Entries() throws {
        let endpoint = BluetoothEndpoint(address: "AA:00:00:00:00:01")!
        let duplicateEndpoint = WorkspaceConfiguration(devices: [RegisteredDevice(configuration: .genericBluetooth(endpoint)), RegisteredDevice(configuration: .genericBluetooth(endpoint))])
        XCTAssertThrowsError(try duplicateEndpoint.validated())
        let native = try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))
        XCTAssertThrowsError(try WorkspaceConfiguration(devices: [native, try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S))]).validated())
        let devices = (0..<256).map { index in
            RegisteredDevice(configuration: .genericBluetooth(BluetoothEndpoint(address: String(format: "AA:00:00:00:%02X:%02X", index / 256, index % 256))!))
        }
        XCTAssertNoThrow(try WorkspaceConfiguration(devices: devices).validated())
        XCTAssertThrowsError(try WorkspaceConfiguration(devices: devices + [native]).validated())
        XCTAssertNil(RegisteredDevice.make(family: .genericBluetooth))
    }

    func testLegacyMigrationBacksUpExactBytesAndKeepsUUIDsAcrossReload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        var legacy = ConfigurationFixtures.configuration
        let appearance = D200XTileAppearance(label: "Editor", imageAsset: String(repeating: "a", count: 64) + ".png")
        let action = ConfiguredExecutable(executable: "/synthetic/build", arguments: ["literal", "", "line\nbreak"])
        legacy.d200x = D200XConfiguration(defaults: ["key0": .action("build"), "key1": .action("bell")],
            applications: ["com.example.Editor": ["key1": .disabled]],
            tiles: ["key0": appearance], brightnessPercent: 1,
            actions: ["build": action], notificationTopics: ["key0": ["build.*"]],
            applicationTiles: ["com.example.Editor": ["key0": appearance]],
            applicationNotificationTopics: ["com.example.Editor": ["key0": []]],
            tilePresets: ["editor": .init(name: "Editor", appearance: appearance,
                binding: .action("build"), actions: ["build": action])],
            nativeActions: ["bell": NativeAction(kind: .bell)])
        let bytes = try ConfigurationCodec.encode(legacy)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        let assetURL = assets.appendingPathComponent(appearance.imageAsset!)
        let assetBytes = Data("synthetic image bytes".utf8)
        try assetBytes.write(to: assetURL)
        try bytes.write(to: url)
        let first = try await ConfigurationStore(url: url).load()
        let second = try await ConfigurationStore(url: url).load()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.configuration, legacy)
        XCTAssertEqual(Set(first.workspace.devices.map(\.id)).count, 3)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("legacy-v1.backup")), bytes)
        XCTAssertEqual(try RegistryCodec.version(Data(contentsOf: url)), 2)
        XCTAssertEqual(try Data(contentsOf: assetURL), assetBytes)
    }

    func testFlatPayloadNamesUseContentHashesAndReuseIdenticalBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let rootBytes = try Data(contentsOf: url)
        let references = try RegistryCodec.manifest(rootBytes).devices

        for reference in references {
            guard case .contentHash(let hash) = reference.revision else {
                return XCTFail("Expected content-addressed payload reference")
            }
            let bytes = try Data(contentsOf: root.appendingPathComponent(reference.relativePath))
            XCTAssertEqual(hash, RegistryCodec.shortSHA256(bytes))
            XCTAssertEqual(reference.relativePath,
                           "devices/\(reference.family.rawValue).\(reference.id.uuidString).\(hash).toml")
        }

        let reusedPayload = root.appendingPathComponent(references[0].relativePath)
        let devicesDirectory = root.appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: reusedPayload.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devicesDirectory.path)
        let second = try await store.save(first.workspace, expecting: first.revision)
        let nextReferences = try RegistryCodec.manifest(Data(contentsOf: url)).devices
        XCTAssertEqual(references.map(\.relativePath), nextReferences.map(\.relativePath))
        XCTAssertEqual(second.workspace, first.workspace)
        let payloadAttributes = try FileManager.default.attributesOfItem(atPath: reusedPayload.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: devicesDirectory.path)
        XCTAssertEqual(payloadAttributes[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, 0o700)
    }

    func testNestedUUIDPayloadReferencesMigrateOnLoad() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let original = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let previous = try RegistryCodec.manifest(Data(contentsOf: url))
        var nestedReferences: [RegistryReference] = []

        for device in original.workspace.devices {
            let revision = UUID()
            let reference = RegistryReference(device: device, legacyRevision: revision)
            let sourceReference = try XCTUnwrap(previous.devices.first { $0.id == device.id })
            let source = root.appendingPathComponent(sourceReference.relativePath)
            let destination = root.appendingPathComponent(reference.relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contentsOf: source).write(to: destination)
            nestedReferences.append(reference)
        }

        let nestedRoot = try RegistryCodec.encode(RegistryManifest(
            connectOnLaunch: previous.connectOnLaunch,
            devices: nestedReferences
        ))
        try nestedRoot.write(to: url)

        let migrated = try await store.load()
        let migratedReferences = try RegistryCodec.manifest(Data(contentsOf: url)).devices
        XCTAssertEqual(migrated.workspace.devices, original.workspace.devices)
        XCTAssertEqual(migrated.workspace.connectOnLaunch, original.workspace.connectOnLaunch)
        XCTAssertTrue(migratedReferences.allSatisfy { if case .contentHash = $0.revision { true } else { false } })
        XCTAssertTrue(nestedReferences.allSatisfy {
            !FileManager.default.fileExists(atPath: root.appendingPathComponent($0.relativePath).path)
        })
    }

    func testManifestRejectsUntrustedRevisionPathBeforeReadingPayload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        _ = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let validRoot = try Data(contentsOf: url)
        let reference = try XCTUnwrap(RegistryCodec.manifest(validRoot).devices.first)
        guard case .contentHash(let hash) = reference.revision else {
            return XCTFail("Expected a content-hash reference")
        }
        let outsideFile = root.appendingPathComponent("outside.toml")
        let outsideBytes = Data("leave this file unchanged".utf8)
        try outsideBytes.write(to: outsideFile)
        let invalidRoot = Data(String(decoding: validRoot, as: UTF8.self)
            .replacingOccurrences(of: hash, with: "../../outside.toml").utf8)
        try invalidRoot.write(to: url)

        do {
            _ = try await store.load()
            XCTFail("Expected untrusted revision to be rejected")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .invalidDocument)
        }

        XCTAssertEqual(try Data(contentsOf: url), invalidRoot)
        XCTAssertEqual(try Data(contentsOf: outsideFile), outsideBytes)
    }

    func testMetadataOnlySaveReusesPayloadsAndIgnoresOrphanFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let references = try RegistryCodec.manifest(Data(contentsOf: url)).devices
        var changed = first.workspace
        changed.devices[0].isEnabled = false
        changed.devices[0].displayName = "Desk mouse"
        let orphan = root.appendingPathComponent("devices/\(references[0].id)/\(UUID()).toml")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt orphan".utf8).write(to: orphan)
        let second = try await store.save(changed, expecting: first.revision)
        let nextReferences = try RegistryCodec.manifest(Data(contentsOf: url)).devices
        XCTAssertEqual(references.map(\.relativePath), nextReferences.map(\.relativePath))
        XCTAssertEqual(second.workspace.devices[0].id, first.workspace.devices[0].id)
        XCTAssertFalse(second.workspace.devices[0].isEnabled)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, second)
    }

    func testReferencedEditConflictsAndInvalidReloadDoesNotPublish() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let saved = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let rootBytes = try Data(contentsOf: url)
        let reference = try RegistryCodec.manifest(rootBytes).devices[0]
        let payload = root.appendingPathComponent(reference.relativePath)
        let corrupt = Data("invalid = true".utf8)
        try corrupt.write(to: payload)
        do {
            _ = try await store.save(saved.workspace, expecting: saved.revision)
            XCTFail("Expected referenced-file conflict")
        } catch let error as ConfigurationError { XCTAssertEqual(error, .revisionConflict) }
        do {
            _ = try await store.load()
            XCTFail("Expected invalid referenced payload rejection")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), rootBytes)
        XCTAssertEqual(try Data(contentsOf: payload), corrupt)
    }

    func testRemoveAndReAddGetsNewUUIDAndCleansOldPayload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let original = try RegistryCodec.manifest(Data(contentsOf: url)).devices[0]
        var removed = first.workspace
        removed.devices.removeAll { $0.id == original.id }
        let second = try await store.save(removed, expecting: first.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(original.relativePath).path))
        var readded = second.workspace
        readded.devices.append(try XCTUnwrap(RegisteredDevice.make(family: original.family)))
        let third = try await store.save(readded, expecting: second.revision)
        XCTAssertNotEqual(third.workspace.devices.last?.id, original.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(original.relativePath).path))
        let loaded = try await store.load()
        XCTAssertEqual(loaded, third)
    }

    func testBackupFailureLeavesLegacyUntouched() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let bytes = try ConfigurationCodec.encode(ConfigurationFixtures.configuration)
        try bytes.write(to: url)
        let wrongBackup = Data("different backup".utf8)
        try wrongBackup.write(to: url.appendingPathExtension("legacy-v1.backup"))
        do {
            _ = try await ConfigurationStore(url: url).load()
            XCTFail("Expected mismatched backup rejection")
        } catch let error as ConfigurationError { XCTAssertEqual(error, .revisionConflict) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("legacy-v1.backup")), wrongBackup)
    }

    func testMissingSymlinkedAndMismatchedPayloadsRejectWholeReload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        _ = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let rootBytes = try Data(contentsOf: url)
        let reference = try RegistryCodec.manifest(rootBytes).devices[0]
        let payload = root.appendingPathComponent(reference.relativePath)
        let bytes = try Data(contentsOf: payload)
        try FileManager.default.removeItem(at: payload)
        do {
            _ = try await store.load()
            XCTFail("Expected missing payload rejection")
        } catch let error as ConfigurationError { XCTAssertEqual(error, .invalidDocument) }
        let target = root.appendingPathComponent("synthetic-target.toml")
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: target)
        do {
            _ = try await store.load()
            XCTFail("Expected symlinked payload rejection")
        } catch let error as ConfigurationError { XCTAssertEqual(error, .symbolicLinkNotAllowed) }
        try FileManager.default.removeItem(at: payload)
        let mismatched = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: reference.id.uuidString, with: UUID().uuidString)
        try Data(mismatched.utf8).write(to: payload)
        do {
            _ = try await store.load()
            XCTFail("Expected mismatched payload UUID rejection")
        } catch let error as ConfigurationError { XCTAssertEqual(error, .invalidDocument) }
        XCTAssertEqual(try Data(contentsOf: url), rootBytes)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testChangingMouseDoesNotRewriteD200XPayload() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        var configuration = ConfigurationFixtures.configuration
        configuration.d200x = D200XConfiguration(brightnessPercent: 20)
        let first = try await store.save(configuration, expecting: .missing)
        let before = try RegistryCodec.manifest(Data(contentsOf: url)).devices
        configuration.devices[0].wheelInverted = true
        let second = try await store.save(configuration, expecting: first.revision)
        let after = try RegistryCodec.manifest(Data(contentsOf: url)).devices
        XCTAssertNotEqual(before.first { $0.family == .mxMaster3S }?.relativePath,
                          after.first { $0.family == .mxMaster3S }?.relativePath)
        let oldMouseReference = try XCTUnwrap(before.first { $0.family == .mxMaster3S })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(oldMouseReference.relativePath).path))
        XCTAssertEqual(before.first { $0.family == .d200x }?.relativePath,
                       after.first { $0.family == .d200x }?.relativePath)
        XCTAssertEqual(second.configuration.d200x, configuration.d200x)
    }

    func testFailureAfterStagingKeepsOldReferencesUntilLaterSuccessfulPublication() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let bytes = try Data(contentsOf: url)
        var changed = first.workspace
        if case .mouse(var mouse) = changed.devices[0].configuration {
            mouse.wheelInverted = true
            changed.devices[0].configuration = .mouse(mouse)
        }
        let failingStore = ConfigurationStore(url: url, beforeRegistryPublication: {
            throw ConfigurationError.filesystemAccessFailed
        })
        do {
            _ = try await failingStore.save(changed, expecting: first.revision)
            XCTFail("Expected staged publication failure")
        } catch let error as ConfigurationError { XCTAssertEqual(error, .filesystemAccessFailed) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let devicesDirectory = root.appendingPathComponent("devices", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: devicesDirectory.path).filter { $0.hasSuffix(".toml") }.count, 4)

        let retried = try await store.save(first.workspace, expecting: first.revision)
        XCTAssertEqual(retried.workspace, first.workspace)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: devicesDirectory.path).filter { $0.hasSuffix(".toml") }.count, 3)
    }

    func testShortHashCollisionFailsWithoutOverwritingExistingBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let workspace = WorkspaceConfiguration(legacy: ConfigurationFixtures.configuration)
        let device = workspace.devices[0]
        let payload = try RegistryCodec.encode(device: device)
        let reference = RegistryReference(device: device, contentHash: RegistryCodec.shortSHA256(payload))
        let target = root.appendingPathComponent(reference.relativePath)
        let conflictingBytes = Data("different bytes at the expected hash path".utf8)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try conflictingBytes.write(to: target)

        do {
            _ = try await ConfigurationStore(url: url).save(workspace, expecting: .missing)
            XCTFail("Expected same-path different-byte rejection")
        } catch let error as ConfigurationError {
            XCTAssertEqual(error, .payloadHashCollision)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: target), conflictingBytes)
    }

    func testCleanupPreservesSymlinkAndUnrelatedFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let devicesDirectory = root.appendingPathComponent("devices", isDirectory: true)
        let target = root.appendingPathComponent("external.toml")
        let targetBytes = Data("external payload".utf8)
        try targetBytes.write(to: target)
        let symlinkName = "\(DeviceFamily.mxMaster3S.rawValue).\(UUID().uuidString).123456abcdef.toml"
        let symlink = devicesDirectory.appendingPathComponent(symlinkName)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let unrelated = devicesDirectory.appendingPathComponent("notes.txt")
        let unrelatedBytes = Data("keep this file".utf8)
        try unrelatedBytes.write(to: unrelated)
        let unrelatedDirectory = devicesDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: false)

        var changed = first.workspace
        if case .mouse(var mouse) = changed.devices[0].configuration {
            mouse.wheelInverted = true
            changed.devices[0].configuration = .mouse(mouse)
        }
        _ = try await store.save(changed, expecting: first.revision)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
        XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
    }

    func testCleanupFailureDoesNotFailSaveAndRetriesOnNextPublication() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let oldReference = try XCTUnwrap(RegistryCodec.manifest(Data(contentsOf: url)).devices.first { $0.family == .mxMaster3S })
        var changed = first.workspace
        if case .mouse(var mouse) = changed.devices[0].configuration {
            mouse.wheelInverted = true
            changed.devices[0].configuration = .mouse(mouse)
        }

        let committed = try await ConfigurationStore(url: url, beforePayloadCleanup: {
            throw ConfigurationError.filesystemAccessFailed
        }).save(changed, expecting: first.revision)
        let oldPayload = root.appendingPathComponent(oldReference.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldPayload.path))
        let loadedAfterCommit = try await store.load()
        XCTAssertEqual(loadedAfterCommit.workspace, committed.workspace)

        _ = try await store.save(committed.workspace, expecting: committed.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPayload.path))
        let loadedAfterRetry = try await store.load()
        XCTAssertEqual(loadedAfterRetry.workspace, committed.workspace)
    }

    func testCleanupStopsIfRootChangesAfterCandidateScan() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let oldRoot = try Data(contentsOf: url)
        let oldReference = try XCTUnwrap(RegistryCodec.manifest(oldRoot).devices.first { $0.family == .mxMaster3S })
        var changed = first.workspace
        if case .mouse(var mouse) = changed.devices[0].configuration {
            mouse.wheelInverted = true
            changed.devices[0].configuration = .mouse(mouse)
        }

        _ = try await ConfigurationStore(url: url, beforePayloadCleanup: {
            try oldRoot.write(to: url)
        }).save(changed, expecting: first.revision)

        XCTAssertEqual(try Data(contentsOf: url), oldRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(oldReference.relativePath).path))
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, first)
    }

    func testManualPayloadEditLoadsAndStaleHashFileSurvivesCleanup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let first = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let reference = try XCTUnwrap(RegistryCodec.manifest(Data(contentsOf: url)).devices.first { $0.family == .mxMaster3S })
        let payloadURL = root.appendingPathComponent(reference.relativePath)
        var editedDevice = try XCTUnwrap(first.workspace.devices.first { $0.id == reference.id })
        if case .mouse(var mouse) = editedDevice.configuration {
            mouse.wheelInverted = true
            editedDevice.configuration = .mouse(mouse)
        }
        let editedBytes = try RegistryCodec.encode(device: editedDevice)
        try editedBytes.write(to: payloadURL)

        let loaded = try await store.load()
        guard let loadedDevice = loaded.workspace.devices.first(where: { $0.id == reference.id }),
              case .mouse(let loadedMouse) = loadedDevice.configuration else {
            return XCTFail("Expected edited mouse payload")
        }
        XCTAssertEqual(loadedMouse.wheelInverted, true)
        var changed = loaded.workspace
        let changedIndex = try XCTUnwrap(changed.devices.firstIndex { $0.id == reference.id })
        changed.devices[changedIndex].displayName = "Edited mouse"
        let saved = try await store.save(changed, expecting: loaded.revision)

        XCTAssertNotEqual(try RegistryCodec.manifest(Data(contentsOf: url)).devices.first { $0.id == reference.id }?.relativePath,
                          reference.relativePath)
        XCTAssertEqual(try Data(contentsOf: payloadURL), editedBytes)
        XCTAssertEqual(saved.workspace.devices.first { $0.id == reference.id }?.displayName, "Edited mouse")
    }

    func testInvalidRegistryCannotReplaceValidPublication() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.toml")
        let store = ConfigurationStore(url: url)
        let saved = try await store.save(ConfigurationFixtures.configuration, expecting: .missing)
        let bytes = try Data(contentsOf: url)
        for invalidName in ["", "bad\nname", String(repeating: "é", count: 65)] {
            var invalid = saved.workspace
            invalid.devices[0].displayName = invalidName
            do {
                _ = try await store.save(invalid, expecting: saved.revision)
                XCTFail("Expected invalid registry rejection")
            } catch {}
        }
        var duplicate = saved.workspace
        duplicate.devices.append(try XCTUnwrap(RegisteredDevice.make(family: .mxMaster3S)))
        do {
            _ = try await store.save(duplicate, expecting: saved.revision)
            XCTFail("Expected duplicate family rejection")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("HidhoggRegistryTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
