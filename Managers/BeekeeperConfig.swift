import Foundation

enum BeekeeperConfigError: Error {
    case hostNotConfigured
}

enum BeekeeperConfig {
    private static let hostKey = "beekeeperHost"
    private static let defaults: UserDefaults = .standard

    /// The configured Beekeeper host (e.g. "beekeeper.example.com" or "bee.example.com:8443").
    /// Always TLS-only — never contains a scheme or path.
    static var host: String? {
        get { defaults.string(forKey: hostKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: hostKey)
            } else {
                defaults.removeObject(forKey: hostKey)
            }
        }
    }

    /// `https://<host>` — throws if no host is configured.
    static func httpsURL() throws -> URL {
        guard let host else { throw BeekeeperConfigError.hostNotConfigured }
        guard let url = URL(string: "https://\(host)") else {
            throw BeekeeperConfigError.hostNotConfigured
        }
        return url
    }

    /// `wss://<host>` — throws if no host is configured.
    static func wssURL() throws -> URL {
        guard let host else { throw BeekeeperConfigError.hostNotConfigured }
        guard let url = URL(string: "wss://\(host)") else {
            throw BeekeeperConfigError.hostNotConfigured
        }
        return url
    }

    /// Validate and normalize a user-entered host string.
    /// Returns the normalized `host[:port]` on success, `nil` on failure.
    static func validate(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("://"),
              !trimmed.contains("/"),
              !trimmed.contains(" ") else { return nil }

        // Match host[:port] with an optional numeric port.
        let pattern = #"^[a-z0-9.-]+(:[0-9]{1,5})?$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }

        // If a port is present, range-check it (regex alone accepts 0/99999).
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let portString = trimmed[trimmed.index(after: colonIndex)...]
            guard let port = Int(portString), (1...65535).contains(port) else { return nil }
        }

        return trimmed
    }

    /// Force re-pair on upgrade: if a token exists but no host is configured,
    /// the legacy install pre-dates configurable hosts. Clear the token so
    /// `ContentView` drops the user into `PairingView`. Runs before any
    /// network manager is constructed, so first-launch races are impossible.
    static func migrateIfNeeded() {
        if KeychainManager.token != nil && host == nil {
            KeychainManager.clearAll()
        }
    }
}
