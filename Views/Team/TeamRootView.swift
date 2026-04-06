import SwiftUI

struct TeamRootView: View {
    @ObservedObject var viewModel: TeamViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            TeamSidebarView(viewModel: viewModel)
                .navigationTitle("Team")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Circle()
                            .fill(viewModel.ws.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                    }
                }
        } detail: {
            if viewModel.activeChannelId != nil {
                TeamChatView(viewModel: viewModel)
            } else {
                ContentUnavailableView {
                    Label("Select a conversation", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Choose a channel or DM from the sidebar")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
