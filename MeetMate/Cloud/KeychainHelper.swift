import Foundation
import Security

/// Simple Keychain CRUD for storing API keys and secrets.
/// Uses `kSecClassGenericPassword` with a service prefix for namespacing.
enum KeychainHelper {
    private static let servicePrefix = "dev.mingz.MeetMate"

    /// Store or update a value in the Keychain.
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let service = "\(servicePrefix).\(key)"
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first (update = delete + add)
        delete(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Keychain] set failed for \(key): \(status)")
        }
        return status == errSecSuccess
    }

    /// Retrieve a value from the Keychain.
    static func get(forKey key: String) -> String? {
        let service = "\(servicePrefix).\(key)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from the Keychain.
    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let service = "\(servicePrefix).\(key)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a key exists without retrieving the value.
    static func exists(forKey key: String) -> Bool {
        get(forKey: key) != nil
    }
}

// MARK: - Well-known keys for Azure configuration

extension KeychainHelper {
    // Azure OpenAI
    static let azureEndpointKey = "azure-openai-endpoint"
    static let azureAPIKeyKey = "azure-openai-api-key"
    static let azureDeploymentKey = "azure-openai-deployment"
    static let azureDeploymentMiniKey = "azure-openai-deployment-mini"  // Lighter model for polish/cheatsheet

    // Azure Speech (shares region with OpenAI when same resource)
    static let azureSpeechKeyKey = "azure-speech-api-key"
    static let azureSpeechRegionKey = "azure-speech-region"
}
