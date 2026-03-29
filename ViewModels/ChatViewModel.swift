import Foundation
import SwiftData
import SwiftUI
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messageText = ""
    @Published var currentStatus: String = "idle"
    @Published var currentWorkspace: String = ""
    @Published var availableWorkspaces: [String] = []
    @Published var currentSessionId: String?
    @Published var pendingApproval: ToolApproval?
    @Published var isAuthenticated = true

    let ws = WebSocketManager()
    let speechManager = SpeechManager()
    var autoReadAloud = false
    private var modelContext: ModelContext?
    private var streamingMessageId: String?
    private var lastCompletedMessageId: String?

    struct ToolApproval: Identifiable {
        let id: String  // toolUseId
        let tool: String
        let input: String
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

    func newSession(workspace: String? = nil) {
        ws.send(.newSession(workspace: workspace))
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

        case .toolApproval(let toolUseId, let tool, let input):
            pendingApproval = ToolApproval(id: toolUseId, tool: tool, input: input)

        case .status(let state):
            currentStatus = state
            if state == "session_ended" {
                if let sessionId = currentSessionId {
                    let divider = Message(sessionId: sessionId, text: "Session ended", role: "system")
                    context.insert(divider)
                    try? context.save()
                }
                streamingMessageId = nil
            }

        case .sessionInfo(let sessionId, let workspace, let workspaces):
            if sessionId != currentSessionId {
                let session = Session(id: sessionId, workspace: workspace)
                context.insert(session)
                try? context.save()
            }
            currentSessionId = sessionId
            currentWorkspace = workspace
            if !workspaces.isEmpty {
                availableWorkspaces = workspaces
            }
            currentStatus = "idle"

        case .error(let message):
            if let sessionId = currentSessionId {
                let msg = Message(sessionId: sessionId, text: "Error: \(message)", role: "system")
                context.insert(msg)
                try? context.save()
            }

        case .pong:
            break
        }
    }

    private func handleStreamingMessage(text: String, sessionId: String, final: Bool, context: ModelContext) {
        if final {
            if !text.isEmpty, let existingId = streamingMessageId {
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate { $0.id == existingId }
                )
                if let msg = try? context.fetch(descriptor).first {
                    msg.text += text
                    try? context.save()
                }
            }
            // Read aloud the completed response
            if autoReadAloud, let completedId = streamingMessageId ?? lastCompletedMessageId {
                let descriptor = FetchDescriptor<Message>(
                    predicate: #Predicate { $0.id == completedId }
                )
                if let msg = try? context.fetch(descriptor).first, msg.role == "assistant" {
                    speechManager.speak(msg.text)
                }
            }
            lastCompletedMessageId = streamingMessageId
            streamingMessageId = nil
            return
        }

        if let existingId = streamingMessageId {
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
            streamingMessageId = msg.id
        }
    }
}
