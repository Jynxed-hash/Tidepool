import CoreFoundation
import Foundation

enum MeterJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let text = value as? String { return Double(text) }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let parsed = number.doubleValue
        return parsed.isFinite ? parsed : nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = double(value) else { return nil }
        return Int(number)
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return nil
    }

    /// google-auth-library and Claude Code both persist either milliseconds or seconds.
    /// A value at or above 1e11 is milliseconds.
    static func unixDate(_ value: Any?) -> Date? {
        guard let number = double(value) else { return nil }
        if number >= 1e11 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        return Date(timeIntervalSince1970: number)
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    static func percent(used: Double, limit: Double) -> Double? {
        guard limit > 0, used.isFinite, limit.isFinite else { return nil }
        return min(100, max(0, used / limit * 100))
    }

    static func environmentValue(_ environment: [String: String], _ name: String) -> String? {
        let trimmed = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
