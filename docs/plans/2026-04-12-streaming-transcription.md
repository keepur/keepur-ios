# Streaming Transcription Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Replace batch record→stop→wait→send voice input with real-time streaming transcription that shows live text as the user speaks.

**Architecture:** Swap `SpeechManager`'s manual `AVAudioEngine` tap + `AudioBufferCollector` + batch `whisperKit.transcribe()` with WhisperKit's `AudioStreamTranscriber`. The stream transcriber handles mic capture, VAD, and continuous transcription internally. A `liveText` published property pipes text into the message `TextField` via SwiftUI binding. On stop, text stays in the input for editing before manual send.

**Tech Stack:** SwiftUI, WhisperKit 0.18.0 (`AudioStreamTranscriber`), AVFoundation

---

### Task 1: Rewrite SpeechManager — Remove batch path, add streaming

**Files:**
- Modify: `Managers/SpeechManager.swift`

This is the core change. Remove the entire batch recording infrastructure and replace with `AudioStreamTranscriber`.

- [ ] **Step 1:** Remove the `AudioBufferCollector` class and its doc comment (lines 9-29). No import lines need to be removed — `AVFoundation` and `Combine` are still used by the remaining code.

Delete lines 9-29:

```swift
/// Thread-safe buffer collector for AVAudioEngine tap callbacks.
/// The tap runs on the audio render thread — appends are synchronous under lock,
/// so stopRecording() can drain all buffers with zero race condition.
final class AudioBufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock()
        let result = buffers
        buffers = []
        lock.unlock()
        return result
    }
}
```

- [ ] **Step 2:** Replace published properties and private state.

Change the properties block (currently lines 33-48) from:

```swift
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isSpeaking = false
    @Published var transcribedText = ""
    @Published var modelReady = false
    /// Whisper prompt text for domain vocabulary conditioning.
    /// Set by TeamViewModel on connect; tokenized lazily before each transcription.
    var whisperPrompt: String = WhisperPromptBuilder.staticPrompt
    @Published var selectedVoiceId: String? {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "selectedVoiceId") }
    }

    private var whisperKit: WhisperKit?
    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let bufferCollector = AudioBufferCollector()
```

To:

```swift
    @Published var isRecording = false
    @Published var isSpeaking = false
    /// Live transcription text — updates continuously while recording.
    @Published var liveText: String = ""
    @Published var modelReady = false
    /// Whisper prompt text for domain vocabulary conditioning.
    /// Set by TeamViewModel on connect; tokenized lazily before each transcription.
    var whisperPrompt: String = WhisperPromptBuilder.staticPrompt
    @Published var selectedVoiceId: String? {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "selectedVoiceId") }
    }

    private var whisperKit: WhisperKit?
    private let synthesizer = AVSpeechSynthesizer()
    private var streamTranscriber: AudioStreamTranscriber?
```

- [ ] **Step 3:** Replace `startRecording()` method.

Replace the entire `startRecording()` (currently lines 86-159) with:

```swift
    func startRecording() {
        // Prevent double-tap: if already recording, stop instead
        if isRecording {
            stopRecording()
            return
        }

        guard modelReady, let whisperKit else { return }

        // Stop TTS if playing
        if isSpeaking { stopSpeaking() }
        liveText = ""

        // Retain mic permission pre-check for first-install UX.
        // AudioStreamTranscriber calls requestRecordPermission() internally,
        // but it doesn't retry on grant — without this guard the user would
        // need to tap mic twice on first install.
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        guard audioSession.recordPermission == .granted else {
            if audioSession.recordPermission == .undetermined {
                if #available(iOS 17, *) {
                    AVAudioApplication.requestRecordPermission { [weak self] granted in
                        Task { @MainActor in
                            if granted { self?.startRecording() }
                        }
                    }
                } else {
                    audioSession.requestRecordPermission { [weak self] granted in
                        Task { @MainActor in
                            if granted { self?.startRecording() }
                        }
                    }
                }
            }
            return
        }
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { return }
        #endif

        // Build decoding options with prompt tokens + VAD
        let options = buildDecodingOptions() ?? DecodingOptions(chunkingStrategy: .vad)

        // AudioStreamTranscriber requires individual WhisperKit components.
        // Only tokenizer is optional among them.
        guard let tokenizer = whisperKit.tokenizer else { return }

        streamTranscriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options
        ) { [weak self] oldState, newState in
            // Callback fires on each transcription cycle (~1s).
            // Read confirmedSegments (finalized) + unconfirmedSegments (tentative).
            let confirmed = newState.confirmedSegments.map(\.text).joined(separator: " ")
            let unconfirmed = newState.unconfirmedSegments.map(\.text).joined(separator: " ")
            let combined = [confirmed, unconfirmed]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            Task { @MainActor in
                self?.liveText = combined
            }
        }

        isRecording = true
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif

        // startStreamTranscription() suspends inside realtimeLoop() until
        // recording stops. If permission was denied internally (does NOT throw),
        // the loop exits immediately — reset isRecording on completion.
        Task { [weak self] in
            do {
                try await self?.streamTranscriber?.startStreamTranscription()
            } catch {
                print("[SpeechManager] Stream transcription error: \(error)")
            }
            // Always reset when the loop exits (normal stop or error).
            await MainActor.run {
                if self?.isRecording == true {
                    self?.isRecording = false
                }
            }
        }
    }
```

- [ ] **Step 4:** Replace `stopRecording()` method.

Replace the entire `stopRecording()` (currently lines 161-200) with:

```swift
    func stopRecording() {
        // AudioStreamTranscriber is an actor — actor isolation requires await
        // even for synchronous methods. Fire-and-forget; update local state immediately.
        let transcriber = streamTranscriber
        streamTranscriber = nil
        isRecording = false
        Task { await transcriber?.stopStreamTranscription() }

        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        // liveText stays as-is — ChatView will have it in messageText for user to edit/send
    }
```

- [ ] **Step 5:** Remove batch transcription helpers and audio conversion.

Delete the entire `// MARK: - Transcription Helpers` section (lines 202-212: `extractText`) and the entire `// MARK: - Audio Format Conversion` section (lines 241-357: `convertBuffersToSamples`).

- [ ] **Step 6:** Simplify `buildDecodingOptions()`.

Replace the current method (lines 214-239) with:

```swift
    /// Tokenize the prompt string and build DecodingOptions for Whisper.
    /// Returns nil if the tokenizer isn't available (graceful fallback to no prompt).
    ///
    /// Important: `tokenizer.encode(text:)` may include special tokens (SOT, EOT,
    /// language tags) that corrupt the decoder when passed as `promptTokens`.
    /// Filter them out before use. See: https://github.com/argmaxinc/WhisperKit/issues/372
    private func buildDecodingOptions() -> DecodingOptions? {
        guard let tokenizer = whisperKit?.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: whisperPrompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        guard !tokens.isEmpty else { return nil }
        // Whisper base model has ~448 token context per 30s window.
        // 50 tokens preserves key vocabulary conditioning while
        // leaving ~398 tokens (~265 words) for transcription output.
        let clampedTokens = Array(tokens.prefix(50))
        return DecodingOptions(
            promptTokens: clampedTokens,
            chunkingStrategy: .vad
        )
    }
```

- [ ] **Step 7:** Remove `cleanupRecording(inputNode:)`.

Delete the entire method (currently lines 401-408):

```swift
    private func cleanupRecording(inputNode: AVAudioInputNode) {
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        isRecording = false
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
```

- [ ] **Step 8:** Verify the final file structure has these MARK sections in order:

```
// MARK: - AVSpeechSynthesizerDelegate
// MARK: - Model Loading
// MARK: - Recording
// MARK: - TTS (unchanged)
// MARK: - Private (only buildDecodingOptions and bestVoice remain)
```

- [ ] **Step 9:** Commit

```bash
git add Managers/SpeechManager.swift
git commit -m "feat(stt): replace batch transcription with AudioStreamTranscriber

Remove AudioBufferCollector, AVAudioEngine tap, convertBuffersToSamples,
and batch whisperKit.transcribe() call. Use WhisperKit's built-in
AudioStreamTranscriber for real-time streaming transcription.

New liveText published property updates continuously during recording.
isTranscribing and transcribedText removed — no more waiting state."
```

---

### Task 2: Simplify VoiceButton — Remove onComplete callback and spinner

**Files:**
- Modify: `Views/VoiceButton.swift`

- [ ] **Step 1:** Rewrite VoiceButton to remove the `onComplete` callback, `isTranscribing` spinner, and the `.onChange` observer.

Replace the entire file contents with:

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
                        .fill(Color.red)
                        .frame(width: 44, height: 44)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.title2)
                        .foregroundStyle(speechManager.modelReady ? Color.accentColor : .gray)
                        .frame(width: 44, height: 44)
                }
            }
            .frame(width: 44, height: 44)
            .animation(.easeInOut(duration: 0.2), value: speechManager.isRecording)
        }
        .disabled(!speechManager.modelReady)
    }
}
```

- [ ] **Step 2:** Commit

```bash
git add Views/VoiceButton.swift
git commit -m "feat(stt): simplify VoiceButton — remove onComplete and spinner

Drop isTranscribing spinner state and onComplete callback.
Two states only: idle (mic icon) and recording (stop icon).
Transcription happens live — no waiting phase needed."
```

---

### Task 3: Wire live text into ChatView input field

**Files:**
- Modify: `Views/ChatView.swift`

- [ ] **Step 1:** Replace the `VoiceButton` call site at line 228.

Change:

```swift
                VoiceButton(speechManager: viewModel.speechManager) {
                    viewModel.sendVoiceText()
                }
```

To:

```swift
                VoiceButton(speechManager: viewModel.speechManager)
```

- [ ] **Step 2:** Add `.onChange` observer to pipe live text into the message input.

Add this modifier on the `inputBar` VStack, after the existing `.onChange(of: selectedPhoto)` block (after line 268 — the closing `}` of that modifier), before the `.fileImporter` call at line 269:

```swift
        .onChange(of: viewModel.speechManager.liveText) { _, newText in
            if viewModel.speechManager.isRecording {
                viewModel.messageText = newText
            }
        }
```

- [ ] **Step 3:** Commit

```bash
git add Views/ChatView.swift
git commit -m "feat(stt): wire live transcription text into message input

VoiceButton no longer takes onComplete closure.
New .onChange observer pipes speechManager.liveText into messageText
during recording. After stop, text stays for editing before send."
```

---

### Task 4: Remove sendVoiceText from ChatViewModel

**Files:**
- Modify: `ViewModels/ChatViewModel.swift`

- [ ] **Step 1:** Delete `sendVoiceText()` (lines 103-108):

```swift
    func sendVoiceText() {
        let text = speechManager.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = text
        sendText()
    }
```

- [ ] **Step 2:** Verify no other references to `sendVoiceText` exist:

Run:
```bash
grep -r "sendVoiceText" --include="*.swift" .
```
Expected: No results (ChatView call site already removed in Task 3).

- [ ] **Step 3:** Verify no other references to `transcribedText` or `isTranscribing` exist outside SpeechManager:

Run:
```bash
grep -r "transcribedText\|isTranscribing" --include="*.swift" .
```
Expected: No results (all references removed in Tasks 1-3).

- [ ] **Step 4:** Commit

```bash
git add ViewModels/ChatViewModel.swift
git commit -m "feat(stt): remove sendVoiceText — manual send via existing sendText

Voice text now flows into messageText via live transcription binding.
User sends with the regular Send button, same as typed text."
```

---

### Task 5: Build verification

**Files:** None (verification only)

- [ ] **Step 1:** Build for iOS simulator:

Run:
```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2:** Build for macOS:

Run:
```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' -quiet 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3:** Run existing tests:

Run:
```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' -quiet 2>&1 | tail -10
```
Expected: All tests pass. `WhisperPromptBuilderTests` should be unaffected.

- [ ] **Step 4:** If build fails, fix compilation errors and amend the relevant commit.
