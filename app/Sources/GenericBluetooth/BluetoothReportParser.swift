import CoreFoundation
import Foundation
import HidhoggDomain

public enum BluetoothReportParser {
    public static func batteries(in data: Data, pairedEndpoints: Set<BluetoothEndpoint>) throws -> [BluetoothEndpoint: BluetoothBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]], !controllers.isEmpty else {
            throw BluetoothObservationFailure.unsupportedReport
        }
        var recognized = false
        var entries: [BluetoothEndpoint: BluetoothBattery] = [:]
        var seen: Set<BluetoothEndpoint> = []
        var ambiguous: Set<BluetoothEndpoint> = []
        for controller in controllers {
            for section in ["device_connected", "device_not_connected"] {
                guard let value = controller[section] else { continue }
                guard let records = value as? [[String: Any]] else { throw BluetoothObservationFailure.unsupportedReport }
                recognized = true
                for record in records {
                    guard record.count == 1, let device = record.values.first as? [String: Any] else {
                        throw BluetoothObservationFailure.unsupportedReport
                    }
                    guard let address = device["device_address"] as? String,
                          let endpoint = BluetoothEndpoint(address: address), pairedEndpoints.contains(endpoint) else { continue }
                    if !seen.insert(endpoint).inserted { ambiguous.insert(endpoint); continue }
                    let battery = BluetoothBattery(main: percentage(device["device_batteryLevelMain"]),
                                                   left: percentage(device["device_batteryLevelLeft"]),
                                                   right: percentage(device["device_batteryLevelRight"]),
                                                   caseLevel: percentage(device["device_batteryLevelCase"]))
                    if battery.isAvailable { entries[endpoint] = battery }
                }
            }
        }
        guard recognized else { throw BluetoothObservationFailure.unsupportedReport }
        for endpoint in ambiguous { entries.removeValue(forKey: endpoint) }
        return entries
    }

    private static func percentage(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
                  (0...100).contains(number.doubleValue) else { return nil }
            return number.intValue
        }
        guard let rawString = value as? String else { return nil }
        var string = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasSuffix("%") { string.removeLast() }
        string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty, string.utf8.allSatisfy({ (48...57).contains($0) }),
              let percent = Int(string), (0...100).contains(percent) else { return nil }
        return percent
    }
}
