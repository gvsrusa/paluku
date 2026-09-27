import Foundation
import Security

/// Generic-password items in the login keychain, service "Paluku".
public enum Keychain {
    static let service = "com.gvsrusa.Paluku"  // pre-rename name, kept so existing secrets stay readable

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Stores (or deletes when empty) a secret.
    @discardableResult
    public static func set(_ value: String?, for account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static let placeholder = "••keychain••"

    /// Moves non-empty MCP env values / auth headers into the keychain, leaving a placeholder in settings JSON.
    public static func externalize(_ servers: [MCPServerConfig]) -> [MCPServerConfig] {
        servers.map { s in
            var s = s
            for (k, v) in s.env where !v.isEmpty && v != placeholder {
                set(v, for: "mcp.\(s.id).env.\(k)")
                s.env[k] = placeholder
            }
            if let h = s.authorizationHeader, !h.isEmpty, h != placeholder {
                set(h, for: "mcp.\(s.id).auth")
                s.authorizationHeader = placeholder
            }
            return s
        }
    }

    public static func purge(_ s: MCPServerConfig) {
        for k in s.env.keys { set(nil, for: "mcp.\(s.id).env.\(k)") }
        set(nil, for: "mcp.\(s.id).auth")
    }

    /// Inverse of `externalize`: resolves placeholders for use at runtime.
    public static func resolve(_ s: MCPServerConfig) -> MCPServerConfig {
        var s = s
        for (k, v) in s.env where v == placeholder { s.env[k] = get("mcp.\(s.id).env.\(k)") ?? "" }
        if s.authorizationHeader == placeholder { s.authorizationHeader = get("mcp.\(s.id).auth") }
        return s
    }
}
