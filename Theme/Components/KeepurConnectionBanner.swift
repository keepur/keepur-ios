import SwiftUI

/// Thin connection strip above a message list: connecting / reconnecting /
/// not-connected / error. Renders nothing for a `nil` presentation; the container's
/// `.animation(.default, value:)` covers appear/disappear. Not color-only — the
/// symbol and copy carry the state. The state → `Presentation` mapping lives in
/// `Views/ConnectionBannerPresentation.swift`, so this file stays token-only.
struct KeepurConnectionBanner: View {
    struct Presentation: Equatable {
        enum Tint: Equatable { case warning, danger }

        let text: String
        let tint: Tint
        let symbol: String                 // "arrow.triangle.2.circlepath" (warning) / "exclamationmark.triangle.fill" (danger)
        let actionTitle: String?           // "Retry now" / "Retry" / nil
        let accessibilityLabel: String
        let dismissesOnTap: Bool           // true iff an error is showing
    }

    let presentation: Presentation?        // nil → renders nothing
    let onRetry: () -> Void
    let onDismissError: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let presentation {
                strip(presentation)
            }
        }
        .animation(.default, value: presentation)
    }

    private func strip(_ p: Presentation) -> some View {
        HStack(spacing: KeepurTheme.Spacing.s2) {
            HStack(spacing: KeepurTheme.Spacing.s2) {
                Image(systemName: p.symbol)
                    .foregroundStyle(tintColor(p.tint))
                Text(p.text)
                    .font(KeepurTheme.Font.bodySm)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            // Tap-to-dismiss on the text region only while an error is showing; the action
            // button stays a separate accessibility element. The accessibility modifiers
            // run consecutively: a non-accessibility ViewModifier interposed between
            // `.accessibilityElement(children: .ignore)` and the trait/hint would leave
            // the trait/hint on an inner element the `.ignore` then discards.
            .contentShape(Rectangle())
            .onTapGesture { if p.dismissesOnTap { onDismissError() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(p.accessibilityLabel)
            .accessibilityAddTraits(p.dismissesOnTap ? .isButton : [])
            .accessibilityHint(p.dismissesOnTap ? "Dismiss" : "")

            if let title = p.actionTitle {
                Button(action: onRetry) {
                    Text(title)
                        .font(KeepurTheme.Font.bodySm)
                        .fontWeight(.bold)
                        .foregroundStyle(KeepurTheme.Color.honey700)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(KeepurTheme.Spacing.s3)
        .frame(maxWidth: .infinity)
        .background(KeepurTheme.Color.bgSunkenDynamic)
    }

    private func tintColor(_ tint: Presentation.Tint) -> Color {
        switch tint {
        case .warning: return KeepurTheme.Color.warning
        case .danger:  return KeepurTheme.Color.danger
        }
    }
}
