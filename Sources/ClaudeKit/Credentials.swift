import CoreFoundation
import Dispatch
import Foundation

public enum CredentialError: Error, Equatable {
    case notFound
    case malformed
    case expired
    /// The keychain or `security` refused the read. Distinct from a missing login.
    case readFailed
}

enum SecretFetch: Sendable {
    case value(Data)
    case missing
    case denied
}

public enum CredentialFile {
    /// Reads a Claude Code login. Accepts `claudeAiOauth.accessToken` and a
    /// bare `{ accessToken, expiresAt }` object. An `mcpOAuth`-only document
    /// is `.notFound` so the caller can try the next keychain item or the file.
    /// Does not refresh or rewrite anything.
    /// `expiresAt` is milliseconds when the number is at least 1e11, otherwise seconds.
    public static func accessToken(from data: Data, now: Date) throws -> String {
        switch classify(data, now: now) {
        case .login(let login):
            return login.token
        case .expired:
            throw CredentialError.expired
        case .notLogin:
            throw CredentialError.notFound
        case .malformed:
            throw CredentialError.malformed
        }
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

    static func classify(_ data: Data, now: Date) -> CredentialClass {
        let trimmed = data.trimmingWhitespace
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: trimmed)
        } catch {
            if let raw = rawAccessToken(trimmed) {
                return .login(ParsedLogin(token: raw, expiresAt: nil))
            }
            return .malformed
        }
        guard let root = json as? [String: Any] else { return .malformed }
        if let oauth = root["claudeAiOauth"] as? [String: Any] {
            return classifyObject(oauth, now: now)
        }
        if root["accessToken"] != nil {
            return classifyObject(root, now: now)
        }
        return .notLogin
    }

    private static func classifyObject(_ oauth: [String: Any], now: Date) -> CredentialClass {
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .malformed
        }
        let expires = expiration(oauth["expiresAt"])
        if let expires, expires <= now {
            return .expired
        }
        return .login(ParsedLogin(token: token, expiresAt: expires))
    }

    /// Some installs store the raw access token rather than the JSON document.
    private static func rawAccessToken(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("sk-ant-"),
              !raw.contains(where: \.isWhitespace),
              !raw.contains("{") else {
            return nil
        }
        return raw
    }
}

enum CredentialClass {
    case login(ParsedLogin)
    case expired
    case notLogin
    case malformed
}

struct ParsedLogin: Equatable {
    var token: String
    var expiresAt: Date?
}

enum ClaudeCredentialNames {
    static let service = "Claude Code-credentials"
    /// Claude Code's own fallback when `$USER` is not a plain account label.
    static let fallbackAccount = "claude-code-user"

    static func accountLabel(user: String?) -> String {
        guard let user, user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return fallbackAccount
        }
        return user
    }

    /// Default service, or `Claude Code-credentials-` plus the first 8 hex
    /// characters of SHA-256 over the NFC config-dir string. Claude Code hashes
    /// the raw string, not a canonicalized path.
    static func serviceName(configDirectory: String?) -> String {
        guard let configDirectory, !configDirectory.isEmpty else { return service }
        let normalized = configDirectory.precomposedStringWithCanonicalMapping
        let digest = SHA256Digest.hex(Data(normalized.utf8))
        return service + "-" + String(digest.prefix(8))
    }

    /// Directory Claude Code folds into the keychain service name.
    /// An empty `CLAUDE_SECURESTORAGE_CONFIG_DIR` pins the default store.
    static func secureConfigDirectory(environment: [String: String]) -> String? {
        if let secure = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] {
            return secure.isEmpty ? nil : secure
        }
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            return config
        }
        return nil
    }

    static func credentialFiles(home: URL, environment: [String: String]) -> [URL] {
        var urls: [URL] = []
        func append(_ url: URL) {
            let path = url.standardizedFileURL.path
            if urls.contains(where: { $0.standardizedFileURL.path == path }) { return }
            urls.append(url)
        }
        func appendDirectory(_ path: String) {
            guard !path.isEmpty else { return }
            append(URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".credentials.json"))
        }
        if let secure = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"], !secure.isEmpty {
            appendDirectory(secure)
        } else if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            appendDirectory(config)
        }
        append(home.appendingPathComponent(".claude/.credentials.json"))
        return urls
    }
}

struct KeychainItem: Sendable, Equatable {
    let account: String
    let data: Data
}

struct KeychainBatch: Sendable {
    var items: [KeychainItem]
    var denied: Bool
}

final class CredentialCache: @unchecked Sendable {
    static let shared = CredentialCache()

    private let lock = NSLock()
    private var token: String?
    private var until: Date?

    func token(now: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let token, let until, until > now else { return nil }
        return token
    }

    func store(token: String, until: Date) {
        lock.lock()
        self.token = token
        self.until = until
        lock.unlock()
    }
}

public protocol CredentialReading: Sendable {
    func accessToken(home: URL, now: Date) throws -> String
}

public struct ClaudeCredentialReader: CredentialReading {
    let security: @Sendable (String, String?) -> SecretFetch
    let keychainItems: @Sendable (String) -> KeychainBatch
    let file: @Sendable (URL) -> Data?
    let environment: [String: String]
    let user: String
    let cache: CredentialCache

    public init() {
        #if os(macOS)
        let security: @Sendable (String, String?) -> SecretFetch = SecurityPassword.lookup
        let keychainItems: @Sendable (String) -> KeychainBatch = KeychainCredentials.lookup
        #else
        let security: @Sendable (String, String?) -> SecretFetch = { _, _ in .missing }
        let keychainItems: @Sendable (String) -> KeychainBatch = { _ in KeychainBatch(items: [], denied: false) }
        #endif
        self.init(
            security: security,
            keychainItems: keychainItems,
            file: { try? Data(contentsOf: $0) },
            environment: ProcessInfo.processInfo.environment,
            user: ProcessInfo.processInfo.environment["USER"] ?? NSUserName(),
            cache: .shared
        )
    }

    init(
        security: @escaping @Sendable (String, String?) -> SecretFetch,
        keychainItems: @escaping @Sendable (String) -> KeychainBatch,
        file: @escaping @Sendable (URL) -> Data?,
        environment: [String: String],
        user: String,
        cache: CredentialCache = CredentialCache()
    ) {
        self.security = security
        self.keychainItems = keychainItems
        self.file = file
        self.environment = environment
        self.user = user
        self.cache = cache
    }

    public func accessToken(home: URL, now: Date) throws -> String {
        if let cached = cache.token(now: now) {
            return cached
        }
        let login = try resolve(home: home, now: now)
        let until = login.expiresAt ?? now.addingTimeInterval(10 * 60)
        if until > now {
            cache.store(token: login.token, until: until)
        }
        return login.token
    }

    private func resolve(home: URL, now: Date) throws -> ParsedLogin {
        let account = ClaudeCredentialNames.accountLabel(user: user)
        let service = ClaudeCredentialNames.serviceName(
            configDirectory: ClaudeCredentialNames.secureConfigDirectory(environment: environment)
        )
        var sawExpired = false
        var sawMalformed = false
        var readDenied = false

        func consider(_ data: Data) -> ParsedLogin? {
            switch CredentialFile.classify(data, now: now) {
            case .login(let login):
                return login
            case .expired:
                sawExpired = true
                return nil
            case .malformed:
                sawMalformed = true
                return nil
            case .notLogin:
                return nil
            }
        }

        switch security(service, account) {
        case .value(let data):
            if let login = consider(data) {
                return login
            }
        case .denied:
            readDenied = true
        case .missing:
            break
        }

        let batch = keychainItems(service)
        if batch.denied { readDenied = true }
        let preferred = batch.items.filter { $0.account == account }
        let others = batch.items.filter { $0.account != account }
        for item in preferred + others {
            if let login = consider(item.data) {
                return login
            }
        }

        for url in ClaudeCredentialNames.credentialFiles(home: home, environment: environment) {
            if let data = file(url), let login = consider(data) {
                return login
            }
        }

        if sawExpired { throw CredentialError.expired }
        if sawMalformed { throw CredentialError.malformed }
        if readDenied { throw CredentialError.readFailed }
        throw CredentialError.notFound
    }
}

#if os(macOS)
import Security

enum SecurityPassword {
    /// Same read Claude Code and cc-usage use. `SecItemCopyMatching` from this
    /// menu-bar process often returns interaction-not-allowed, because the
    /// item's ACL is the `security` tool, and an LSUIElement app may not show
    /// the keychain panel. `/usr/bin/security` can.
    static func lookup(service: String, account: String?) -> SecretFetch {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")
        process.arguments = arguments
        let output = SecurityOutput()
        process.standardOutput = output.pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            output.cancel()
            return .denied
        }
        // Drop the parent's write end so the reader sees EOF when `security` exits.
        try? output.pipe.fileHandleForWriting.close()
        output.begin()
        let status = output.wait(process: process, timeout: 45)
        let data = output.snapshot()
        if status == 0 {
            return data.isEmpty ? .missing : .value(data)
        }
        // `security` uses 44 when the item is not in the keychain. Any other
        // failure (cancel, interaction not allowed, timeout) is a denied read.
        if status == 44 {
            return .missing
        }
        return .denied
    }
}

/// Reads a pipe off the calling thread so a large credential blob cannot fill
/// the pipe, and so a keychain dialog can be timed out.
final class SecurityOutput: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()
    private let finished = DispatchSemaphore(value: 0)
    private var started = false

    func begin() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.readAll()
        }
    }

    private func readAll() {
        let read = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        data = read
        lock.unlock()
        finished.signal()
    }

    func cancel() {
        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
        begin()
        _ = finished.wait(timeout: .now() + 2)
    }

    func wait(process: Process, timeout: TimeInterval) -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            try? pipe.fileHandleForReading.close()
        }
        _ = finished.wait(timeout: .now() + 2)
        guard !process.isRunning else { return -1 }
        return process.terminationStatus
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum KeychainCredentials {
    /// Second try when `security` cannot see the item. Match limit all, because
    /// several items share the service `Claude Code-credentials` and the first
    /// one is often MCP state (`account` `unknown`, payload `mcpOAuth` only).
    /// The authentication UI is disabled so a menu-bar refresh cannot hang here.
    static func lookup(service: String) -> KeychainBatch {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let entries = result as? [Any] {
            var items: [KeychainItem] = []
            for entry in entries {
                guard let dict = entry as? [String: Any] else { continue }
                guard let data = dict[kSecValueData as String] as? Data else { continue }
                let account = dict[kSecAttrAccount as String] as? String ?? ""
                items.append(KeychainItem(account: account, data: data))
            }
            return KeychainBatch(items: items, denied: false)
        }
        let denied = status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecUserCanceled
        return KeychainBatch(items: [], denied: denied)
    }
}
#endif

enum SHA256Digest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ message: Data) -> String {
        var bytes = [UInt8](message)
        let bitLength = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var offset = 0
        while offset < bytes.count {
            var word = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                word[index] = (UInt32(bytes[start]) << 24)
                    | (UInt32(bytes[start + 1]) << 16)
                    | (UInt32(bytes[start + 2]) << 8)
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotate(word[index - 15], 7) ^ rotate(word[index - 15], 18) ^ (word[index - 15] >> 3)
                let s1 = rotate(word[index - 2], 17) ^ rotate(word[index - 2], 19) ^ (word[index - 2] >> 10)
                word[index] = word[index - 16] &+ s0 &+ word[index - 7] &+ s1
            }
            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choose = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choose &+ k[index] &+ word[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a
            hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c
            hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e
            hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g
            hash[7] = hash[7] &+ h
            offset += 64
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}

private extension Data {
    var trimmingWhitespace: Data {
        var slice = self[...]
        while let first = slice.first, first == 0x20 || first == 0x09 || first == 0x0a || first == 0x0d {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == 0x20 || last == 0x09 || last == 0x0a || last == 0x0d {
            slice = slice.dropLast()
        }
        return Data(slice)
    }
}
