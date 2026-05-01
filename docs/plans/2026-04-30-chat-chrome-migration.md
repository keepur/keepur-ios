# Chat Chrome Migration Implementation Plan

> **For agentic workers:** Use `dodi-dev:implement` to execute this plan.

**Goal:** Migrate `Views/ChatView.swift`, `Views/MessageInputBar.swift`, and `Views/VoiceButton.swift` to consume `KeepurTheme` tokens. Completes the chat-screen surface — the chrome around `MessageBubble` (which migrated in DOD-394).

**Architecture:** Three-file rewrite. No new components. No foundation changes.

**Tech Stack:** SwiftUI, PhotosUI, UniformTypeIdentifiers. iOS 26.2+ / macOS 15.0+.

**Spec:** [docs/specs/2026-04-30-chat-chrome-migration.md](../specs/2026-04-30-chat-chrome-migration.md)

**Out of scope:** ToolApprovalView, MarkdownTheme, link helpers, behavior of any control.

---

## File Map

| File | Change |
|------|--------|
| `Views/ChatView.swift` | **Rewrite** — toolbar speaker button colors, read-only bar typography, StatusIndicator surfaces & content tokens, LazyVStack spacing/padding |
| `Views/MessageInputBar.swift` | **Rewrite** — send + attachment buttons via Symbol constants & token foregrounds, pill input field, wax-surface attachment preview, popover paddings |
| `Views/VoiceButton.swift` | **Rewrite** — idle honey, recording danger circle, fgOnDark stop icon, Symbol.mic |

---

## Task 1: Preflight verification

- [ ] **Step 1.1:** Confirm worktree state.

```bash
pwd
git rev-parse --abbrev-ref HEAD
git log --oneline -2
```

Expected: `/Users/mayhuang/github/keepur-ios-DOD-395`, branch `DOD-395`, top commit is the spec, parent is the MessageBubble merge `5c16645`.

- [ ] **Step 1.2:** Confirm tokens used resolve.

```bash
for sym in honey500 fgMuted fgSecondaryDynamic fgOnDark danger bgSunkenDynamic; do
  printf "Color.%-22s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in body bodySm caption; do
  printf "Font.%-23s -> %s\n" "$sym" "$(grep -c "let $sym" Theme/KeepurTheme.swift)"
done
for sym in s1 s2 s3 s4; do
  printf "Spacing.%-20s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in sm lg pill; do
  printf "Radius.%-21s -> %s\n" "$sym" "$(grep -c "let $sym:" Theme/KeepurTheme.swift)"
done
for sym in send plus mic settings; do
  printf "Symbol.%-21s -> %s\n" "$sym" "$(grep -c "let $sym " Theme/KeepurTheme.swift)"
done
```

Expected: every count ≥ 1. (`Font.body` = 2 due to FontName.mono shadowing.)

- [ ] **Step 1.3:** Confirm no test references to these views.

```bash
grep -rln "ChatView\|MessageInputBar\|VoiceButton\|StatusIndicator" KeeperTests/ 2>/dev/null || echo "(no matches)"
```

Expected: `(no matches)`.

- [ ] **Step 1.4:** No commit.

---

## Task 2: Rewrite `Views/VoiceButton.swift`

**Files:** Modify `Views/VoiceButton.swift`

- [ ] **Step 2.1:** Replace the entire file.

```swift
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct VoiceButton: View {
    @ObservedObject var speechManager: SpeechManager

    var body: some View {
        Button {
            if speechManager.isRecording {
                speechManager.stopRecording()
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
            } else {
                speechManager.startRecording()
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                #endif
            }
        } label: {
            ZStack {
                if speechManager.isRecording {
                    Circle()
                        .fill(KeepurTheme.Color.danger)
                        .frame(width: 44, height: 44)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(KeepurTheme.Color.fgOnDark)
                } else {
                    Image(systemName: KeepurTheme.Symbol.mic)
                        .font(.title2)
                        .foregroundStyle(speechManager.modelReady ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted)
                        .frame(width: 44, height: 44)
                }
            }
            .frame(width: 44, height: 44)
            .animation(.easeInOut(duration: 0.2), value: speechManager.isRecording)
        }
        .disabled(!speechManager.modelReady)
        .alert("Microphone Access Needed", isPresented: $speechManager.showMicPermissionAlert) {
            Button("Cancel", role: .cancel) { }
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            #endif
        } message: {
            Text("Keepur needs microphone access to transcribe your voice. Enable it in Settings.")
        }
    }
}
```

Behavior preserved: recording state machine, haptics (medium on stop, heavy on start), `.disabled(!modelReady)`, mic permission alert with Cancel / Open Settings buttons, `stop.fill` literal kept inline (one use site).

---

## Task 3: Rewrite `Views/MessageInputBar.swift`

**Files:** Modify `Views/MessageInputBar.swift`

- [ ] **Step 3.1:** Replace the entire file.

```swift
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AttachmentData: Equatable {
    let data: Data
    let name: String
    let mimeType: String
}

struct MessageInputBar: View {
    @Binding var messageText: String
    @Binding var pendingAttachment: AttachmentData?
    @ObservedObject var speechManager: SpeechManager
    var onSend: () -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showDocumentPicker = false
    @State private var showAttachmentOptions = false
    @State private var attachmentError: String?
    private static let maxAttachmentSize = 10 * 1024 * 1024 // 10 MB

    var body: some View {
        VStack(spacing: 0) {
            if let attachment = pendingAttachment {
                attachmentPreview(name: attachment.name, data: attachment.data, mimeType: attachment.mimeType)
                    .padding(.top, KeepurTheme.Spacing.s2)
            }

            HStack(spacing: KeepurTheme.Spacing.s2) {
                Button { showAttachmentOptions = true } label: {
                    Image(systemName: KeepurTheme.Symbol.plus)
                        .font(.system(size: 26))
                        .foregroundStyle(KeepurTheme.Color.fgMuted)
                }
                .popover(isPresented: $showAttachmentOptions) {
                    VStack(spacing: 0) {
                        Button {
                            showAttachmentOptions = false
                            showDocumentPicker = true
                        } label: {
                            Label("Choose File", systemImage: "doc")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, KeepurTheme.Spacing.s4)
                                .padding(.vertical, KeepurTheme.Spacing.s2 + 2)
                        }
                        .buttonStyle(.plain)

                        Divider()

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Photo Library", systemImage: "photo")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, KeepurTheme.Spacing.s4)
                                .padding(.vertical, KeepurTheme.Spacing.s2 + 2)
                        }
                        .buttonStyle(.plain)
                        .onChange(of: selectedPhoto) {
                            if selectedPhoto != nil { showAttachmentOptions = false }
                        }
                    }
                    .frame(width: 200)
                    .padding(.vertical, KeepurTheme.Spacing.s1)
                }

                TextField("Message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(KeepurTheme.Font.body)
                    .padding(.horizontal, KeepurTheme.Spacing.s3)
                    .padding(.vertical, KeepurTheme.Spacing.s2)
                    .background(
                        RoundedRectangle(cornerRadius: KeepurTheme.Radius.pill)
                            .fill(.ultraThinMaterial)
                    )
                    .lineLimit(1...6)
                    .onSubmit { onSend() }

                VoiceButton(speechManager: speechManager)

                Button { onSend() } label: {
                    Image(systemName: KeepurTheme.Symbol.send)
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, KeepurTheme.Spacing.s3)
            .padding(.vertical, KeepurTheme.Spacing.s2)
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
                pendingAttachment = AttachmentData(data: data, name: name, mimeType: mimeType)
                selectedPhoto = nil
            }
        }
        .onReceive(speechManager.$liveText) { newText in
            guard !newText.isEmpty else { return }
            messageText = newText
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

    // MARK: - Private

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingAttachment != nil
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
        pendingAttachment = AttachmentData(data: data, name: url.lastPathComponent, mimeType: url.mimeType)
    }

    private func attachmentPreview(name: String, data: Data, mimeType: String) -> some View {
        HStack {
            if mimeType.hasPrefix("image/"), let img = PlatformImage(data: data) {
                Image(platformImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 80)
                    .clipShape(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm))
            } else {
                Image(systemName: "doc.fill")
                    .font(.title2)
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            }
            Text(name)
                .font(KeepurTheme.Font.caption)
                .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
                .lineLimit(1)
            Spacer()
            Button { pendingAttachment = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(KeepurTheme.Color.fgSecondaryDynamic)
            }
        }
        .padding(.horizontal, KeepurTheme.Spacing.s3)
        .padding(.vertical, KeepurTheme.Spacing.s1 + 2)
        .background(RoundedRectangle(cornerRadius: KeepurTheme.Radius.sm).fill(KeepurTheme.Color.bgSunkenDynamic))
        .padding(.horizontal, KeepurTheme.Spacing.s1)
    }
}
```

The `sendButtonColor` computed property is dropped (single use site, inline ternary is clearer). All other behavior identical: PhotosPicker / fileImporter / dropDestination flow, 10 MB size cap, attachment-error alert, speech transcript injection via `speechManager.$liveText`.

---

## Task 4: Rewrite `Views/ChatView.swift`

**Files:** Modify `Views/ChatView.swift`

- [ ] **Step 4.1:** Replace the entire file.

```swift
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
        return session.displayName
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
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: KeepurTheme.Spacing.s2) {
                    Button {
                        if viewModel.speechManager.isSpeaking {
                            viewModel.speechManager.stopSpeaking()
                        } else {
                            autoReadAloud.toggle()
                        }
                    } label: {
                        Image(systemName: viewModel.speechManager.isSpeaking ? "stop.circle.fill"
                              : autoReadAloud ? "speaker.wave.2.fill" : "speaker.slash")
                            .font(KeepurTheme.Font.bodySm)
                    }
                    .foregroundStyle(
                        viewModel.speechManager.isSpeaking ? KeepurTheme.Color.danger
                        : autoReadAloud ? KeepurTheme.Color.honey500
                        : KeepurTheme.Color.fgSecondaryDynamic
                    )

                    #if os(iOS)
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: KeepurTheme.Symbol.settings)
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
```

`HStack(spacing: KeepurTheme.Spacing.s1 + 2)` expresses the original `spacing: 6` (4+2). Animation timing (`0.6s easeInOut repeatForever`, `phase = .pi`), thinking dot offset formula (`sin(phase + Double(i) * 0.8) * 4`), and all status string formats unchanged.

---

## Task 5: Build + test verification

- [ ] **Step 5.1:** iOS build.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.2:** macOS build.

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -quiet 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.3:** iOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KeeperTests \
  -quiet > /tmp/dod-395-ios-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-395-ios-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-395-ios-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 5.4:** macOS unit tests.

```bash
set -o pipefail
xcodebuild test -project Keepur.xcodeproj -scheme Keepur \
  -destination 'platform=macOS' \
  -only-testing:KeeperTests \
  -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  > /tmp/dod-395-mac-test.log 2>&1
echo "EXIT=$?"
echo "passed: $(grep -c 'passed on' /tmp/dod-395-mac-test.log)"
echo "failed: $(grep -c 'failed on' /tmp/dod-395-mac-test.log)"
```

Expected: `EXIT=0`, `failed: 0`.

- [ ] **Step 5.5:** Single commit covering all three rewrites.

```bash
git add Views/ChatView.swift Views/MessageInputBar.swift Views/VoiceButton.swift
git commit -m "$(cat <<'EOF'
feat: migrate chat chrome to KeepurTheme tokens (DOD-395)

Completes the chat surface that DOD-394 (MessageBubble) started.
Three files together — they're visually one screen.

Visible changes:
- Send button: Symbol.send + honey500 (canSend) / fgMuted
  (disabled), replacing accentColor / gray
- Attachment + button: Symbol.plus + fgMuted
- Voice button idle: honey500 mic when modelReady, fgMuted otherwise
- Voice button recording: Color.danger filled circle with fgOnDark
  stop icon (was Color.red)
- Status indicator card: bgSunkenDynamic + Radius.lg (matches
  assistant message bubble's surface — visually grouped as
  "Claude is doing something")
- Status indicator content (thinking dots, busy/clock, tool/hammer,
  cancel xmark): fgSecondaryDynamic with Font.caption
- Toolbar speaker button: danger when speaking, honey500 when
  auto-read on, fgSecondaryDynamic when off
- Read-only bar: Font.caption + fgSecondaryDynamic
- Input field: Radius.pill (true capsule) + ultraThinMaterial bg
- Attachment preview: bgSunkenDynamic + Radius.sm (replacing
  secondarySystemFill + 12pt)

No behavior changes. PhotosPicker / fileImporter / dropDestination
flow, recording state machine + haptics, mic permission alert,
sheet presentation for ToolApproval and Settings, autoReadAloud
UserDefaults persistence, scroll-to-bottom on message arrival,
animation timings (0.2s for recording transition, 0.6s easeInOut
for thinking dots) all preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Final regression sweep

- [ ] **Step 6.1:** Confirm clean tree and 2 commits ahead.

```bash
git status --short
git log --oneline main..HEAD
```

Expected: empty status, 2 commits (spec + rewrite).
