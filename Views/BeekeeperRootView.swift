import SwiftUI
import SwiftData
import Combine

struct BeekeeperRootView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext
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
                    navigationTitle: "Beekeeper",
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
            // KPR-204 cleanup: pre-fix iOS builds inserted a SwiftData Session
            // row for the concierge slot (server didn't emit `mode` on
            // session_info, so the handler couldn't tell). Clear those vestigial
            // rows once on the cached id; new concierge sessions skip the
            // insert at the source. Safe to run every appearance — idempotent
            // (no-op if the row is already gone).
            cleanupVestigialConciergeRow()
            concierge.start(viewModel: viewModel, store: store)
        }
        .onChange(of: viewModel.connectionState) { _, newState in
            // ⚠9: a slow-but-eventually-successful connect after an offline bail re-runs
            // the flow once, so the tab does not sit on "Not connected…" while the banner
            // already says nothing.
            if newState == .connected {
                concierge.retryIfBailedOffline(viewModel: viewModel, store: store)
            }
        }
    }

    private func cleanupVestigialConciergeRow() {
        guard let cached = store.cachedSession else { return }
        let cachedId = cached.sessionId
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == cachedId }
        )
        guard let row = try? modelContext.fetch(descriptor).first else { return }
        modelContext.delete(row)
        try? modelContext.save()
    }
}

/// Coordinates the resume → list-fallback → fresh-spawn flow for the
/// admin's single concierge session. Observes `ChatViewModel.@Published`
/// outputs (`currentSessionId`, `currentPath`, `serverSessions`) instead
/// of subscribing to `WSIncoming` directly — `BeekeeperSocket.frames` is
/// multicast, but this coordinator still observes `ChatViewModel`'s
/// published state; child C switches it to the decoded-frame stream.
/// Less invasive than adding a multicast hook for one tab's worth of
/// orchestration.
@MainActor
final class ConciergeViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(sessionId: String, path: String)
        case error(String)
    }

    @Published private(set) var state: State = .loading

    /// True after `runFlow` gave up because the socket was down (nothing sent, cache
    /// kept). Reset by `start`/`retry`; `BeekeeperRootView` re-runs the flow on the
    /// next `.connected` transition (spec ⚠9). No self-heal loop: a flapping link
    /// re-runs at most once per bail.
    private(set) var bailedOffline = false

    private var hasStarted = false
    private static let offlineBailMessage = "Not connected. Retry when reconnected."

    func start(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        // Idempotent: tab `.task` fires on every appear; only run the dance once
        // unless the caller explicitly retries.
        guard !hasStarted else { return }
        hasStarted = true
        bailedOffline = false
        state = .loading
        Task { await runFlow(viewModel: viewModel, store: store) }
    }

    func retry(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        hasStarted = false
        start(viewModel: viewModel, store: store)
    }

    /// What `BeekeeperRootView`'s `.onChange(of: connectionState)` calls: re-run only
    /// after an offline bail and only once actually connected. Unit-reachable so the
    /// predicate is tested without the view.
    func retryIfBailedOffline(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        guard bailedOffline, viewModel.connectionState == .connected else { return }
        retry(viewModel: viewModel, store: store)
    }

    private func runFlow(viewModel: ChatViewModel, store: ConciergeSessionStore) async {
        // Cold start races this task against the socket handshake: the tab's `.task`
        // fires `start()` → `runFlow` as soon as the view appears, while `configure()`
        // has only just called `connect()`. Sending into `.connecting` is a silent
        // no-op (`BeekeeperSocket.send` returns `false`), which used to lose the
        // cache-hit `resume_session` and spawn duplicates. Wait for the connection.
        // If the socket is definitively down (`.disconnected` after a connect request:
        // not paired, host unconfigured, token retries exhausted) bail right away —
        // without sending and WITHOUT `store.clear()`; the old flow would burn
        // 3 s + 3 s + 5 s of dead timeouts and wipe the cached concierge id.
        let connected = await waitForSocketConnected(viewModel: viewModel, timeoutSeconds: 5)
        // The transition may have landed in the timeout's own turn; re-read before bailing.
        if !connected, viewModel.connectionState != .connected {
            bailedOffline = true
            state = .error(Self.offlineBailMessage)
            return
        }

        // 1) Cache hit → resume_session.
        if let cached = store.cachedSession {
            viewModel.send(.resumeSession(sessionId: cached.sessionId, path: cached.path))
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
        viewModel.send(.listSessions)
        if let match = await waitForConciergeInList(viewModel: viewModel, timeoutSeconds: 3) {
            viewModel.send(.resumeSession(sessionId: match.sessionId, path: match.path))
            if let info = await waitForSessionInfo(viewModel: viewModel, expecting: match.sessionId, timeoutSeconds: 3) {
                store.cache(sessionId: info.sessionId, path: info.path)
                state = .ready(sessionId: info.sessionId, path: info.path)
                return
            }
        }

        // 3) Still nothing → spawn fresh.
        viewModel.send(.newSessionConcierge)
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

    /// Consumes `viewModel.$connectionState` (no polling, no `socket` read). Returns
    /// `true` on `.connected`; `false` immediately on `.disconnected` once the VM has
    /// asked the socket to connect (nothing is in flight), or when the timeout elapses
    /// while still `.connecting`/`.reconnecting` — waiting through `.reconnecting` is
    /// deliberate: on a flaky cold start the first 2 s backoff often lands inside the
    /// budget. A `.disconnected` seen before any connect request is the cold initial
    /// value, not a failure, so the result does not depend on `configure()` having run
    /// before the tab's `.task` (ordering-proof). The `.disconnected` case also re-reads
    /// `viewModel.connectionState` live rather than trusting the buffered value alone:
    /// `AsyncPublisher` can hand this loop a stale `.disconnected` on a main-actor turn
    /// after `configure()`/`reconnect()` has already flipped the socket to `.connecting`
    /// (that emission just has not been consumed yet); without the re-read the flow
    /// would bail "Not connected…" while a connect is in flight. The buffered
    /// `.connecting`, if any, arrives on the next iteration and the wait continues.
    private func waitForSocketConnected(viewModel: ChatViewModel, timeoutSeconds: Double) async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { @MainActor in
                for await state in viewModel.$connectionState.values {
                    switch state {
                    case .connected:
                        return true
                    case .disconnected where viewModel.hasRequestedConnection && viewModel.connectionState == .disconnected:
                        return false
                    case .disconnected, .connecting, .reconnecting:
                        continue
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()   // AsyncPublisher honours cancellation; the loser finishes
            return first ?? false
        }
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
