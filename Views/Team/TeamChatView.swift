import SwiftUI

struct TeamChatView: View {
    @ObservedObject var viewModel: TeamViewModel
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
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    if let speechManager = viewModel.speechManager {
                        Button {
                            if speechManager.isSpeaking {
                                speechManager.stopSpeaking()
                            } else {
                                autoReadAloud.toggle()
                            }
                        } label: {
                            Image(systemName: speechManager.isSpeaking ? "stop.circle.fill"
                                  : autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash")
                                .font(.subheadline)
                        }
                        .foregroundStyle(speechManager.isSpeaking ? .red
                                         : autoReadAloud ? Color.accentColor : Color.secondary)
                    }

                    if isDMWithAgent {
                        Button { showAgentDetail = true } label: {
                            Image(systemName: "info.circle")
                        }
                    }
                }
            }
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

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.isLoadingHistory {
                        ProgressView()
                            .padding()
                    } else if viewModel.hasMoreHistory {
                        Button("Load earlier messages") {
                            if let channelId = viewModel.activeChannelId {
                                viewModel.fetchHistory(channelId: channelId)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
