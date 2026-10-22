import CoreFoundation
import Foundation

public struct SavedRateWindow: Codable, Equatable, Sendable {
    public var usedPercentage: Double
    public var resetsAt: Date

    public init(usedPercentage: Double, resetsAt: Date) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }
}

public struct StatuslineSnapshot: Codable, Equatable, Sendable {
    public var fiveHour: SavedRateWindow?
    public var sevenDay: SavedRateWindow?
    public var capturedAt: Date

    public init(fiveHour: SavedRateWindow?, sevenDay: SavedRateWindow?, capturedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.capturedAt = capturedAt
    }

    public static func parse(_ data: Data, capturedAt: Date) -> StatuslineSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let limits = json["rate_limits"] as? [String: Any] else {
            return StatuslineSnapshot(fiveHour: nil, sevenDay: nil, capturedAt: capturedAt)
        }
        return StatuslineSnapshot(
            fiveHour: window(limits["five_hour"]),
            sevenDay: window(limits["seven_day"]),
            capturedAt: capturedAt
        )
    }

    public func write(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let temp = directory.appendingPathComponent(".statusline-\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temp, to: url)
    }

    public static func read(from url: URL) -> StatuslineSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StatuslineSnapshot.self, from: data)
    }

    private static func window(_ value: Any?) -> SavedRateWindow? {
        guard let object = value as? [String: Any] else { return nil }
        guard let percent = number(object["used_percentage"]) else { return nil }
        guard let resets = number(object["resets_at"]) else { return nil }
        return SavedRateWindow(usedPercentage: percent, resetsAt: Date(timeIntervalSince1970: resets))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let string = value as? String { return Double(string) }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return number.doubleValue
    }
}
