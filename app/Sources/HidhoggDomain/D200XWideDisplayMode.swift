public enum D200XWideDisplayMode: String, Codable, CaseIterable, Sendable {
    case custom, systemStatus, clockFace, background, dateTimeWeekday, timeWeekday, timeDate, time

    public var firmwareMode: Int? {
        switch self {
        case .custom: nil
        case .systemStatus: 0
        case .clockFace: 1
        case .background: 2
        case .dateTimeWeekday: 200
        case .timeWeekday: 201
        case .timeDate: 202
        case .time: 203
        }
    }

    public var title: String {
        switch self {
        case .custom: "Custom tile"
        case .systemStatus: "CPU / RAM / GPU"
        case .clockFace: "Clock face"
        case .background: "Background"
        case .dateTimeWeekday: "Date, time and weekday"
        case .timeWeekday: "Time and weekday"
        case .timeDate: "Time and date"
        case .time: "Time only"
        }
    }
}
