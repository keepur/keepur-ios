import SwiftUI

struct AgentRow: View {
    let agent: TeamAgentInfo
    let dmChannel: TeamChannel?
    let isActive: Bool

    private var statusColor: Color {
        switch agent.status {
        case "idle": return .green
        case "processing": return .yellow
        case "error", "stopped": return .red
        default: return .gray
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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)

                if let secondLineText {
                    Text(secondLineText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let lastAt = dmChannel?.lastMessageAt {
                Text(lastAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
