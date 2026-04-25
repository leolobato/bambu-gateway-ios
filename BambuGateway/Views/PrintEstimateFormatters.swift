import Foundation

enum PrintEstimateFormatters {
    static func formatLength(millimeters: Double?, locale: Locale = .current) -> String? {
        guard let millimeters else { return nil }
        let measurement = Measurement(value: millimeters, unit: UnitLength.millimeters)
            .converted(to: .meters)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let number = formatter.string(from: NSNumber(value: measurement.value)) else { return nil }
        return "\(number) m"
    }

    static func formatMass(grams: Double?, locale: Locale = .current) -> String? {
        guard let grams else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let number = formatter.string(from: NSNumber(value: grams)) else { return nil }
        return "\(number) g"
    }

    static func formatDuration(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        if seconds == 0 { return "0s" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }
        return "\(secs)s"
    }
}
