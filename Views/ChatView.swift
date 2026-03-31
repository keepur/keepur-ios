import SwiftUI
import SwiftData
import UIKit

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let sessionId: String
    @Query(sort: \Message.timestamp) private var allMessages: [Message]
    @State private var showSettings = false
    @State private var autoReadAloud: Bool = UserDefaults.standard.bool(forKey: "autoReadAloud") {
        didSet { UserDefaults.standard.set(autoReadAloud, forKey: "autoReadAloud") }
    }

    private var messages: [Message] {
        allMessages.filter { $0.sessionId == sessionId }
    }

    @Query private var allSessions: [Session]

    private var navigationTitle: String {
        guard let session = allSessions.first(where: { $0.id == sessionId }) else { return "Keepur" }
        let name = URL(fileURLWithPath: session.path).lastPathComponent
        return name.isEmpty ? "Keepur" : name
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages, id: \.id) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if viewModel.currentSessionId == sessionId &&
                            (viewModel.currentStatus == "thinking" || viewModel.currentStatus == "tool_running") {
                            StatusIndicator(status: viewModel.currentStatus)
                                .id("status")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) {
                    withAnimation {
                        proxy.scrollTo(messages.last?.id ?? "status", anchor: .bottom)
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

            if viewModel.currentSessionId == sessionId {
                inputBar
            } else {
                readOnlyBar
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    // Read aloud toggle
                    Button {
                        autoReadAloud.toggle()
                    } label: {
                        Image(systemName: autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash")
                            .font(.subheadline)
                    }
                    .foregroundStyle(autoReadAloud ? Color.accentColor : Color.secondary)

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
        .sheet(item: Binding(
            get: {
                guard let approval = viewModel.pendingApproval,
                      approval.sessionId == nil || approval.sessionId == sessionId else { return nil }
                return approval
            },
            set: { viewModel.pendingApproval = $0 }
        )) { approval in
            ToolApprovalView(
                approval: approval,
                onApprove: { viewModel.approve(toolUseId: approval.id) },
                onDeny: { viewModel.deny(toolUseId: approval.id) }
            )
            .interactiveDismissDisabled()
        }
        .onAppear {
            viewModel.autoReadAloud = autoReadAloud
        }
        .onChange(of: autoReadAloud) {
            viewModel.autoReadAloud = autoReadAloud
        }
    }

    // MARK: - Input Bar (active session)

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Voice button
            VoiceButton(speechManager: viewModel.speechManager) {
                viewModel.sendVoiceText()
            }

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
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Read-only Bar (old sessions)

    private var readOnlyBar: some View {
        HStack {
            Spacer()
            Text("Session ended — read only")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 12)
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
