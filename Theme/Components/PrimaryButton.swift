import SwiftUI

/// Honey-amber primary call-to-action with the brand's signature shadow,
/// pressed-state opacity, and disabled-state opacity. Used by every primary
/// CTA across the app (pairing, settings save, tool approval, etc.).
///
/// Apply with `.buttonStyle(KeepurPrimaryButtonStyle())`.
struct KeepurPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KeepurTheme.Font.button)
            .foregroundStyle(KeepurTheme.Color.fgOnHoney)
            .frame(maxWidth: .infinity)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .background(
                KeepurTheme.Color.honey500
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
            .keepurShadow(.honey)
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}
