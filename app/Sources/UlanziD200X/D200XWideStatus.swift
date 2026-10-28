import Foundation

public struct D200XWideStatus: Equatable, Sendable {
    public let mode: Int
    public let cpu: Double?
    public let memory: Double?
    public let gpu: Double?
    public let time: String
    public let clockFormat: String
    public let dateWeekText: String

    public init(mode: Int, cpu: Double? = nil, memory: Double? = nil, gpu: Double? = nil,
                time: String, clockFormat: String, dateWeekText: String = "") {
        self.mode = mode
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.time = time
        self.clockFormat = clockFormat
        self.dateWeekText = dateWeekText
    }

    public func payload() throws -> Data {
        guard [0, 1, 2, 200, 201, 202, 203].contains(mode),
              ["24H", "12H"].contains(clockFormat),
              time.utf8.count == 8, time.enumerated().allSatisfy({ index, character in
                  index == 2 || index == 5 ? character == ":" : character.isASCII && character.isNumber
              }),
              let hour = Int(time.prefix(2)), hour < 24,
              let minute = Int(time.dropFirst(3).prefix(2)), minute < 60,
              let second = Int(time.suffix(2)), second < 60,
              dateWeekText.utf8.count <= 256,
              !dateWeekText.unicodeScalars.contains(where: { $0.value < 32 || $0 == "|" }),
              [cpu, memory, gpu].allSatisfy({ $0.map { $0.isFinite && (0...100).contains($0) } ?? true }),
              mode != 0 || (cpu != nil && memory != nil && gpu != nil) else { throw D200XFailure.invalidPage }
        // Nontelemetry zeroes preserve the accepted numeric wire shape; they are not readings.
        let percentage: (Double?) -> String = { $0.map { String(Int($0.rounded())) } ?? "0" }
        return Data([String(mode), percentage(cpu), percentage(memory), time, percentage(gpu), clockFormat, dateWeekText].joined(separator: "|").utf8)
    }
}
