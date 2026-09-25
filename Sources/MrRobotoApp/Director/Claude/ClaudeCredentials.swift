import Foundation
import Security

/// An API key, wrapped so it cannot be printed by accident.
///
/// The value is reachable only through `secret`, which is used in exactly one place — the request
/// header. Everything else in the app that touches this type gets `sk-ant-…` and a length.
public struct ClaudeAPIKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    public init(_ value: String) { self.value = value.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The only accessor. Callers are the header builder and nothing else.
    public var secret: String { value }

    public var isEmpty: Bool { value.isEmpty }

    /// What logging, interpolation and the debugger all see.
    public var description: String { redacted }
    public var debugDescription: String { redacted }

    private var redacted: String {
        let prefix = value.prefix(7)
        return value.isEmpty ? "(no key)" : "\(prefix)…(\(value.count) chars, redacted)"
    }
}

/// Where a key can come from. A test injects one rather than reading the developer's keychain.
public protocol ClaudeKeySource: Sendable {
    /// The key, or nil when there is none. Never throws: "no key" is an answer, not a failure.
    func apiKey() -> ClaudeAPIKey?
    /// Whether a key is there, without reading it. The launch check asks this: reading a keychain
    /// item's secret is what makes macOS ask for a password, and looking at whether it exists is not.
    func hasKey() -> Bool
}

public extension ClaudeKeySource {
    func hasKey() -> Bool { apiKey().map { !$0.isEmpty } ?? false }
}

/// A fixed key. Tests and previews.
public struct ClaudeFixedKey: ClaudeKeySource {
    private let key: ClaudeAPIKey?
    public init(_ key: ClaudeAPIKey?) { self.key = key }
    public init(_ value: String) { self.key = ClaudeAPIKey(value) }
    public func apiKey() -> ClaudeAPIKey? { key }
    /// The state the app has to survive: no key anywhere.
    public static let none = ClaudeFixedKey(nil as ClaudeAPIKey?)
}

/// The real lookup: the environment first, then the user's keychain.
///
/// The environment comes first because that is how a developer runs the app from a shell without
/// touching their login keychain; the keychain is where the shipped app keeps it. Neither is
/// created here — the app never writes a key it was not given.
public struct ClaudeCredentials: ClaudeKeySource {
    public static let environmentVariable = "ANTHROPIC_API_KEY"
    public static let keychainService = "com.mrroboto.anthropic"
    public static let keychainAccount = "api-key"

    private let environment: [String: String]
    private let keychain: any ClaudeKeychain

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                keychain: any ClaudeKeychain = SystemKeychain()) {
        self.environment = environment
        self.keychain = keychain
    }

    public func apiKey() -> ClaudeAPIKey? {
        if let value = environment[Self.environmentVariable], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ClaudeAPIKey(value)
        }
        guard let stored = keychain.password(service: Self.keychainService, account: Self.keychainAccount),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ClaudeAPIKey(stored)
    }

    /// Where a present key came from. The settings panel says this; it never shows the key.
    public enum Origin: String, Sendable, Equatable {
        case environment, keychain, absent
    }

    /// Where a key would come from, by looking and not reading: no keychain prompt.
    public var origin: Origin {
        if let value = environment[Self.environmentVariable], !value.isEmpty { return .environment }
        if keychain.exists(service: Self.keychainService, account: Self.keychainAccount) { return .keychain }
        return .absent
    }

    public func hasKey() -> Bool { origin != .absent }

    /// Keeps a key the user typed, in the keychain. The one place the app writes a key, and it
    /// writes what it was given: until this the only ways in were an environment variable and a
    /// keychain item made by hand, neither of which a person finds from inside the app.
    ///
    /// Rejects an empty key and one that does not look like one, so a pasted sentence cannot
    /// become the credential. Returns what went wrong, or nil.
    public func store(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The key is empty." }
        guard Self.looksLikeKey(trimmed) else { return "That does not look like an API key: they start with sk-ant- and have no spaces." }
        do {
            try keychain.store(password: trimmed, service: Self.keychainService, account: Self.keychainAccount)
        } catch {
            return "The keychain would not keep it: \(error)"
        }
        return nil
    }

    /// Takes the keychain's key out. The environment's, if any, is not the app's to remove.
    public func forget() -> String? {
        do {
            try keychain.remove(service: Self.keychainService, account: Self.keychainAccount)
        } catch {
            return "The keychain would not let it go: \(error)"
        }
        return nil
    }

    /// `sk-ant-…`, one token, long enough to be one. Anthropic's keys start so; a prefix check is
    /// what keeps a stray paste out, not a guarantee the key is live.
    public static func looksLikeKey(_ text: String) -> Bool {
        text.hasPrefix("sk-ant-") && text.count >= 20 && !text.contains { $0.isWhitespace }
    }
}

/// The keychain, behind a door, so a test never touches the login keychain.
public protocol ClaudeKeychain: Sendable {
    func password(service: String, account: String) -> String?
    /// Whether the item is there. Must not read the secret.
    func exists(service: String, account: String) -> Bool
    /// Keeps a secret, replacing one already there.
    func store(password: String, service: String, account: String) throws
    /// Removes the item. Removing one that is not there is not an error.
    func remove(service: String, account: String) throws
}

public extension ClaudeKeychain {
    func exists(service: String, account: String) -> Bool { password(service: service, account: account) != nil }
    /// A keychain that only reads — a test double counting lookups — refuses to write, in the
    /// keychain's own words, rather than pretending it kept something.
    func store(password: String, service: String, account: String) throws { throw KeychainFailure(status: errSecUnimplemented) }
    func remove(service: String, account: String) throws { throw KeychainFailure(status: errSecUnimplemented) }
}

/// What the keychain said when it would not do something.
public struct KeychainFailure: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

/// The real one.
public struct SystemKeychain: ClaudeKeychain {
    public init() {}

    public func store(password: String, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainFailure(status: updated) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Mr. Roboto — Anthropic API key"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainFailure(status: added) }
    }

    public func remove(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }

    public func password(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Attributes only. The access list guards the secret, not the item's existence, so this
    /// never puts the password dialog up.
    public func exists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }
}

/// An in-memory keychain for tests. A class, so a test can store through one handle and read
/// back through another that shares it — which is what the app does with the real one.
public final class ClaudeMemoryKeychain: ClaudeKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String]

    public init(_ entries: [String: String] = [:]) { self.entries = entries }

    public func password(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries["\(service)/\(account)"]
    }

    public func store(password: String, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        entries["\(service)/\(account)"] = password
    }

    public func remove(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        entries["\(service)/\(account)"] = nil
    }
}
