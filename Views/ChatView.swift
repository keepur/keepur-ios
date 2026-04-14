import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

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
    @Query(sort: \Message.timestamp) private var allMessages: [Message]
    @State private var showSettings = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showDocumentPicker = false
    @State private var showAttachmentOptions = false
    @State private var attachmentError: String?
    private static let maxAttachmentSize = 10 * 1024 * 1024 // 10 MB
    @State private var autoReadAloud: Bool = UserDefaults.standard.bool(forKey: "autoReadAloud") {
        didSet { UserDefaults.standard.set(autoReadAloud, forKey: "autoReadAloud") }
    }

    private var messages: [Message] {
        allMessages.filter { $0.sessionId == sessionId }
    }

    @Query private var allSessions: [Session]

    private var navigationTitle: String {
        guard let session = allSessions.first(where: { $0.id == sessionId }) else { return "Keepur" }
        return session.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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
                inputBar
            } else {
                readOnlyBar
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button {
                        if viewModel.speechManager.isSpeaking {
                            viewModel.speechManager.stopSpeaking()
                        } else {
                            autoReadAloud.toggle()
                        }
                    } label: {
                        Image(systemName: viewModel.speechManager.isSpeaking ? "stop.circle.fill"
                              : autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash")
                            .font(.subheadline)
                    }
                    .foregroundStyle(viewModel.speechManager.isSpeaking ? .red
                                     : autoReadAloud ? Color.accentColor : Color.secondary)

                    #if os(iOS)
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    #endif
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        #endif
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

    // MARK: - Input Bar (active session)

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let attachment = viewModel.pendingAttachment {
                attachmentPreview(name: attachment.name, data: attachment.data, mimeType: attachment.mimeType)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                // Attachment button
                Button { showAttachmentOptions = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .popover(isPresented: $showAttachmentOptions) {
                    VStack(spacing: 0) {
                        Button {
                            showAttachmentOptions = false
                            showDocumentPicker = true
                        } label: {
                            Label("Choose File", systemImage: "doc")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        Divider()

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Photo Library", systemImage: "photo")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .onChange(of: selectedPhoto) {
                            if selectedPhoto != nil { showAttachmentOptions = false }
                        }
                    }
                    .frame(width: 200)
                    .padding(.vertical, 4)
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

                // Voice button
                VoiceButton(speechManager: viewModel.speechManager)

                Button { viewModel.sendText() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            (viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingAttachment == nil)
                                ? Color.gray.opacity(0.3) : Color.accentColor
                        )
                }
                .disabled(
                    viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingAttachment == nil
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .onChange(of: selectedPhoto) {
            guard let item = selectedPhoto else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    attachmentError = "Could not load the selected photo."
                    selectedPhoto = nil
                    return
                }
                guard data.count <= Self.maxAttachmentSize else {
                    attachmentError = "File is too large. Maximum size is 10 MB."
                    selectedPhoto = nil
                    return
                }
                let contentType = item.supportedContentTypes.first
                let mimeType = contentType?.preferredMIMEType ?? "image/jpeg"
                let ext = contentType?.preferredFilenameExtension ?? "jpg"
                let name = "image_\(Int(Date().timeIntervalSince1970)).\(ext)"
                viewModel.pendingAttachment = (data: data, name: name, mimeType: mimeType)
                selectedPhoto = nil
            }
        }
        .onReceive(viewModel.speechManager.$liveText) { newText in
            // No `isRecording` gate: the stream transcriber's final callback
            // (carrying the last confirmed text) hops to MainActor *after*
            // `stopRecording()` has already flipped `isRecording` to false.
            // Gating here drops that final emission. Cumulative state is reset
            // at the start of the next recording, so stale text can't leak in.
            guard !newText.isEmpty else { return }
            viewModel.messageText = newText
        }
        .fileImporter(isPresented: $showDocumentPicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                loadAttachment(from: url)
            case .failure:
                break
            }
        }
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            loadAttachment(from: url)
            return true
        }
        #endif
        .alert("Attachment Error", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("OK") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
    }

    private func loadAttachment(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            attachmentError = "Could not read the selected file."
            return
        }
        guard data.count <= Self.maxAttachmentSize else {
            attachmentError = "File is too large. Maximum size is 10 MB."
            return
        }
        viewModel.pendingAttachment = (data: data, name: url.lastPathComponent, mimeType: url.mimeType)
    }

    private func attachmentPreview(name: String, data: Data, mimeType: String) -> some View {
        HStack {
            if mimeType.hasPrefix("image/"), let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button { viewModel.pendingAttachment = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondarySystemFill))
        .padding(.horizontal, 4)
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
    var toolName: String? = nil
    var onCancel: (() -> Void)? = nil
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
                } else if status == "busy" {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Server busy...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "hammer.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Running \(toolName ?? "tool")...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let onCancel {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.secondarySystemFill)
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
