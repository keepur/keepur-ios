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

    /// Enablement probe only — never used to emit log lines itself. `Logger` (this
    /// SDK's version) has no `isEnabled` accessor, so this parallel `OSLog` (same
    /// subsystem/category, sharing the OS's enablement state for that pair) exists
    /// solely to answer `isEnabled(type:)` and gate debug-only work that isn't cheap
    /// enough to run unconditionally (e.g. parsing a multi-MB frame just to log its
    /// `type`).
    static let socketEnablement = OSLog(subsystem: subsystem, category: "socket")
}
