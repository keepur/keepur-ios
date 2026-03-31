import Foundation
import SwiftData
import SwiftUI
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messageText = ""
    @Published var currentStatus: String = "idle"
    @Published var currentPath: String = ""
    @Published var currentSessionId: String?
    @Published var pendingApproval: ToolApproval?
    @Published var isPaired = true
    @Published var browseEntries: [BrowseEntry] = []
    @Published var browsePath: String = ""
    @Published var serverSessions: [ServerSession] = []

    let ws = WebSocketManager()
    let speechManager = SpeechManager()
    var autoReadAloud = false
    private var modelContext: ModelContext?
    private var streamingMessageIds: [String: String] = [:]
    private var lastCompletedMessageIds: [String: String] = [:]

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
        deleteLocalSession(sessionId: sessionId)
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

    func unpair() {
        ws.disconnect()
        KeychainManager.clearAll()
        isPaired = false
    }

    // MARK: - Private

    private func handleIncoming(_ incoming: WSIncoming) {
        guard let context = modelContext else { return }

        switch incoming {
        case .message(let text, let sessionId, let final):
            handleStreamingMessage(text: text, sessionId: sessionId, final: final, context: context)

        case .toolApproval(let toolUseId, let tool, let input, let sessionId):
            if let sessionId, sessionId != currentSessionId {
                currentSessionId = sessionId
            }
            pendingApproval = ToolApproval(id: toolUseId, tool: tool, input: input, sessionId: sessionId)

        case .status(let state, let sessionId):
            if sessionId == nil || sessionId == currentSessionId {
                currentStatus = state
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
            currentStatus = "idle"
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
            browsePath = path
            browseEntries = entries

        case .error(let message, let sessionId):
            let targetSessionId = sessionId ?? currentSessionId
            if let targetSessionId {
                let msg = Message(sessionId: targetSessionId, text: "Error: \(message)", role: "system")
                context.insert(msg)
                try? context.save()
            }

        case .pong:
            break
        }
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
