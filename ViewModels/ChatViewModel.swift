import Foundation
import SwiftData
import SwiftUI
import Combine

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
    @Published var browseEntries: [BrowseEntry] = []
    @Published var browsePath: String = ""
    @Published var browseError: String?
    private var isBrowsePending = false
    @Published var serverSessions: [ServerSession] = []
    @Published var workspaceSessions: [WorkspaceSession] = []
    @Published var pendingMessageIds: Set<String> = []
    @Published var pendingAttachment: (data: Data, name: String, mimeType: String)? = nil

    let ws = WebSocketManager()
    let speechManager = SpeechManager()
    var autoReadAloud = false
    private var modelContext: ModelContext?
    private var streamingMessageIds: [String: String] = [:]
    private var lastCompletedMessageIds: [String: String] = [:]
    private var pendingMessages: [(text: String, messageId: String, sessionId: String, attachment: (data: Data, name: String, mimeType: String)?)] = []
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

    func configure(context: ModelContext) {
        self.modelContext = context
        ws.onMessage = { [weak self] incoming in
            self?.handleIncoming(incoming)
        }
        ws.onAuthFailure = { [weak self] in
            self?.unpair()
        }
        ws.onConnect = { [weak self] in
            self?.listSessions()
        }
        ws.connect()
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

        if statusFor(sessionId) != "idle" {
            pendingMessages.append((text: effectiveText, messageId: message.id, sessionId: sessionId, attachment: attachment))
            pendingMessageIds.insert(message.id)
        } else {
            sendToServer(text: text, attachment: attachment, sessionId: sessionId)
        }
        messageText = ""
        pendingAttachment = nil
    }

    func cancelCurrentOperation(for sessionId: String) {
        ws.send(.cancel(sessionId: sessionId))
        clearPendingMessages(for: sessionId)
    }

    func newSession(path: String) {
        ws.send(.newSession(path: path))
    }

    func clearSession(sessionId: String) {
        ws.send(.clearSession(sessionId: sessionId))
        deleteLocalSession(sessionId: sessionId)
    }

    func listSessions() {
        ws.send(.listSessions)
    }

    func listWorkspaceSessions(path: String) {
        workspaceSessions = []
        ws.send(.listWorkspaceSessions(path: path))
    }

    func resumeSession(sessionId: String, path: String) {
        ws.send(.resumeSession(sessionId: sessionId, path: path))
    }

    func browse(path: String? = nil) {
        browseError = nil
        isBrowsePending = true
        ws.send(.browse(path: path))
    }

    func approve(toolUseId: String, sessionId: String) {
        ws.send(.approve(toolUseId: toolUseId))
        pendingApprovals[sessionId] = nil
    }

    func deny(toolUseId: String, sessionId: String) {
        ws.send(.deny(toolUseId: toolUseId))
        pendingApprovals[sessionId] = nil
    }

    func unpair() {
        ws.disconnect()
        KeychainManager.clearAll()
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
                ws.send(.deny(toolUseId: toolUseId))
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
                    streamingMessageIds.removeValue(forKey: effectiveId)
                    pendingApprovals.removeValue(forKey: effectiveId)
                    sessionStatuses.removeValue(forKey: effectiveId)
                    sessionToolNames.removeValue(forKey: effectiveId)
                    clearPendingMessages(for: effectiveId)
                }
            }

        case .sessionInfo(let sessionId, let path):
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
                pendingMessages[i] = (
                    text: pendingMessages[i].text,
                    messageId: pendingMessages[i].messageId,
                    sessionId: newSessionId,
                    attachment: pendingMessages[i].attachment
                )
            }

            // 5. Delete the old Session row.
            if let oldSession {
                context.delete(oldSession)
                try? context.save()
            }

            saveWorkspace(path: path, context: context)

        case .error(let message, let sessionId):
            if sessionId == nil && isBrowsePending {
                isBrowsePending = false
                browseError = message
            }
            let targetSessionId = sessionId ?? currentSessionId
            if let targetSessionId {
                let msg = Message(sessionId: targetSessionId, text: "Error: \(message)", role: "system")
                context.insert(msg)
                try? context.save()
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

    private func sendToServer(text: String, attachment: (data: Data, name: String, mimeType: String)?, sessionId: String) {
        if !text.isEmpty {
            ws.send(.message(text: text, sessionId: sessionId))
        }
        if let attachment {
            let base64 = attachment.data.base64EncodedString()
            if attachment.mimeType.hasPrefix("image/") {
                ws.send(.image(sessionId: sessionId, data: base64, filename: attachment.name))
            } else {
                ws.send(.file(sessionId: sessionId, data: base64, filename: attachment.name, mimetype: attachment.mimeType))
            }
        }
    }

    private func flushNextPendingMessage(for sessionId: String) {
        guard let index = pendingMessages.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        let pending = pendingMessages.remove(at: index)
        pendingMessageIds.remove(pending.messageId)
        sendToServer(text: pending.text, attachment: pending.attachment, sessionId: pending.sessionId)
    }

    private func clearPendingMessages(for sessionId: String) {
        let removedIds = Set(pendingMessages.filter { $0.sessionId == sessionId }.map { $0.messageId })
        pendingMessages.removeAll { $0.sessionId == sessionId }
        pendingMessageIds.subtract(removedIds)
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

    private func syncSessions(serverSessions: [ServerSession], context: ModelContext) {
        let serverIds = Set(serverSessions.map(\.sessionId))

        let descriptor = FetchDescriptor<Session>()
        guard let localSessions = try? context.fetch(descriptor) else { return }

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

        let localIds = Set(localSessions.map(\.id))
        for server in serverSessions where !localIds.contains(server.sessionId) {
            let session = Session(id: server.sessionId, path: server.path)
            context.insert(session)
        }

        // Reconcile session statuses from server state
        for server in serverSessions {
            let serverState = server.state  // "idle" or "busy"
            let clientState = sessionStatuses[server.sessionId]
            if clientState != nil && clientState != "idle" && serverState == "idle" {
                sessionStatuses[server.sessionId] = "idle"
                busyTimers[server.sessionId]?.cancel()
                busyTimers.removeValue(forKey: server.sessionId)
                flushNextPendingMessage(for: server.sessionId)
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
