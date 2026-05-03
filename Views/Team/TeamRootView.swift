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
                            .foregroundStyle(KeepurTheme.Color.warning)
                        Text(banner)
                            .foregroundStyle(KeepurTheme.Color.fgPrimaryDynamic)
                        Spacer()
                        Text("Retry")
                            .fontWeight(.bold)
                            .foregroundStyle(KeepurTheme.Color.honey700)
                    }
                    .font(KeepurTheme.Font.bodySm)
                    .padding(KeepurTheme.Spacing.s3)
                    .frame(maxWidth: .infinity)
                    .background(KeepurTheme.Color.honey100)
                }
                .buttonStyle(.plain)
            }

            NavigationSplitView(columnVisibility: $columnVisibility) {
                TeamSidebarView(viewModel: viewModel)
                    .navigationTitle(capabilityManager.selectedHive ?? "Hive")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Circle()
                                .fill(viewModel.ws.isConnected ? KeepurTheme.Color.success : KeepurTheme.Color.danger)
                                .frame(width: 8, height: 8)
                        }
                    }
            } detail: {
                if viewModel.activeChannelId != nil {
                    TeamChatView(viewModel: viewModel)
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
        .toolbar(viewModel.activeChannelId == nil ? .visible : .hidden, for: .tabBar)
        #endif
    }
}
