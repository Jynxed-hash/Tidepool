import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MeterResponse: Sendable, Equatable {
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

public protocol MeterHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> MeterResponse
}

public struct MeterURLSession: MeterHTTP {
    public init() {}

    public func send(_ request: URLRequest) async throws -> MeterResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MeterTransportError.badResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                headers[name] = text
            }
        }
        return MeterResponse(status: http.statusCode, headers: headers, body: data)
    }
}

public enum MeterTransportError: Error {
    case badResponse
}

enum MeterRequest {
    static func bearer(_ url: URL, method: String, token: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tidepool/0.1", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = Double(header), seconds >= 0 else { return nil }
        return seconds
    }
}

enum MeterCall {
    case ok(Data)
    case unauthorized(Int, Data)
    case limited(TimeInterval?)
    case http(Int)
    case unreachable

    static func perform(_ request: URLRequest, http: any MeterHTTP) async -> MeterCall {
        let response: MeterResponse
        do {
            response = try await http.send(request)
        } catch {
            return .unreachable
        }
        switch response.status {
        case 200:
            return .ok(response.body)
        case 401, 403:
            return .unauthorized(response.status, response.body)
        case 429:
            return .limited(MeterRequest.retryAfter(response.header("Retry-After")))
        default:
            return .http(response.status)
        }
    }
}
