import Foundation
import SwiftData
import SwiftUI
import Combine
import os

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messageText = ""
    @Published var sessionStatuses: [String: String] = [:]
    @Published var sessionToolNames: [String: String] = [:]

    func statusFor(_ sessionId: String) -> String {
        sessionStatuses[sessionId] ?? "idle"
    }

    func toolNameFor(_ sessionId: String) -> String? {
        sessionToolNames[sessionId]
    }
    @Published var currentPath: String = ""
    @Published var currentSessionId: String?
    @Published var pendingApprovals: [String: ToolApproval] = [:]
    @Published var isAuthenticated = true
    var onUnpair: (() -> Void)?
    @Published var browseEntries: [BrowseEntry] = []
    @Published var browsePath: String = ""
    @Published var browseError: String?
    private var isBrowsePending = false
    @Published var serverSessions: [ServerSession] = []
    @Published var workspaceSessions: [WorkspaceSession] = []
    enum PendingReason: Equatable { case busy, offline }
    /// Message id → why it has not gone out yet. Replaces the old id set; the
    /// bubble badge reads "waiting" for `.busy` and "not sent" for `.offline`.
    @Published private(set) var pendingReasons: [String: PendingReason] = [:]
    @Published var pendingAttachment: AttachmentData?
    /// Mirrors `socket.$state`; views observe this, never `socket` directly.
    @Published private(set) var connectionState: BeekeeperSocket.State = .disconnected
    /// Banner-consumed. Auto-clears after `lastErrorAutoClear` or on tap (set to nil).
    @Published var lastError: UserFacingError? {
        didSet {
            lastErrorTimer?.cancel()
            lastErrorTimer = nil
            guard let id = lastError?.id else { return }
            let delay = lastErrorAutoClear
            lastErrorTimer = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.lastError?.id == id else { return }
                self.lastError = nil
            }
        }
    }
    /// True once `configure()` or `reconnect()` has asked the socket to connect. Lets
    /// the concierge coordinator tell the cold initial `.disconnected` from a failed one.
    private(set) var hasRequestedConnection = false

    static let channel = "beekeeper"

    let socket: BeekeeperSocket
    let speechManager = SpeechManager()
    private let credentials: CredentialStore
    private var frameSubscription: AnyCancellable?
    private var stateSubscription: AnyCancellable?     // sibling of frameSubscription; no Set here
    private var lastErrorTimer: Task<Void, Never>?
    private let lastErrorAutoClear: Duration
    var autoReadAloud = false
    private var modelContext: ModelContext?
    private var streamingMessageIds: [String: String] = [:]
    private var lastCompletedMessageIds: [String: String] = [:]
    private struct PendingMessage {
        /// The trimmed input text — empty for an attachment-only send. Not
        /// `effectiveText` (the attachment name), which the `Message` row keeps for
        /// display; sending it would emit a text frame the direct path never did.
        let text: String
        let messageId: String
        var sessionId: String
        let attachment: AttachmentData?
    }
    /// Ordered queue for both `.busy` and `.offline` entries; `pendingReasons` mirrors it.
    private var pendingMessages: [PendingMessage] = []
    private var queueReleasePendingIdle: Set<String> = []
    private var releasedBeforeReconnectSync: Set<String> = []
    var queuedAttachmentCountForTesting: Int {
        pendingMessages.filter { $0.attachment != nil }.count
    }
    /// Armed on the transition into `.connected`; whichever of the next `syncSessions`
    /// and the fallback fires first clears it — exactly one reclassify + flush per reconnect.
    private var awaitingPostReconnectSync = false
    private var postReconnectFlushFallback: Task<Void, Never>?
    private static let postReconnectFlushTimeout: Duration = .seconds(5)
    private static let staleBusyTimeout: TimeInterval = 90
    private var busyTimers: [String: Task<Void, Never>] = [:]
    /// Pending `/clear` handoffs, keyed by workspace path. Populated when
    /// `context_cleared` arrives; consumed by the follow-up `session_info` for the
    /// same path which performs the atomic old→new swap (see HIVE-113).
    private struct ClearHandoff {
        let oldSessionId: String
        let oldName: String?
    }
    private var pendingClearHandoffs: [String: ClearHandoff] = [:]

    struct ToolApproval: Identifiable {
        let id: String  // toolUseId
        let tool: String
        let input: String
        let sessionId: String?
    }

    init(
        socket: BeekeeperSocket? = nil,
        credentials: CredentialStore = KeychainCredentialStore(),
        lastErrorAutoClear: Duration = .seconds(6)
    ) {
        self.socket = socket ?? BeekeeperSocket(config: .standard, credentials: credentials)
        self.credentials = credentials
        self.lastErrorAutoClear = lastErrorAutoClear
        // Subscribed in init, not configure, so Settings and the list views observe
        // truth before configure runs and independently of it.
        stateSubscription = self.socket.$state.sink { [weak self] state in
            self?.handleSocketState(state)
        }
    }

    func configure(context: ModelContext) {
        self.modelContext = context
        frameSubscription = socket.frames.sink { [weak self] data in
            self?.handleFrame(data)
        }
        socket.onAuthFailure = { [weak self] in
            self?.unpair()
        }
        socket.onConnected = { [weak self] in
            self?.listSessions()
        }
        hasRequestedConnection = true
        socket.connect(channel: Self.channel)
    }

    // MARK: - Connection

    func reconnect() {
        hasRequestedConnection = true
        socket.connect(channel: Self.channel)
    }

    func disconnect() {
        socket.disconnect()
    }

    // MARK: - Connection state

    private func handleSocketState(_ state: BeekeeperSocket.State) {
        let previous = connectionState
        connectionState = state
        // NEVER call socket.send from here: @Published emits on willSet, so the socket's
        // own send gate still reads the previous state during this call. Beekeeper
        // flushes on the post-reconnect session_list (or the fallback below).
        if state == .connected, previous != .connected {
            awaitingPostReconnectSync = true
            postReconnectFlushFallback?.cancel()
            postReconnectFlushFallback = Task { [weak self] in
                try? await Task.sleep(for: Self.postReconnectFlushTimeout)
                guard !Task.isCancelled, let self else { return }
                // Clear the flag and the handle FIRST so a session_list that lands later is an
                // ordinary sync and a fired task is never cancelled or mistaken for pending.
                self.awaitingPostReconnectSync = false
                self.postReconnectFlushFallback = nil
                self.flushOfflineQueue(skipping: [])
            }
        } else if state != .connected, previous == .connected {
            postReconnectFlushFallback?.cancel()
            postReconnectFlushFallback = nil
            awaitingPostReconnectSync = false
            // Queued entries stay; nothing else.
        }
    }

    /// Encodes and forwards. Returns `false` when the socket is not connected;
    /// child B queues on that signal.
    @discardableResult
    func send(_ outgoing: WSOutgoing) -> Bool {
        guard let data = try? outgoing.encode() else {
            Log.chat.error("failed to encode outgoing frame")
            return false
        }
        return socket.send(data)
    }

    private func handleFrame(_ data: Data) {
        let incoming = WSIncoming.decode(from: data)
            ?? .unknown(raw: String(decoding: data, as: UTF8.self))
        handleIncoming(incoming)
    }

    func sendText() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingAttachment
        guard !text.isEmpty || attachment != nil, let context = modelContext, let sessionId = currentSessionId else { return }

        let effectiveText = text.isEmpty ? (attachment?.name ?? "") : text
        let message = Message(
            sessionId: sessionId,
            text: effectiveText,
            role: "user",
            attachmentName: attachment?.name,
            attachmentType: attachment?.mimeType,
            attachmentData: attachment?.data
        )
        context.insert(message)
        try? context.save()

        let entry = PendingMessage(text: text, messageId: message.id, sessionId: sessionId, attachment: attachment)
        if connectionState != .connected {
            enqueue(entry, reason: .offline)
        } else if statusFor(sessionId) != "idle" {
            enqueue(entry, reason: .busy)
        } else {
            sendToServer(entry)   // a `false` re-enqueues at the head as .offline
        }
        messageText = ""
        speechManager.liveText = ""
        pendingAttachment = nil
    }

    func cancelCurrentOperation(for sessionId: String) {
        send(.cancel(sessionId: sessionId))
        clearPendingMessages(for: sessionId)
    }

    func newSession(path: String) {
        send(.newSession(path: path))
    }

    func clearSession(sessionId: String) {
        send(.clearSession(sessionId: sessionId))
        deleteLocalSession(sessionId: sessionId)
    }

    func listSessions() {
        send(.listSessions)
    }

    func listWorkspaceSessions(path: String) {
        workspaceSessions = []
        send(.listWorkspaceSessions(path: path))
    }

    func resumeSession(sessionId: String, path: String) {
        send(.resumeSession(sessionId: sessionId, path: path))
    }

    func browse(path: String? = nil) {
        browseError = nil
        // Only arm the pending flag when the frame actually went out — a dropped
        // send (socket not connected) must not leave `isBrowsePending` stuck true,
        // or a later unrelated `error` frame with a nil sessionId gets misattributed
        // to this browse (see the `.error` case in `handleIncoming`).
        isBrowsePending = send(.browse(path: path))
    }

    func approve(toolUseId: String, sessionId: String) {
        send(.approve(toolUseId: toolUseId))
        pendingApprovals[sessionId] = nil
    }

    func deny(toolUseId: String, sessionId: String) {
        send(.deny(toolUseId: toolUseId))
        pendingApprovals[sessionId] = nil
    }

    func unpair() {
        socket.disconnect()
        pendingMessages.removeAll()
        pendingReasons.removeAll()
        postReconnectFlushFallback?.cancel()
        postReconnectFlushFallback = nil
        awaitingPostReconnectSync = false
        queueReleasePendingIdle.removeAll()
        releasedBeforeReconnectSync.removeAll()
        onUnpair?()
        credentials.clearAll()
        isAuthenticated = false
    }

    // MARK: - Private

    private func handleIncoming(_ incoming: WSIncoming) {
        guard let context = modelContext else { return }

        switch incoming {
        case .message(let text, let sessionId, let final):
            handleStreamingMessage(text: text, sessionId: sessionId, final: final, context: context)

        case .toolApproval(let toolUseId, let tool, let input, let sessionId):
            guard let effectiveSessionId = sessionId ?? currentSessionId else {
                send(.deny(toolUseId: toolUseId))
                return
            }
            if let sessionId, sessionId != currentSessionId {
                currentSessionId = sessionId
            }
            pendingApprovals[effectiveSessionId] = ToolApproval(id: toolUseId, tool: tool, input: input, sessionId: sessionId)

        case .status(let state, let sessionId, let toolName):
            let effectiveId = sessionId ?? currentSessionId
            if let effectiveId {
                sessionStatuses[effectiveId] = state

                // Store or clear tool name based on state
                if state == "tool_running" || state == "tool_starting" {
                    if let toolName {
                        sessionToolNames[effectiveId] = toolName
                    } else {
                        sessionToolNames.removeValue(forKey: effectiveId)
                    }
                } else {
                    sessionToolNames.removeValue(forKey: effectiveId)
                }

                // Clear streaming ID on round boundaries so the next
                // streaming segment creates a new message bubble.
                if state == "thinking" || state == "tool_starting" || state == "tool_running" {
                    streamingMessageIds.removeValue(forKey: effectiveId)
                }

                // Stale-busy watchdog
                if state != "idle" && state != "session_ended" {
                    busyTimers[effectiveId]?.cancel()
                    busyTimers[effectiveId] = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(Self.staleBusyTimeout))
                        guard !Task.isCancelled else { return }
                        self?.sessionStatuses[effectiveId] = "idle"
                        self?.flushNextPendingMessage(for: effectiveId)
                    }
                } else {
                    // Covers both idle and session_ended — cancel any active watchdog
                    busyTimers[effectiveId]?.cancel()
                    busyTimers.removeValue(forKey: effectiveId)
                }

                // Flush next pending message when session becomes idle
                if state == "idle" && pendingMessages.contains(where: { $0.sessionId == effectiveId }) {
                    flushNextPendingMessage(for: effectiveId)
                }

                if state == "session_ended" {
                    endSession(effectiveId)
                }
            }

        case .sessionInfo(let sessionId, let path, let mode):
            // Concierge slots (KPR-204): don't add to the SwiftData Session table
            // and don't add to workspace history. Concierge is owned by
            // ConciergeSessionStore + BeekeeperRootView; it has its own dedicated
            // tab and shouldn't appear in the Sessions list. Detect via either
            // wire `mode == "concierge"` (correct path for new slots) OR the
            // locally-cached concierge id (fallback for slots persisted server-
            // side before KPR-203 — those report `mode: "sessions"` because
            // restoreSessions defaults missing-mode to "sessions").
            // We still update currentSessionId/currentPath/sessionStatuses so
            // ConciergeViewModel can detect arrival via its Combine observation
            // and ChatView's status indicator works inside the concierge tab.
            let isConcierge = mode == "concierge"
                || sessionId == ConciergeSessionStore.cachedSessionId
            if isConcierge {
                currentSessionId = sessionId
                currentPath = path
                sessionStatuses[sessionId] = "idle"
                break
            }

            // If a /clear handoff for this path is pending (HIVE-113), perform the
            // atomic swap: insert the new Session *first* so the sidebar @Query
            // always has at least one row for this slot, flip currentSessionId so
            // view navigation follows, then delete the old row. This keeps the
            // chat screen mounted throughout the handoff.
            let handoff = pendingClearHandoffs.removeValue(forKey: path)
            let existingDescriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == sessionId }
            )
            if let existing = try? context.fetch(existingDescriptor).first {
                existing.path = path
                existing.isStale = false
                if let handoff, existing.name == nil {
                    existing.name = handoff.oldName
                }
            } else {
                let session = Session(id: sessionId, path: path, name: handoff?.oldName)
                context.insert(session)
            }
            try? context.save()
            currentSessionId = sessionId
            currentPath = path
            sessionStatuses[sessionId] = "idle"
            if let handoff {
                // Now delete the old (already-wiped) Session row.
                let oldId = handoff.oldSessionId
                let oldDescriptor = FetchDescriptor<Session>(
                    predicate: #Predicate { $0.id == oldId }
                )
                if let oldRow = try? context.fetch(oldDescriptor).first {
                    context.delete(oldRow)
                    try? context.save()
                }
            }
            saveWorkspace(path: path, context: context)

        case .sessionList(let sessions):
            // Keep the full list on serverSessions — ConciergeViewModel filters
            // by mode == "concierge" against this. For the SwiftData Session
            // table (which drives the Sessions tab), exclude concierge rows.
            // Detect via wire mode OR the cached concierge id (fallback for
            // server-side mode classification bugs, e.g. KPR-203 slots persisted
            // by v1.6.0 that restored with mode defaulted to "sessions").
            serverSessions = sessions
            var conciergeIds = Set(sessions.filter { $0.mode == "concierge" }.map(\.sessionId))
            if let cachedConciergeId = ConciergeSessionStore.cachedSessionId {
                conciergeIds.insert(cachedConciergeId)
            }
            if !conciergeIds.isEmpty {
                let descriptor = FetchDescriptor<Session>()
                if let localRows = try? context.fetch(descriptor) {
                    for row in localRows where conciergeIds.contains(row.id) {
                        context.delete(row)
                    }
                    try? context.save()
                }
            }
            let sessionsTabOnly = sessions.filter { row in
                row.mode == "sessions" && !conciergeIds.contains(row.sessionId)
            }
            // The absent-id check needs the FULL reply, not the Sessions-tab filter,
            // or the concierge slot (never in the Session table) is reaped every list.
            syncSessions(serverSessions: sessionsTabOnly,
                         allServerIds: Set(sessions.map(\.sessionId)),
                         context: context)

        case .sessionCleared(let sessionId):
            deleteLocalSession(sessionId: sessionId)
            if sessionId == currentSessionId {
                currentSessionId = nil
            }

        case .browseResult(let path, let entries):
            isBrowsePending = false
            browsePath = path
            browseEntries = entries
            listWorkspaceSessions(path: path)

        case .workspaceSessionList(_, let sessions):
            workspaceSessions = sessions

        case .contextCleared(let oldSessionId, _):
            // /clear handoff phase 1 (HIVE-113): wipe messages + per-session state
            // for the old session, but *keep* the Session row and leave
            // currentSessionId untouched so the chat screen stays mounted with its
            // title/input bar intact. Phase 2 (the atomic row swap + navigation
            // handoff) happens in `.sessionInfo` when the server hands back the new
            // session id for the same workspace path.
            //
            // Note: the server sends oldSessionId == sessionId here — both fields
            // carry the OLD id. The real new id only arrives via session_info.
            let sessionDescriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == oldSessionId }
            )
            let oldSession = try? context.fetch(sessionDescriptor).first
            if let oldSession {
                pendingClearHandoffs[oldSession.path] = ClearHandoff(
                    oldSessionId: oldSessionId,
                    oldName: oldSession.name
                )
            }
            // Wipe messages for the old session.
            let msgDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.sessionId == oldSessionId }
            )
            if let messages = try? context.fetch(msgDescriptor) {
                for msg in messages { context.delete(msg) }
                try? context.save()
            }
            // Clear per-session transient state.
            streamingMessageIds.removeValue(forKey: oldSessionId)
            lastCompletedMessageIds.removeValue(forKey: oldSessionId)
            sessionStatuses.removeValue(forKey: oldSessionId)
            sessionToolNames.removeValue(forKey: oldSessionId)
            pendingApprovals.removeValue(forKey: oldSessionId)
            busyTimers[oldSessionId]?.cancel()
            busyTimers.removeValue(forKey: oldSessionId)
            clearPendingMessages(for: oldSessionId)

        case .sessionReplaced(let oldSessionId, let newSessionId, let path):
            // Single-phase atomic swap: the server replaced one session with
            // another at the same workspace path. Unlike context_cleared (which
            // is two-phase), we get everything in one message.
            //
            // 1. Insert (or update) the new Session row first so the sidebar
            //    @Query always has a row for this slot.
            let oldSessDescriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == oldSessionId }
            )
            let oldSession = try? context.fetch(oldSessDescriptor).first
            let preservedName = oldSession?.name

            let existingNewDescriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == newSessionId }
            )
            if let existingNew = try? context.fetch(existingNewDescriptor).first {
                existingNew.path = path
                existingNew.isStale = false
                if existingNew.name == nil { existingNew.name = preservedName }
            } else {
                let newSession = Session(id: newSessionId, path: path, name: preservedName)
                context.insert(newSession)
            }
            try? context.save()

            // 2. Migrate messages from old → new session ID so the user keeps
            //    their conversation history.
            let msgDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.sessionId == oldSessionId }
            )
            if let messages = try? context.fetch(msgDescriptor) {
                for msg in messages { msg.sessionId = newSessionId }
                try? context.save()
            }

            // 3. Flip currentSessionId so the view navigation follows.
            if currentSessionId == oldSessionId {
                currentSessionId = newSessionId
            }
            currentPath = path

            // 4. Migrate transient per-session state.
            if let streamId = streamingMessageIds.removeValue(forKey: oldSessionId) {
                streamingMessageIds[newSessionId] = streamId
            }
            if let completedId = lastCompletedMessageIds.removeValue(forKey: oldSessionId) {
                lastCompletedMessageIds[newSessionId] = completedId
            }
            if let status = sessionStatuses.removeValue(forKey: oldSessionId) {
                sessionStatuses[newSessionId] = status
            }
            if let toolName = sessionToolNames.removeValue(forKey: oldSessionId) {
                sessionToolNames[newSessionId] = toolName
            }
            if let approval = pendingApprovals.removeValue(forKey: oldSessionId) {
                pendingApprovals[newSessionId] = approval
            }
            if let timer = busyTimers.removeValue(forKey: oldSessionId) {
                timer.cancel()
                busyTimers.removeValue(forKey: newSessionId)
            }

            // Migrate queued pending messages.
            for i in pendingMessages.indices where pendingMessages[i].sessionId == oldSessionId {
                pendingMessages[i].sessionId = newSessionId
            }

            // 5. Delete the old Session row.
            if let oldSession {
                context.delete(oldSession)
                try? context.save()
            }

            saveWorkspace(path: path, context: context)

        case .error(let message, let sessionId):
            if let sessionId {
                let msg = Message(sessionId: sessionId, text: "Error: \(message)", role: "system")
                context.insert(msg)
                try? context.save()
            } else if isBrowsePending {
                isBrowsePending = false
                browseError = message                    // the picker shows it inline; no banner
            } else {
                lastError = UserFacingError(message)     // no more bubble in whichever session is current
            }

        case .pong:
            break

        case .toolOutput(let toolName, let output, _, let sessionId):
            let msg = Message(sessionId: sessionId, text: "[\(toolName)]\n\(output)", role: "tool")
            context.insert(msg)
            try? context.save()

        case .unknown(let raw):
            let targetSessionId = currentSessionId ?? "unknown"
            let msg = Message(sessionId: targetSessionId, text: raw, role: "unknown")
            context.insert(msg)
            try? context.save()
        }
    }

    // MARK: - Private: busy / offline queue

    private func enqueue(_ entry: PendingMessage, reason: PendingReason, atFront: Bool = false) {
        if atFront {
            pendingMessages.insert(entry, at: 0)
        } else {
            pendingMessages.append(entry)
        }
        pendingReasons[entry.messageId] = reason
    }

    /// Sends the entry's frames in order (text if non-empty, then image/file). The
    /// first `false` from the socket re-enqueues the whole entry at the head of the
    /// queue as `.offline` and returns `false`. The socket's gate is read synchronously
    /// on the main actor, so a later frame cannot fail after an earlier one succeeded;
    /// partial re-sends do not occur.
    @discardableResult
    private func sendToServer(_ entry: PendingMessage) -> Bool {
        var frames: [WSOutgoing] = []
        if !entry.text.isEmpty {
            frames.append(.message(text: entry.text, sessionId: entry.sessionId))
        }
        if let attachment = entry.attachment {
            let base64 = attachment.data.base64EncodedString()
            if attachment.mimeType.hasPrefix("image/") {
                frames.append(.image(sessionId: entry.sessionId, data: base64, filename: attachment.name))
            } else {
                frames.append(.file(sessionId: entry.sessionId, data: base64, filename: attachment.name, mimetype: attachment.mimeType))
            }
        }
        for frame in frames {
            guard send(frame) else {
                enqueue(entry, reason: .offline, atFront: true)
                return false
            }
        }
        return true
    }

    private func flushNextPendingMessage(for sessionId: String) {
        guard let index = pendingMessages.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        let entry = pendingMessages.remove(at: index)
        pendingReasons.removeValue(forKey: entry.messageId)
        sendToServer(entry)   // on `false` the entry is back at the head with reason .offline
    }

    private func clearPendingMessages(for sessionId: String) {
        let removed = pendingMessages.filter { $0.sessionId == sessionId }
        guard !removed.isEmpty else { return }
        pendingMessages.removeAll { $0.sessionId == sessionId }
        for entry in removed {
            pendingReasons.removeValue(forKey: entry.messageId)
        }
    }

    private func reclassifyOfflineAsBusy() {
        guard pendingReasons.values.contains(.offline) else { return }
        pendingReasons = pendingReasons.mapValues { $0 == .offline ? .busy : $0 }
    }

    /// Post-reconnect flush: one head per idle session that `syncSessions` did not
    /// already flush, in first-appearance order. The existing one-in-flight rule
    /// (`.status("idle")` flushes the next) drains the rest.
    private func flushOfflineQueue(skipping flushed: Set<String>) {
        reclassifyOfflineAsBusy()   // no-op on the sync path; real work on the fallback path
        var seen = Set<String>()
        for sessionId in pendingMessages.map(\.sessionId) where seen.insert(sessionId).inserted {
            guard statusFor(sessionId) == "idle", !flushed.contains(sessionId) else { continue }
            flushNextPendingMessage(for: sessionId)
        }
    }

    /// The `session_ended` cleanup, shared by the status frame and the absent-id check
    /// in `syncSessions` (child C's watchdog relies on the latter).
    private func endSession(_ sessionId: String) {
        streamingMessageIds.removeValue(forKey: sessionId)
        pendingApprovals.removeValue(forKey: sessionId)
        sessionStatuses.removeValue(forKey: sessionId)
        sessionToolNames.removeValue(forKey: sessionId)
        busyTimers[sessionId]?.cancel()
        busyTimers.removeValue(forKey: sessionId)
        clearPendingMessages(for: sessionId)
    }

    private func handleStreamingMessage(text: String, sessionId: String, final: Bool, context: ModelContext) {
        if final {
            if !text.isEmpty, let existingId = streamingMessageIds[sessionId] {
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate { $0.id == existingId }
                )
                if let msg = try? context.fetch(descriptor).first {
                    msg.text += text
                    try? context.save()
                }
            } else if !text.isEmpty {
                // Single-shot final message (e.g. AskUserQuestion) — no prior chunks existed
                let msg = Message(sessionId: sessionId, text: text, role: "assistant")
                context.insert(msg)
                try? context.save()
                streamingMessageIds[sessionId] = msg.id
            }
            if autoReadAloud, let completedId = streamingMessageIds[sessionId] ?? lastCompletedMessageIds[sessionId] {
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate { $0.id == completedId }
                )
                if let msg = try? context.fetch(descriptor).first, msg.role == "assistant" {
                    speechManager.speak(msg.text)
                }
            }
            lastCompletedMessageIds[sessionId] = streamingMessageIds[sessionId]
            streamingMessageIds[sessionId] = nil
            return
        }

        if let existingId = streamingMessageIds[sessionId] {
            let descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.id == existingId }
            )
            if let msg = try? context.fetch(descriptor).first {
                msg.text += text
                try? context.save()
            }
        } else {
            let msg = Message(sessionId: sessionId, text: text, role: "assistant")
            context.insert(msg)
            try? context.save()
            streamingMessageIds[sessionId] = msg.id
        }
    }

    private func syncSessions(serverSessions: [ServerSession], allServerIds: Set<String>, context: ModelContext) {
        let serverIds = Set(serverSessions.map(\.sessionId))

        let descriptor = FetchDescriptor<Session>()
        guard let localSessions = try? context.fetch(descriptor) else { return }

        // B insertion 1 of 3 — post-reconnect reclassify (§4). Exactly one pass per
        // reconnect: whichever of this sync and the 5 s fallback fires first clears the flag.
        // Below the fetch guard on purpose: a failed fetch returns early and leaves the flag
        // armed, so the fallback still gets its single flush pass instead of consuming it here.
        let isPostReconnectSync = awaitingPostReconnectSync
        if isPostReconnectSync {
            awaitingPostReconnectSync = false
            postReconnectFlushFallback?.cancel()
            postReconnectFlushFallback = nil
            reclassifyOfflineAsBusy()
        }

        for local in localSessions {
            let wasStale = local.isStale
            local.isStale = !serverIds.contains(local.id)
            if local.isStale && !wasStale {
                streamingMessageIds[local.id] = nil
                lastCompletedMessageIds[local.id] = nil
                sessionToolNames.removeValue(forKey: local.id)
                busyTimers[local.id]?.cancel()
                busyTimers.removeValue(forKey: local.id)
            }
        }

        // B insertion 2 of 3 — absent-id cleanup (§5), against the FULL reply so the
        // concierge slot is never reaped. Queued messages for any absent session are
        // dropped; a non-idle absent session gets the full session_ended cleanup.
        let knownIds = Set(sessionStatuses.keys).union(pendingMessages.map(\.sessionId))
        for id in knownIds where !allServerIds.contains(id) {
            if statusFor(id) != "idle" {
                endSession(id)
            } else {
                clearPendingMessages(for: id)
            }
        }

        let localIds = Set(localSessions.map(\.id))
        for server in serverSessions where !localIds.contains(server.sessionId) {
            let session = Session(id: server.sessionId, path: server.path)
            context.insert(session)
        }

        // Reconcile session statuses from server state
        var flushed = Set<String>()
        for server in serverSessions {
            let serverState = server.state  // "idle" or "busy"
            let clientState = sessionStatuses[server.sessionId]
            if clientState != nil && clientState != "idle" && serverState == "idle" {
                sessionStatuses[server.sessionId] = "idle"
                busyTimers[server.sessionId]?.cancel()
                busyTimers.removeValue(forKey: server.sessionId)
                flushNextPendingMessage(for: server.sessionId)
                flushed.insert(server.sessionId)
            } else if clientState == nil || clientState == "idle" {
                sessionStatuses[server.sessionId] = serverState
                // Start watchdog if adopting a non-idle state from the server
                if serverState != "idle" {
                    busyTimers[server.sessionId]?.cancel()
                    busyTimers[server.sessionId] = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(Self.staleBusyTimeout))
                        guard !Task.isCancelled else { return }
                        self?.sessionStatuses[server.sessionId] = "idle"
                        self?.flushNextPendingMessage(for: server.sessionId)
                    }
                }
            }
        }

        try? context.save()

        if let currentSessionId, localSessions.first(where: { $0.id == currentSessionId })?.isStale == true {
            self.currentSessionId = nil
        }

        // B insertion 3 of 3 — post-loop flush (§4), only on the sync that cleared the flag.
        if isPostReconnectSync {
            flushOfflineQueue(skipping: flushed)
        }
    }

    private func deleteLocalSession(sessionId: String) {
        guard let context = modelContext else { return }

        streamingMessageIds[sessionId] = nil
        lastCompletedMessageIds[sessionId] = nil
        sessionToolNames.removeValue(forKey: sessionId)
        busyTimers[sessionId]?.cancel()
        busyTimers.removeValue(forKey: sessionId)

        let msgDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        if let messages = try? context.fetch(msgDescriptor) {
            for msg in messages { context.delete(msg) }
        }

        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == sessionId }
        )
        if let session = try? context.fetch(sessionDescriptor).first {
            context.delete(session)
        }

        try? context.save()
    }

    private func saveWorkspace(path: String, context: ModelContext) {
        let maxRecent = 5
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.path == path }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.lastUsed = .now
        } else {
            let workspace = Workspace(path: path)
            context.insert(workspace)
        }

        // Prune old workspaces beyond the limit
        var allDescriptor = FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\Workspace.lastUsed, order: .reverse)]
        )
        allDescriptor.fetchOffset = maxRecent
        if let stale = try? context.fetch(allDescriptor) {
            for workspace in stale {
                context.delete(workspace)
            }
        }

        try? context.save()
    }
}
