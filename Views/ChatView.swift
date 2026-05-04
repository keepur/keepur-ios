import SwiftUI
import SwiftData

// MARK: - Cross-platform image helpers

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension URL {
    var mimeType: String {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    let sessionId: String
    @Environment(\.dismiss) private var dismiss
    @Query private var messages: [Message]
    @Query private var matchingSessions: [Session]
    @State private var autoReadAloud: Bool = UserDefaults.standard.bool(forKey: "autoReadAloud") {
        didSet { UserDefaults.standard.set(autoReadAloud, forKey: "autoReadAloud") }
    }

    init(viewModel: ChatViewModel, sessionId: String) {
        self.viewModel = viewModel
        self.sessionId = sessionId
        let sid = sessionId
        let msgDescriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.sessionId == sid },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        _messages = Query(msgDescriptor)
        var sessDescriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == sid }
        )
        sessDescriptor.fetchLimit = 1
        _matchingSessions = Query(sessDescriptor)
    }

    private var navigationTitle: String {
        matchingSessions.first?.displayName ?? "Keepur"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: KeepurTheme.Spacing.s3) {
                        ForEach(messages, id: \.id) { message in
                            MessageBubble(
                                message: message,
                                showWaitingBadge: viewModel.pendingMessageIds.contains(message.id),
                                onSpeak: message.role == "assistant" ? { text in
                                    viewModel.speechManager.speak(text)
                                } : nil
                            )
                                .id(message.id)
                        }

                        if ["thinking", "tool_running", "tool_starting", "busy"].contains(viewModel.statusFor(sessionId)) {
                            StatusIndicator(status: viewModel.statusFor(sessionId), toolName: viewModel.toolNameFor(sessionId), onCancel: { viewModel.cancelCurrentOperation(for: sessionId) })
                                .id("status")
                        }
                    }
                    .padding(.horizontal, KeepurTheme.Spacing.s4)
                    .padding(.vertical, KeepurTheme.Spacing.s3)
                }
                .onAppear {
                    if let lastId = messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) {
                    withAnimation {
                        proxy.scrollTo(messages.last?.id ?? "status", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.sessionStatuses[sessionId]) {
                    if ["thinking", "tool_running", "tool_starting", "busy"].contains(viewModel.statusFor(sessionId)) {
                        withAnimation {
                            proxy.scrollTo("status", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            if viewModel.currentSessionId == sessionId {
                MessageInputBar(
                    messageText: $viewModel.messageText,
                    pendingAttachment: $viewModel.pendingAttachment,
                    speechManager: viewModel.speechManager,
                    onSend: { viewModel.sendText() }
                )
            } else {
                readOnlyBar
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                KeepurChatHeader.BackButton(onBack: backAction)
            }
            ToolbarItem(placement: .principal) {
                KeepurChatHeader.TitleBlock(
                    title: navigationTitle,
                    statusText: headerStatusText,
                    statusDate: headerStatusDate,
                    isStatusActive: headerIsStatusActive
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                KeepurChatHeader.TrailingStack(actions: headerTrailingActions)
            }
            #else
            ToolbarItem(placement: .automatic) { chatHeader }
            #endif
        }
        .sheet(item: Binding(
            get: {
                viewModel.pendingApprovals[sessionId]
            },
            set: { viewModel.pendingApprovals[sessionId] = $0 }
        )) { approval in
            ToolApprovalView(
                approval: approval,
                onApprove: { viewModel.approve(toolUseId: approval.id, sessionId: sessionId) },
                onDeny: { viewModel.deny(toolUseId: approval.id, sessionId: sessionId) }
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

    // MARK: - Chat Header

    private var chatHeader: KeepurChatHeader {
        KeepurChatHeader(
            title: navigationTitle,
            statusText: headerStatusText,
            statusDate: headerStatusDate,
            isStatusActive: headerIsStatusActive,
            onBack: backAction,
            trailingActions: headerTrailingActions
        )
    }

    static func mapSessionStatus(_ status: String) -> (text: String?, isActive: Bool) {
        switch status {
        case "idle": return (nil, false)
        case "thinking": return ("thinking", true)
        case "tool_running": return ("running tool", true)
        case "tool_starting": return ("starting tool", true)
        case "busy": return ("server busy", true)
        default: return (status, false)
        }
    }

    private var headerStatusText: String? { Self.mapSessionStatus(viewModel.statusFor(sessionId)).text }
    private var headerIsStatusActive: Bool { Self.mapSessionStatus(viewModel.statusFor(sessionId)).isActive }
    private var headerStatusDate: Date? { messages.last?.timestamp }

    private var backAction: (() -> Void)? {
        #if os(iOS)
        return { dismiss() }
        #else
        return nil
        #endif
    }

    private var headerTrailingActions: [KeepurChatHeader.Action] {
        [
            .init(symbol: speakerSymbol) {
                if viewModel.speechManager.isSpeaking {
                    viewModel.speechManager.stopSpeaking()
                } else {
                    autoReadAloud.toggle()
                }
            }
        ]
    }

    private var speakerSymbol: String {
        if viewModel.speechManager.isSpeaking { return "stop.circle.fill" }
        return autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash"
    }

    // MARK: - Read-only Bar (old sessions)

    private var readOnlyBar: some View {
        HStack {
            Spacer()
            Text("Session ended — read only")
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            Spacer()
        }
        .padding(.vertical, KeepurTheme.Spacing.s3)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let status: String
    var toolName: String? = nil
    var onCancel: (() -> Void)? = nil
    @State private var phase = 0.0

    var body: some View {
        HStack {
            HStack(spacing: KeepurTheme.Spacing.s1 + 2) {
                if status == "thinking" {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(KeepurTheme.Color.fgSecondaryDynamic)
                            .frame(width: 8, height: 8)
                            .offset(y: sin(phase + Double(i) * 0.8) * 4)
                    }
                } else if status == "busy" {
                    Image(systemName: "clock")
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    Text("Server busy...")
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                } else {
                    Image(systemName: "hammer.fill")
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    Text("Running \(toolName ?? "tool")...")
                        .font(KeepurTheme.Font.caption)
                        .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                }

                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(KeepurTheme.Font.caption)
                            .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                    }
                }
            }
            .padding(.horizontal, KeepurTheme.Spacing.s4)
            .padding(.vertical, KeepurTheme.Spacing.s3)
            .background(
                RoundedRectangle(cornerRadius: KeepurTheme.Radius.lg)
                    .fill(KeepurTheme.Color.bgSunkenDynamic)
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
