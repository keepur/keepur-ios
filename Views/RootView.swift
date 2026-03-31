import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if KeychainManager.isPaired && viewModel.isPaired {
                SessionListView(viewModel: viewModel)
                    .task {
                        do {
                            _ = try await APIManager.fetchMe()
                        } catch APIManager.APIError.unauthorized {
                            viewModel.unpair()
                        } catch {
                            // Network error — don't log out
                        }
                    }
            } else {
                PairingView(onPaired: {
                    viewModel.isPaired = true
                    viewModel.configure(context: modelContext)
                })
            }
        }
        .onAppear {
            if KeychainManager.isPaired {
                viewModel.configure(context: modelContext)
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active && KeychainManager.isPaired {
                viewModel.ws.connect()
            }
        }
    }
}
