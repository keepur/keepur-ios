# UX Improvements Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Improve chat UX with file/image uploads, text selection on all bubbles, clickable links, and macOS settings cleanup.

**Architecture:** Four independent changes touching the view layer and WS protocol. File upload adds a PhotosPicker + document picker to the input bar, extends the WS message to carry base64 attachments, and adds attachment display in bubbles. Text selection and links are single-line additions to existing views. macOS settings cleanup removes the redundant gear button behind a `#if os(macOS)` guard.

**Tech Stack:** SwiftUI, PhotosUI, UniformTypeIdentifiers, MarkdownUI, SwiftData

---

### Task 1: Text Selection on All Message Bubbles

**Files:**
- Modify: `Views/MessageBubble.swift:30-31` (userBubble), `Views/MessageBubble.swift:123` (systemBubble), `Views/MessageBubble.swift:154` (toolBubble output)

Currently only assistant and unknown bubbles have `.textSelection(.enabled)`. User, system, and tool output text need it too.

- [ ] **Step 1:** Add `.textSelection(.enabled)` to user bubble `Text(message.text)` at line 30

```swift
Text(message.text)
    .font(.body)
    .textSelection(.enabled)
    .padding(.horizontal, 14)
```

- [ ] **Step 2:** Add `.textSelection(.enabled)` to system bubble `Text(message.text)` at line 123

```swift
Text(message.text)
    .font(.caption)
    .foregroundStyle(.secondary)
    .textSelection(.enabled)
    .padding(.vertical, 8)
```

- [ ] **Step 3:** Verify tool bubble output `Text(output)` at line 154 already has `.textSelection(.enabled)` — it does. No change needed.

- [ ] **Step 4:** Commit

```bash
git add Views/MessageBubble.swift
git commit -m "feat: enable text selection on user and system message bubbles"
```

---

### Task 2: Clickable Links in Messages

**Files:**
- Modify: `Views/MessageBubble.swift:30` (user bubble — use attributed string with link detection)
- Modify: `Views/MarkdownTheme+Keepur.swift` (verify MarkdownUI link handling — should already work)

MarkdownUI handles link taps by default for assistant messages. The issue is user messages use plain `Text()` with no link detection. We'll use `Text(AttributedString)` with markdown parsing to auto-linkify URLs in user bubbles.

- [ ] **Step 1:** In user bubble, parse message text as markdown `AttributedString` to auto-detect links. Fall back to plain text if parsing fails.

Replace the user bubble `Text(message.text)` with:

```swift
Text(Self.attributedText(message.text))
    .font(.body)
    .textSelection(.enabled)
```

- [ ] **Step 2:** Add a static helper to `MessageBubble` that converts plain text to `AttributedString` with link detection:

```swift
// MARK: - Link Detection

private static func attributedText(_ text: String) -> AttributedString {
    // Try markdown parsing first (handles URLs automatically)
    if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return attributed
    }
    return AttributedString(text)
}
```

- [ ] **Step 3:** Verify MarkdownUI assistant links work — MarkdownUI opens links in the default browser by default via SwiftUI's `OpenURLAction`. The existing `.link { ForegroundColor(.accentColor) }` in the theme is styling only; tap handling is automatic. No changes needed.

- [ ] **Step 4:** Commit

```bash
git add Views/MessageBubble.swift
git commit -m "feat: make URLs clickable in user message bubbles"
```

---

### Task 3: Remove Redundant macOS Per-Thread Settings Button

**Files:**
- Modify: `Views/ChatView.swift:79-106` (toolbar section)

On macOS, `SessionListView` already has a settings gear in the sidebar toolbar (line 99-105 of SessionListView.swift). The duplicate gear in `ChatView`'s toolbar opens the same global `SettingsView` — it's redundant on macOS. On iOS, the ChatView gear is the only way to access settings, so keep it there.

- [ ] **Step 1:** Wrap the settings gear button in the ChatView toolbar with `#if os(iOS)`:

```swift
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
```

- [ ] **Step 2:** Also guard the settings sheet so it doesn't compile dead code on macOS:

After the toolbar, wrap the settings sheet:

```swift
#if os(iOS)
.sheet(isPresented: $showSettings) {
    SettingsView(viewModel: viewModel)
}
#endif
```

- [ ] **Step 3:** Guard the `showSettings` state variable with `#if os(iOS)` or leave it (minor — unused var warning won't fire because it's still referenced in the `#if` block). Leave as-is to keep the diff minimal.

- [ ] **Step 4:** Commit

```bash
git add Views/ChatView.swift
git commit -m "fix: remove redundant settings button from macOS chat thread toolbar"
```

---

### Task 4: File & Image Upload in Chat

**Files:**
- Modify: `Views/ChatView.swift` (add attachment button to input bar, photo/file picker sheets)
- Modify: `ViewModels/ChatViewModel.swift` (add attachment state, send with attachment)
- Modify: `Models/Message.swift` (add optional attachment fields)
- Modify: `Models/WSMessage.swift` (extend WSOutgoing.message to carry attachment data)
- Modify: `Views/MessageBubble.swift` (display image/file attachments in bubbles)

#### Step 1: Extend the Message model with optional attachment fields

```swift
@Model
final class Message {
    @Attribute(.unique) var id: String
    var sessionId: String
    var text: String
    var role: String
    var timestamp: Date
    var attachmentName: String?
    var attachmentType: String?      // MIME type e.g. "image/jpeg", "application/pdf"
    var attachmentData: Data?        // raw file bytes (images stored for local display)

    init(
        id: String = UUID().uuidString,
        sessionId: String,
        text: String,
        role: String,
        timestamp: Date = .now,
        attachmentName: String? = nil,
        attachmentType: String? = nil,
        attachmentData: Data? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.role = role
        self.timestamp = timestamp
        self.attachmentName = attachmentName
        self.attachmentType = attachmentType
        self.attachmentData = attachmentData
    }
}
```

#### Step 2: Extend WSOutgoing to carry optional base64 attachment

Add an `attachment` case parameter to `.message`:

```swift
case message(text: String, sessionId: String, attachment: MessageAttachment? = nil)

struct MessageAttachment {
    let name: String
    let mimeType: String
    let base64Data: String
}
```

Update `encode()` for `.message` to include attachment fields when present:

```swift
case .message(let text, let sessionId, let attachment):
    var d: [String: Any] = ["type": "message", "text": text, "sessionId": sessionId]
    if let attachment {
        d["attachment"] = [
            "name": attachment.name,
            "mimeType": attachment.mimeType,
            "data": attachment.base64Data
        ]
    }
    dict = d
```

#### Step 3: Add attachment state to ChatViewModel

```swift
@Published var pendingAttachment: (data: Data, name: String, mimeType: String)? = nil
```

Update `sendText()` to include attachment when present:

```swift
func sendText() {
    let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachment = pendingAttachment
    guard !text.isEmpty || attachment != nil,
          let context = modelContext,
          let sessionId = currentSessionId else { return }

    let message = Message(
        sessionId: sessionId,
        text: text.isEmpty ? (attachment?.name ?? "attachment") : text,
        role: "user",
        attachmentName: attachment?.name,
        attachmentType: attachment?.mimeType,
        attachmentData: attachment?.data
    )
    context.insert(message)
    try? context.save()

    let wsAttachment: MessageAttachment? = attachment.map {
        MessageAttachment(name: $0.name, mimeType: $0.mimeType, base64Data: $0.data.base64EncodedString())
    }

    if statusFor(sessionId) != "idle" {
        pendingMessages.append((text: message.text, messageId: message.id, sessionId: sessionId))
        pendingMessageIds.insert(message.id)
    } else {
        ws.send(.message(text: message.text, sessionId: sessionId, attachment: wsAttachment))
    }
    messageText = ""
    pendingAttachment = nil
}
```

#### Step 4: Add attachment picker UI to ChatView input bar

Add imports and state:

```swift
import PhotosUI

@State private var selectedPhoto: PhotosPickerItem?
@State private var showDocumentPicker = false
@State private var showAttachmentMenu = false
```

Add attachment button to `inputBar` (before the TextField):

```swift
private var inputBar: some View {
    VStack(spacing: 8) {
        // Attachment preview
        if let attachment = viewModel.pendingAttachment {
            attachmentPreview(name: attachment.name, data: attachment.data, mimeType: attachment.mimeType)
        }

        HStack(spacing: 8) {
            // Attachment menu button
            Menu {
                Button {
                    showDocumentPicker = true
                } label: {
                    Label("Choose File", systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
            }
            .photosPicker(isPresented: .constant(false), selection: .constant(nil)) // handled separately

            // Photo picker
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
            }

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
                        && viewModel.pendingAttachment == nil
                            ? Color.gray.opacity(0.3) : Color.accentColor
                    )
            }
            .disabled(
                viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && viewModel.pendingAttachment == nil
            )
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial)
    .onChange(of: selectedPhoto) {
        Task {
            if let item = selectedPhoto,
               let data = try? await item.loadTransferable(type: Data.self) {
                let mimeType = "image/jpeg"
                let name = "photo.jpg"
                viewModel.pendingAttachment = (data: data, name: name, mimeType: mimeType)
            }
            selectedPhoto = nil
        }
    }
    .fileImporter(isPresented: $showDocumentPicker, allowedContentTypes: [.item]) { result in
        if case .success(let url) = result {
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
                let mimeType = url.mimeType
                viewModel.pendingAttachment = (data: data, name: url.lastPathComponent, mimeType: mimeType)
            }
        }
    }
}
```

#### Step 5: Add attachment preview and dismiss button

```swift
private func attachmentPreview(name: String, data: Data, mimeType: String) -> some View {
    HStack {
        if mimeType.hasPrefix("image/"), let uiImage = PlatformImage(data: data) {
            Image(platformImage: uiImage)
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

        Button {
            viewModel.pendingAttachment = nil
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondarySystemFill)
    )
    .padding(.horizontal, 4)
}
```

Add cross-platform image type alias at top of ChatView:

```swift
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
```

#### Step 6: Display attachments in MessageBubble

Add to user bubble, before the text:

```swift
private var userBubble: some View {
    HStack {
        Spacer(minLength: 60)
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 6) {
                    if let attachmentData = message.attachmentData,
                       let mimeType = message.attachmentType {
                        if mimeType.hasPrefix("image/"), let img = PlatformImage(data: attachmentData) {
                            Image(platformImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else if let name = message.attachmentName {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.fill")
                                    .font(.caption)
                                Text(name)
                                    .font(.caption)
                            }
                            .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    Text(Self.attributedText(message.text))
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.accentColor)
                )
                .foregroundStyle(.white)

                // ... existing waiting badge
            }

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
```

#### Step 7: Add URL mimeType helper

```swift
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
```

#### Step 8: Commit

```bash
git add Models/Message.swift Models/WSMessage.swift ViewModels/ChatViewModel.swift Views/ChatView.swift Views/MessageBubble.swift
git commit -m "feat: add file and image upload support to chat"
```
