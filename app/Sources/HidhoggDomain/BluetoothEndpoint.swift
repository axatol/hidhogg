import Foundation

public struct BluetoothEndpoint: Hashable, Sendable, Codable {
    public let address: String

    public init?(address: String) {
        let separator: Character = address.contains(":") ? ":" : "-"
        let components = address.split(separator: separator, omittingEmptySubsequences: false)
        guard components.count == 6, components.allSatisfy({ component in
            component.utf8.count == 2 && component.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }) else { return nil }
        self.address = components.map { $0.uppercased() }.joined(separator: ":")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let endpoint = BluetoothEndpoint(address: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Bluetooth endpoint")
        }
        self = endpoint
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(address)
    }
}
