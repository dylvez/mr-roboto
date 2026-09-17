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

    public var origin: Origin {
        if let value = environment[Self.environmentVariable], !value.isEmpty { return .environment }
        if keychain.password(service: Self.keychainService, account: Self.keychainAccount) != nil { return .keychain }
        return .absent
    }
}

/// The keychain, behind a door, so a test never touches the login keychain.
public protocol ClaudeKeychain: Sendable {
    func password(service: String, account: String) -> String?
}

/// The real one.
public struct SystemKeychain: ClaudeKeychain {
    public init() {}

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
}

/// An in-memory keychain for tests.
public struct ClaudeMemoryKeychain: ClaudeKeychain {
    private let entries: [String: String]
    public init(_ entries: [String: String] = [:]) { self.entries = entries }
    public func password(service: String, account: String) -> String? { entries["\(service)/\(account)"] }
}
