import os

/// One `Logger` per subsystem area. Never log a URL, a token, or a frame body:
/// the socket logs frame *types* only, at debug level.
enum Log {
    private static let subsystem = "io.keepur"

    static let socket       = Logger(subsystem: subsystem, category: "socket")
    static let chat         = Logger(subsystem: subsystem, category: "chat")
    static let team         = Logger(subsystem: subsystem, category: "team")
    static let capabilities = Logger(subsystem: subsystem, category: "capabilities")
    static let persistence  = Logger(subsystem: subsystem, category: "persistence")

    /// `Logger` has no `isEnabled` accessor, so this parallel `OSLog` (same
    /// subsystem/category, sharing the OS's enablement state for that pair) backs the
    /// gate around debug-only work that isn't cheap enough to run unconditionally
    /// (e.g. parsing a multi-MB frame just to log its `type`).
    static let socketRaw = OSLog(subsystem: subsystem, category: "socket")
}
