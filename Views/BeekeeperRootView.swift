import SwiftUI
import Combine

struct BeekeeperRootView: View {
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var store = ConciergeSessionStore()
    @StateObject private var concierge = ConciergeViewModel()

    var body: some View {
        Group {
            switch concierge.state {
            case .loading:
                ProgressView("Opening concierge…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(KeepurTheme.Color.bgPageDynamic)
            case .ready(let sessionId, _):
                // showsBackButton: false — concierge ChatView is the root of
                // the Beekeeper tab's NavigationStack; no parent to pop to.
                ChatView(
                    viewModel: viewModel,
                    sessionId: sessionId,
                    navigationTitle: "Concierge",
                    showsBackButton: false
                )
            case .error(let message):
                ContentUnavailableView {
                    Label("Concierge unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        concierge.retry(viewModel: viewModel, store: store)
                    }
                    .buttonStyle(KeepurPrimaryButtonStyle())
                    .padding(.horizontal, KeepurTheme.Spacing.s7)
                }
                .background(KeepurTheme.Color.bgPageDynamic)
            }
        }
        .navigationTitle("Beekeeper")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            concierge.start(viewModel: viewModel, store: store)
        }
    }
}

/// Coordinates the resume → list-fallback → fresh-spawn flow for the
/// admin's single concierge session. Observes `ChatViewModel.@Published`
/// outputs (`currentSessionId`, `currentPath`, `serverSessions`) instead
/// of subscribing to `WSIncoming` directly — `WebSocketManager.onMessage`
/// is single-consumer and already taken by `ChatViewModel`. Less invasive
/// than adding a multicast hook for one tab's worth of orchestration.
@MainActor
final class ConciergeViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(sessionId: String, path: String)
        case error(String)
    }

    @Published private(set) var state: State = .loading

    private var hasStarted = false

    func start(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        // Idempotent: tab `.task` fires on every appear; only run the dance once
        // unless the caller explicitly retries.
        guard !hasStarted else { return }
        hasStarted = true
        state = .loading
        Task { await runFlow(viewModel: viewModel, store: store) }
    }

    func retry(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        hasStarted = false
        start(viewModel: viewModel, store: store)
    }

    private func runFlow(viewModel: ChatViewModel, store: ConciergeSessionStore) async {
        // 1) Cache hit → resume_session.
        if let cached = store.cachedSession {
            viewModel.ws.send(.resumeSession(sessionId: cached.sessionId, path: cached.path))
            if let info = await waitForSessionInfo(viewModel: viewModel, expecting: cached.sessionId, timeoutSeconds: 3) {
                store.cache(sessionId: info.sessionId, path: info.path)
                state = .ready(sessionId: info.sessionId, path: info.path)
                return
            }
            // Resume failed (server reaped the slot, returned error, or timed out).
            // Drop cache and fall through to list_sessions discovery.
            store.clear()
        }

        // 2) Cache miss → list_sessions, filter mode == "concierge".
        viewModel.ws.send(.listSessions)
        if let match = await waitForConciergeInList(viewModel: viewModel, timeoutSeconds: 3) {
            viewModel.ws.send(.resumeSession(sessionId: match.sessionId, path: match.path))
            if let info = await waitForSessionInfo(viewModel: viewModel, expecting: match.sessionId, timeoutSeconds: 3) {
                store.cache(sessionId: info.sessionId, path: info.path)
                state = .ready(sessionId: info.sessionId, path: info.path)
                return
            }
        }

        // 3) Still nothing → spawn fresh.
        viewModel.ws.send(.newSessionConcierge)
        if let info = await waitForSessionInfo(viewModel: viewModel, expecting: nil, timeoutSeconds: 5) {
            store.cache(sessionId: info.sessionId, path: info.path)
            state = .ready(sessionId: info.sessionId, path: info.path)
            return
        }

        state = .error("Concierge did not respond in time")
    }

    /// Polls `viewModel.currentSessionId` and `currentPath` until a `session_info`
    /// has landed (ChatViewModel updates both atomically in its `.sessionInfo` handler).
    /// When `expecting` is non-nil the wait is satisfied only by that exact id;
    /// when nil, any new id distinct from the snapshot taken at entry counts.
    private func waitForSessionInfo(
        viewModel: ChatViewModel,
        expecting: String?,
        timeoutSeconds: Double
    ) async -> (sessionId: String, path: String)? {
        let initial = viewModel.currentSessionId
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let id = viewModel.currentSessionId, !viewModel.currentPath.isEmpty {
                if let expecting {
                    if id == expecting { return (id, viewModel.currentPath) }
                } else if id != initial {
                    return (id, viewModel.currentPath)
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Polls `viewModel.serverSessions` for the concierge slot until one shows
    /// up or the timeout elapses. The list_sessions response could already be
    /// in `serverSessions` from a prior tab fetch — checking on entry is fine.
    private func waitForConciergeInList(
        viewModel: ChatViewModel,
        timeoutSeconds: Double
    ) async -> ServerSession? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let match = ConciergeSessionStore.pickConciergeSession(from: viewModel.serverSessions) {
                return match
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}
