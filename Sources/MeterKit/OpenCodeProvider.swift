import Foundation
import ProviderKit

public enum OpenCodeUsage {
    /// `usage.rolling`, `usage.weekly`, and `usage.monthly`. `percent` is used percent.
    /// The payload does not name the rolling duration, so the row stays "Rolling".
    public static func windows(from data: Data) -> [UsageWindow]? {
        guard let root = MeterJSON.object(data), let usage = MeterJSON.dictionary(root["usage"]) else {
            return nil
        }
        let specs: [(String, String, String, Bool)] = [
            ("rolling", "rolling", "Rolling", true),
            ("weekly", "weekly", "Weekly", false),
            ("monthly", "monthly", "Monthly", false),
        ]
        var windows: [UsageWindow] = []
        for (key, id, title, countdown) in specs {
            guard let window = MeterJSON.dictionary(usage[key]),
                  let percent = MeterJSON.double(window["percent"]) else { continue }
            windows.append(
                UsageWindow(
                    id: id,
                    title: title,
                    usedPercent: min(100, max(0, percent)),
                    resetsAt: MeterJSON.isoDate(window["resetsAt"]),
                    origin: .server,
                    showsCountdown: countdown
                )
            )
        }
        return windows
    }
}

public struct OpenCodeProvider<HTTP: MeterHTTP>: UsageProvider {
    public var id: String { ToolCatalog.openCode }
    public var displayName: String { "OpenCode" }
    private var http: HTTP

    public init(http: HTTP) {
        self.http = http
    }

    public func refresh(_ request: ProviderRefreshRequest) async -> ProviderSnapshot {
        guard request.allowNetwork else {
            return ProviderSnapshot(providerID: id, checkedAt: request.now)
        }
        guard let token = MeterJSON.environmentValue(request.environment, "OPENCODE_API_KEY") else {
            return ProviderSnapshot(
                providerID: id,
                notice: "OpenCode Go usage needs OPENCODE_API_KEY. Tidepool does not read auth.json.",
                checkedAt: request.now
            )
        }
        let url = URL(string: "https://opencode.ai/zen/go/v1/usage")!
        switch await MeterCall.perform(MeterRequest.bearer(url, method: "GET", token: token), http: http) {
        case .ok(let body):
            guard let windows = OpenCodeUsage.windows(from: body) else {
                return ProviderSnapshot(
                    providerID: id,
                    notice: "OpenCode Go returned a response Tidepool could not read.",
                    checkedAt: request.now
                )
            }
            let notice = windows.isEmpty ? "OpenCode Go returned no usage windows." : nil
            return ProviderSnapshot(providerID: id, windows: windows, notice: notice, checkedAt: request.now)
        case .unauthorized(let status, let body):
            let text = String(data: body, encoding: .utf8) ?? ""
            if status == 403, text.contains("EntitlementError") {
                return ProviderSnapshot(
                    providerID: id,
                    notice: "This key has no OpenCode Go subscription.",
                    checkedAt: request.now
                )
            }
            return ProviderSnapshot(providerID: id, notice: "OpenCode rejected the API key.", checkedAt: request.now)
        case .limited(let retry):
            return ProviderSnapshot(
                providerID: id,
                notice: "OpenCode asked Tidepool to slow down.",
                checkedAt: request.now,
                retryAfter: retry
            )
        case .http(let status):
            return ProviderSnapshot(providerID: id, notice: "OpenCode returned HTTP \(status).", checkedAt: request.now)
        case .unreachable:
            return ProviderSnapshot(providerID: id, notice: "OpenCode could not be reached.", checkedAt: request.now)
        }
    }
}

extension OpenCodeProvider where HTTP == MeterURLSession {
    public init() {
        self.init(http: MeterURLSession())
    }
}

public typealias LiveOpenCodeProvider = OpenCodeProvider<MeterURLSession>
