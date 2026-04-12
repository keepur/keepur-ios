import Foundation
import Combine
import SwiftData
import SwiftUI

@MainActor
final class TeamViewModel: ObservableObject {
    // MARK: - Published State

    @Published var channels: [TeamChannel] = []
    @Published var activeChannelId: String?
    @Published var activeMessages: [TeamMessage] = []
    @Published var isLoadingHistory: Bool = false
    @Published var hasMoreHistory: Bool = true
    @Published var messageText: String = ""
    @Published var isAuthenticated = true
    @Published var lastLiveMessageId: String?  // Set on live messages only, drives scroll-to-bottom

    /// Reference to SpeechManager for updating Whisper prompt with dynamic vocabulary.
    /// Set by the parent view that owns both TeamViewModel and SpeechManager.
    /// Weak because TeamViewModel does not own SpeechManager — ChatViewModel does.
    weak var speechManager: SpeechManager?

    /// Cached dynamic vocabulary for prompt rebuilding.
    private var agentNames: [String] = []
    private var channelNames: [String] = []
    private var commandNames: [String] = []

    // MARK: - Internal State

    let ws = TeamWebSocketManager()
    private var modelContext: ModelContext?
    private var deviceId: String = ""
    private var pendingCommandChannels: [String: String] = [:]  // requestId -> channelId
    private var pendingMessageIds: [String: String] = [:]       // requestId -> local message id
    private var pendingNewCommands: Set<String> = []             // requestIds for /new commands

    // MARK: - Setup

    func configure(context: ModelContext) {
        guard modelContext == nil else { return }  // Idempotency guard
        self.modelContext = context
        self.deviceId = KeychainManager.deviceId ?? ""

        ws.onMessage = { [weak self] incoming in
            self?.handleIncoming(incoming)
        }
        ws.onAuthFailure = { [weak self] in
            self?.handleAuthFailure()
        }
        ws.onConnect = { [weak self] in
            self?.onConnected()
        }
        ws.connect()
    }

    func disconnect() {
        ws.disconnect()
    }

    // MARK: - Public Actions

    func sendMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let channelId = activeChannelId,
              let context = modelContext else { return }

        // Check for slash commands
        if trimmed.hasPrefix("/") {
            sendSlashCommand(text: trimmed, channelId: channelId)
            messageText = ""
            return
        }

        // Create optimistic local message
        let localId = UUID().uuidString
        let message = TeamMessage(
            id: localId,
            channelId: channelId,
            senderId: deviceId,
            senderType: "person",
            senderName: KeychainManager.deviceName ?? "Me",
            text: trimmed,
            pending: true
        )
        context.insert(message)
        try? context.save()

        // Send via WS and track for ack
        if let requestId = ws.sendWithId(.teamMessage(channelId: channelId, text: trimmed, threadId: nil)) {
            pendingMessageIds[requestId] = localId
        }

        refreshActiveMessages()
        lastLiveMessageId = localId
        messageText = ""
    }

    func selectChannel(_ channelId: String) {
        activeChannelId = channelId
        hasMoreHistory = true
        refreshActiveMessages()

        // Reset cursor on channel selection — the full page load starts fresh.
        // Seeding only loaded 1 message for sidebar preview; now we load the full
        // latest page. Dedup prevents duplicates if messages were already loaded.
        if let context = modelContext {
            let cid = channelId
            let channelDescriptor = FetchDescriptor<TeamChannel>(
                predicate: #Predicate { $0.id == cid }
            )
            if let channel = try? context.fetch(channelDescriptor).first {
                channel.lastServerMessageId = nil
            }
        }

        fetchHistory(channelId: channelId)
    }

    func fetchHistory(channelId: String) {
        // Only track loading state for active channel (user-initiated pagination)
        let isActive = channelId == activeChannelId
        if isActive {
            guard !isLoadingHistory else { return }
            isLoadingHistory = true
        }

        // Find the oldest server message ID for cursor-based pagination.
        // nil means "fetch the latest page" (no cursor).
        var before: String?
        if let context = modelContext {
            let cid = channelId
            let channelDescriptor = FetchDescriptor<TeamChannel>(
                predicate: #Predicate { $0.id == cid }
            )
            if let channel = try? context.fetch(channelDescriptor).first {
                before = channel.lastServerMessageId
            }
        }

        ws.send(.history(channelId: channelId, before: before, limit: 50))
    }

    func fetchChannels() {
        ws.send(.channelList)
    }

    func joinChannel(channelId: String) {
        // Only join if not already in local store
        guard let context = modelContext else { return }
        let cid = channelId
        let descriptor = FetchDescriptor<TeamChannel>(
            predicate: #Predicate { $0.id == cid }
        )
        if (try? context.fetch(descriptor).first) != nil { return }
        ws.send(.join(channelId: channelId))
    }

    func leaveChannel(channelId: String) {
        ws.send(.leave(channelId: channelId))
    }

    // MARK: - Private: Connection

    private func onConnected() {
        fetchChannels()
        ws.send(.agentList)       // Extract agent names for Whisper vocabulary
        ws.send(.commandList)     // Extract command names for Whisper vocabulary
        // Reconnect gap-fill: fetch latest messages for the active channel.
        // Use fetchHistory (not direct ws.send) so cursor and loading state
        // are managed correctly and we don't race with seeding fetches.
        if let channelId = activeChannelId {
            // Reset cursor so we get the latest page, not stale pagination
            if let context = modelContext {
                let cid = channelId
                let descriptor = FetchDescriptor<TeamChannel>(
                    predicate: #Predicate { $0.id == cid }
                )
                if let channel = try? context.fetch(descriptor).first {
                    channel.lastServerMessageId = nil
                }
            }
            fetchHistory(channelId: channelId)
        }
    }

    private func handleAuthFailure() {
        ws.disconnect()
        // Don't call KeychainManager.clearAll() here — ContentView observes
        // isAuthenticated and calls chatViewModel.unpair() which handles Keychain cleanup.
        isAuthenticated = false
    }

    // MARK: - Private: Slash Commands

    private func sendSlashCommand(text: String, channelId: String) {
        let parts = text.dropFirst().split(separator: " ", maxSplits: 1)
        guard let commandName = parts.first else { return }
        let args = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []

        let command = TeamWSOutgoing.command(
            channelId: channelId,
            name: String(commandName),
            args: args
        )
        if let requestId = ws.sendWithId(command) {
            pendingCommandChannels[requestId] = channelId
            // Track /new commands for auto-refresh
            if commandName == "new" || commandName == "dm" {
                pendingNewCommands.insert(requestId)
            }
        }
    }

    // MARK: - Private: Incoming Message Handling

    private func handleIncoming(_ incoming: TeamWSIncoming) {
        guard let context = modelContext else { return }

        switch incoming {
        case .teamMessage(let text, let channelId, let agentId, let agentName, _):
            let message = TeamMessage(
                channelId: channelId,
                senderId: agentId,
                senderType: "agent",
                senderName: agentName,
                text: text
            )
            context.insert(message)
            try? context.save()

            updateChannelPreview(channelId: channelId, text: text, context: context)
            refreshActiveMessages()
            if channelId == activeChannelId {
                lastLiveMessageId = message.id
            }

        case .systemMessage(let text, _, let agentName, let replyTo):
            // Route to the channel that sent the command
            var channelId: String?
            if let replyTo {
                channelId = pendingCommandChannels.removeValue(forKey: replyTo)
                // Auto-refresh channels after /new commands
                if pendingNewCommands.remove(replyTo) != nil {
                    fetchChannels()
                }
            }
            guard let targetChannelId = channelId ?? activeChannelId else { return }

            let message = TeamMessage(
                channelId: targetChannelId,
                senderId: "system",
                senderType: "agent",
                senderName: agentName,
                text: text
            )
            context.insert(message)
            try? context.save()

            updateChannelPreview(channelId: targetChannelId, text: text, context: context)
            refreshActiveMessages()
            if targetChannelId == activeChannelId {
                lastLiveMessageId = message.id
            }

        case .channelList(let channelInfos, _):
            syncChannels(channelInfos, context: context)
            channelNames = channelInfos.map(\.name)
            rebuildWhisperPrompt()
            // Seed previews with 1-message history per channel.
            // Skip the active channel — a full-page fetch is already in flight
            // from onConnected/selectChannel, and a seeding response would
            // prematurely clear isLoadingHistory and corrupt the cursor.
            for info in channelInfos {
                guard info.id != activeChannelId else { continue }
                ws.send(.history(channelId: info.id, before: nil, limit: 1))
            }

        case .history(let channelId, let messages, let hasMore, _):
            processHistory(channelId: channelId, messages: messages, hasMore: hasMore, context: context)

        case .channelEvent(let channelId, let event, let memberId, _):
            handleChannelEvent(channelId: channelId, event: event, memberId: memberId, context: context)

        case .ack(let id):
            // Mark pending message as sent
            if let localId = pendingMessageIds.removeValue(forKey: id) {
                let lid = localId
                let descriptor = FetchDescriptor<TeamMessage>(
                    predicate: #Predicate { $0.id == lid }
                )
                if let msg = try? context.fetch(descriptor).first {
                    msg.pending = false
                    try? context.save()
                    refreshActiveMessages()
                }
            }

        case .typing:
            break  // v1: ignore typing indicators

        case .error(let message):
            print("[Team WS error] \(message)")

        case .pong:
            break

        case .agentList(let agents, _):
            agentNames = agents.map(\.name)
            rebuildWhisperPrompt()

        case .commandList(let commands, _):
            commandNames = commands.map(\.name)
            rebuildWhisperPrompt()
        }
    }

    // MARK: - Private: Channel Sync

    private func syncChannels(_ channelInfos: [TeamChannelInfo], context: ModelContext) {
        let serverIds = Set(channelInfos.map(\.id))

        // Fetch all local channels
        let descriptor = FetchDescriptor<TeamChannel>()
        let localChannels = (try? context.fetch(descriptor)) ?? []

        // Remove channels no longer on server
        for local in localChannels where !serverIds.contains(local.id) {
            context.delete(local)
        }

        // Insert or update channels
        for info in channelInfos {
            if let existing = localChannels.first(where: { $0.id == info.id }) {
                existing.name = info.name
                existing.members = info.members
                existing.updatedAt = .now
            } else {
                let channel = TeamChannel(
                    id: info.id,
                    type: info.type,
                    name: info.name,
                    members: info.members
                )
                context.insert(channel)
            }
        }

        try? context.save()
        loadChannels(context: context)
    }

    private func loadChannels(context: ModelContext) {
        let descriptor = FetchDescriptor<TeamChannel>(
            sortBy: [SortDescriptor(\TeamChannel.lastMessageAt, order: .reverse)]
        )
        channels = (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Private: History Processing with Dedup

    private func processHistory(channelId: String, messages: [TeamHistoryMessage], hasMore: Bool, context: ModelContext) {
        let isActiveChannel = channelId == activeChannelId

        if isActiveChannel {
            self.hasMoreHistory = hasMore
        }

        // Update cursor to the oldest message in this batch for scroll-up pagination.
        // Use min(createdAt) to be sort-order-agnostic. For seeding fetches (limit 1
        // returning the newest message), only set if no cursor exists. For pagination
        // fetches (isActiveChannel), always advance the cursor deeper into history.
        if let oldestMsg = messages.min(by: { $0.createdAt < $1.createdAt }) {
            let cid = channelId
            let descriptor = FetchDescriptor<TeamChannel>(
                predicate: #Predicate { $0.id == cid }
            )
            if let channel = try? context.fetch(descriptor).first {
                if isActiveChannel || channel.lastServerMessageId == nil {
                    channel.lastServerMessageId = oldestMsg.id
                }
            }
        }

        // Pre-fetch ALL existing messages for this channel once — O(1) fetch instead of O(N*4).
        // Build lookup sets for in-memory dedup matching.
        let cid = channelId
        let allDescriptor = FetchDescriptor<TeamMessage>(
            predicate: #Predicate { $0.channelId == cid }
        )
        let existingMessages = (try? context.fetch(allDescriptor)) ?? []

        // Build lookup structures for fast dedup
        let existingIds = Set(existingMessages.map(\.id))
        // Key: "senderId|text" for content-based matching
        let existingContentKeys = Set(existingMessages.map { "\($0.senderId)|\($0.text)" })
        // For user message time-windowed matching: store (key, createdAt) pairs
        let userMessages = existingMessages.filter { $0.senderId == deviceId && !$0.pending }

        for histMsg in messages {
            // Step 1: ID match — already imported from history
            if existingIds.contains(histMsg.id) {
                continue
            }

            let contentKey = "\(histMsg.senderId)|\(histMsg.text)"

            // Step 2: User message match (own messages, acked + ±30s window)
            if histMsg.senderId == deviceId {
                let hasMatch = userMessages.contains { local in
                    local.text == histMsg.text &&
                    abs(local.createdAt.timeIntervalSince(histMsg.createdAt)) < 30
                }
                if hasMatch { continue }
            }

            // Step 3: Agent message match
            if histMsg.senderType == "agent" && existingContentKeys.contains(contentKey) {
                continue
            }

            // Step 4: System message match
            if histMsg.senderId == "system" && existingContentKeys.contains(contentKey) {
                continue
            }

            // Step 5: Insert as new message with server ObjectId
            let message = TeamMessage(
                id: histMsg.id,
                channelId: channelId,
                threadId: histMsg.threadId,
                senderId: histMsg.senderId,
                senderType: histMsg.senderType,
                senderName: histMsg.senderName,
                text: histMsg.text,
                createdAt: histMsg.createdAt,
                pending: false
            )
            context.insert(message)
        }

        try? context.save()

        // Update sidebar preview from the most recent history message.
        // Use max(by:) since server may return messages in descending order.
        if let newest = messages.max(by: { $0.createdAt < $1.createdAt }) {
            updateChannelPreview(channelId: channelId, text: newest.text, date: newest.createdAt, context: context)
        }

        if isActiveChannel {
            isLoadingHistory = false
            refreshActiveMessages()
        }
    }

    // MARK: - Private: Channel Events

    private func handleChannelEvent(channelId: String, event: String, memberId: String?, context: ModelContext) {
        switch event {
        case "joined":
            if memberId == deviceId {
                fetchChannels()
            } else if let memberId {
                // Update local member list for non-self joins
                let cid = channelId
                let descriptor = FetchDescriptor<TeamChannel>(
                    predicate: #Predicate { $0.id == cid }
                )
                if let channel = try? context.fetch(descriptor).first,
                   !channel.members.contains(memberId) {
                    channel.members.append(memberId)
                    try? context.save()
                }
            }
        case "left":
            if memberId == deviceId {
                let cid = channelId
                let descriptor = FetchDescriptor<TeamChannel>(
                    predicate: #Predicate { $0.id == cid }
                )
                if let channel = try? context.fetch(descriptor).first {
                    context.delete(channel)
                    try? context.save()
                    loadChannels(context: context)
                    if activeChannelId == channelId {
                        activeChannelId = nil
                        activeMessages = []
                    }
                }
            }
        case "created":
            fetchChannels()
        case "archived":
            let cid = channelId
            let descriptor = FetchDescriptor<TeamChannel>(
                predicate: #Predicate { $0.id == cid }
            )
            if let channel = try? context.fetch(descriptor).first {
                context.delete(channel)
                try? context.save()
                loadChannels(context: context)
                if activeChannelId == channelId {
                    activeChannelId = nil
                    activeMessages = []
                }
            }
        default:
            break
        }
    }

    // MARK: - Private: Helpers

    private func updateChannelPreview(channelId: String, text: String, date: Date = .now, context: ModelContext) {
        let cid = channelId
        let descriptor = FetchDescriptor<TeamChannel>(
            predicate: #Predicate { $0.id == cid }
        )
        if let channel = try? context.fetch(descriptor).first {
            channel.lastMessageText = String(text.prefix(100))
            if channel.lastMessageAt == nil || date > channel.lastMessageAt! {
                channel.lastMessageAt = date
            }
            try? context.save()
            loadChannels(context: context)
        }
    }

    // MARK: - Private: Whisper Prompt

    private func rebuildWhisperPrompt() {
        speechManager?.whisperPrompt = WhisperPromptBuilder.buildPrompt(
            agentNames: agentNames,
            channelNames: channelNames,
            commandNames: commandNames
        )
    }

    func refreshActiveMessages() {
        guard let context = modelContext, let channelId = activeChannelId else {
            activeMessages = []
            return
        }
        let cid = channelId
        let descriptor = FetchDescriptor<TeamMessage>(
            predicate: #Predicate { $0.channelId == cid },
            sortBy: [SortDescriptor(\TeamMessage.createdAt)]
        )
        activeMessages = (try? context.fetch(descriptor)) ?? []
    }
}
