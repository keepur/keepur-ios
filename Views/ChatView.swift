import SwiftUI
import SwiftData
import UIKit

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Message.timestamp) private var messages: [Message]
    @State private var showSettings = false

    // Filter messages client-side by session. Acceptable for v1 single-user volume.
    private var sessionMessages: [Message] {
        guard let sessionId = viewModel.currentSessionId else { return [] }
        return messages.filter { $0.sessionId == sessionId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sessionMessages, id: \.id) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if viewModel.currentStatus == "thinking" || viewModel.currentStatus == "tool_running" {
                            StatusIndicator(status: viewModel.currentStatus)
                                .id("status")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: sessionMessages.count) {
                    withAnimation {
                        proxy.scrollTo(sessionMessages.last?.id ?? "status", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.currentStatus) {
                    if viewModel.currentStatus == "thinking" || viewModel.currentStatus == "tool_running" {
                        withAnimation {
                            proxy.scrollTo("status", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            inputBar
        }
        .navigationTitle(viewModel.currentWorkspace.isEmpty ? "Keepur" : viewModel.currentWorkspace)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Circle()
                    .fill(viewModel.ws.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        viewModel.newSession()
                    } label: {
                        Image(systemName: "plus.message")
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(item: $viewModel.pendingApproval) { approval in
            ToolApprovalView(
                approval: approval,
                onApprove: { viewModel.approve(toolUseId: approval.id) },
                onDeny: { viewModel.deny(toolUseId: approval.id) }
            )
            .interactiveDismissDisabled()
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("Message...", text: $viewModel.messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                )
                .lineLimit(1...6)
                .onSubmit { viewModel.sendText() }

            Button { viewModel.sendText() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.gray.opacity(0.3) : Color.accentColor
                    )
            }
            .disabled(
                viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || viewModel.currentSessionId == nil
                || viewModel.currentStatus == "session_ended"
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let status: String
    @State private var phase = 0.0

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                if status == "thinking" {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 8, height: 8)
                            .offset(y: sin(phase + Double(i) * 0.8) * 4)
                    }
                } else {
                    Image(systemName: "hammer.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Running tool...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.systemGray5))
            )
            Spacer()
        }
        .onAppear {
            if status == "thinking" {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    phase = .pi
                }
            }
        }
    }
}
