import CoreFoundation
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ProviderKit

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

public protocol HTTPSending: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTP: HTTPSending {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.badResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                headers[name] = text
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

public enum UsageClientError: Error, Equatable {
    case badResponse
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
}

public struct OAuthUsage: Sendable, Equatable {
    public struct Bucket: Sendable, Equatable {
        public var utilization: Double
        public var resetsAt: Date?
    }

    public struct Extra: Sendable, Equatable {
        public var isEnabled: Bool
        public var utilization: Double?
    }

    public var fiveHour: Bucket?
    public var sevenDay: Bucket?
    public var sevenDayOpus: Bucket?
    public var sevenDaySonnet: Bucket?
    public var extra: Extra?

    public static func request(token: String) -> URLRequest {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tidepool/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func parse(_ data: Data) throws -> OAuthUsage {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else { throw UsageClientError.badResponse }
        return OAuthUsage(
            fiveHour: bucket(object["five_hour"]),
            sevenDay: bucket(object["seven_day"]),
            sevenDayOpus: bucket(object["seven_day_opus"]),
            sevenDaySonnet: bucket(object["seven_day_sonnet"]),
            extra: extra(object["extra_usage"])
        )
    }

    public static func fetch(token: String, http: any HTTPSending) async throws -> OAuthUsage {
        let response = try await http.send(request(token: token))
        switch response.status {
        case 200:
            return try parse(response.body)
        case 401, 403:
            throw UsageClientError.unauthorized
        case 429:
            throw UsageClientError.rateLimited(retryAfter: retryAfter(response.header("Retry-After")))
        default:
            throw UsageClientError.http(response.status)
        }
    }

    private static func bucket(_ value: Any?) -> Bucket? {
        guard let object = value as? [String: Any] else { return nil }
        guard let utilization = JSONNumbers.double(object["utilization"]) else { return nil }
        return Bucket(utilization: utilization, resetsAt: JSONDates.parse(object["resets_at"]))
    }

    private static func extra(_ value: Any?) -> Extra? {
        guard let object = value as? [String: Any] else { return nil }
        let enabled = JSONNumbers.bool(object["is_enabled"]) ?? false
        return Extra(isEnabled: enabled, utilization: JSONNumbers.double(object["utilization"]))
    }

    private static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = Double(header) else { return nil }
        return seconds
    }
}

enum JSONNumbers {
    static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let string = value as? String { return Double(string) }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        return number.doubleValue
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let bool = value as? Bool { return bool }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = double(value) else { return nil }
        return Int(number)
    }
}

enum JSONDates {
    static func parse(_ value: Any?) -> Date? {
        if let number = JSONNumbers.double(value) {
            return Date(timeIntervalSince1970: number)
        }
        guard let text = value as? String else { return nil }
        return parseISO(text)
    }

    static func parseISO(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
