import Foundation
import Security
import LocalAuthentication
import CryptoKit
import MeetingCore

/// Credentials are bound to the normalized endpoint, never copied into meetings or version snapshots.
public enum ModelAPIKeychain {
    static func account(for endpoint: String) throws -> String {
        let url = try ResponsesEndpoint.url(endpoint).absoluteString
        return SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func query(_ endpoint: String) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.meetingrecord.responses",
         kSecAttrAccount as String: try account(for: endpoint)]
    }
    public static func isConfigured(endpoint: String) throws -> Bool {
        var lookup = try query(endpoint)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext(); context.interactionNotAllowed = true
        lookup[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(lookup as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw ModelProviderError.keychain(status) }
        return true
    }
    public static func read(endpoint: String) throws -> String? {
        var lookup = try query(endpoint)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ModelProviderError.keychain(status)
        }
        return key
    }
    static func validatedKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4096, !key.contains(where: \.isWhitespace),
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw ModelProviderError.invalidKey }
        return key
    }
    public static func save(_ value: String, endpoint: String) throws {
        let key = try validatedKey(value)
        let query = try query(endpoint)
        let changes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query.merging(changes) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ModelProviderError.keychain(status) }
    }
    public static func delete(endpoint: String) throws {
        let status = SecItemDelete(try query(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ModelProviderError.keychain(status) }
    }
}
