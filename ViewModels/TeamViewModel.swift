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
    private let saveOperation: (ModelContext) throws -> Void
    /// Read on every use so a re-pair (new device id) is picked up immediately.
    private var deviceId: String { credentials.deviceId ?? "" }
    private var pendingCommandChannels: [String: String] = [:]  // requestId -> channelId
    private var pendingMessageIds: [String: String] = [:]       // requestId -> local message id
    private var pendingNewCommands: Set<String> = []             // requestIds for /new commands
    private struct RequestOwner: Equatable {
        let generation: UUID
        let hive: String
    }
    private struct HistoryRequest {
        let id: String
        let channelId: String
        let owner: RequestOwner
    }
    private var connectionGeneration = UUID()
    private var activeHistoryRequest: HistoryRequest?
    private var seedHistoryRequests: [String: HistoryRequest] = [:]

    private var currentRequestOwner: RequestOwner? {
        guard connectionState == .connected, let hive = activeHive else { return nil }
        return RequestOwner(generation: connectionGeneration, hive: hive)
    }
    private func retireFullHistory() {
        activeHistoryRequest = nil
        isLoadingHistory = false
    }
    private func retireHistoryRequests() {
        retireFullHistory()
        seedHistoryRequests.removeAll()
    }
    private func retireHistoryRequests(channelId: String) {
        if activeHistoryRequest?.channelId == channelId { retireFullHistory() }
        seedHistoryRequests = seedHistoryRequests.filter { $0.value.channelId != channelId }
    }
    private func removedChannel(_ channelId: String) {
        retireHistoryRequests(channelId: channelId)
        if activeChannelId == channelId {
            activeChannelId = nil
            activeMessages = []
            isLoadingHistory = false
        }
    }
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
        lastErrorAutoClear: Duration = .seconds(6),
        saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.socket = socket ?? BeekeeperSocket(config: .standard, credentials: credentials)
        self.credentials = credentials
        self.lastErrorAutoClear = lastErrorAutoClear
        self.saveOperation = saveOperation
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
        if activeHive != channel {
            retireHistoryRequests()
            connectionGeneration = UUID()
        }
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
            retireHistoryRequests()
            connectionGeneration = UUID()
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
        retireHistoryRequests()
        connectionGeneration = UUID()
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
        save(context, "team.sendMessage.save")

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
        retireFullHistory()
        activeChannelId = channelId
        hasMoreHistory = true
        refreshActiveMessages()

        // Reset the selected channel to its latest page; history identities prevent repeat inserts.
        if let context = modelContext {
            let cid = channelId
            let channelDescriptor = FetchDescriptor<TeamChannel>(
                predicate: #Predicate { $0.id == cid }
            )
            if let channel = context.fetchOrEmpty(channelDescriptor, "team.selectChannel.fetch").first {
                channel.lastServerMessageId = nil
            }
        }

        fetchHistory(channelId: channelId)
    }

    func fetchHistory(channelId: String) {
        guard channelId == activeChannelId, activeHistoryRequest == nil,
              let owner = currentRequestOwner else { return }
        var before: String?
        if let context = modelContext {
            let cid = channelId
            let descriptor = FetchDescriptor<TeamChannel>(predicate: #Predicate { $0.id == cid })
            before = context.fetchOrEmpty(descriptor, "team.fetchHistory.fetch").first?.lastServerMessageId
        }
        guard let id = sendWithId(.history(channelId: channelId, before: before, limit: 50)) else {
            return
        }
        activeHistoryRequest = HistoryRequest(id: id, channelId: channelId, owner: owner)
        isLoadingHistory = true
    }

    private func seedHistory(channelId: String) {
        guard let owner = currentRequestOwner,
              let id = sendWithId(.history(channelId: channelId, before: nil, limit: 1)) else { return }
        seedHistoryRequests[id] = HistoryRequest(id: id, channelId: channelId, owner: owner)
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
        if context.fetchOrEmpty(descriptor, "team.joinChannel.fetch").first != nil { return }
        send(.join(channelId: channelId))
    }

    func leaveChannel(channelId: String) {
        send(.leave(channelId: channelId))
    }

    // MARK: - Private: Connection

    private func onConnected() {
        retireHistoryRequests()
        connectionGeneration = UUID()
        pendingAgentDM = nil
        pendingDMRequestId = nil
        fetchChannels()
        send(.agentList)
        send(.commandList)
        // Reconnect gap-fill: fetch latest messages for the active channel.
        // Use fetchHistory (not direct send) so cursor and loading state
        // are managed correctly and we don't race with seeding fetches.
        if let channelId = activeChannelId {
            hasMoreHistory = true
            // Reset cursor so we get the latest page, not stale pagination
            if let context = modelContext {
                let cid = channelId
                let descriptor = FetchDescriptor<TeamChannel>(
                    predicate: #Predicate { $0.id == cid }
                )
                if let channel = context.fetchOrEmpty(descriptor, "team.onConnected.fetch").first {
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
            ordered = context.fetchOrEmpty(descriptor, "team.moveUnacked.fetch").map(\.id)
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
            guard let row = context.fetchOrEmpty(descriptor, "team.resendOffline.fetch").first else {
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
            save(context, "team.message.save")

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
            save(context, "team.systemMessage.save")

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
                seedHistory(channelId: info.id)
            }

        case .history(let channelId, let messages, let hasMore, let id):
            receiveHistory(id: id, channelId: channelId, messages: messages, hasMore: hasMore, context: context)

        case .channelEvent(let channelId, let event, let memberId, _):
            handleChannelEvent(channelId: channelId, event: event, memberId: memberId, context: context)

        case .ack(let id):
            // Mark pending message as sent
            if let localId = pendingMessageIds.removeValue(forKey: id) {
                let lid = localId
                let descriptor = FetchDescriptor<TeamMessage>(
                    predicate: #Predicate { $0.id == lid }
                )
                if let msg = context.fetchOrEmpty(descriptor, "team.ack.fetch").first {
                    msg.pending = false
                    save(context, "team.ack.save")
                    refreshActiveMessages()
                }
            }

        case .typing:
            break // Deliberately ignored: the current Team UI has no typing surface.

        case .error(let message):
            retireFullHistory()
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
            break // Deliberately ignored: slash commands use the existing free-form input.
        }
    }

    // MARK: - Private: Channel Sync

    private func syncChannels(_ channelInfos: [TeamChannelInfo], context: ModelContext) {
        let serverIds = Set(channelInfos.map(\.id))

        // Fetch all local channels
        let descriptor = FetchDescriptor<TeamChannel>()
        let localChannels = context.fetchOrEmpty(descriptor, "team.syncChannels.fetch")

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

        save(context, "team.syncChannels.save")
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
        channels = context.fetchOrEmpty(descriptor, "team.loadChannels.fetch")
        recomputeSortedAgents()
    }

    // MARK: - Private: Correlated History

    private func receiveHistory(id: String, channelId: String, messages: [TeamHistoryMessage],
                                hasMore: Bool, context: ModelContext) {
        if let request = activeHistoryRequest, request.id == id {
            guard request.channelId == channelId, activeChannelId == channelId,
                  request.owner == currentRequestOwner else {
                Log.team.debug("ignoring history with mismatched active ownership")
                return
            }
            retireFullHistory()
            self.hasMoreHistory = hasMore
            processHistory(channelId: channelId, messages: messages, context: context)
            return
        }
        if let request = seedHistoryRequests[id] {
            guard request.channelId == channelId, request.owner == currentRequestOwner else {
                Log.team.debug("ignoring history with mismatched preview ownership")
                return
            }
            seedHistoryRequests.removeValue(forKey: id)
            if let newest = messages.max(by: HistoryMerger.chronological) {
                updateChannelPreview(channelId: channelId, text: newest.text,
                                     date: newest.createdAt, context: context)
            }
            return
        }
        Log.team.debug("ignoring unregistered history response")
    }

    private func processHistory(channelId: String, messages: [TeamHistoryMessage], context: ModelContext) {
        let cid = channelId
        let channelDescriptor = FetchDescriptor<TeamChannel>(predicate: #Predicate { $0.id == cid })
        if let oldest = messages.min(by: HistoryMerger.chronological),
           let channel = context.fetchOrEmpty(channelDescriptor, "team.history.cursor.fetch").first {
            channel.lastServerMessageId = oldest.id
        }
        let descriptor = FetchDescriptor<TeamMessage>(predicate: #Predicate { $0.channelId == cid })
        let fetched = context.fetchOrEmpty(descriptor, "team.history.messages.fetch")
        let foreignIds = Set(offlineEntries.filter { $0.hive != activeHive }.map(\.localId))
        let rows = fetched.filter { !foreignIds.contains($0.id) }
        let snapshots = rows.map { row in
            TeamMessageSnapshot(id: row.id, serverId: row.serverId, channelId: row.channelId,
                senderId: row.senderId, senderType: row.typedSenderType, senderName: row.senderName,
                text: row.text, threadId: row.threadId, createdAt: row.createdAt, pending: row.pending)
        }
        let result = HistoryMerger.merge(existing: snapshots, incoming: messages,
                                         ownDeviceId: deviceId, now: .now)
        for row in rows {
            if let serverId = result.serverIdStamps[row.id] { row.serverId = serverId }
            if result.unpendIds.contains(row.id) { row.pending = false }
        }
        // Do not let a conflicting incoming local ID upsert a protected foreign row.
        for incoming in result.inserts where !foreignIds.contains(incoming.id) {
            context.insert(TeamMessage(id: incoming.id, serverId: incoming.id,
                channelId: incoming.channelId, threadId: incoming.threadId,
                senderId: incoming.senderId, senderType: incoming.senderType.wireValue,
                senderName: incoming.senderName, text: incoming.text,
                createdAt: incoming.createdAt, pending: false))
        }
        save(context, "team.history.save")
        if let newest = messages.max(by: HistoryMerger.chronological) {
            updateChannelPreview(channelId: channelId, text: newest.text,
                                 date: newest.createdAt, context: context)
        }
        refreshActiveMessages()
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
                if let channel = context.fetchOrEmpty(descriptor, "team.channelEvent.joined.fetch").first,
                   !channel.members.contains(memberId) {
                    channel.members.append(memberId)
                    save(context, "team.channelEvent.joined.save")
                }
            }
        case "left":
            if memberId == deviceId {
                let cid = channelId
                let descriptor = FetchDescriptor<TeamChannel>(
                    predicate: #Predicate { $0.id == cid }
                )
                if let channel = context.fetchOrEmpty(descriptor, "team.channelEvent.left.fetch").first {
                    context.delete(channel)
                    save(context, "team.channelEvent.left.save")
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
            if let channel = context.fetchOrEmpty(descriptor, "team.channelEvent.archived.fetch").first {
                context.delete(channel)
                save(context, "team.channelEvent.archived.save")
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

    private func updateChannelPreview(channelId: String, text: String, date: Date = .now,
                                      context: ModelContext) {
        let cid = channelId
        let descriptor = FetchDescriptor<TeamChannel>(predicate: #Predicate { $0.id == cid })
        guard let channel = context.fetchOrEmpty(descriptor, "team.preview.fetch").first else { return }
        if let previous = channel.lastMessageAt, date < previous { return }
        channel.lastMessageText = String(text.prefix(100))
        channel.lastMessageAt = date
        save(context, "team.preview.save")
        channels.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }
        recomputeSortedAgents()
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
        activeMessages = context.fetchOrEmpty(descriptor, "team.activeMessages.fetch")
    }

    private func save(_ context: ModelContext, _ what: StaticString) {
        if context.saveReporting(what, operation: { try saveOperation(context) }) != nil {
            lastError = UserFacingError("Couldn't save. Your last change may not be kept.")
        }
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
