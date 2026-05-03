import SwiftUI

/// Branded bottom-sheet replacement for popovers. Caller owns sheet
/// presentation and detents; embed inside `.sheet { ... }`:
///
/// ```swift
/// .sheet(isPresented: $showAttach) {
///     KeepurActionSheet(
///         title: "Attach",
///         subtitle: "Add a file or photo to the message.",
///         actions: [...]
///     )
///     .presentationDetents([.medium])
/// }
/// ```
struct KeepurActionSheet: View {
    struct Action: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let subtitle: String?
        let action: () -> Void

        init(symbol: String, title: String, subtitle: String? = nil, action: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.subtitle = subtitle
            self.action = action
        }
    }

    let title: String
    let subtitle: String?
    let actions: [Action]

    init(title: String, subtitle: String? = nil, actions: [Action]) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s4) {
                VStack(alignment: .leading, spacing: KeepurTheme.Spacing.s1) {
                    Text(title)
                        .font(KeepurTheme.Font.h3)
                        .tracking(KeepurTheme.Font.lsH3)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(KeepurTheme.Font.bodySm)
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    }
                }

                VStack(spacing: KeepurTheme.Spacing.s2) {
                    ForEach(actions) { action in
                        actionRow(action)
                    }
                }
            }
            .padding(.horizontal, KeepurTheme.Spacing.s4)
            .padding(.top, KeepurTheme.Spacing.s5)
            .padding(.bottom, KeepurTheme.Spacing.s4)
        }
        .background(KeepurTheme.Color.bgPageDynamic)
    }

    private func actionRow(_ action: Action) -> some View {
        Button {
            action.action()
        } label: {
            HStack(spacing: KeepurTheme.Spacing.s3) {
                RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm)
                    .fill(KeepurTheme.Color.accentTint)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: action.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(KeepurTheme.Color.honey700)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(KeepurTheme.Font.body)
                        .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if let sub = action.subtitle {
                        Text(sub)
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(KeepurTheme.Font.bodySm)
                    .foregroundStyle(KeepurTheme.Color.fgTertiary)
            }
            .padding(.horizontal, KeepurTheme.Spacing.s3)
            .padding(.vertical, KeepurTheme.Spacing.s2)
            .background(KeepurTheme.Color.bgSurfaceDynamic)
            .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(action.title), \(action.subtitle ?? "")")
        .accessibilityHint("Double tap to select")
    }
}
