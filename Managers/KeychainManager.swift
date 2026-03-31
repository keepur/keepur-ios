import Foundation
import Security

enum KeychainManager {
    private static let service = "io.keepur.beekeeper"
    private static let tokenKey = "auth_token"
    private static let deviceIdKey = "device_id"
    private static let deviceNameKey = "device_name"

    static var token: String? {
        get { read(key: tokenKey) }
        set {
            if let newValue {
                save(key: tokenKey, value: newValue)
            } else {
                delete(key: tokenKey)
            }
        }
    }

    static var deviceId: String? {
        get { read(key: deviceIdKey) }
        set {
            if let newValue {
                save(key: deviceIdKey, value: newValue)
            } else {
                delete(key: deviceIdKey)
            }
        }
    }

    static var deviceName: String? {
        get { read(key: deviceNameKey) }
        set {
            if let newValue {
                save(key: deviceNameKey, value: newValue)
            } else {
                delete(key: deviceNameKey)
            }
        }
    }

    static var isPaired: Bool { token != nil }

    static var tokenExpiryDate: Date? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func clearAll() {
        token = nil
        deviceId = nil
        deviceName = nil
    }

    // MARK: - Private

    private static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
