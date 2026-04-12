import SwiftUI

struct AgentDetailSheet: View {
    let agent: TeamAgentInfo

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

    private var lastActivityDate: Date? {
        guard let str = agent.lastActivity else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: str)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        Text(iconText)
                            .font(.system(size: 48))
                        Text(agent.name)
                            .font(.title2.bold())
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 10, height: 10)
                            Text(agent.status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top)

                    // Info grid
                    VStack(spacing: 0) {
                        if let title = agent.title, !title.isEmpty {
                            infoRow(label: "Title", value: title)
                        }
                        if !agent.model.isEmpty {
                            infoRow(label: "Model", value: agent.model)
                        }
                        infoRow(label: "Messages", value: "\(agent.messagesProcessed)")
                        infoRow(label: "Last Active", date: lastActivityDate)
                    }
                    .background(Color.secondarySystemGroupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    // Tools
                    if !agent.tools.isEmpty {
                        sectionCard(title: "Tools") {
                            Text(agent.tools.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Schedule
                    if !agent.schedule.isEmpty {
                        sectionCard(title: "Schedule") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(agent.schedule.enumerated()), id: \.offset) { _, entry in
                                    if let cron = entry["cron"], let task = entry["task"] {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(cron)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                            Text("— \(task)")
                                                .font(.subheadline)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Channels
                    if !agent.channels.isEmpty {
                        sectionCard(title: "Channels") {
                            Text(agent.channels.map { "#\($0)" }.joined(separator: ", "))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .background(Color.systemGroupedBackground)
            .navigationTitle("Agent Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    // MARK: - Subviews

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func infoRow(label: String, date: Date?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let date {
                Text(date, style: .relative)
            } else {
                Text("Never")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondarySystemGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
