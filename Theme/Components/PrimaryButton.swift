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

/// Danger-red destructive call-to-action with the same shape as
/// `KeepurPrimaryButtonStyle` but a red background. Used for irreversible
/// destructive actions where the user must consciously commit (Deny tool
/// approval, etc.). For inline destructive actions in lists, use
/// `Button(role: .destructive)` instead — that surface doesn't deserve the
/// full CTA chrome.
///
/// Apply with `.buttonStyle(KeepurDestructiveButtonStyle())`.
struct KeepurDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KeepurTheme.Font.button)
            .foregroundStyle(KeepurTheme.Color.fgOnDark)
            .frame(maxWidth: .infinity)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .background(
                KeepurTheme.Color.danger
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.md))
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}
