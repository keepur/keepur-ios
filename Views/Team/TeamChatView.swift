import SwiftUI

struct TeamChatView: View {
    @ObservedObject var viewModel: TeamViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAgentDetail = false
    @State private var autoReadAloud: Bool = UserDefaults.standard.bool(forKey: "teamAutoReadAloud") {
        didSet { UserDefaults.standard.set(autoReadAloud, forKey: "teamAutoReadAloud") }
    }

    private var deviceId: String {
        KeychainManager.deviceId ?? ""
    }

    private var activeAgent: TeamAgentInfo? {
        guard let channelId = viewModel.activeChannelId,
              let channel = viewModel.channels.first(where: { $0.id == channelId }),
              channel.type == "dm" else { return nil }
        return viewModel.agents.first { channel.members.contains($0.id) }
    }

    private var isDMWithAgent: Bool { activeAgent != nil }

    private var channelTitle: String {
        guard let channelId = viewModel.activeChannelId,
              let channel = viewModel.channels.first(where: { $0.id == channelId }) else {
            return "Team"
        }
        return viewModel.displayName(for: channel)
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            if let speechManager = viewModel.speechManager {
                MessageInputBar(
                    messageText: $viewModel.messageText,
                    pendingAttachment: $viewModel.pendingAttachment,
                    speechManager: speechManager,
                    onSend: { viewModel.sendMessage(text: viewModel.messageText) }
                )
            }
        }
        .navigationTitle(channelTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) { chatHeader }
            #else
            ToolbarItem(placement: .automatic) { chatHeader }
            #endif
        }
        .sheet(isPresented: $showAgentDetail) {
            if let agent = activeAgent, let speechManager = viewModel.speechManager {
                AgentDetailSheet(agent: agent, speechManager: speechManager)
                    .presentationDetents([.medium, .large])
            }
        }
        .onChange(of: viewModel.activeChannelId) {
            showAgentDetail = false
        }
        .onAppear {
            viewModel.autoReadAloud = autoReadAloud
        }
        .onChange(of: autoReadAloud) {
            viewModel.autoReadAloud = autoReadAloud
        }
    }

    // MARK: - Chat Header

    private var activeChannel: TeamChannel? {
        guard let id = viewModel.activeChannelId else { return nil }
        return viewModel.channels.first(where: { $0.id == id })
    }

    private var chatHeader: KeepurChatHeader {
        KeepurChatHeader(
            title: channelTitle,
            statusText: headerStatusText,
            statusDate: headerStatusDate,
            isStatusActive: headerIsStatusActive,
            onBack: backAction,
            trailingActions: headerTrailingActions
        )
    }

    static func mapAgentStatus(_ status: String?) -> (text: String?, isActive: Bool) {
        switch status {
        case nil, "idle": return (nil, false)
        case "processing": return ("working", true)
        case "error": return ("error", false)
        case "stopped": return ("stopped", false)
        case let other?: return (other, false)
        }
    }

    private var headerStatusText: String? { Self.mapAgentStatus(activeAgent?.status).text }
    private var headerIsStatusActive: Bool { Self.mapAgentStatus(activeAgent?.status).isActive }
    private var headerStatusDate: Date? { activeChannel?.lastMessageAt }

    private var backAction: (() -> Void)? {
        #if os(iOS)
        return { dismiss() }
        #else
        return nil
        #endif
    }

    private var headerTrailingActions: [KeepurChatHeader.Action] {
        var actions: [KeepurChatHeader.Action] = []
        if let speech = viewModel.speechManager {
            actions.append(.init(symbol: speakerSymbol(speech)) {
                if speech.isSpeaking { speech.stopSpeaking() } else { autoReadAloud.toggle() }
            })
        }
        if isDMWithAgent {
            actions.append(.init(symbol: "info.circle") { showAgentDetail = true })
        }
        return actions
    }

    private func speakerSymbol(_ speech: SpeechManager) -> String {
        if speech.isSpeaking { return "stop.circle.fill" }
        return autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash"
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: KeepurTheme.Spacing.s3) {
                    if viewModel.isLoadingHistory {
                        ProgressView()
                            .padding()
                    } else if viewModel.hasMoreHistory {
                        Button("Load earlier messages") {
                            if let channelId = viewModel.activeChannelId {
                                viewModel.fetchHistory(channelId: channelId)
                            }
                        }
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                        .padding(.vertical, KeepurTheme.Spacing.s2)
                    }

                    ForEach(viewModel.activeMessages, id: \.id) { message in
                        TeamMessageBubble(
                            message: message,
                            isOwnMessage: message.senderId == deviceId,
                            onSpeak: message.senderType == "agent" && message.senderId != "system" ? { text in
                                viewModel.speechManager?.speak(text, agentId: message.senderId)
                            } : nil
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, KeepurTheme.Spacing.s4)
                .padding(.vertical, KeepurTheme.Spacing.s3)
            }
            .onChange(of: viewModel.lastLiveMessageId) {
                if let lastId = viewModel.activeMessages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let lastId = viewModel.activeMessages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
}
