import Foundation
import IOKit.hid
import HidhoggDomain
import ObjectiveC

final class BoltHIDInputBuffer {
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    deinit { bytes.deallocate() }
}

final class BoltHIDInputBufferAssociation: @unchecked Sendable {
    private static let key = BoltHIDInputBufferAssociation()
    private let lock = NSLock()

    private init() {}

    static func bind(_ buffer: BoltHIDInputBuffer, to nativeClient: AnyObject) -> Bool {
        key.lock.withLock {
            let address = Unmanaged.passUnretained(key).toOpaque()
            if let existing = objc_getAssociatedObject(nativeClient, address) {
                return (existing as? BoltHIDInputBuffer) === buffer
            }
            objc_setAssociatedObject(nativeClient, address, buffer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return (objc_getAssociatedObject(nativeClient, address) as? BoltHIDInputBuffer) === buffer
        }
    }
}

class BoltNativeDevice: @unchecked Sendable {
    private(set) var raw: IOHIDDevice?
    var inputBuffer: BoltHIDInputBuffer?

    init(raw: IOHIDDevice? = nil) {
        self.raw = raw
    }

    deinit {
        raw = nil
        inputBuffer = nil
    }
}

final class BoltNativeManager {
    let raw: IOHIDManager?
    init(raw: IOHIDManager? = nil) { self.raw = raw }
}

final class BoltNativeOutputElement {
    let raw: IOHIDElement?
    init(raw: IOHIDElement? = nil) { self.raw = raw }
}

protocol BoltHIDNativeAPI: Sendable {
    func makeManager(connection: LogitechConnection) -> BoltNativeManager
    func devices(_ manager: BoltNativeManager) -> [BoltNativeDevice]
    func catalogDevice(_ endpoint: IOKitEndpointHandle) -> BoltNativeDevice
    func registryKey(_ device: BoltNativeDevice) -> UInt64?
    func makePrivateDevice(_ device: BoltNativeDevice) -> BoltNativeDevice?
    func eligible(_ device: BoltNativeDevice, connection: LogitechConnection) -> Bool
    func outputElement(_ device: BoltNativeDevice) -> BoltNativeOutputElement?
    func open(_ device: BoltNativeDevice) -> IOReturn
    func registerInput(_ device: BoltNativeDevice, buffer: BoltHIDInputBuffer, callback: IOHIDReportCallback, context: UnsafeMutableRawPointer?) -> Bool
    func registerRemoval(_ device: BoltNativeDevice, callback: IOHIDCallback, context: UnsafeMutableRawPointer?)
    func registerMatching(_ manager: BoltNativeManager, callback: IOHIDDeviceCallback, context: UnsafeMutableRawPointer?)
    func schedule(_ device: BoltNativeDevice)
    func schedule(_ manager: BoltNativeManager)
    func unregister(_ device: BoltNativeDevice, context: UnsafeMutableRawPointer?)
    func unregister(_ manager: BoltNativeManager, context: UnsafeMutableRawPointer?)
    func unschedule(_ device: BoltNativeDevice)
    func unschedule(_ manager: BoltNativeManager)
    func close(_ device: BoltNativeDevice) -> IOReturn
    func sendReport(_ device: BoltNativeDevice, reportID: Int, bytes: UnsafeMutablePointer<UInt8>, count: Int,
                    callback: IOHIDReportCallback, context: UnsafeMutableRawPointer?) -> IOReturn
}

struct IOKitBoltNativeAPI: BoltHIDNativeAPI {
    func makeManager(connection: LogitechConnection) -> BoltNativeManager {
        let manager = IOHIDManagerCreate(nil, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = switch connection {
        case .bolt:
            [[kIOHIDVendorIDKey as String: LogitechEndpointEligibility.vendorID,
              kIOHIDProductIDKey as String: LogitechEndpointEligibility.boltProductID,
              kIOHIDTransportKey as String: kIOHIDTransportUSBValue]]
        case .bluetooth:
            LogitechEndpointEligibility.bluetoothProductIDs.sorted().map {
                [kIOHIDVendorIDKey as String: LogitechEndpointEligibility.vendorID,
                 kIOHIDProductIDKey as String: $0]
            }
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        return BoltNativeManager(raw: manager)
    }

    func devices(_ manager: BoltNativeManager) -> [BoltNativeDevice] {
        guard let raw = manager.raw,
              let devices = IOHIDManagerCopyDevices(raw) as? Set<IOHIDDevice> else { return [] }
        return devices.map { BoltNativeDevice(raw: $0) }
    }

    func catalogDevice(_ endpoint: IOKitEndpointHandle) -> BoltNativeDevice { BoltNativeDevice(raw: endpoint.device) }

    func registryKey(_ device: BoltNativeDevice) -> UInt64? {
        guard let raw = device.raw else { return nil }
        let service = IOHIDDeviceGetService(raw)
        var key: UInt64 = 0
        guard service != 0, IORegistryEntryGetRegistryEntryID(service, &key) == KERN_SUCCESS else { return nil }
        return key
    }

    func makePrivateDevice(_ device: BoltNativeDevice) -> BoltNativeDevice? {
        guard let raw = device.raw else { return nil }
        let service = IOHIDDeviceGetService(raw)
        guard service != 0, let created = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return nil }
        return BoltNativeDevice(raw: created)
    }

    func eligible(_ device: BoltNativeDevice, connection: LogitechConnection) -> Bool {
        guard let raw = device.raw else { return false }
        if connection == .bluetooth { return outputElement(device) != nil }
        let vendorID = (IOHIDDeviceGetProperty(raw, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let productID = (IOHIDDeviceGetProperty(raw, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        let transport = IOHIDDeviceGetProperty(raw, kIOHIDTransportKey as CFString) as? String
        let capacity = (IOHIDDeviceGetProperty(raw, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue
        guard let elements = IOHIDDeviceCopyMatchingElements(raw, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return false }
        let reportTypes = elements.filter { IOHIDElementGetReportID($0) == LogitechEndpointEligibility.hidppReportID }
            .map { (IOHIDElementGetReportID($0), IOHIDElementGetType($0).rawValue) }
        return LogitechEndpointEligibility.isEligibleBolt(vendorID: vendorID, productID: productID,
                                                          transport: transport, maxInputReportSize: capacity,
                                                          reportIDs: reportTypes)
    }

    func outputElement(_ device: BoltNativeDevice) -> BoltNativeOutputElement? {
        guard let raw = device.raw,
              let elements = IOHIDDeviceCopyMatchingElements(raw, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return nil }
        let vendorID = (IOHIDDeviceGetProperty(raw, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let productID = (IOHIDDeviceGetProperty(raw, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        let transport = IOHIDDeviceGetProperty(raw, kIOHIDTransportKey as CFString) as? String
        let outputs = elements.filter {
            LogitechEndpointEligibility.bluetoothOutputIsEligible(
                vendorID: vendorID, productID: productID, transport: transport,
                output: LogitechBluetoothOutputDescriptor(reportID: IOHIDElementGetReportID($0),
                    usagePage: IOHIDElementGetUsagePage($0), isOutput: IOHIDElementGetType($0) == kIOHIDElementTypeOutput,
                    reportCount: IOHIDElementGetReportCount($0), reportSize: IOHIDElementGetReportSize($0)))
        }
        let hasInput = elements.contains {
            IOHIDElementGetReportID($0) == LogitechEndpointEligibility.hidppReportID
                && [1, 2, 3, 4, 5].contains(IOHIDElementGetType($0).rawValue)
        }
        return outputs.count == 1 && hasInput ? BoltNativeOutputElement(raw: outputs[0]) : nil
    }

    func open(_ device: BoltNativeDevice) -> IOReturn {
        guard let raw = device.raw else { return kIOReturnBadArgument }
        return IOHIDDeviceOpen(raw, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func registerInput(_ device: BoltNativeDevice, buffer: BoltHIDInputBuffer, callback: IOHIDReportCallback,
                       context: UnsafeMutableRawPointer?) -> Bool {
        guard let raw = device.raw, BoltHIDInputBufferAssociation.bind(buffer, to: raw) else { return false }
        device.inputBuffer = buffer
        IOHIDDeviceRegisterInputReportCallback(raw, buffer.bytes, 256, callback, context)
        return true
    }

    func registerRemoval(_ device: BoltNativeDevice, callback: IOHIDCallback, context: UnsafeMutableRawPointer?) {
        guard let raw = device.raw else { return }
        IOHIDDeviceRegisterRemovalCallback(raw, callback, context)
    }

    func registerMatching(_ manager: BoltNativeManager, callback: IOHIDDeviceCallback, context: UnsafeMutableRawPointer?) {
        guard let raw = manager.raw else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(raw, callback, context)
    }

    func schedule(_ device: BoltNativeDevice) {
        guard let raw = device.raw else { return }
        IOHIDDeviceScheduleWithRunLoop(raw, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
    func schedule(_ manager: BoltNativeManager) {
        guard let raw = manager.raw else { return }
        IOHIDManagerScheduleWithRunLoop(raw, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
    func unregister(_ device: BoltNativeDevice, context: UnsafeMutableRawPointer?) {
        guard let raw = device.raw, let input = device.inputBuffer else { return }
        IOHIDDeviceRegisterInputReportCallback(raw, input.bytes, 256, nil, context)
        IOHIDDeviceRegisterRemovalCallback(raw, nil, context)
    }
    func unregister(_ manager: BoltNativeManager, context: UnsafeMutableRawPointer?) {
        guard let raw = manager.raw else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(raw, nil, context)
    }
    func unschedule(_ device: BoltNativeDevice) {
        guard let raw = device.raw else { return }
        IOHIDDeviceUnscheduleFromRunLoop(raw, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
    func unschedule(_ manager: BoltNativeManager) {
        guard let raw = manager.raw else { return }
        IOHIDManagerUnscheduleFromRunLoop(raw, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }
    func close(_ device: BoltNativeDevice) -> IOReturn {
        guard let raw = device.raw else { return kIOReturnBadArgument }
        return IOHIDDeviceClose(raw, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func sendReport(_ device: BoltNativeDevice, reportID: Int, bytes: UnsafeMutablePointer<UInt8>, count: Int,
                    callback: IOHIDReportCallback, context: UnsafeMutableRawPointer?) -> IOReturn {
        guard let raw = device.raw else { return kIOReturnBadArgument }
        return IOHIDDeviceSetReportWithCallback(raw, kIOHIDReportTypeOutput, reportID, bytes, count,
                                               600, callback, context)
    }
}

enum BoltHIDCallbacks {
    static let inputReport: IOHIDReportCallback = { context, result, _, type, reportID, bytes, count in
        BoltHIDCallbackRegistry.shared.withOwner(context) {
            $0.receive(result: result, type: type, reportID: reportID, bytes: bytes, count: count)
        }
    }

    static let removalReport: IOHIDCallback = { context, _, _ in
        BoltHIDCallbackRegistry.shared.withOwner(context) { $0.receiveRemoval() }
    }

    static let matchingReport: IOHIDDeviceCallback = { context, _, _, added in
        BoltHIDCallbackRegistry.shared.withOwner(context) { $0.receiveMatching(BoltNativeDevice(raw: added)) }
    }
}
