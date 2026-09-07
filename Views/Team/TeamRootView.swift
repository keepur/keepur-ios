import SwiftUI

struct TeamRootView: View {
    @ObservedObject var viewModel: TeamViewModel
    @ObservedObject var capabilityManager: CapabilityManager
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isViewingChat = false

    var body: some View {
        VStack(spacing: 0) {
            KeepurConnectionBanner(
                presentation: .make(state: viewModel.connectionState, error: viewModel.lastError),
                onRetry: { viewModel.reconnect() },
                onDismissError: { viewModel.lastError = nil }
            )

            NavigationSplitView(columnVisibility: $columnVisibility) {
                TeamSidebarView(viewModel: viewModel)
                    .navigationTitle(capabilityManager.selectedHive ?? "Hive")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Circle()
                                .fill(viewModel.connectionState == .connected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                                .frame(width: 8, height: 8)
                        }
                    }
            } detail: {
                if viewModel.activeChannelId != nil {
                    TeamChatView(viewModel: viewModel)
                        .onAppear { isViewingChat = true }
                        .onDisappear { isViewingChat = false }
                } else {
                    ContentUnavailableView {
                        Label("Select an agent", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Choose an agent to start a conversation")
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        #if os(iOS)
        .toolbar(isViewingChat ? .hidden : .visible, for: .tabBar)
        #endif
    }
}
