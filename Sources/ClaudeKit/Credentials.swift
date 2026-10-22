import CoreFoundation
import Foundation

public enum CredentialError: Error, Equatable {
    case notFound
    case malformed
    case expired
}

public enum CredentialFile {
    /// Reads `claudeAiOauth.accessToken`. Does not refresh or rewrite the file.
    /// `expiresAt` is milliseconds when the number is at least 1e11, otherwise seconds.
    public static func accessToken(from data: Data, now: Date) throws -> String {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CredentialError.malformed
        }
        guard let root = json as? [String: Any] else { throw CredentialError.malformed }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { throw CredentialError.notFound }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw CredentialError.malformed
        }
        if let expires = expiration(oauth["expiresAt"]), expires <= now {
            throw CredentialError.expired
        }
        return token
    }

    public static func expiration(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let raw = number.doubleValue
        guard raw > 0 else { return nil }
        if raw >= 100_000_000_000 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }
}

public protocol CredentialReading: Sendable {
    func accessToken(home: URL, now: Date) throws -> String
}

public struct ClaudeCredentialReader: CredentialReading {
    public init() {}

    public func accessToken(home: URL, now: Date) throws -> String {
        #if os(macOS)
        if let token = try? KeychainCredentials.accessToken(now: now) {
            return token
        }
        #endif
        let url = home.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { throw CredentialError.notFound }
        return try CredentialFile.accessToken(from: data, now: now)
    }
}

#if os(macOS)
import Security

enum KeychainCredentials {
    /// Community-documented item Claude Code writes. Read-only.
    static let service = "Claude Code-credentials"

    static func accessToken(now: Date) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialError.notFound
        }
        if let token = try? CredentialFile.accessToken(from: data, now: now) {
            return token
        }
        // Some installs store the raw access token rather than the JSON document.
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           raw.hasPrefix("sk-ant-") {
            return raw
        }
        throw CredentialError.malformed
    }
}
#endif
