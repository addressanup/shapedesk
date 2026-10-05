import Foundation
import Security
import ShapeDeskSorting

/// Per-user credentials belong in Keychain, never in the app bundle or defaults.
struct ProCredentialsStore: Sendable {
    private let service = (Bundle.main.bundleIdentifier ?? "com.shapedesk.app") + ".pro"
    private let account: String
    init(account: String = "license") { self.account = account }

    func load() throws -> ProCredentials? {
        try loadValue(ProCredentials.self)
    }

    func loadPurchase() throws -> ProPurchase? { try loadValue(ProPurchase.self) }

    private func loadValue<T: Decodable>(_ type: T.Type) throws -> T? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(T.self, from: Data(key.utf8))
    }

    func save(_ credentials: ProCredentials) throws {
        try saveValue(credentials)
    }

    func savePurchase(_ purchase: ProPurchase) throws { try saveValue(purchase) }

    private func saveValue<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Could not access your ShapeDesk Pro license in Keychain (\(status))."
        }
    }
}
