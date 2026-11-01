import CoreFoundation
import Foundation
import HidhoggDomain

public enum BluetoothRegistryBatteryParser {
    public static func batteries(in data: Data, pairedEndpoints: Set<BluetoothEndpoint>) throws -> [BluetoothEndpoint: BluetoothBattery] {
        let propertyList: Any
        do { propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw BluetoothObservationFailure.unsupportedReport }
        guard let nodes = propertyList as? [Any] else { throw BluetoothObservationFailure.unsupportedReport }
        var values: [BluetoothEndpoint: Int] = [:]
        var ambiguous: Set<BluetoothEndpoint> = []
        for value in nodes {
            guard let node = value as? [String: Any] else { throw BluetoothObservationFailure.unsupportedReport }
            guard let endpoint = normalizeBluetoothEndpoint(in: node), pairedEndpoints.contains(endpoint),
                  node["BatteryPercent"] != nil else { continue }
            guard let percent = percentage(node["BatteryPercent"]) else {
                ambiguous.insert(endpoint)
                values.removeValue(forKey: endpoint)
                continue
            }
            guard !ambiguous.contains(endpoint) else { continue }
            if let previous = values[endpoint], previous != percent {
                ambiguous.insert(endpoint)
                values.removeValue(forKey: endpoint)
                continue
            }
            values[endpoint] = percent
        }
        return values.mapValues { BluetoothBattery(main: $0) }
    }

    private static func normalizeBluetoothEndpoint(in node: [String: Any]) -> BluetoothEndpoint? {
        guard let address = node["DeviceAddress"] as? String else { return nil }
        return BluetoothEndpoint(address: address)
    }

    private static func percentage(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue,
              (0...100).contains(number.doubleValue) else { return nil }
        return number.intValue
    }
}
