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

    // MARK: - Internal State

    let ws = TeamWebSocketManager()
    private var modelContext: ModelContext?
    private var deviceId: String = ""
    private var pendingCommandChannels: [String: String] = [:]  // requestId -> channelId
    private var pendingMessageIds: [String: String] = [:]       // requestId -> local message id
    private var pendingNewCommands: Set<String> = []             // requestIds for /new commands

    // MARK: - Setup

    func configure(context: ModelContext) {
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
        messageText = ""
    }

    func selectChannel(_ channelId: String) {
        activeChannelId = channelId
        hasMoreHistory = true
        refreshActiveMessages()

        // Always fetch history on channel selection. Seeding only loads 1 message
        // for sidebar preview — the full page load happens here. Dedup prevents
        // duplicates if messages were already loaded.
        ws.send(.history(channelId: channelId, before: nil, limit: 50))
    }

    func fetchHistory(channelId: String) {
        // Only track loading state for active channel (user-initiated pagination)
        let isActive = channelId == activeChannelId
        if isActive {
            guard !isLoadingHistory else { return }
            isLoadingHistory = true
        }

        // Find the oldest server message ID for cursor-based pagination
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
        // Reconnect gap-fill: fetch latest messages for the active channel
        if let channelId = activeChannelId {
            ws.send(.history(channelId: channelId, before: nil, limit: 50))
        }
    }

    private func handleAuthFailure() {
        ws.disconnect()
        KeychainManager.clearAll()
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

        case .channelList(let channelInfos, _):
            syncChannels(channelInfos, context: context)
            // Seed previews with 1-message history per channel
            for info in channelInfos {
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

        case .commandList:
            break  // v1: not used
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

        // Update cursor to the oldest message in this batch (first element,
        // assuming server returns chronological order). Used for scroll-up pagination.
        if let oldest = messages.first {
            let cid = channelId
            let descriptor = FetchDescriptor<TeamChannel>(
                predicate: #Predicate { $0.id == cid }
            )
            if let channel = try? context.fetch(descriptor).first {
                channel.lastServerMessageId = oldest.id
            }
        }

        for histMsg in messages {
            let hid = histMsg.id
            // Step 1: ID match — already imported from history
            let idDescriptor = FetchDescriptor<TeamMessage>(
                predicate: #Predicate { $0.id == hid }
            )
            if (try? context.fetch(idDescriptor).first) != nil {
                continue
            }

            let cid = channelId
            let msgText = histMsg.text
            let sid = histMsg.senderId

            // Step 2: User message match (own messages, ±30s window)
            if histMsg.senderId == deviceId {
                let userDescriptor = FetchDescriptor<TeamMessage>(
                    predicate: #Predicate {
                        $0.channelId == cid && $0.senderId == sid && $0.text == msgText
                    }
                )
                if let match = try? context.fetch(userDescriptor).first {
                    let timeDiff = abs(match.createdAt.timeIntervalSince(histMsg.createdAt))
                    if timeDiff < 30 {
                        continue
                    }
                }
            }

            // Step 3: Agent message match
            if histMsg.senderType == "agent" {
                let agentDescriptor = FetchDescriptor<TeamMessage>(
                    predicate: #Predicate {
                        $0.channelId == cid && $0.senderId == sid && $0.text == msgText
                    }
                )
                if (try? context.fetch(agentDescriptor).first) != nil {
                    continue
                }
            }

            // Step 4: System message match
            if histMsg.senderId == "system" {
                let sysId = "system"
                let sysDescriptor = FetchDescriptor<TeamMessage>(
                    predicate: #Predicate {
                        $0.channelId == cid && $0.senderId == sysId && $0.text == msgText
                    }
                )
                if (try? context.fetch(sysDescriptor).first) != nil {
                    continue
                }
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

        // Update sidebar preview from the most recent history message
        if let newest = messages.last {
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
