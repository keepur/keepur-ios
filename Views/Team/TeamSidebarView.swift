import SwiftUI

struct TeamSidebarView: View {
    @ObservedObject var viewModel: TeamViewModel
    @State private var selectedAgentId: String?

    var body: some View {
        List(selection: Binding(
            get: { selectedAgentId },
            set: { newId in
                selectedAgentId = newId
                if let newId,
                   let entry = viewModel.sortedAgents.first(where: { $0.agent.id == newId }) {
                    viewModel.openAgentDM(agent: entry.agent)
                }
            }
        )) {
            ForEach(viewModel.sortedAgents, id: \.agent.id) { entry in
                AgentRow(
                    agent: entry.agent,
                    dmChannel: entry.dmChannel,
                    isActive: entry.dmChannel?.id == viewModel.activeChannelId
                )
                .tag(entry.agent.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(KeepurTheme.Color.bgPageDynamic)
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
