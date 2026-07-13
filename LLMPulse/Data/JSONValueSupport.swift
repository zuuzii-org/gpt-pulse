import Foundation

enum JSONValueSupport {
    static func object(from data: Data) -> [String: Any]? {
        guard
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else {
            return nil
        }
        return object
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let doubleValue = double(value), doubleValue.isFinite else { return nil }
        let rounded = doubleValue.rounded(.towardZero)
        guard rounded == doubleValue,
              rounded >= Double(Int.min),
              rounded <= Double(Int.max)
        else {
            return nil
        }
        return Int(rounded)
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let rawValue = number.doubleValue
            let seconds = rawValue > 10_000_000_000 ? rawValue / 1_000 : rawValue
            return Date(timeIntervalSince1970: seconds)
        }

        guard let string = value as? String else { return nil }
        if let numericValue = Double(string) {
            let seconds = numericValue > 10_000_000_000 ? numericValue / 1_000 : numericValue
            return Date(timeIntervalSince1970: seconds)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
