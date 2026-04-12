import SwiftUI

struct AgentRow: View {
    let agent: TeamAgentInfo
    let isActive: Bool

    private var statusColor: Color {
        switch agent.status {
        case "idle": return .green
        case "processing": return .yellow
        case "error", "stopped": return .red
        default: return .gray
        }
    }

    private var iconText: String {
        agent.icon.isEmpty ? "🤖" : agent.icon
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

    var body: some View {
        HStack(spacing: 10) {
            Text(iconText)
                .font(.title2)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.body)
                        .fontWeight(isActive ? .semibold : .regular)
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}
