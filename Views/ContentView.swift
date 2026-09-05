import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var teamViewModel = TeamViewModel()
    @StateObject private var capabilityManager = CapabilityManager()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPaired = KeychainManager.isPaired

    var body: some View {
        Group {
            if isPaired {
                tabView
            } else {
                PairingView(
                    onPaired: {
                        isPaired = true
                        chatViewModel.isAuthenticated = true
                        chatViewModel.configure(context: modelContext)
                        teamViewModel.speechManager = chatViewModel.speechManager
                        teamViewModel.configure(context: modelContext, capabilityManager: capabilityManager)
                    },
                    capabilityManager: capabilityManager
                )
            }
        }
        .onAppear {
            capabilityManager.onAuthFailure = {
                chatViewModel.unpair()
            }
            if isPaired {
                chatViewModel.configure(context: modelContext)
                teamViewModel.speechManager = chatViewModel.speechManager
                teamViewModel.configure(context: modelContext, capabilityManager: capabilityManager)
                Task {
                    await capabilityManager.refresh()
                    teamViewModel.connectIfPossible()
                }
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active && isPaired {
                chatViewModel.reconnect()
                Task {
                    await capabilityManager.refresh()
                    teamViewModel.connectIfPossible()
                }
            }
        }
        .onChange(of: chatViewModel.isAuthenticated) {
            if !chatViewModel.isAuthenticated && isPaired {
                isPaired = false
                teamViewModel.disconnect()
            }
        }
        .onChange(of: teamViewModel.isAuthenticated) {
            if !teamViewModel.isAuthenticated && isPaired {
                isPaired = false
                chatViewModel.unpair()
            }
        }
        .task(id: isPaired) {
            guard isPaired else { return }
            await chatViewModel.speechManager.loadModel()
        }
    }

    @ViewBuilder
    private var tabView: some View {
        // Split by role so each branch presents a stable Tab structure.
        // Wrapping individual `Tab` items in `if` made the TabView's tab list
        // depend on every CapabilityManager publish, which churned the view
        // graph during scene transitions and triggered scene-update watchdog
        // kills (0x8BADF00D). KPR-186 follow-up.
        if capabilityManager.role == "admin" {
            adminTabs
        } else {
            memberTabs
        }
    }

    @ViewBuilder
    private var adminTabs: some View {
        TabView {
            Tab("Beekeeper", systemImage: KeepurTheme.Symbol.bolt) {
                NavigationStack {
                    BeekeeperRootView(viewModel: chatViewModel)
                }
            }

            Tab("Hive", systemImage: "hexagon.fill") {
                hiveTabBody
            }

            Tab("Sessions", systemImage: KeepurTheme.Symbol.chat) {
                SessionListView(viewModel: chatViewModel)
            }

            Tab("Settings", systemImage: KeepurTheme.Symbol.settings) {
                SettingsView(viewModel: chatViewModel)
            }
        }
        .tint(KeepurTheme.Color.honey500)
    }

    @ViewBuilder
    private var memberTabs: some View {
        TabView {
            Tab("Hive", systemImage: "hexagon.fill") {
                hiveTabBody
            }

            Tab("Settings", systemImage: KeepurTheme.Symbol.settings) {
                SettingsView(viewModel: chatViewModel)
            }
        }
        .tint(KeepurTheme.Color.honey500)
    }

    @ViewBuilder
    private var hiveTabBody: some View {
        if capabilityManager.hives.count == 1 {
            TeamRootView(viewModel: teamViewModel, capabilityManager: capabilityManager)
        } else {
            NavigationStack {
                HivesGridView(
                    capabilityManager: capabilityManager,
                    teamViewModel: teamViewModel
                )
            }
        }
    }
}
