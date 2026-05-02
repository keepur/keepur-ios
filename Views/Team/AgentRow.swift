import SwiftUI

struct AgentRow: View {
    let agent: TeamAgentInfo
    let dmChannel: TeamChannel?
    let isActive: Bool

    private var statusColor: Color {
        switch agent.status {
        case "idle": return KeepurTheme.Color.success
        case "processing": return KeepurTheme.Color.warning
        case "error", "stopped": return KeepurTheme.Color.danger
        default: return KeepurTheme.Color.fgMuted
        }
    }

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
            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 36, height: 36)

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

            if let lastAt = dmChannel?.lastMessageAt {
                Text(lastAt, style: .relative)
                    .font(KeepurTheme.Font.caption)
                    .foregroundStyle(KeepurTheme.Color.fgTertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
