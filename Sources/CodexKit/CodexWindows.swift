import Foundation
import ProviderKit

enum CodexWindows {
    /// App-server uses `usedPercent` / `windowDurationMins` / `resetsAt`.
    /// Session files use the Codex `RateLimitWindow` names `used_percent` / `window_minutes` / `resets_at`.
    static func windows(from snapshot: [String: Any], origin: DataOrigin) -> [UsageWindow] {
        let bucket = preferredBucket(snapshot)
        var windows: [UsageWindow] = []
        if let primary = CodexJSON.dictionary(bucket["primary"] ?? snapshot["primary"]) {
            append(primary, into: &windows, origin: origin)
        }
        if let secondary = CodexJSON.dictionary(bucket["secondary"] ?? snapshot["secondary"]) {
            append(secondary, into: &windows, origin: origin)
        }
        return windows
    }

    static func windows(fromAppServerResult result: [String: Any]) -> [UsageWindow] {
        windows(from: result, origin: .server)
    }

    private static func preferredBucket(_ snapshot: [String: Any]) -> [String: Any] {
        let byID = CodexJSON.dictionary(snapshot["rateLimitsByLimitId"])
            ?? CodexJSON.dictionary(snapshot["rate_limits_by_limit_id"])
        if let codex = byID.flatMap({ CodexJSON.dictionary($0["codex"]) }) {
            return codex
        }
        if let rateLimits = CodexJSON.dictionary(snapshot["rateLimits"])
            ?? CodexJSON.dictionary(snapshot["rate_limits"]) {
            return rateLimits
        }
        return snapshot
    }

    private static func append(_ window: [String: Any], into windows: inout [UsageWindow], origin: DataOrigin) {
        guard let used = CodexJSON.double(window["usedPercent"] ?? window["used_percent"]) else { return }
        let minutes = CodexJSON.int(window["windowDurationMins"] ?? window["window_minutes"])
        let resets = CodexJSON.date(window["resetsAt"] ?? window["resets_at"])
        let named = name(minutes: minutes, taken: Set(windows.map(\.id)))
        windows.append(UsageWindow(
            id: named.id,
            title: named.title,
            usedPercent: used,
            resetsAt: resets,
            origin: origin,
            showsCountdown: named.countdown
        ))
    }

    static func name(minutes: Int?, taken: Set<String>) -> (id: String, title: String, countdown: Bool) {
        let title: String
        let id: String
        let countdown: Bool
        switch minutes {
        case 300:
            title = "5-hour session"
            id = "five_hour"
            countdown = true
        case 10_080:
            title = "Weekly"
            id = "weekly"
            countdown = false
        case let minutes?:
            if minutes > 0, minutes % (24 * 60) == 0 {
                let days = minutes / (24 * 60)
                title = days == 7 ? "Weekly" : "\(days)-day"
                id = days == 7 ? "weekly" : "window-\(minutes)"
                countdown = false
            } else if minutes > 0, minutes % 60 == 0 {
                let hours = minutes / 60
                title = hours == 1 ? "1-hour" : "\(hours)-hour"
                id = "window-\(minutes)"
                countdown = hours < 24
            } else if minutes > 0 {
                title = "\(minutes) min"
                id = "window-\(minutes)"
                countdown = true
            } else {
                title = "Usage"
                id = "usage"
                countdown = false
            }
        case nil:
            title = "Usage"
            id = "usage"
            countdown = false
        }
        if taken.contains(id) {
            return ("\(id)-2", title, countdown)
        }
        return (id, title, countdown)
    }
}
