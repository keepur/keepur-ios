import SwiftUI

/// Square rounded container with a letter or emoji content and an optional
/// semantic status overlay in the bottom-right corner. Sizes scale internal
/// content (letter/emoji glyph and overlay diameter) proportionally.
struct KeepurAvatar: View {
    enum Content {
        case letter(String)
        case emoji(String)
    }

    let size: CGFloat
    let content: Content
    let statusOverlay: KeepurStatusPill.Tint?
    let background: Color

    init(
        size: CGFloat = 56,
        content: Content,
        statusOverlay: KeepurStatusPill.Tint? = nil,
        background: Color = KeepurTheme.Color.wax100
    ) {
        self.size = size
        self.content = content
        self.statusOverlay = statusOverlay
        self.background = background
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)
                .fill(background)
                .frame(width: size, height: size)
                .overlay(glyph)

            if let statusOverlay {
                Circle()
                    .fill(statusOverlay.color)
                    .frame(width: overlayDiameter, height: overlayDiameter)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .padding(size * 0.05)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var glyph: some View {
        switch content {
        case .letter(let raw):
            Text(letterCharacter(from: raw))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(KeepurTheme.Color.fgPrimary)
        case .emoji(let raw):
            Text(firstCharacter(of: raw))
                .font(.system(size: size * 0.6))
        }
    }

    private var overlayDiameter: CGFloat {
        max(8, size * 0.16)
    }

    private var accessibilityLabel: String {
        switch content {
        case .letter(let raw):
            return raw.isEmpty ? "Avatar" : "Avatar \(letterCharacter(from: raw))"
        case .emoji:
            return "Avatar"
        }
    }

    private func letterCharacter(from raw: String) -> String {
        guard let first = raw.first else { return "?" }
        return String(first).uppercased()
    }

    private func firstCharacter(of raw: String) -> String {
        guard let first = raw.first else { return "" }
        return String(first)
    }
}
