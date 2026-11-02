import Foundation
import IOKit.hid
import HidhoggDomain

struct LogitechEndpointLocator: Equatable, Sendable {
    let id: UUID
    let key: UInt64
    let connection: LogitechConnection
    let productID: Int
}

protocol LogitechEndpointCatalog: Sendable {
    func enumerate() async throws -> [LogitechEndpointLocator]
    func makeTransport(for locator: LogitechEndpointLocator,
                       onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport
    func makeReceiverTransport(for locator: LogitechEndpointLocator,
                               onTerminal: @escaping @Sendable () -> Void) -> (any BoltReceiverTransport)?
}

extension LogitechEndpointCatalog {
    func makeReceiverTransport(for locator: LogitechEndpointLocator,
                               onTerminal: @escaping @Sendable () -> Void) -> (any BoltReceiverTransport)? {
        nil
    }
}

struct LogitechBluetoothOutputDescriptor: Equatable, Sendable {
    let reportID: UInt32
    let usagePage: UInt32
    let isOutput: Bool
    let reportCount: UInt32
    let reportSize: UInt32
}

enum LogitechEndpointEligibility {
    static let vendorID = 0x046D
    static let boltProductID = 0xC548
    static let bluetoothProductIDs: Set<Int> = [0xB034, 0xB042]
    static let bluetoothTransports: Set<String> = ["Bluetooth", "BluetoothLowEnergy", "Bluetooth Low Energy"]
    static let hidppReportID: UInt32 = 0x11
    static let hidppBodyLength: UInt32 = 19

    static func bluetoothOutputIsEligible(vendorID: Int?, productID: Int?, transport: String?,
                                          output: LogitechBluetoothOutputDescriptor?) -> Bool {
        guard vendorID == Self.vendorID,
              let productID, bluetoothProductIDs.contains(productID),
              let transport, bluetoothTransports.contains(transport),
              let output else { return false }
        return output.reportID == hidppReportID && output.usagePage >= 0xFF00 && output.isOutput
            && output.reportCount == hidppBodyLength && output.reportSize == 8
    }

    static func isEligibleBolt(vendorID: Int?, productID: Int?, transport: String?,
                               maxInputReportSize: Int?, reportIDs: [(UInt32, UInt32)]?) -> Bool {
        guard vendorID == Self.vendorID, productID == boltProductID, transport == "USB",
              let maxInputReportSize, (20...256).contains(maxInputReportSize),
              let reportIDs else { return false }
        let inputTypes: Set<UInt32> = [1, 2, 3, 4, 5]
        let input = reportIDs.contains { $0.0 == hidppReportID && inputTypes.contains($0.1) }
        let output = reportIDs.contains { $0.0 == hidppReportID && $0.1 == kIOHIDElementTypeOutput.rawValue }
        return input && output
    }
}

final class IOKitEndpointHandle: @unchecked Sendable {
    let device: IOHIDDevice
    let outputElement: IOHIDElement?
    let key: UInt64

    init(device: IOHIDDevice, outputElement: IOHIDElement?, key: UInt64) {
        self.device = device
        self.outputElement = outputElement
        self.key = key
    }
}

final class IOKitLogitechEndpointCatalog: LogitechEndpointCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [UUID: IOKitEndpointHandle] = [:]

    func enumerate() async throws -> [LogitechEndpointLocator] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey as String: LogitechEndpointEligibility.vendorID,
             kIOHIDProductIDKey as String: LogitechEndpointEligibility.boltProductID,
             kIOHIDTransportKey as String: kIOHIDTransportUSBValue],
            [kIOHIDVendorIDKey as String: LogitechEndpointEligibility.vendorID,
             kIOHIDProductIDKey as String: 0xB034],
            [kIOHIDVendorIDKey as String: LogitechEndpointEligibility.vendorID,
             kIOHIDProductIDKey as String: 0xB042]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            throw BoltFailure.unavailable
        }

        var nextHandles: [UUID: IOKitEndpointHandle] = [:]
        var locators: [LogitechEndpointLocator] = []
        for device in devices {
            guard let endpoint = Self.endpoint(for: device) else { continue }
            let id = UUID()
            nextHandles[id] = endpoint.handle
            locators.append(LogitechEndpointLocator(id: id, key: endpoint.handle.key,
                                                    connection: endpoint.connection, productID: endpoint.productID))
        }

        guard locators.count <= 16 else { throw BoltFailure.ambiguous }
        lock.withLock { handles = nextHandles }
        return locators.sorted {
            if $0.connection != $1.connection { return $0.connection.rawValue < $1.connection.rawValue }
            if $0.productID != $1.productID { return $0.productID < $1.productID }
            return $0.key < $1.key
        }
    }

    func makeTransport(for locator: LogitechEndpointLocator,
                       onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport {
        let handle = lock.withLock { handles[locator.id] }
        return IOKitBoltTransport(connection: locator.connection, endpoint: handle,
                                  requireEndpoint: true, onTerminal: onTerminal)
    }

    func makeReceiverTransport(for locator: LogitechEndpointLocator,
                               onTerminal: @escaping @Sendable () -> Void) -> (any BoltReceiverTransport)? {
        guard locator.connection == .bolt, locator.productID == LogitechEndpointEligibility.boltProductID,
              let handle = lock.withLock({ handles[locator.id] }) else { return nil }
        return IOKitBoltTransport(connection: .bolt, endpoint: handle, requireEndpoint: true,
                                  onTerminal: onTerminal)
    }

    private static func endpoint(for device: IOHIDDevice) -> (handle: IOKitEndpointHandle, connection: LogitechConnection, productID: Int)? {
        let vendorID = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return nil
        }

        let connection: LogitechConnection
        let outputElement: IOHIDElement?
        if LogitechEndpointEligibility.bluetoothProductIDs.contains(productID ?? -1) {
            let outputs = elements.filter { element in
                LogitechEndpointEligibility.bluetoothOutputIsEligible(
                    vendorID: vendorID, productID: productID, transport: transport,
                    output: LogitechBluetoothOutputDescriptor(
                        reportID: IOHIDElementGetReportID(element),
                        usagePage: IOHIDElementGetUsagePage(element),
                        isOutput: IOHIDElementGetType(element) == kIOHIDElementTypeOutput,
                        reportCount: IOHIDElementGetReportCount(element),
                        reportSize: IOHIDElementGetReportSize(element)
                    )
                )
            }
            let hasInput = elements.contains {
                IOHIDElementGetReportID($0) == LogitechEndpointEligibility.hidppReportID
                    && [1, 2, 3, 4, 5].contains(IOHIDElementGetType($0).rawValue)
            }
            guard outputs.count == 1, hasInput else { return nil }
            connection = .bluetooth
            outputElement = outputs[0]
        } else {
            let reportTypes = elements
                .filter { IOHIDElementGetReportID($0) == LogitechEndpointEligibility.hidppReportID }
                .map { (IOHIDElementGetReportID($0), IOHIDElementGetType($0).rawValue) }
            let maxInputReportSize = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue
            guard LogitechEndpointEligibility.isEligibleBolt(vendorID: vendorID, productID: productID,
                                                              transport: transport, maxInputReportSize: maxInputReportSize,
                                                              reportIDs: reportTypes) else { return nil }
            connection = .bolt
            outputElement = nil
        }

        let service = IOHIDDeviceGetService(device)
        var key: UInt64 = 0
        guard service != 0, IORegistryEntryGetRegistryEntryID(service, &key) == KERN_SUCCESS else { return nil }
        return (IOKitEndpointHandle(device: device, outputElement: outputElement, key: key), connection, productID ?? 0)
    }
}

final class UnavailableBoltEndpointCatalog: LogitechEndpointCatalog, Sendable {
    func enumerate() async throws -> [LogitechEndpointLocator] { [] }

    func makeTransport(for locator: LogitechEndpointLocator,
                       onTerminal: @escaping @Sendable () -> Void) -> any BoltTransport {
        UnavailableBoltTransport()
    }
}

private struct UnavailableBoltTransport: BoltTransport {
    let events = AsyncStream<BoltTransportEvent> { $0.finish() }

    func open() async throws { throw BoltFailure.unavailable }
    func availableRequestIDs(slot: UInt8, feature: UInt8, function: UInt8) -> Int { 0 }
    func request(slot: UInt8, feature: UInt8, function: UInt8, parameters: [UInt8]) async throws -> [UInt8] {
        throw BoltFailure.unavailable
    }
    func close() async {}
}
