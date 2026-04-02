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

    let ws = WebSocketManager()
    let speechManager = SpeechManager()
    var autoReadAloud = false
    private var modelContext: ModelContext?
    private var streamingMessageIds: [String: String] = [:]
    private var lastCompletedMessageIds: [String: String] = [:]
    private var pendingMessages: [(text: String, messageId: String, sessionId: String)] = []

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
        ws.connect()
    }

    func sendText() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context = modelContext, let sessionId = currentSessionId else { return }

        let message = Message(sessionId: sessionId, text: text, role: "user")
        context.insert(message)
        try? context.save()

        if statusFor(sessionId) != "idle" {
            pendingMessages.append((text: text, messageId: message.id, sessionId: sessionId))
            pendingMessageIds.insert(message.id)
        } else {
            ws.send(.message(text: text, sessionId: sessionId))
        }
        messageText = ""
    }

    func cancelCurrentOperation(for sessionId: String) {
        ws.send(.cancel(sessionId: sessionId))
        clearPendingMessages(for: sessionId)
    }

    func sendVoiceText() {
        let text = speechManager.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = text
        sendText()
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
                if state == "tool_running" {
                    if let toolName {
                        sessionToolNames[effectiveId] = toolName
                    } else {
                        sessionToolNames.removeValue(forKey: effectiveId)
                    }
                } else {
                    sessionToolNames.removeValue(forKey: effectiveId)
                }

                // Flush next pending message when session becomes idle
                if state == "idle" && !pendingMessages.filter({ $0.sessionId == effectiveId }).isEmpty {
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
            let existingDescriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == sessionId }
            )
            if let existing = try? context.fetch(existingDescriptor).first {
                existing.path = path
                existing.isStale = false
            } else {
                let session = Session(id: sessionId, path: path)
                context.insert(session)
            }
            try? context.save()
            currentSessionId = sessionId
            currentPath = path
            sessionStatuses[sessionId] = "idle"
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

        case .unknown(let raw):
            let targetSessionId = currentSessionId ?? "unknown"
            let msg = Message(sessionId: targetSessionId, text: raw, role: "unknown")
            context.insert(msg)
            try? context.save()
        }
    }

    private func flushNextPendingMessage(for sessionId: String) {
        guard let index = pendingMessages.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        let pending = pendingMessages.remove(at: index)
        pendingMessageIds.remove(pending.messageId)
        ws.send(.message(text: pending.text, sessionId: pending.sessionId))
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
            }
        }

        let localIds = Set(localSessions.map(\.id))
        for server in serverSessions where !localIds.contains(server.sessionId) {
            let session = Session(id: server.sessionId, path: server.path)
            context.insert(session)
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
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.path == path }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.lastUsed = .now
        } else {
            let workspace = Workspace(path: path)
            context.insert(workspace)
        }
        try? context.save()
    }
}
