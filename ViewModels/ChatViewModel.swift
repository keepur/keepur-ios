import Foundation
import SwiftData
import SwiftUI
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messageText = ""
    @Published var currentSessionId: String?
    @Published var pendingApproval: ToolApproval?
    @Published var isAuthenticated = true

    // Per-session status: sessionId -> state
    @Published var sessionStatuses: [String: String] = [:]

    // Browse state
    @Published var browseEntries: [BrowseEntry] = []
    @Published var browsePath: String = ""

    let ws = WebSocketManager()
    let speechManager = SpeechManager()
    var autoReadAloud = false
    private var modelContext: ModelContext?
    private var streamingMessageIds: [String: String] = [:]  // sessionId -> messageId
    private var lastCompletedMessageIds: [String: String] = [:]

    struct ToolApproval: Identifiable {
        let id: String  // toolUseId
        let tool: String
        let input: String
        let sessionId: String
    }

    func configure(context: ModelContext) {
        self.modelContext = context
        ws.onMessage = { [weak self] incoming in
            self?.handleIncoming(incoming)
        }
        ws.onAuthFailure = { [weak self] in
            self?.isAuthenticated = false
        }
        ws.connect()
    }

    func statusFor(_ sessionId: String) -> String {
        sessionStatuses[sessionId] ?? "idle"
    }

    func sendText() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let context = modelContext, let sessionId = currentSessionId else { return }

        let message = Message(sessionId: sessionId, text: text, role: "user")
        context.insert(message)
        try? context.save()

        ws.send(.message(text: text, sessionId: sessionId))
        messageText = ""
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
    }

    func listSessions() {
        ws.send(.listSessions)
    }

    func browse(path: String? = nil) {
        ws.send(.browse(path: path))
    }

    func approve(toolUseId: String) {
        ws.send(.approve(toolUseId: toolUseId))
        pendingApproval = nil
    }

    func deny(toolUseId: String) {
        ws.send(.deny(toolUseId: toolUseId))
        pendingApproval = nil
    }

    func clearToken() {
        ws.disconnect()
        KeychainManager.clear()
        isAuthenticated = false
    }

    // MARK: - Private

    private func handleIncoming(_ incoming: WSIncoming) {
        guard let context = modelContext else { return }

        switch incoming {
        case .message(let text, let sessionId, let final):
            handleStreamingMessage(text: text, sessionId: sessionId, final: final, context: context)

        case .toolApproval(let toolUseId, let tool, let input, let sessionId):
            pendingApproval = ToolApproval(id: toolUseId, tool: tool, input: input, sessionId: sessionId)

        case .status(let state, let sessionId):
            sessionStatuses[sessionId] = state

        case .sessionInfo(let sessionId, let path):
            // Upsert session
            let descriptor = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == sessionId }
            )
            if (try? context.fetch(descriptor).first) == nil {
                let session = Session(id: sessionId, path: path)
                context.insert(session)
                try? context.save()
            }

            // Remember workspace
            let wsDescriptor = FetchDescriptor<Workspace>(
                predicate: #Predicate { $0.path == path }
            )
            if let existing = try? context.fetch(wsDescriptor).first {
                existing.lastUsed = .now
            } else {
                context.insert(Workspace(path: path))
            }
            try? context.save()

            currentSessionId = sessionId
            sessionStatuses[sessionId] = "idle"

        case .sessionList(let sessions):
            syncSessions(serverSessions: sessions, context: context)

        case .sessionCleared(let sessionId):
            deleteLocalSession(sessionId: sessionId, context: context)
            if currentSessionId == sessionId {
                currentSessionId = nil
            }

        case .browseResult(let path, let entries):
            browsePath = path
            browseEntries = entries

        case .error(let message, let sessionId):
            let targetSessionId = sessionId ?? currentSessionId
            if let sid = targetSessionId {
                let msg = Message(sessionId: sid, text: "Error: \(message)", role: "system")
                context.insert(msg)
                try? context.save()
            }

        case .pong:
            break
        }
    }

    private func syncSessions(serverSessions: [ServerSession], context: ModelContext) {
        let serverIds = Set(serverSessions.map(\.sessionId))

        // Mark local sessions not on server as stale
        let descriptor = FetchDescriptor<Session>()
        if let localSessions = try? context.fetch(descriptor) {
            for session in localSessions {
                session.isStale = !serverIds.contains(session.id)
            }
        }

        // Create local sessions for any server sessions we don't have
        for serverSession in serverSessions {
            let sid = serverSession.sessionId
            let check = FetchDescriptor<Session>(
                predicate: #Predicate { $0.id == sid }
            )
            if (try? context.fetch(check).first) == nil {
                let session = Session(id: serverSession.sessionId, path: serverSession.path)
                context.insert(session)
            }
            sessionStatuses[serverSession.sessionId] = serverSession.state
        }
        try? context.save()

        // Clear current session if it became stale
        if let current = currentSessionId, !serverIds.contains(current) {
            currentSessionId = nil
        }
    }

    private func deleteLocalSession(sessionId: String, context: ModelContext) {
        let sid = sessionId
        let msgDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sid }
        )
        if let messages = try? context.fetch(msgDescriptor) {
            for msg in messages { context.delete(msg) }
        }
        let sessionDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == sid }
        )
        if let session = try? context.fetch(sessionDescriptor).first {
            context.delete(session)
        }
        try? context.save()
        streamingMessageIds.removeValue(forKey: sessionId)
        sessionStatuses.removeValue(forKey: sessionId)
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
            // Read aloud the completed response
            if autoReadAloud, let completedId = streamingMessageIds[sessionId] ?? lastCompletedMessageIds[sessionId] {
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate { $0.id == completedId }
                )
                if let msg = try? context.fetch(descriptor).first, msg.role == "assistant" {
                    speechManager.speak(msg.text)
                }
            }
            lastCompletedMessageIds[sessionId] = streamingMessageIds[sessionId]
            streamingMessageIds.removeValue(forKey: sessionId)
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
}
