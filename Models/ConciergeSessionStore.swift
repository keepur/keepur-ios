import Foundation
import Combine

/// Owns the iOS-side concierge-session cache + the picker for list_sessions
/// fallback. Cache key shape (UserDefaults): `concierge.sessionId` and
/// `concierge.path`.
@MainActor
final class ConciergeSessionStore: ObservableObject {
    private static let sessionIdKey = "concierge.sessionId"
    private static let pathKey = "concierge.path"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var cachedSession: (sessionId: String, path: String)? {
        guard let id = defaults.string(forKey: Self.sessionIdKey),
              let path = defaults.string(forKey: Self.pathKey) else { return nil }
        return (id, path)
    }

    func cache(sessionId: String, path: String) {
        defaults.set(sessionId, forKey: Self.sessionIdKey)
        defaults.set(path, forKey: Self.pathKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.sessionIdKey)
        defaults.removeObject(forKey: Self.pathKey)
    }

    /// Pick the concierge slot from a list_sessions response when the cache is
    /// empty (fresh install, app data wipe). Per spec §iOS surface tiebreaker:
    /// the per-admin map invariant should leave at most one match; if more
    /// than one comes back, pick the first and warn so we'd notice drift.
    static func pickConciergeSession(from sessions: [ServerSession]) -> ServerSession? {
        let matches = sessions.filter { $0.mode == "concierge" }
        if matches.count > 1 {
            print("[Concierge] Warning: multiple concierge slots returned by server (\(matches.count)); using first")
        }
        return matches.first
    }
}
