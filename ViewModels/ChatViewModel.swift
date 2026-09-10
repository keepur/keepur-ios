import Foundation
import SwiftData
import SwiftUI
import Combine
import os

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messageText = ""
    @Published var sessionStatuses: [String: SessionStatus] = [:]
    @Published var sessionToolNames: [String: String] = [:]

    func statusFor(_ sessionId: String) -> SessionStatus {
        sessionStatuses[sessionId] ?? .idle
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

    private let socket: BeekeeperSocket
    let incoming = PassthroughSubject<WSIncoming, Never>()
    private var storedSpeech: SpeechManager?
    private let credentials: CredentialStore
    private var frameSubscription: AnyCancellable?
    private var stateSubscription: AnyCancellable?     // sibling of frameSubscription; no Set here
    private var lastErrorTimer: Task<Void, Never>?
    private let staleBusyTimeout: Duration
    private let lastErrorAutoClear: Duration
    private let saveOperation: (ModelContext) throws -> Void
    private let sessionFetchOperation: (ModelContext, FetchDescriptor<Session>) throws -> [Session]
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
    private struct BusyWatch {
        let token: UUID
        let task: Task<Void, Never>
    }
    private var busyTimers: [String: BusyWatch] = [:]
    private var knownConciergeSessionId: String?
    /// Pending `/clear` handoffs, keyed by workspace path. Populated when
    /// `context_cleared` arrives; consumed by the follow-up `session_info` for the
    /// same path which performs the atomic old→new swap (see HIVE-113).
    private struct ClearHandoff {
        let oldSessionId: String
        let oldName: String?
    }
    private var pendingClearHandoffs: [String: ClearHandoff] = [:]

    var speechManager: SpeechManager {
        if let storedSpeech { return storedSpeech }
        let created = SpeechManager()
        storedSpeech = created
        return created
    }

    struct ToolApproval: Identifiable {
        let id: String  // toolUseId
        let tool: String
        let input: String
        let sessionId: String?
    }

    init(
        socket: BeekeeperSocket? = nil,
        credentials: CredentialStore = KeychainCredentialStore(),
        speech: SpeechManager? = nil,
        staleBusyTimeout: Duration = .seconds(90),
        lastErrorAutoClear: Duration = .seconds(6),
        saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() },
        sessionFetchOperation: @escaping (ModelContext, FetchDescriptor<Session>) throws -> [Session] = { try $0.fetch($1) }
    ) {
        self.socket = socket ?? BeekeeperSocket(config: .standard, credentials: credentials)
        self.credentials = credentials
        self.storedSpeech = speech
        self.staleBusyTimeout = staleBusyTimeout
        self.lastErrorAutoClear = lastErrorAutoClear
        self.saveOperation = saveOperation
        self.sessionFetchOperation = sessionFetchOperation
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
        if state == .connected, previous != .connected {
            queueReleasePendingIdle.removeAll()
            releasedBeforeReconnectSync.removeAll()
            awaitingPostReconnectSync = true
            postReconnectFlushFallback?.cancel()
            postReconnectFlushFallback = Task { [weak self] in
                try? await Task.sleep(for: Self.postReconnectFlushTimeout)
                guard !Task.isCancelled, let self else { return }
                let alreadyReleased = self.releasedBeforeReconnectSync
                self.awaitingPostReconnectSync = false
                self.postReconnectFlushFallback = nil
                self.releasedBeforeReconnectSync.removeAll()
                self.flushOfflineQueue(skipping: alreadyReleased)
            }
            for id in sessionStatuses.keys where isActiveBusy(id) {
                armBusyWatchdog(for: id)
            }
        } else if state != .connected {
            cancelAllBusyWatchdogs()
            if previous == .connected {
                postReconnectFlushFallback?.cancel()
                postReconnectFlushFallback = nil
                awaitingPostReconnectSync = false
                queueReleasePendingIdle.removeAll()
                releasedBeforeReconnectSync.removeAll()
                // Unsent entries survive; already submitted Chat messages are not requeued.
            }
        }
    }

    /// Encodes and forwards. Returns `false` when the socket is not connected;
    /// child B queues on that signal.
    @discardableResult
    private func send(_ outgoing: WSOutgoing) -> Bool {
        guard let data = try? outgoing.encode() else {
            Log.chat.error("failed to encode outgoing frame")
            return false
        }
        return socket.send(data)
    }

    private func handleFrame(_ data: Data) {
        let decoded = WSIncoming.decode(from: data)
            ?? .unknown(raw: String(decoding: data, as: UTF8.self))
        handleIncoming(decoded)
        incoming.send(decoded)
    }

    func sendText() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingAttachment
        guard !text.isEmpty || attachment != nil, let context = modelContext, let sessionId = currentSessionId else { return }

        let effectiveText = text.isEmpty ? (attachment?.name ?? "") : text
        let message = Message(
            sessionId: sessionId,
            text: effectiveText,
            role: MessageRole.user.rawValue,
            attachmentName: attachment?.name,
            attachmentType: attachment?.mimeType,
            attachmentData: attachment?.data
        )
        context.insert(message)
        save(context, "chat.sendText.save")

        let entry = PendingMessage(text: text, messageId: message.id, sessionId: sessionId, attachment: attachment)
        if connectionState != .connected {
            enqueue(entry, reason: .offline)
        } else if pendingMessages.contains(where: { $0.sessionId == sessionId })
                    || queueReleasePendingIdle.contains(sessionId) {
            let hasOffline = pendingMessages.contains {
                $0.sessionId == sessionId && pendingReasons[$0.messageId] == .offline
            }
            enqueue(entry, reason: hasOffline ? .offline : .busy)
        } else if statusFor(sessionId) != .idle {
            enqueue(entry, reason: .busy)
        } else {
            sendToServer(entry)
        }
        messageText = ""
        storedSpeech?.liveText = ""
        pendingAttachment = nil
    }

    func cancelCurrentOperation(for sessionId: String) {
        send(.cancel(sessionId: sessionId))
        clearPendingMessages(for: sessionId)
    }

    func newSession(path: String) {
        send(.newSession(path: path))
    }

    @discardableResult
    func clearSession(sessionId: String) -> Bool {
        let sent = requestSessionClear(sessionId: sessionId)
        deleteLocalSession(sessionId: sessionId)
        return sent
    }

    @discardableResult
    func requestSessionClear(sessionId: String) -> Bool {
        send(.clearSession(sessionId: sessionId))
    }

    @discardableResult
    func listSessions() -> Bool {
        send(.listSessions)
    }

    func listWorkspaceSessions(path: String) {
        workspaceSessions = []
        send(.listWorkspaceSessions(path: path))
    }

    @discardableResult
    func resumeSession(sessionId: String, path: String) -> Bool {
        send(.resumeSession(sessionId: sessionId, path: path))
    }

    @discardableResult
    func newConciergeSession() -> Bool {
        send(.newSessionConcierge)
    }

    /// Supplies already-known identity before a legacy resume reply is handled.
    /// It is metadata, not a request, cache write, or raw transport entry point.
    func registerConciergeSession(_ sessionId: String?) {
        knownConciergeSessionId = sessionId
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
        cancelAllBusyWatchdogs()
        knownConciergeSessionId = nil
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

    private func save(_ context: ModelContext, _ what: StaticString) {
        if context.saveReporting(what, operation: { try saveOperation(context) }) != nil {
            lastError = UserFacingError("Couldn't save. Your last change may not be kept.")
        }
    }

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
            pendingApprovals[effectiveSessionId] = ToolApproval(id: toolUseId, tool: tool, input: input, sessionId: sessionId)

        case .status(let state, let sessionId, let toolName):
            let effectiveId = sessionId ?? currentSessionId
            if let effectiveId {
                sessionStatuses[effectiveId] = state

                // Store or clear tool name based on state
                if state == .toolRunning || state == .toolStarting {
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
                if state == .thinking || state == .toolStarting || state == .toolRunning {
                    streamingMessageIds.removeValue(forKey: effectiveId)
                }

                if isActiveBusy(effectiveId) {
                    armBusyWatchdog(for: effectiveId)
                } else {
                    cancelBusyWatchdog(for: effectiveId)
                }

                // Flush next pending message when session becomes idle
                if state == .idle {
                    releaseQueuedHead(for: effectiveId)
                } else {
                    reclassifyOfflineAsBusy(for: effectiveId)
                }

                if state == .sessionEnded {
                    endSession(effectiveId)
                }
            }

        case .sessionInfo(let sessionId, let path, let mode):
            // Concierge slots (KPR-204): don't add to the SwiftData Session table
            // and don't add to workspace history. Concierge is owned by
            // ConciergeSessionStore + BeekeeperRootView; it has its own dedicated
            // tab and shouldn't appear in the Sessions list. Detect via wire
            // `mode == "concierge"` (correct path for new slots), a registered
            // request identity, or the locally-cached concierge id (fallback for
            // slots persisted server-side before KPR-203 — those report
            // `mode: "sessions"` because restoreSessions defaults missing-mode
            // to "sessions").
            // We still update currentSessionId/currentPath/sessionStatuses so
            // ConciergeViewModel can detect arrival via its Combine observation
            // and ChatView's status indicator works inside the concierge tab.
            let isConcierge = mode == .concierge
                || sessionId == knownConciergeSessionId
                || sessionId == ConciergeSessionStore.cachedSessionId
            if isConcierge {
                currentSessionId = sessionId
                currentPath = path
                sessionStatuses[sessionId] = .idle
                cancelBusyWatchdog(for: sessionId)
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
            if let existing = context.fetchOrEmpty(existingDescriptor, "chat.sessionInfo.existing.fetch").first {
                existing.path = path
                existing.isStale = false
                if let handoff, existing.name == nil {
                    existing.name = handoff.oldName
                }
            } else {
                let session = Session(id: sessionId, path: path, name: handoff?.oldName)
                context.insert(session)
            }
            save(context, "chat.sessionInfo.upsert.save")
            currentSessionId = sessionId
            currentPath = path
            sessionStatuses[sessionId] = .idle
            cancelBusyWatchdog(for: sessionId)
            if let handoff {
                // Now delete the old (already-wiped) Session row.
                let oldId = handoff.oldSessionId
                let oldDescriptor = FetchDescriptor<Session>(
                    predicate: #Predicate { $0.id == oldId }
                )
                if let oldRow = context.fetchOrEmpty(oldDescriptor, "chat.sessionInfo.old.fetch").first {
                    context.delete(oldRow)
                    save(context, "chat.sessionInfo.old.save")
                }
            }
            saveWorkspace(path: path, context: context)

        case .sessionList(let sessions):
            serverSessions = sessions
            syncSessions(serverSessions: sessions, context: context)

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
            let oldSession = context.fetchOrEmpty(sessionDescriptor, "chat.contextCleared.old.fetch").first
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
            var messageFetchFailure: Error?
            let messages = context.fetchOrEmpty(msgDescriptor, "chat.contextCleared.messages.fetch",
                                                failure: &messageFetchFailure)
            if messageFetchFailure == nil {
                for msg in messages { context.delete(msg) }
                save(context, "chat.contextCleared.messages.save")
            }
            // Clear per-session transient state.
            streamingMessageIds.removeValue(forKey: oldSessionId)
            lastCompletedMessageIds.removeValue(forKey: oldSessionId)
            sessionStatuses.removeValue(forKey: oldSessionId)
            sessionToolNames.removeValue(forKey: oldSessionId)
            pendingApprovals.removeValue(forKey: oldSessionId)
            cancelBusyWatchdog(for: oldSessionId)
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
            let oldSession = context.fetchOrEmpty(oldSessDescriptor, "chat.sessionReplaced.old.fetch").first
            let preservedName = oldSession?.name

            let existingNewDescriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == newSessionId }
            )
            if let existingNew = context.fetchOrEmpty(existingNewDescriptor, "chat.sessionReplaced.new.fetch").first {
                existingNew.path = path
                existingNew.isStale = false
                if existingNew.name == nil { existingNew.name = preservedName }
            } else {
                let newSession = Session(id: newSessionId, path: path, name: preservedName)
                context.insert(newSession)
            }
            save(context, "chat.sessionReplaced.upsert.save")

            // 2. Migrate messages from old → new session ID so the user keeps
            //    their conversation history.
            let msgDescriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.sessionId == oldSessionId }
            )
            var messageFetchFailure: Error?
            let messages = context.fetchOrEmpty(msgDescriptor, "chat.sessionReplaced.messages.fetch",
                                                failure: &messageFetchFailure)
            if messageFetchFailure == nil {
                for msg in messages { msg.sessionId = newSessionId }
                save(context, "chat.sessionReplaced.messages.save")
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
            cancelBusyWatchdog(for: oldSessionId)
            cancelBusyWatchdog(for: newSessionId)
            if isActiveBusy(newSessionId) {
                armBusyWatchdog(for: newSessionId)
            }
            if let toolName = sessionToolNames.removeValue(forKey: oldSessionId) {
                sessionToolNames[newSessionId] = toolName
            }
            if let approval = pendingApprovals.removeValue(forKey: oldSessionId) {
                pendingApprovals[newSessionId] = approval
            }
            // Migrate queued pending messages.
            for i in pendingMessages.indices where pendingMessages[i].sessionId == oldSessionId {
                pendingMessages[i].sessionId = newSessionId
            }
            if queueReleasePendingIdle.remove(oldSessionId) != nil {
                queueReleasePendingIdle.insert(newSessionId)
            }
            if releasedBeforeReconnectSync.remove(oldSessionId) != nil {
                releasedBeforeReconnectSync.insert(newSessionId)
            }

            // 5. Delete the old Session row.
            if let oldSession {
                context.delete(oldSession)
                save(context, "chat.sessionReplaced.old.save")
            }

            saveWorkspace(path: path, context: context)

        case .error(let message, let sessionId):
            if let sessionId {
                let msg = Message(sessionId: sessionId, text: "Error: \(message)", role: MessageRole.system.rawValue)
                context.insert(msg)
                save(context, "chat.error.save")
            } else if isBrowsePending {
                isBrowsePending = false
                browseError = message                    // the picker shows it inline; no banner
            } else {
                lastError = UserFacingError(message)     // no more bubble in whichever session is current
            }

        case .pong:
            break

        case .toolOutput(let toolName, let output, _, let sessionId):
            let msg = Message(sessionId: sessionId, text: "[\(toolName)]\n\(output)", role: MessageRole.tool.rawValue)
            context.insert(msg)
            save(context, "chat.toolOutput.save")

        case .unknown(let raw):
            let targetSessionId = currentSessionId ?? "unknown"
            let msg = Message(sessionId: targetSessionId, text: raw, role: MessageRole.unknown.rawValue)
            context.insert(msg)
            save(context, "chat.unknown.save")
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

    @discardableResult
    private func flushNextPendingMessage(for sessionId: String) -> Bool {
        guard connectionState == .connected, statusFor(sessionId) == .idle,
              !queueReleasePendingIdle.contains(sessionId),
              let index = pendingMessages.firstIndex(where: { $0.sessionId == sessionId }) else {
            return false
        }
        let entry = pendingMessages.remove(at: index)
        pendingReasons.removeValue(forKey: entry.messageId)
        guard sendToServer(entry) else { return false }
        queueReleasePendingIdle.insert(sessionId)
        if awaitingPostReconnectSync { releasedBeforeReconnectSync.insert(sessionId) }
        return true
    }

    private func clearPendingMessages(for sessionId: String) {
        queueReleasePendingIdle.remove(sessionId)
        releasedBeforeReconnectSync.remove(sessionId)
        let removed = pendingMessages.filter { $0.sessionId == sessionId }
        pendingMessages.removeAll { $0.sessionId == sessionId }
        for entry in removed { pendingReasons.removeValue(forKey: entry.messageId) }
    }

    private func reclassifyOfflineAsBusy(for sessionId: String) {
        guard connectionState == .connected else { return }
        for entry in pendingMessages where entry.sessionId == sessionId {
            if pendingReasons[entry.messageId] == .offline { pendingReasons[entry.messageId] = .busy }
        }
    }

    @discardableResult
    private func releaseQueuedHead(for sessionId: String) -> Bool {
        queueReleasePendingIdle.remove(sessionId)
        reclassifyOfflineAsBusy(for: sessionId)
        return flushNextPendingMessage(for: sessionId)
    }

    private func reclassifyOfflineAsBusy() {
        guard pendingReasons.values.contains(.offline) else { return }
        pendingReasons = pendingReasons.mapValues { $0 == .offline ? .busy : $0 }
    }

    private func isActiveBusy(_ id: String) -> Bool {
        statusFor(id).isActive
    }

    private func cancelBusyWatchdog(for id: String) {
        busyTimers.removeValue(forKey: id)?.task.cancel()
    }

    private func cancelAllBusyWatchdogs() {
        let watches = busyTimers.values
        busyTimers.removeAll()
        for watch in watches { watch.task.cancel() }
    }

    private func armBusyWatchdog(for id: String) {
        cancelBusyWatchdog(for: id)
        guard isAuthenticated, connectionState == .connected,
              isActiveBusy(id), staleBusyTimeout > .zero else { return }
        let token = UUID(), delay = staleBusyTimeout
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self,
                  self.busyTimers[id]?.token == token,
                  self.isAuthenticated, self.connectionState == .connected,
                  self.isActiveBusy(id) else { return }
            self.listSessions()
            guard !Task.isCancelled, self.busyTimers[id]?.token == token else { return }
            self.armBusyWatchdog(for: id)
        }
        busyTimers[id] = BusyWatch(token: token, task: task)
    }

    /// Post-reconnect flush: one head per idle session that `syncSessions` did not
    /// already flush, in first-appearance order. The existing one-in-flight rule
    /// (`.status("idle")` flushes the next) drains the rest.
    private func flushOfflineQueue(skipping flushed: Set<String>) {
        reclassifyOfflineAsBusy()   // no-op on the sync path; real work on the fallback path
        var seen = Set<String>()
        for sessionId in pendingMessages.map(\.sessionId) where seen.insert(sessionId).inserted {
            guard statusFor(sessionId) == .idle, !flushed.contains(sessionId) else { continue }
            flushNextPendingMessage(for: sessionId)
        }
    }

    /// The `session_ended` cleanup, shared by the status frame and the absent-id check
    /// in `syncSessions` (child C's watchdog relies on the latter).
    private func endSession(_ sessionId: String) {
        streamingMessageIds.removeValue(forKey: sessionId)
        lastCompletedMessageIds.removeValue(forKey: sessionId)
        pendingApprovals.removeValue(forKey: sessionId)
        sessionStatuses.removeValue(forKey: sessionId)
        sessionToolNames.removeValue(forKey: sessionId)
        cancelBusyWatchdog(for: sessionId)
        clearPendingMessages(for: sessionId)
    }

    private func handleStreamingMessage(text: String, sessionId: String, final: Bool, context: ModelContext) {
        if final {
            if !text.isEmpty, let existingId = streamingMessageIds[sessionId] {
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate { $0.id == existingId }
                )
                if let msg = context.fetchOrEmpty(descriptor, "chat.stream.final.fetch").first {
                    msg.text += text
                    save(context, "chat.stream.final.save")
                }
            } else if !text.isEmpty {
                // Single-shot final message (e.g. AskUserQuestion) — no prior chunks existed
                let msg = Message(sessionId: sessionId, text: text, role: MessageRole.assistant.rawValue)
                context.insert(msg)
                save(context, "chat.stream.single.save")
                streamingMessageIds[sessionId] = msg.id
            }
            if autoReadAloud, let completedId = streamingMessageIds[sessionId] ?? lastCompletedMessageIds[sessionId] {
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate { $0.id == completedId }
                )
                if let msg = context.fetchOrEmpty(descriptor, "chat.stream.speech.fetch").first,
                   msg.typedRole == .assistant {
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
            if let msg = context.fetchOrEmpty(descriptor, "chat.stream.append.fetch").first {
                msg.text += text
                save(context, "chat.stream.append.save")
            }
        } else {
            let msg = Message(sessionId: sessionId, text: text, role: MessageRole.assistant.rawValue)
            context.insert(msg)
            save(context, "chat.stream.first.save")
            streamingMessageIds[sessionId] = msg.id
        }
    }

    private func syncSessions(serverSessions: [ServerSession], context: ModelContext) {
        let allServerIds = Set(serverSessions.map(\.sessionId))
        var conciergeIds = Set(serverSessions.filter { $0.mode == .concierge }.map(\.sessionId))
        if let knownConciergeSessionId { conciergeIds.insert(knownConciergeSessionId) }
        if let cached = ConciergeSessionStore.cachedSessionId { conciergeIds.insert(cached) }
        let tableRows = serverSessions.filter {
            $0.mode == .sessions && !conciergeIds.contains($0.sessionId)
        }
        let tableIds = Set(tableRows.map(\.sessionId))
        var sessionFetchFailure: Error?
        let fetched = context.fetchOrEmpty(FetchDescriptor<Session>(), "chat.syncSessions.fetch",
                                           failure: &sessionFetchFailure) { descriptor in
            try sessionFetchOperation(context, descriptor)
        }
        guard sessionFetchFailure == nil else { return }

        // Snapshot every release-only identity before consuming reconnect bookkeeping.
        let knownIds = Set(sessionStatuses.keys).union(pendingMessages.map(\.sessionId))
            .union(queueReleasePendingIdle).union(releasedBeforeReconnectSync)
        let isPostReconnectSync = awaitingPostReconnectSync
        let alreadyReleased = isPostReconnectSync ? releasedBeforeReconnectSync : Set<String>()
        if isPostReconnectSync {
            awaitingPostReconnectSync = false
            releasedBeforeReconnectSync.removeAll()
            postReconnectFlushFallback?.cancel()
            postReconnectFlushFallback = nil
            reclassifyOfflineAsBusy()
        }

        for row in fetched where conciergeIds.contains(row.id) { context.delete(row) }
        let localSessions = fetched.filter { !conciergeIds.contains($0.id) }
        for local in localSessions {
            let wasStale = local.isStale
            local.isStale = !tableIds.contains(local.id)
            if local.isStale && !wasStale {
                streamingMessageIds[local.id] = nil
                lastCompletedMessageIds[local.id] = nil
                sessionToolNames.removeValue(forKey: local.id)
                cancelBusyWatchdog(for: local.id)
            }
        }
        for id in knownIds where !allServerIds.contains(id) {
            if isActiveBusy(id) { endSession(id) }
            else { clearPendingMessages(for: id); cancelBusyWatchdog(for: id) }
        }
        let localIds = Set(localSessions.map(\.id))
        for server in tableRows where !localIds.contains(server.sessionId) {
            context.insert(Session(id: server.sessionId, path: server.path))
        }

        var flushed = alreadyReleased
        for server in serverSessions {
            let id = server.sessionId
            let wasBusy = isActiveBusy(id)
            if server.state == .sessionEnded {
                endSession(id)
            } else if server.state == .idle {
                sessionStatuses[id] = .idle
                sessionToolNames.removeValue(forKey: id)
                cancelBusyWatchdog(for: id)
                if wasBusy, !flushed.contains(id), releaseQueuedHead(for: id) {
                    flushed.insert(id)
                }
            } else {
                if !wasBusy { sessionStatuses[id] = server.state }
                // Preserve useful tool/thinking detail on busy → busy.
                armBusyWatchdog(for: id)
            }
        }
        save(context, "chat.syncSessions.save")
        if let currentSessionId, localSessions.first(where: { $0.id == currentSessionId })?.isStale == true {
            self.currentSessionId = nil
        }
        if isPostReconnectSync { flushOfflineQueue(skipping: flushed) }
    }

    private func deleteLocalSession(sessionId: String) {
        clearPendingMessages(for: sessionId)
        guard let context = modelContext else { return }

        streamingMessageIds[sessionId] = nil
        lastCompletedMessageIds[sessionId] = nil
        sessionToolNames.removeValue(forKey: sessionId)
        cancelBusyWatchdog(for: sessionId)

        let msgDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        for msg in context.fetchOrEmpty(msgDescriptor, "chat.deleteLocal.messages.fetch") {
            context.delete(msg)
        }

        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == sessionId }
        )
        if let session = context.fetchOrEmpty(sessionDescriptor, "chat.deleteLocal.session.fetch").first {
            context.delete(session)
        }

        save(context, "chat.deleteLocal.save")
    }

    private func saveWorkspace(path: String, context: ModelContext) {
        let maxRecent = 5
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.path == path }
        )
        if let existing = context.fetchOrEmpty(descriptor, "chat.workspace.existing.fetch").first {
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
        for workspace in context.fetchOrEmpty(allDescriptor, "chat.workspace.stale.fetch") {
            context.delete(workspace)
        }

        save(context, "chat.workspace.save")
    }

    deinit {
        for watch in busyTimers.values { watch.task.cancel() }
        postReconnectFlushFallback?.cancel()
        lastErrorTimer?.cancel()
    }
}
