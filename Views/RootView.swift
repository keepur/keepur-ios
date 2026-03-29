import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if KeychainManager.hasToken && viewModel.isAuthenticated {
                NavigationStack {
                    ChatView(viewModel: viewModel)
                }
            } else {
                SetupView {
                    viewModel.isAuthenticated = true
                    viewModel.configure(context: modelContext)
                }
            }
        }
        .onAppear {
            if KeychainManager.hasToken {
                viewModel.configure(context: modelContext)
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active && KeychainManager.hasToken {
                viewModel.ws.connect()
            }
        }
    }
}
