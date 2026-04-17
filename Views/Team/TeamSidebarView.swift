import SwiftUI

struct TeamSidebarView: View {
    @ObservedObject var viewModel: TeamViewModel

    var body: some View {
        List {
            ForEach(viewModel.sortedAgents, id: \.agent.id) { entry in
                Button {
                    viewModel.openAgentDM(agent: entry.agent)
                } label: {
                    AgentRow(
                        agent: entry.agent,
                        dmChannel: entry.dmChannel,
                        isActive: entry.dmChannel?.id == viewModel.activeChannelId
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if viewModel.agents.isEmpty {
                ContentUnavailableView {
                    Label("No Agents", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Connecting to Hive...")
                }
            }
        }
    }
}
