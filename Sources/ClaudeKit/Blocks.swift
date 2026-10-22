import Foundation

public struct UsageBlock: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var timestamps: [Date]

    public init(start: Date, end: Date, timestamps: [Date]) {
        self.start = start
        self.end = end
        self.timestamps = timestamps
    }
}

public struct BlockCalculator: Sendable {
    public var calendar: Calendar
    public var duration: TimeInterval

    public init(calendar: Calendar = .current, duration: TimeInterval = 5 * 60 * 60) {
        self.calendar = calendar
        self.duration = duration
    }

    /// A block starts at the floored hour of its first message and lasts five
    /// hours. A message at or after that end, or a gap of more than five hours
    /// since the previous message, opens a new block.
    public func blocks(from timestamps: [Date]) -> [UsageBlock] {
        let sorted = timestamps.sorted()
        guard let first = sorted.first else { return [] }
        var result: [UsageBlock] = []
        var currentStart = floorToHour(first)
        var current = UsageBlock(start: currentStart, end: currentStart.addingTimeInterval(duration), timestamps: [])
        var previous: Date?
        for timestamp in sorted {
            let gap = previous.map { timestamp.timeIntervalSince($0) } ?? 0
            if timestamp >= current.end || gap > duration {
                if !current.timestamps.isEmpty {
                    result.append(current)
                }
                currentStart = floorToHour(timestamp)
                current = UsageBlock(
                    start: currentStart,
                    end: currentStart.addingTimeInterval(duration),
                    timestamps: []
                )
            }
            current.timestamps.append(timestamp)
            previous = timestamp
        }
        if !current.timestamps.isEmpty {
            result.append(current)
        }
        return result
    }

    public func floorToHour(_ date: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: parts) ?? date
    }
}
