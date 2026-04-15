import SwiftUI

struct TeamRootView: View {
    @ObservedObject var viewModel: TeamViewModel
    @ObservedObject var capabilityManager: CapabilityManager
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        VStack(spacing: 0) {
            if let banner = viewModel.disconnectedBanner {
                Button {
                    viewModel.retryConnect()
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(banner)
                        Spacer()
                        Text("Retry").bold()
                    }
                    .padding(12)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange)
                }
                .buttonStyle(.plain)
            }

            NavigationSplitView(columnVisibility: $columnVisibility) {
                TeamSidebarView(viewModel: viewModel)
                    .navigationTitle(capabilityManager.selectedHive ?? "Hive")
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
}
