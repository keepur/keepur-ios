import SwiftUI

struct TeamSidebarView: View {
    @ObservedObject var viewModel: TeamViewModel

    private var dmChannels: [TeamChannel] {
        viewModel.channels.filter { $0.type == "dm" }
    }

    private var groupChannels: [TeamChannel] {
        viewModel.channels.filter { $0.type == "channel" }
    }

    var body: some View {
        List(selection: Binding(
            get: { viewModel.activeChannelId },
            set: { id in
                if let id { viewModel.selectChannel(id) }
            }
        )) {
            if !dmChannels.isEmpty {
                Section("Direct Messages") {
                    ForEach(dmChannels, id: \.id) { channel in
                        ChannelRow(
                            channel: channel,
                            title: viewModel.displayName(for: channel),
                            isActive: channel.id == viewModel.activeChannelId
                        )
                        .tag(channel.id)
                    }
                }
            }

            if !groupChannels.isEmpty {
                Section("Channels") {
                    ForEach(groupChannels, id: \.id) { channel in
                        ChannelRow(
                            channel: channel,
                            title: viewModel.displayName(for: channel),
                            isActive: channel.id == viewModel.activeChannelId
                        )
                        .tag(channel.id)
                    }
                }
            }

            if !viewModel.agents.isEmpty {
                Section("Agents") {
                    ForEach(viewModel.agents, id: \.id) { agent in
                        AgentRow(agent: agent, isActive: false)
                            .onTapGesture { viewModel.openAgentDM(agent: agent) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if viewModel.channels.isEmpty && viewModel.agents.isEmpty {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Connecting to Hive...")
                }
            }
        }
    }
}

// MARK: - Channel Row

struct ChannelRow: View {
    let channel: TeamChannel
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(channel.type == "dm" ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: channel.type == "dm" ? "person.fill" : "number")
                        .font(.system(size: 14))
                        .foregroundStyle(channel.type == "dm" ? .blue : .purple)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)

                if let preview = channel.lastMessageText {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let lastAt = channel.lastMessageAt {
                Text(lastAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
