import SwiftUI
import SwiftData

struct RootView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
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
    }
}
