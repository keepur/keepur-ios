import SwiftUI

struct TeamChatView: View {
    @ObservedObject var viewModel: TeamViewModel

    private var deviceId: String {
        KeychainManager.deviceId ?? ""
    }

    private var channelTitle: String {
        guard let channelId = viewModel.activeChannelId,
              let channel = viewModel.channels.first(where: { $0.id == channelId }) else {
            return "Team"
        }
        return channel.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(channelTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
                            isOwnMessage: message.senderId == deviceId
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: viewModel.lastLiveMessageId) {
                // Only scroll to bottom on live incoming messages, NOT on
                // history pagination (which prepends older messages and should
                // preserve scroll position).
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

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message...", text: $viewModel.messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                )
                .lineLimit(1...6)
                .onSubmit {
                    viewModel.sendMessage(text: viewModel.messageText)
                }

            Button {
                viewModel.sendMessage(text: viewModel.messageText)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.gray.opacity(0.3) : Color.accentColor
                    )
            }
            .disabled(
                viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
