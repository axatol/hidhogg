import Foundation
import HidhoggDomain
import UlanziD200X

enum D200XDisplayStatus {
    static func make(mode: Int, format: D200XClockFormat, date: Date,
                     metrics: D200XMetricsSnapshot, timeZone: TimeZone = .current) -> D200XWideStatus {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: date)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "EEEE"
        let weekday = formatter.string(from: date)
        let text: String
        switch mode {
        case 200: text = "\(day) \(weekday)"
        case 201: text = weekday
        case 202: text = day
        default: text = ""
        }
        let values = mode == 0 ? metrics : D200XMetricsSnapshot()
        return D200XWideStatus(mode: mode, cpu: values.cpu, memory: values.memory, gpu: values.gpu,
                               time: time, clockFormat: format.rawValue, dateWeekText: text)
    }
}
