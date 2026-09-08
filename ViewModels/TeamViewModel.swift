import Foundation
import Combine
import SwiftData
import SwiftUI
import os

@MainActor
final class TeamViewModel: ObservableObject {
    // MARK: - Published State

    @Published var channels: [TeamChannel] = []
    @Published var activeChannelId: String?
    @Published var activeMessages: [TeamMessage] = []
    @Published var isLoadingHistory: Bool = false
    @Published var hasMoreHistory: Bool = true
    @Published var messageText: String = ""
    @Published var pendingAttachment: AttachmentData?
    @Published var isAuthenticated = true
    var onAuthFailure: (() -> Void)?
    @Published var lastLiveMessageId: String?  // Set on live messages only, drives scroll-to-bottom
    @Published var agents: [TeamAgentInfo] = []

    /// Agents paired with their DM channel (if any), sorted for sidebar display.
    /// Sort: `dmChannel?.lastMessageAt` descending (nil last), then `agent.name` ascending.
    /// Must be a stored @Published (not computed) — `agents` and `channels` arrive
    /// via separate WS responses in unpredictable order, and a computed derivation
    /// wouldn't reliably trigger SwiftUI updates.
    @Published var sortedAgents: [(agent: TeamAgentInfo, dmChannel: TeamChannel?)] = []

    var autoReadAloud = false

    /// Reference to the shared SpeechManager (owned by ChatViewModel).
    /// Set by the parent view that owns both TeamViewModel and SpeechManager.
    /// Weak because TeamViewModel does not own SpeechManager — ChatViewModel does.
    weak var speechManager: SpeechManager?

    weak var capabilityManager: CapabilityManager?

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

    struct OfflineEntry: Equatable {
        let localId: String
        let hive: String   // the socket channel the message was written for
    }
    /// Never-sent and un-acked messages in send order (⚠2). Hive-scoped: an entry is
    /// re-sent only by an `onConnected` for the hive it was written for; it is never
    /// delivered into another hive (§7 *Hive switch*). Whole-queue clears happen only
    /// on pairing teardown (⚠6); a single entry is dropped only if its row is gone at re-send.
    @Published private(set) var offlineEntries: [OfflineEntry] = []
    /// Projection for views (bubble badge) and tests.
    var offlineMessageIds: [String] { offlineEntries.map(\.localId) }
    var queuedAttachmentCountForTesting: Int { offlineAttachments.count }
    var pendingMessageRequestCountForTesting: Int { pendingMessageIds.count }


    // MARK: - Internal State

    private let socket: BeekeeperSocket
    private let credentials: CredentialStore
    private var subscriptions = Set<AnyCancellable>()
    private var modelContext: ModelContext?
    /// Read on every use so a re-pair (new device id) is picked up immediately.
    private var deviceId: String { credentials.deviceId ?? "" }
    private var pendingCommandChannels: [String: String] = [:]  // requestId -> channelId
    private var pendingMessageIds: [String: String] = [:]       // requestId -> local message id
    private var pendingNewCommands: Set<String> = []             // requestIds for /new commands
    private var pendingAgentDM: String?       // agent ID to auto-select after channel refresh
    private var pendingDMRequestId: String?   // request UUID of the /dm command
    private var offlineAttachments: [String: AttachmentData] = [:]   // localId → attachment, in-memory only
    /// Channel of the last `socket.connect(channel:)`, assigned AFTER that call returns:
    /// a connected→connected hive switch emits `.connecting` synchronously inside
    /// `connect`, and that transition must stamp un-acked entries with the hive they
    /// were *sent to*, not the one being connected. Never cleared by `disconnect()` or
    /// the hive-vanished path — an entry queued while `.disconnected` still belongs to
    /// the hive the user is looking at. The `?? ""` fallbacks below never match a hive
    /// and so can only leave an entry queued, never misroute it.
    private var activeHive: String?
    private var lastErrorTimer: Task<Void, Never>?
    private let lastErrorAutoClear: Duration
    private static let notConnectedText = "Not connected. Try again when reconnected."

    init(
        socket: BeekeeperSocket? = nil,
        credentials: CredentialStore = KeychainCredentialStore(),
        lastErrorAutoClear: Duration = .seconds(6)
    ) {
        self.socket = socket ?? BeekeeperSocket(config: .standard, credentials: credentials)
        self.credentials = credentials
        self.lastErrorAutoClear = lastErrorAutoClear
        // In init, not configure: Settings observes truth before configure runs. The
        // `capabilityManager` uses in the handler are `guard let`-safe before configure.
        self.socket.$state
            .sink { [weak self] state in self?.handleSocketState(state) }
            .store(in: &subscriptions)
    }

    // MARK: - Setup

    func configure(context: ModelContext, capabilityManager: CapabilityManager) {
        guard modelContext == nil else { return }  // Idempotency guard
        self.modelContext = context
        self.capabilityManager = capabilityManager

        socket.frames
            .sink { [weak self] data in self?.handleFrame(data) }
            .store(in: &subscriptions)
        socket.onAuthFailure = { [weak self] in
            self?.handleAuthFailure()
        }
        socket.onConnected = { [weak self] in
            self?.onConnected()
        }
    }

    private func handleFrame(_ data: Data) {
        guard let incoming = TeamWSIncoming.decode(from: data) else {
            Log.team.debug("dropping undecodable frame")
            return
        }
        handleIncoming(incoming)
    }

    func connectIfPossible() {
        guard let manager = capabilityManager,
              let channel = manager.selectedHive,
              manager.hives.contains(channel) else {
            Log.team.info("connectIfPossible: no valid selectedHive; disconnecting")
            socket.disconnect()
            return
        }
        Log.team.info("connectIfPossible: channel=\(channel, privacy: .public)")
        socket.connect(channel: channel)
        activeHive = channel   // after connect returns — see the activeHive doc comment
    }

    /// Foregrounding, the Settings button and the banner's Retry call this; during
    /// backoff it attempts immediately, keeping the attempt count.
    func reconnect() {
        connectIfPossible()
    }

    /// The banner is state-driven (`connectionState`), so nothing is re-set here. Two
    /// hooks: leaving `.connected` moves sent-but-un-acked messages into the offline
    /// queue; the first `.reconnecting` of a loss runs the hive-vanished check (once
    /// per loss — child A's documented deviation). NEVER call `socket.send` from here:
    /// @Published emits on willSet, so the socket's gate still reads the old state.
    private func handleSocketState(_ state: BeekeeperSocket.State) {
        let previous = connectionState
        connectionState = state
        if previous == .connected, state != .connected {
            moveUnackedToOffline()
        }
        if case .reconnecting(let attempt) = state, state != previous, attempt == 1 {
            refreshCapabilitiesAfterConnectionLost()
        }
    }

    private func refreshCapabilitiesAfterConnectionLost() {
        guard let manager = capabilityManager else { return }
        Task { [weak self] in
            await manager.refresh()
            guard let self else { return }
            if let current = manager.selectedHive, manager.hives.contains(current) {
                // Hive still exists; the socket keeps backing off and the banner offers retry-now.
            } else {
                // After the 6 s auto-clear the banner falls back to "Not connected… Retry";
                // Retry → connectIfPossible() → no valid hive → disconnect(). Accepted (§7).
                self.lastError = UserFacingError("This hive is no longer available.")
                self.socket.disconnect()
            }
        }
    }

    /// Clears no queue state on purpose: entries keep their hive stamp and go out on
    /// the next connect to that hive (§7 *Hive switch*).
    func disconnect() {
        pendingAgentDM = nil
        pendingDMRequestId = nil
        socket.disconnect()
    }

    // MARK: - Sending

    @discardableResult
    private func send(_ outgoing: TeamWSOutgoing) -> Bool {
        guard let data = try? outgoing.encode() else {
            Log.team.error("failed to encode outgoing frame")
            return false
        }
        return socket.send(data)
    }

    /// Send and return the request UUID for correlation; nil when not connected.
    private func sendWithId(_ outgoing: TeamWSOutgoing) -> String? {
        guard socket.isConnected, let result = try? outgoing.encodeWithId() else { return nil }
        guard socket.send(result.data) else { return nil }
        return result.id
    }

    private func sendAttachment(_ attachment: AttachmentData, channelId: String) {
        let base64 = attachment.data.base64EncodedString()
        if attachment.mimeType.hasPrefix("image/") {
            _ = sendWithId(.teamImage(channelId: channelId, data: base64, filename: attachment.name))
        } else {
            _ = sendWithId(.teamFile(channelId: channelId, data: base64, filename: attachment.name, mimetype: attachment.mimeType))
        }
    }

    // MARK: - Public Actions

    func sendMessage(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = pendingAttachment
        guard !trimmed.isEmpty || attachment != nil,
              let channelId = activeChannelId,
              let context = modelContext else { return }

        if trimmed.hasPrefix("/") {
            sendSlashCommand(text: trimmed, channelId: channelId)
            messageText = ""
            speechManager?.liveText = ""
            pendingAttachment = nil
            return
        }

        let effectiveText = trimmed.isEmpty ? (attachment?.name ?? "") : trimmed
        let localId = UUID().uuidString
        let message = TeamMessage(
            id: localId,
            channelId: channelId,
            senderId: deviceId,
            senderType: SenderType.person.wireValue,
            senderName: credentials.deviceName ?? "Me",
            text: effectiveText,
            pending: true
        )
        context.insert(message)
        try? context.save()

        if connectionState == .connected,
           let requestId = sendWithId(.teamMessage(channelId: channelId, text: trimmed, threadId: nil)) {
            pendingMessageIds[requestId] = localId
            if let attachment {
                sendAttachment(attachment, channelId: channelId)   // untracked, as today
            }
        } else {
            offlineEntries.append(OfflineEntry(localId: localId, hive: activeHive ?? ""))
            if let attachment {
                offlineAttachments[localId] = attachment
            }
        }

        refreshActiveMessages()
        lastLiveMessageId = localId
        messageText = ""
        speechManager?.liveText = ""
        pendingAttachment = nil
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

        send(.history(channelId: channelId, before: before, limit: 50))
    }

    func fetchChannels() {
        send(.channelList)
    }

    func joinChannel(channelId: String) {
        // Only join if not already in local store
        guard let context = modelContext else { return }
        let cid = channelId
        let descriptor = FetchDescriptor<TeamChannel>(
            predicate: #Predicate { $0.id == cid }
        )
        if (try? context.fetch(descriptor).first) != nil { return }
        send(.join(channelId: channelId))
    }

    func leaveChannel(channelId: String) {
        send(.leave(channelId: channelId))
    }

    // MARK: - Private: Connection

    private func onConnected() {
        pendingAgentDM = nil
        pendingDMRequestId = nil
        fetchChannels()
        send(.agentList)
        send(.commandList)
        // Reconnect gap-fill: fetch latest messages for the active channel.
        // Use fetchHistory (not direct send) so cursor and loading state
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
        // Bookkeeping frames first, then the offline queue for this hive (§7).
        resendOfflineEntries()
    }

    func resetForPairingTeardown() {
        disconnect()
        // The synchronous transition-out collection has now finished.
        offlineEntries.removeAll()
        offlineAttachments.removeAll()
        pendingMessageIds.removeAll()
        activeHive = nil
        isAuthenticated = false
    }

    private func handleAuthFailure() {
        resetForPairingTeardown()
        onAuthFailure?()
    }

    // MARK: - Private: Offline queue

    /// Leaving `.connected`: every sent-but-un-acked message re-sends on the next
    /// connect to this hive rather than staying "sending" forever. Ordered by the row's
    /// `createdAt`; ids whose row is already gone are appended and dropped at re-send.
    private func moveUnackedToOffline() {
        guard !pendingMessageIds.isEmpty else { return }
        let localIds = Array(pendingMessageIds.values)
        pendingMessageIds.removeAll()
        let hive = activeHive ?? ""

        var ordered: [String] = []
        if let context = modelContext {
            let ids = localIds
            let descriptor = FetchDescriptor<TeamMessage>(
                predicate: #Predicate { ids.contains($0.id) },
                sortBy: [SortDescriptor(\TeamMessage.createdAt)]
            )
            ordered = ((try? context.fetch(descriptor)) ?? []).map(\.id)
        }
        for id in localIds where !ordered.contains(id) {
            ordered.append(id)
        }
        for id in ordered where !offlineEntries.contains(where: { $0.localId == id }) {
            offlineEntries.append(OfflineEntry(localId: id, hive: hive))
        }
    }

    /// End of `onConnected()`: re-send, in order, only the entries stamped with the hive
    /// just connected. A missing row (channel archived/left meanwhile) drops the entry;
    /// a `sendWithId` nil stops the pass and leaves the rest queued.
    private func resendOfflineEntries() {
        guard let context = modelContext, let hive = activeHive else { return }
        for entry in offlineEntries where entry.hive == hive {
            let lid = entry.localId
            let descriptor = FetchDescriptor<TeamMessage>(
                predicate: #Predicate { $0.id == lid }
            )
            guard let row = try? context.fetch(descriptor).first else {
                offlineEntries.removeAll { $0.localId == lid }
                offlineAttachments.removeValue(forKey: lid)
                continue
            }
            guard let requestId = sendWithId(.teamMessage(channelId: row.channelId, text: row.text, threadId: row.threadId)) else {
                break
            }
            pendingMessageIds[requestId] = lid
            if let attachment = offlineAttachments.removeValue(forKey: lid) {
                sendAttachment(attachment, channelId: row.channelId)
            }
            offlineEntries.removeAll { $0.localId == lid }
        }
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
        guard connectionState == .connected, let requestId = sendWithId(command) else {
            lastError = UserFacingError(Self.notConnectedText)   // no pending* state touched
            return
        }
        pendingCommandChannels[requestId] = channelId
        // Track /new commands for auto-refresh
        if commandName == "new" || commandName == "dm" {
            pendingNewCommands.insert(requestId)
        }
    }

    func openAgentDM(agent: TeamAgentInfo) {
        // 1. Search for existing DM with this agent
        if let dm = channels.first(where: { $0.kind == .dm && $0.members.contains(agent.id) }) {
            selectChannel(dm.id)
            return
        }

        // 2. Ignore if a /dm creation is already in flight (prevents overwriting
        //    the pending request ID on rapid taps, which would break suppression).
        guard pendingAgentDM == nil else { return }

        // 3. Not found — create via /dm command. Send agent id so the server's
        // AgentResolver doesn't have to do a display-name lookup (KPR-11).
        let command = TeamWSOutgoing.command(channelId: "", name: "dm", args: [agent.id])
        guard connectionState == .connected, let requestId = sendWithId(command) else {
            lastError = UserFacingError(Self.notConnectedText)
            return
        }

        pendingNewCommands.insert(requestId)
        pendingAgentDM = agent.id
        pendingDMRequestId = requestId
    }

    // MARK: - Private: Incoming Message Handling

    private func handleIncoming(_ incoming: TeamWSIncoming) {
        guard let context = modelContext else { return }

        switch incoming {
        case .teamMessage(let text, let channelId, let agentId, let agentName, _):
            let message = TeamMessage(
                channelId: channelId,
                senderId: agentId,
                senderType: SenderType.agent.wireValue,
                senderName: agentName,
                text: text
            )
            context.insert(message)
            try? context.save()

            updateChannelPreview(channelId: channelId, text: text, context: context)
            refreshActiveMessages()
            if channelId == activeChannelId {
                lastLiveMessageId = message.id
                if autoReadAloud {
                    speechManager?.speak(text, agentId: agentId)
                }
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

            // Suppress /dm system response when initiated from openAgentDM.
            // Only clear pendingDMRequestId here; pendingAgentDM is cleared by
            // syncChannels when it finds the DM (fetchChannels is async).
            if let replyTo, replyTo == pendingDMRequestId {
                pendingDMRequestId = nil
                return  // Navigation is the feedback; don't insert message
            }

            guard let targetChannelId = channelId ?? activeChannelId else { return }

            let message = TeamMessage(
                channelId: targetChannelId,
                senderId: "system",
                senderType: SenderType.agent.wireValue,
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
            // Seed previews with 1-message history per channel.
            // Skip the active channel — a full-page fetch is already in flight
            // from onConnected/selectChannel, and a seeding response would
            // prematurely clear isLoadingHistory and corrupt the cursor.
            for info in channelInfos {
                guard info.id != activeChannelId else { continue }
                send(.history(channelId: info.id, before: nil, limit: 1))
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
            pendingAgentDM = nil
            pendingDMRequestId = nil
            Log.team.error("server error: \(message, privacy: .private)")
            lastError = UserFacingError(message)

        case .pong:
            break

        case .agentList(let agents, _):
            self.agents = agents
            recomputeSortedAgents()

        case .commandList:
            break
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
                    type: info.type.wireValue,
                    name: info.name,
                    members: info.members
                )
                context.insert(channel)
            }
        }

        try? context.save()
        loadChannels(context: context)

        // Auto-select DM after /dm creation.
        if let agentId = pendingAgentDM {
            if let dm = channels.first(where: { $0.kind == .dm && $0.members.contains(agentId) }) {
                // Success: DM found — navigate and clear.
                pendingAgentDM = nil
                selectChannel(dm.id)
            } else if pendingDMRequestId == nil {
                // Failure: suppression already fired (cleared pendingDMRequestId)
                // but the DM was not created. Clear to unblock openAgentDM.
                pendingAgentDM = nil
            }
            // Otherwise pendingDMRequestId is still set (systemMessage hasn't arrived
            // yet, e.g. channel_event "created" raced ahead) — keep waiting.
        }
    }

    private func loadChannels(context: ModelContext) {
        let descriptor = FetchDescriptor<TeamChannel>(
            sortBy: [SortDescriptor(\TeamChannel.lastMessageAt, order: .reverse)]
        )
        channels = (try? context.fetch(descriptor)) ?? []
        recomputeSortedAgents()
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
            if histMsg.senderType == .agent && existingContentKeys.contains(contentKey) {
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
                senderType: histMsg.senderType.wireValue,
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
            channels.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
            recomputeSortedAgents()
        }
    }


    /// Resolve a channel's user-facing title. For DMs the server's `name`
    /// reflects the user's own device (the counterparty from the server's
    /// perspective), which is useless to the person reading the app. Replace
    /// it with the agent name by matching channel members against agents.
    func displayName(for channel: TeamChannel) -> String {
        if channel.kind == .dm {
            if let agent = agents.first(where: { channel.members.contains($0.id) }) {
                return agent.name
            }
            return channel.name
        }
        return channel.kind == .channel ? "#\(channel.name)" : channel.name
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

    /// Rebuild `sortedAgents` from current `agents` and `channels`.
    /// DM predicate (`type == "dm"` + members contains agent.id) intentionally
    /// matches the existing predicate in `openAgentDM(agent:)` and `syncChannels`
    /// so sidebar display and DM navigation stay consistent.
    func recomputeSortedAgents() {
        let paired: [(agent: TeamAgentInfo, dmChannel: TeamChannel?)] = agents.map { agent in
            let dm = channels.first { $0.kind == .dm && $0.members.contains(agent.id) }
            return (agent: agent, dmChannel: dm)
        }
        sortedAgents = paired.sorted { lhs, rhs in
            let lDate = lhs.dmChannel?.lastMessageAt
            let rDate = rhs.dmChannel?.lastMessageAt
            switch (lDate, rDate) {
            case let (l?, r?):
                if l != r { return l > r }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }
            return lhs.agent.name.localizedCaseInsensitiveCompare(rhs.agent.name) == .orderedAscending
        }
    }
}
