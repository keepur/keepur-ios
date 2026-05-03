import SwiftUI

/// Capsule with semantic-tinted background + matching text color. Used for
/// Connected/Idle/Active/Stale/Thinking style indicators across the app.
///
/// Background renders at 15% tint opacity; foreground uses the full tint.
struct KeepurStatusPill: View {
    enum Tint {
        case success
        case warning
        case danger
        case honey
        case muted

        var color: Color {
            switch self {
            case .success: return KeepurTheme.Color.success
            case .warning: return KeepurTheme.Color.warning
            case .danger:  return KeepurTheme.Color.danger
            case .honey:   return KeepurTheme.Color.honey500
            case .muted:   return KeepurTheme.Color.fgMuted
            }
        }
    }

    let text: String
    let tint: Tint

    init(_ text: String, tint: Tint) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(KeepurTheme.Font.caption)
            .fontWeight(.medium)
            .foregroundStyle(tint.color)
            .padding(.horizontal, KeepurTheme.Spacing.s2)
            .padding(.vertical, KeepurTheme.Spacing.s1)
            .background(tint.color.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isStaticText)
    }
}
