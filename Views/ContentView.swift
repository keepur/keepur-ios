import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var teamViewModel = TeamViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPaired = KeychainManager.isPaired

    var body: some View {
        Group {
            if isPaired {
                TabView {
                    Tab("Team", systemImage: "person.3.fill") {
                        TeamRootView(viewModel: teamViewModel)
                    }

                    Tab("Beekeeper", systemImage: "hammer.fill") {
                        RootView(viewModel: chatViewModel)
                    }
                }
            } else {
                PairingView(onPaired: {
                    isPaired = true
                    chatViewModel.isAuthenticated = true
                    chatViewModel.configure(context: modelContext)
                    teamViewModel.configure(context: modelContext)
                })
            }
        }
        .onAppear {
            if isPaired {
                chatViewModel.configure(context: modelContext)
                teamViewModel.configure(context: modelContext)
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active && isPaired {
                chatViewModel.ws.connect()
                teamViewModel.ws.connect()
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
}
