import SwiftUI

/// Custom toolbar content showing a circular back button, a centered title
/// with optional status line beneath ("● working · 2m ago"), and a row of
/// trailing circular action buttons.
///
/// Embed inside a toolbar item; on iOS, also set
/// `.navigationBarBackButtonHidden(true)` on the host view so the system
/// back button doesn't compete with the custom one:
///
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .principal) {
///         KeepurChatHeader(
///             title: "hive-dodi",
///             statusText: "working",
///             statusDate: lastActivity,
///             isStatusActive: true,
///             onBack: { dismiss() },
///             trailingActions: [
///                 .init(symbol: "speaker.wave.2") { toggleMute() },
///                 .init(symbol: "info.circle")    { showInfo() },
///             ]
///         )
///     }
/// }
/// .navigationBarBackButtonHidden(true)
/// ```
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

    @State private var pulse = false

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
            backButton
            titleBlock
            trailingStack
        }
        .onAppear {
            if isStatusActive {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }

    @ViewBuilder
    private var backButton: some View {
        if let onBack {
            Button {
                onBack()
            } label: {
                circleButton(symbol: KeepurTheme.Symbol.chevronBack)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
        }
    }

    private var titleBlock: some View {
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
        .frame(maxWidth: .infinity)
    }

    private var statusLine: some View {
        HStack(spacing: KeepurTheme.Spacing.s1) {
            pulseDot
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

    private var pulseDot: some View {
        Circle()
            .fill(isStatusActive ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted)
            .frame(width: 6, height: 6)
            .scaleEffect(isStatusActive && pulse ? 1.4 : 1.0)
            .opacity(isStatusActive && pulse ? 0.6 : 1.0)
    }

    private var trailingStack: some View {
        HStack(spacing: KeepurTheme.Spacing.s2) {
            ForEach(trailingActions) { action in
                Button {
                    action.action()
                } label: {
                    circleButton(symbol: action.symbol)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func circleButton(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(KeepurTheme.Color.fgPrimary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(KeepurTheme.Color.wax100))
    }
}
