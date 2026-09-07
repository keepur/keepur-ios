import Foundation

extension KeepurConnectionBanner.Presentation {
    static let disconnectedText = "Not connected. Messages will send when reconnected."
    private static let warningSymbol = "arrow.triangle.2.circlepath"
    private static let dangerSymbol = "exclamationmark.triangle.fill"

    /// Pure mapping from socket state + optional error to what the banner shows; the
    /// unit under test. `nil` → render nothing. A non-nil error replaces the *text* in
    /// every state and the state's *action* is kept (spec §3 table).
    static func make(state: BeekeeperSocket.State, error: UserFacingError?) -> Self? {
        switch (state, error) {
        case (.connected, nil):
            return nil
        case (.connected, let e?):
            return Self(text: e.text, tint: .danger, symbol: dangerSymbol,
                        actionTitle: nil, accessibilityLabel: e.text, dismissesOnTap: true)
        case (.connecting, nil):
            return Self(text: "Connecting…", tint: .warning, symbol: warningSymbol,
                        actionTitle: nil, accessibilityLabel: "Connecting", dismissesOnTap: false)
        case (.connecting, let e?):
            return Self(text: e.text, tint: .danger, symbol: dangerSymbol,
                        actionTitle: nil, accessibilityLabel: e.text, dismissesOnTap: true)
        case (.reconnecting(let n), nil):
            return Self(text: "Reconnecting…", tint: .warning, symbol: warningSymbol,
                        actionTitle: "Retry now", accessibilityLabel: "Reconnecting, attempt \(n)", dismissesOnTap: false)
        case (.reconnecting(let n), let e?):
            return Self(text: e.text, tint: .danger, symbol: dangerSymbol,
                        actionTitle: "Retry now", accessibilityLabel: "\(e.text). Reconnecting, attempt \(n)", dismissesOnTap: true)
        case (.disconnected, nil):
            return Self(text: disconnectedText, tint: .danger, symbol: dangerSymbol,
                        actionTitle: "Retry", accessibilityLabel: disconnectedText, dismissesOnTap: false)
        case (.disconnected, let e?):
            return Self(text: e.text, tint: .danger, symbol: dangerSymbol,
                        actionTitle: "Retry", accessibilityLabel: "\(e.text). Not connected.", dismissesOnTap: true)
        }
    }
}
