import SwiftUI

extension Color {
    /// Replaces Color(.systemGray5) — light neutral fill
    static var secondarySystemFill: Color {
        #if os(iOS)
        Color(UIColor.systemGray5)
        #else
        Color(NSColor.quaternarySystemFill)
        #endif
    }

    /// Replaces Color(.systemGray6) — very light neutral fill
    static var tertiarySystemFill: Color {
        #if os(iOS)
        Color(UIColor.systemGray6)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }

    /// Replaces Color(.tertiarySystemBackground)
    static var tertiaryBackground: Color {
        #if os(iOS)
        Color(UIColor.tertiarySystemBackground)
        #else
        Color(NSColor.textBackgroundColor)
        #endif
    }
}
