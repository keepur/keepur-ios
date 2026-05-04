import SwiftUI

/// Toolbar header pieces for chat-style screens: a circular back button, a
/// centered title with optional status line ("● working · 2m ago"), and a
/// row of trailing circular action buttons.
///
/// On iOS, place the three pieces in their native toolbar slots so each can
/// occupy its full alignment region:
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .topBarLeading)  { KeepurChatHeader.BackButton(onBack: { dismiss() }) }
///     ToolbarItem(placement: .principal)      { KeepurChatHeader.TitleBlock(title: "hive-dodi", statusText: "working", statusDate: lastActivity, isStatusActive: true) }
///     ToolbarItem(placement: .topBarTrailing) { KeepurChatHeader.TrailingStack(actions: [...]) }
/// }
/// .navigationBarBackButtonHidden(true)
/// ```
///
/// On macOS, embed the unified `KeepurChatHeader` in a single `.automatic`
/// slot — the title bar there has no leading/trailing alignment regions
/// distinct from the principal slot.
struct KeepurChatHeader: View {
    struct Action: Identifiable {
        let id = UUID()
        let symbol: String
        let action: () -> Void

        init(symbol: String, action: @escaping () -> Void) {
            self.symbol = symbol
            self.action = action
        }
    }

    let title: String
    let statusText: String?
    let statusDate: Date?
    let isStatusActive: Bool
    let onBack: (() -> Void)?
    let trailingActions: [Action]

    init(
        title: String,
        statusText: String? = nil,
        statusDate: Date? = nil,
        isStatusActive: Bool = false,
        onBack: (() -> Void)? = nil,
        trailingActions: [Action] = []
    ) {
        self.title = title
        self.statusText = statusText
        self.statusDate = statusDate
        self.isStatusActive = isStatusActive
        self.onBack = onBack
        self.trailingActions = trailingActions
    }

    var body: some View {
        HStack(spacing: KeepurTheme.Spacing.s3) {
            BackButton(onBack: onBack)
            TitleBlock(
                title: title,
                statusText: statusText,
                statusDate: statusDate,
                isStatusActive: isStatusActive
            )
            .frame(maxWidth: .infinity)
            TrailingStack(actions: trailingActions)
        }
    }
}

// MARK: - Sub-views (composable for native toolbar slots)

extension KeepurChatHeader {
    /// Circular back chevron. Place in `.topBarLeading` (iOS) when splitting
    /// the header across native toolbar slots.
    struct BackButton: View {
        let onBack: (() -> Void)?

        @ViewBuilder
        var body: some View {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    CircleButton(symbol: KeepurTheme.Symbol.chevronBack)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
        }
    }

    /// Centered title + optional status line ("● working · 2m ago"). Place
    /// in `.principal` (iOS) when splitting the header across native
    /// toolbar slots.
    struct TitleBlock: View {
        let title: String
        let statusText: String?
        let statusDate: Date?
        let isStatusActive: Bool

        var body: some View {
            VStack(spacing: 2) {
                Text(title)
                    .font(KeepurTheme.Font.h4)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                if statusText != nil || statusDate != nil {
                    statusLine
                }
            }
        }

        private var statusLine: some View {
            HStack(spacing: KeepurTheme.Spacing.s1) {
                if isStatusActive {
                    PulsingDot()
                } else {
                    Circle()
                        .fill(KeepurTheme.Color.fgMuted)
                        .frame(width: 6, height: 6)
                }
                if let s = statusText {
                    Text(s)
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                }
                if statusText != nil && statusDate != nil {
                    Text("·")
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgMuted)
                }
                if let d = statusDate {
                    Text(d, style: .relative)
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                }
            }
        }
    }

    /// Pulsing honey dot for active-status indicator. Lives only as long as
    /// the surrounding status is active — when the parent flips inactive,
    /// the view is removed from the tree and the repeating animation
    /// unmounts cleanly.
    fileprivate struct PulsingDot: View {
        @State private var pulse = false

        var body: some View {
            Circle()
                .fill(KeepurTheme.Color.honey500)
                .frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.4 : 1.0)
                .opacity(pulse ? 0.6 : 1.0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        }
    }

    /// Row of circular trailing action buttons. Place in `.topBarTrailing`
    /// (iOS) when splitting the header across native toolbar slots.
    struct TrailingStack: View {
        let actions: [Action]

        var body: some View {
            HStack(spacing: KeepurTheme.Spacing.s2) {
                ForEach(actions) { action in
                    Button {
                        action.action()
                    } label: {
                        CircleButton(symbol: action.symbol)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    fileprivate struct CircleButton: View {
        let symbol: String

        var body: some View {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(KeepurTheme.Color.fgPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(KeepurTheme.Color.wax100))
        }
    }
}
