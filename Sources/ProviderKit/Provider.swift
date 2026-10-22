import Foundation

/// Where a number came from. Estimates are labeled in the UI. Server and
/// status-line values are Claude Code's own rate-limit figures.
public enum DataOrigin: String, Sendable, Equatable, Codable {
    case server
    case statusline
    case hook
    case estimate
}

public struct UsageWindow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var origin: DataOrigin
    /// Weekly rows use a weekday. The 5-hour row also shows a countdown.
    public var showsCountdown: Bool

    public init(
        id: String,
        title: String,
        usedPercent: Double,
        resetsAt: Date?,
        origin: DataOrigin,
        showsCountdown: Bool
    ) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.origin = origin
        self.showsCountdown = showsCountdown
    }

    public var isNearLimit: Bool { usedPercent >= 75 }
    public var isAtLimit: Bool { usedPercent >= 90 }
}

public enum SessionActivity: String, Sendable, Equatable, Codable {
    case needsYou
    case working
    case idle
}

public struct TrackedSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var repo: String
    public var branch: String?
    public var cwd: String?
    public var activity: SessionActivity
    public var toolName: String?
    /// Short command, path, or notification text. Never a prompt body.
    public var waitingDetail: String?
    public var idleSince: Date?
    public var updatedAt: Date
    public var origin: DataOrigin

    public init(
        id: String,
        repo: String,
        branch: String? = nil,
        cwd: String? = nil,
        activity: SessionActivity,
        toolName: String? = nil,
        waitingDetail: String? = nil,
        idleSince: Date? = nil,
        updatedAt: Date,
        origin: DataOrigin
    ) {
        self.id = id
        self.repo = repo
        self.branch = branch
        self.cwd = cwd
        self.activity = activity
        self.toolName = toolName
        self.waitingDetail = waitingDetail
        self.idleSince = idleSince
        self.updatedAt = updatedAt
        self.origin = origin
    }
}

public struct UsageEstimate: Sendable, Equatable {
    public var tokens: Int
    public var costUSD: Decimal?
    /// True when at least one entry used a model with no list price.
    public var costIncomplete: Bool
    /// Tokens per hour inside the current estimated 5-hour block.
    public var blockTokensPerHour: Double?
    public var origin: DataOrigin

    public init(
        tokens: Int = 0,
        costUSD: Decimal? = nil,
        costIncomplete: Bool = false,
        blockTokensPerHour: Double? = nil,
        origin: DataOrigin = .estimate
    ) {
        self.tokens = tokens
        self.costUSD = costUSD
        self.costIncomplete = costIncomplete
        self.blockTokensPerHour = blockTokensPerHour
        self.origin = origin
    }

    public static let empty = UsageEstimate()
}

public struct ProviderSnapshot: Sendable, Equatable {
    public var providerID: String
    public var windows: [UsageWindow]
    public var sessions: [TrackedSession]
    public var today: UsageEstimate
    /// One quiet line when the refresh could not reach the usual source.
    public var notice: String?
    public var checkedAt: Date
    /// Set when the usage service asked us to slow down.
    public var retryAfter: TimeInterval?

    public init(
        providerID: String,
        windows: [UsageWindow] = [],
        sessions: [TrackedSession] = [],
        today: UsageEstimate = .empty,
        notice: String? = nil,
        checkedAt: Date,
        retryAfter: TimeInterval? = nil
    ) {
        self.providerID = providerID
        self.windows = windows
        self.sessions = sessions
        self.today = today
        self.notice = notice
        self.checkedAt = checkedAt
        self.retryAfter = retryAfter
    }

    public var needsAttention: Bool {
        sessions.contains { $0.activity == .needsYou }
    }

    public var fiveHour: UsageWindow? {
        windows.first { $0.id == "five_hour" }
    }
}

/// Implemented providers fill this in. Coming-soon tools do not.
public protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot
}

public struct ProviderRefreshRequest: Sendable {
    public var now: Date
    public var home: URL
    public var supportDirectory: URL
    /// When false, the provider skips the network and uses the status line or local files.
    public var allowNetwork: Bool

    public init(now: Date, home: URL, supportDirectory: URL, allowNetwork: Bool = true) {
        self.now = now
        self.home = home
        self.supportDirectory = supportDirectory
        self.allowNetwork = allowNetwork
    }
}

public enum ResetCopy {
    public static func countdown(_ resetsAt: Date, now: Date) -> String {
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        if seconds == 0 { return "Reset due" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        }
        return "Resets in \(minutes)m"
    }

    public static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        if formatter.string(from: date).isEmpty {
            formatter.dateFormat = "h:mm a"
        }
        return formatter.string(from: date)
    }

    public static func weekdayTime(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        if formatter.string(from: date).isEmpty {
            formatter.dateFormat = "EEE h:mm a"
        }
        return formatter.string(from: date)
    }

    public static func fiveHourLine(_ resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        "\(countdown(resetsAt, now: now)) · \(clockTime(resetsAt, calendar: calendar))"
    }

    public static func weeklyLine(_ resetsAt: Date, calendar: Calendar = .current) -> String {
        "Resets \(weekdayTime(resetsAt, calendar: calendar))"
    }
}

public enum TokenFormat {
    public static func compact(_ tokens: Int) -> String {
        let value = Double(tokens)
        if tokens >= 1_000_000 {
            let scaled = value / 1_000_000
            return scaled >= 10 ? String(format: "%.0fM", scaled) : String(format: "%.1fM", scaled)
        }
        if tokens >= 1_000 {
            let scaled = value / 1_000
            return scaled >= 10 ? String(format: "%.0fk", scaled) : String(format: "%.1fk", scaled)
        }
        return "\(tokens)"
    }

    public static func dollars(_ amount: Decimal) -> String {
        let number = NSDecimalNumber(decimal: amount)
        return String(format: "$%.2f", number.doubleValue)
    }

    public static func todayLine(_ estimate: UsageEstimate) -> String {
        let tokens = "Today ≈ \(compact(estimate.tokens)) tokens"
        if estimate.costIncomplete {
            return "\(tokens) · cost incomplete"
        }
        if let cost = estimate.costUSD {
            return "\(tokens) · ≈ \(dollars(cost))"
        }
        return tokens
    }
}

public enum IdleFormat {
    public static func label(since: Date?, now: Date) -> String {
        guard let since else { return "Idle" }
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes < 1 { return "Idle" }
        if minutes < 60 { return "Idle · \(minutes)m" }
        return "Idle · \(minutes / 60)h"
    }
}
