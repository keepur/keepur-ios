import SwiftUI

struct AgentRow: View {
    let agent: TeamAgentInfo
    let dmChannel: TeamChannel?
    let isActive: Bool

    private var subtitle: String? {
        if let title = agent.title, !title.isEmpty {
            return title
        }
        if !agent.model.isEmpty {
            return agent.model
        }
        return nil
    }

    /// Second-line text: DM preview if a conversation exists, else fall back
    /// to the agent's title/model subtitle.
    private var secondLineText: String? {
        if let preview = dmChannel?.lastMessageText, !preview.isEmpty {
            return preview
        }
        return subtitle
    }

    var body: some View {
        HStack(spacing: KeepurTheme.Spacing.s3) {
            KeepurAvatar(
                size: 56,
                content: .letter(agent.name),
                statusOverlay: agent.statusTint
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(KeepurTheme.Font.body)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                    .lineLimit(1)

                if let secondLineText {
                    Text(secondLineText)
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: KeepurTheme.Spacing.s2) {
                if let lastAt = dmChannel?.lastMessageAt {
                    Text(lastAt, style: .relative)
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgTertiary)
                }
                KeepurUnreadBadge(count: 0)
            }
        }
        .padding(.vertical, KeepurTheme.Spacing.s2)
        .contentShape(Rectangle())
    }
}

private extension TeamAgentInfo {
    var statusTint: KeepurStatusPill.Tint {
        switch status {
        case "idle": return .success
        case "processing": return .warning
        case "error", "stopped": return .danger
        default: return .muted
        }
    }
}
