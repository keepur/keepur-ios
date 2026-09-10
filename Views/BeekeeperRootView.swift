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
        .onReceive(viewModel.incoming) { frame in
            concierge.recoverIfConversationMissing(
                frame,
                viewModel: viewModel,
                store: store
            )
        }
        .onChange(of: concierge.state) { _, newState in
            guard case .ready(let sessionId, _) = newState else { return }
            recoverPersistedMissingConversation(sessionId: sessionId)
        }
    }

    private func cleanupVestigialConciergeRow() {
        guard let cached = store.cachedSession else { return }
        let cachedId = cached.sessionId
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == cachedId }
        )
        guard let row = modelContext.fetchOrEmpty(descriptor, "view.conciergeCleanup.fetch").first else { return }
        modelContext.delete(row)
        modelContext.saveReporting("view.conciergeCleanup.save")
    }

    private func recoverPersistedMissingConversation(sessionId: String) {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let hasMissingConversationError = modelContext
            .fetchOrEmpty(descriptor, "view.conciergeRecovery.fetch")
            .contains { ConciergeViewModel.isPersistedMissingConversationError($0) }
        guard hasMissingConversationError else { return }
        concierge.recoverIfConversationMissing(
            .error(
                message: "No conversation found with session ID: \(sessionId)",
                sessionId: sessionId
            ),
            viewModel: viewModel,
            store: store
        )
    }
}

/// Coordinates concierge requests using Chat's post-handler decoded stream.
@MainActor
final class ConciergeViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case ready(sessionId: String, path: String)
        case error(String)
    }
    @Published private(set) var state: State = .loading
    private(set) var bailedOffline = false
    private var hasStarted = false
    private var flowTask: Task<Void, Never>?
    private var activeRun: Run?
    private static let offlineBailMessage = "Not connected. Retry when reconnected."

    private struct Identity: Sendable {
        let sessionId: String
        let path: String
    }
    private enum Reply: Sendable {
        case info(Identity)
        case discovery(Identity?)  // .discovery(nil) is a received no-match list.
        case cleared
    }
    private enum WaitResult {
        case reply(Reply), timeout, offline, stopped
    }

    static func isPersistedMissingConversationError(_ message: Message) -> Bool {
        message.typedRole == .system
            && message.text.localizedCaseInsensitiveContains("error:")
            && message.text.localizedCaseInsensitiveContains("no conversation found with session id")
    }
    private final class ReplyLatch {
        let relay = CurrentValueSubject<Reply?, Never>(nil)
        var subscription: AnyCancellable?
        init(incoming: PassthroughSubject<WSIncoming, Never>,
             match: @escaping (WSIncoming) -> Reply?) {
            let relay = self.relay
            subscription = incoming.compactMap(match).prefix(1).sink { reply in
                relay.send(reply)
            }
        }
        func cancel() {
            subscription?.cancel()
            subscription = nil
            relay.send(completion: .finished)
        }
    }
    private final class Run {
        weak var owner: ConciergeViewModel?
        let viewModel: ChatViewModel
        let store: ConciergeSessionStore
        var authSubscription: AnyCancellable?
        var replyLatch: ReplyLatch?
        init(owner: ConciergeViewModel, viewModel: ChatViewModel, store: ConciergeSessionStore) {
            self.owner = owner
            self.viewModel = viewModel
            self.store = store
        }
        var isCurrent: Bool {
            !Task.isCancelled && viewModel.isAuthenticated && owner?.activeRun === self
        }
        func bailOffline() {
            guard isCurrent else { return }
            owner?.bailedOffline = true
            owner?.state = .error(ConciergeViewModel.offlineBailMessage)
        }
        func ready(_ info: Identity) {
            guard isCurrent else { return }
            viewModel.registerConciergeSession(info.sessionId)
            store.cache(sessionId: info.sessionId, path: info.path)
            owner?.state = .ready(sessionId: info.sessionId, path: info.path)
        }
        func mayContinue(after result: WaitResult) -> Bool {
            guard isCurrent else { return false }
            switch result {
            case .offline: bailOffline(); return false
            case .stopped: return false
            case .timeout, .reply: return true
            }
        }
    }

    deinit { flowTask?.cancel() }

    func start(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        guard !hasStarted, viewModel.isAuthenticated else { return }
        hasStarted = true
        bailedOffline = false
        state = .loading
        let run = Run(owner: self, viewModel: viewModel, store: store)
        activeRun = run
        // Start was checked synchronously above; ignore only this initial value.
        run.authSubscription = viewModel.$isAuthenticated.dropFirst().sink { [weak self] authenticated in
            if !authenticated { self?.cancelFlow() }
        }
        flowTask = Task { @MainActor in await Self.runFlow(run) }
    }
    private func cancelFlow() {
        flowTask?.cancel()
        flowTask = nil
        activeRun?.authSubscription?.cancel()
        activeRun = nil
        hasStarted = false
    }
    private func finished(_ run: Run) {
        guard activeRun === run else { return }
        activeRun = nil
        flowTask = nil
    }
    func retry(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        cancelFlow()
        start(viewModel: viewModel, store: store)
    }
    func retryIfBailedOffline(viewModel: ChatViewModel, store: ConciergeSessionStore) {
        guard bailedOffline, viewModel.connectionState == .connected else { return }
        retry(viewModel: viewModel, store: store)
    }

    func recoverIfConversationMissing(
        _ frame: WSIncoming,
        viewModel: ChatViewModel,
        store: ConciergeSessionStore
    ) {
        guard case .ready(let currentSessionId, _) = state,
              case .error(let message, let failedSessionId) = frame,
              failedSessionId == currentSessionId,
              message.localizedCaseInsensitiveContains("no conversation found with session id") else {
            return
        }

        cancelFlow()
        hasStarted = true
        bailedOffline = false
        state = .loading

        let run = Run(owner: self, viewModel: viewModel, store: store)
        activeRun = run
        run.authSubscription = viewModel.$isAuthenticated.dropFirst().sink { [weak self] authenticated in
            if !authenticated { self?.cancelFlow() }
        }
        flowTask = Task { @MainActor in
            await Self.replaceMissingConversation(
                currentSessionId,
                run: run
            )
        }
    }

    private static func waitForSocketConnected(_ run: Run) async -> Bool {
        if run.viewModel.connectionState == .connected { return true }
        let result: Bool? = await withTimeout(.seconds(5)) {
            for await state in run.viewModel.$connectionState.values {
                guard !Task.isCancelled else { return nil }
                switch state {
                case .connected: return true
                case .disconnected where run.viewModel.hasRequestedConnection
                    && run.viewModel.connectionState == .disconnected: return false
                case .disconnected, .connecting, .reconnecting: continue
                }
            }
            return nil
        }
        return result == true || run.viewModel.connectionState == .connected
    }
    private static func request(
        _ run: Run, timeout: Duration,
        match: @escaping (WSIncoming) -> Reply?,
        send: () -> Bool
    ) async -> WaitResult {
        guard run.isCurrent else { return .stopped }
        let latch = ReplyLatch(incoming: run.viewModel.incoming, match: match)
        run.replyLatch = latch
        defer {
            latch.cancel()
            if run.replyLatch === latch { run.replyLatch = nil }
        }
        guard run.isCurrent else { return .stopped }
        // There is NO await between subscription installation and this request.
        guard send() else { return .offline }
        let reply: Reply? = await withTimeout(timeout) {
            for await value in latch.relay.values {
                guard !Task.isCancelled else { return nil }
                if let value { return value }
            }
            return nil
        }
        guard run.isCurrent else { return .stopped }
        if let reply { return .reply(reply) }
        return run.viewModel.connectionState == .connected ? .timeout : .offline
    }
    private static func resume(_ identity: Identity, run: Run) async -> WaitResult {
        guard run.isCurrent else { return .stopped }
        // Metadata is available to the real handler BEFORE the response arrives.
        run.viewModel.registerConciergeSession(identity.sessionId)
        return await request(run, timeout: .seconds(3), match: { frame in
            guard case .sessionInfo(let id, let path, _) = frame,
                  id == identity.sessionId, !path.isEmpty else { return nil }
            return .info(Identity(sessionId: id, path: path))
        }, send: {
            run.viewModel.resumeSession(sessionId: identity.sessionId, path: identity.path)
        })
    }

    private static func replaceMissingConversation(_ sessionId: String, run: Run) async {
        defer {
            run.authSubscription?.cancel()
            run.authSubscription = nil
            run.owner?.finished(run)
        }
        guard run.isCurrent else { return }

        let cleared = await request(run, timeout: .seconds(3), match: { frame in
            guard case .sessionCleared(let clearedId) = frame,
                  clearedId == sessionId else { return nil }
            return .cleared
        }, send: {
            run.viewModel.requestSessionClear(sessionId: sessionId)
        })
        guard run.mayContinue(after: cleared) else { return }
        guard case .reply(.cleared) = cleared else {
            run.owner?.state = .error("Could not replace the unavailable concierge")
            return
        }
        run.store.clear()
        run.viewModel.registerConciergeSession(nil)

        let spawned = await request(run, timeout: .seconds(5), match: { frame in
            guard case .sessionInfo(let id, let path, let mode) = frame,
                  mode == .concierge, !path.isEmpty else { return nil }
            return .info(Identity(sessionId: id, path: path))
        }, send: {
            run.viewModel.newConciergeSession()
        })
        guard run.mayContinue(after: spawned) else { return }
        if case .reply(.info(let info)) = spawned {
            run.ready(info)
        } else {
            run.owner?.state = .error("Concierge did not respond in time")
        }
    }
    private static func runFlow(_ run: Run) async {
        defer {
            run.authSubscription?.cancel()
            run.authSubscription = nil
            run.owner?.finished(run)
        }
        guard run.isCurrent else { return }
        let connected = await waitForSocketConnected(run)
        guard run.isCurrent else { return }
        guard connected else { run.bailOffline(); return }

        if let cached = run.store.cachedSession {
            let result = await resume(Identity(sessionId: cached.sessionId, path: cached.path), run: run)
            guard run.mayContinue(after: result) else { return }
            if case .reply(.info(let info)) = result { run.ready(info); return }
            // Only a connected response timeout reaches this cache mutation.
            run.store.clear()
            run.viewModel.registerConciergeSession(nil)
        }

        let discovery = await request(run, timeout: .seconds(3), match: { frame in
            guard case .sessionList(let sessions) = frame else { return nil }
            let chosen = ConciergeSessionStore.pickConciergeSession(from: sessions)
            return .discovery(chosen.map { Identity(sessionId: $0.sessionId, path: $0.path) })
        }, send: { run.viewModel.listSessions() })
        guard run.mayContinue(after: discovery) else { return }
        if case .reply(.discovery(let match)) = discovery, let match {
            let result = await resume(match, run: run)
            guard run.mayContinue(after: result) else { return }
            if case .reply(.info(let info)) = result { run.ready(info); return }
            run.viewModel.registerConciergeSession(nil)
        }

        let spawned = await request(run, timeout: .seconds(5), match: { frame in
            guard case .sessionInfo(let id, let path, let mode) = frame,
                  mode == .concierge, !path.isEmpty else { return nil }
            return .info(Identity(sessionId: id, path: path))
        }, send: { run.viewModel.newConciergeSession() })
        guard run.mayContinue(after: spawned) else { return }
        if case .reply(.info(let info)) = spawned { run.ready(info); return }
        run.owner?.state = .error("Concierge did not respond in time")
    }
}
