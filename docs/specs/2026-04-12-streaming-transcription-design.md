# Streaming Transcription — Live Preview with Manual Send

**Status:** Draft
**Date:** 2026-04-12
**Supersedes:** Batch transcription mode from `2026-04-11-whisper-stt-design.md`

## Problem

The current push-to-talk flow (tap → record → tap stop → wait → auto-send) has two UX gaps:

1. **Blind recording** — the user has no feedback on what's being transcribed until recording stops
2. **No correction opportunity** — transcription auto-sends via `sendVoiceText()`, giving no chance to fix errors

Long recordings also hit context-budget limits in the batch path, causing truncation or silent failures.

## Solution

Replace the batch transcription path with WhisperKit's built-in `AudioStreamTranscriber`, which continuously transcribes audio in real-time. Words appear in the message input field as the user speaks. On stop, the text stays in the input field for editing before manual send.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Streaming API | WhisperKit `AudioStreamTranscriber` | Already ships with WhisperKit 0.18.0, handles mic capture + VAD + real-time loop internally |
| Live text target | Message input `TextField` | Reuses existing input field; user can edit after stop, no new UI components needed |
| Send mode | Manual (user taps Send) | Gives opportunity to correct transcription errors |
| Batch fallback | None — replace entirely | One code path to maintain; streaming handles all recording lengths |

## Scope

### In scope
- Replace `SpeechManager`'s batch recording/transcription with `AudioStreamTranscriber`
- Stream `currentText` into `messageText` (ChatViewModel's input field binding)
- Remove `AudioBufferCollector`, `convertBuffersToSamples()`, batch `transcribe()` call
- Remove `isTranscribing` state and spinner — text appears live, no waiting phase
- Remove `sendVoiceText()` — after stop, text is in the input field; user sends manually
- Remove `VoiceButton.onComplete` callback — no auto-send trigger needed

### Out of scope
- Team chat voice input (not yet implemented)
- Model changes (stays `openai_whisper-base`)
- TTS changes

## Architecture

### Data Flow (New)

```
USER TAPS MIC
  → SpeechManager.startRecording()
  → AudioStreamTranscriber.startStreamTranscription()
  → realtimeLoop() begins — continuously transcribes mic audio
  → isRecording = true

WHILE RECORDING (continuous, ~1s intervals)
  → AudioStreamTranscriber.stateChangeCallback fires
  → SpeechManager reads confirmedSegments + unconfirmedSegments
  → SpeechManager.liveText = confirmed + unconfirmed text
  → ChatView observes liveText → viewModel.messageText = liveText
  → TextField shows live words appearing

USER TAPS STOP
  → SpeechManager.stopRecording()
  → AudioStreamTranscriber.stopStreamTranscription()
  → isRecording = false
  → Final confirmed text stays in messageText
  → User reviews, edits if needed, taps Send
```

### Data Flow (Previous — being removed)

```
USER TAPS MIC → startRecording() → AVAudioEngine tap → buffer collection
USER TAPS STOP → stopRecording() → drain buffers → convert to 16kHz
  → whisperKit.transcribe(audioArray:) → wait → transcribedText = result
  → VoiceButton.onChange(isTranscribing) → sendVoiceText() → auto-send
```

## Files to Modify

### 1. `Managers/SpeechManager.swift` — Core rewrite

**Remove:**
- `AudioBufferCollector` class (lines 12-29)
- `private let audioEngine = AVAudioEngine()`
- `private let bufferCollector = AudioBufferCollector()`
- `@Published var isTranscribing = false`
- `@Published var transcribedText = ""`
- `convertBuffersToSamples(_:)` — entire method (~100 lines)
- `extractText(from:)` — no longer needed
- Diagnostic `print()` statements from `buildDecodingOptions()` — simplify the method
- `cleanupRecording(inputNode:)` — AVAudioEngine tap cleanup no longer needed
- Batch transcription `Task.detached` in `stopRecording()`

**Add:**
- `@Published var liveText: String = ""` — continuously updated during recording
- `private var streamTranscriber: AudioStreamTranscriber?`
- Updated `startRecording()` — creates and starts `AudioStreamTranscriber`
- Updated `stopRecording()` — stops stream, finalizes text

**Retain unchanged:**
- `@Published var isRecording`
- `@Published var isSpeaking`
- `@Published var modelReady`
- `var whisperPrompt` and `WhisperPromptBuilder` integration
- `private var whisperKit: WhisperKit?`
- `func loadModel()` — unchanged
- All TTS methods (`speak()`, `stopSpeaking()`, `bestVoice()`)
- `@Published var selectedVoiceId`

**AudioStreamTranscriber setup:**

```swift
func startRecording() {
    if isRecording {
        stopRecording()
        return
    }
    guard modelReady, let whisperKit else { return }

    if isSpeaking { stopSpeaking() }
    liveText = ""

    // Retain the existing mic permission pre-check for first-install UX.
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

    // AudioStreamTranscriber requires individual WhisperKit components, not
    // the WhisperKit instance itself. Only tokenizer is optional.
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

**Stop recording:**

```swift
func stopRecording() {
    // AudioStreamTranscriber is an actor — must await its methods.
    // Fire-and-forget the stop call; update local state immediately.
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

**buildDecodingOptions stays** but simplified (no need for logging since streaming handles its own diagnostics):

```swift
private func buildDecodingOptions() -> DecodingOptions? {
    guard let tokenizer = whisperKit?.tokenizer else { return nil }
    let tokens = tokenizer.encode(text: whisperPrompt)
        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    guard !tokens.isEmpty else { return nil }
    let clampedTokens = Array(tokens.prefix(50))
    return DecodingOptions(
        promptTokens: clampedTokens,
        chunkingStrategy: .vad
    )
}
```

### 2. `Views/VoiceButton.swift` — Simplify

**Remove:**
- `let onComplete: () -> Void` callback
- `isTranscribing` state and spinner
- `.onChange(of: speechManager.isTranscribing)` observer
- `.disabled` condition for `isTranscribing`

**Simplified:**

```swift
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

### 3. `Views/ChatView.swift` — Wire live text, remove onComplete

**Change at line ~228:**

```swift
// Before:
VoiceButton(speechManager: viewModel.speechManager) {
    viewModel.sendVoiceText()
}

// After:
VoiceButton(speechManager: viewModel.speechManager)
```

**Add `.onChange` observer** to pipe live text into the message input:

```swift
.onChange(of: viewModel.speechManager.liveText) { _, newText in
    if viewModel.speechManager.isRecording {
        viewModel.messageText = newText
    }
}
```

Attach this on the `inputBar` view (the `VStack` returned by `var inputBar: some View`), after existing `.onChange` modifiers.

### 4. `ViewModels/ChatViewModel.swift` — Remove sendVoiceText

**Remove:**
```swift
func sendVoiceText() {
    let text = speechManager.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    messageText = text
    sendText()
}
```

`sendText()` remains unchanged — it's the normal send path used by both typed and voice text now.

### 5. `KeeperTests/WhisperPromptBuilderTests.swift` — No changes

Prompt builder logic is unchanged. Existing tests remain valid.

### 6. `ViewModels/TeamViewModel.swift` — No changes

Only references `speechManager?.whisperPrompt` which is retained unchanged.

## State Machine

```
              ┌─────────┐
              │  IDLE    │  mic icon, liveText = ""
              └────┬─────┘
                   │ tap mic
              ┌────▼─────┐
              │RECORDING │  stop icon, liveText updating continuously
              └────┬─────┘
                   │ tap stop
              ┌────▼─────┐
              │ EDITING  │  mic icon, messageText = final text
              │          │  user can edit, then tap Send
              └──────────┘
```

Previous 3-state machine (idle → recording → transcribing) becomes 2-state (idle → recording). The "transcribing" state is eliminated because transcription happens continuously during recording.

## Testing

- Verify live text appears in TextField within ~1-2 seconds of speaking
- Verify text stabilizes (confirmed segments don't change) as speech progresses
- Verify after stop, text remains in input field and is fully editable
- Verify Send button works normally after voice input
- Verify long recordings (>60s) work without truncation
- Verify silence is handled gracefully (VAD skips dead air)
- Verify TTS still works after recording (audio session deactivated properly)
- Verify mic permission prompt still works on first use
- Verify model-not-ready state disables mic button
- macOS: verify recording works without AVAudioSession (iOS-only API)

## Risks

| Risk | Mitigation |
|------|------------|
| Only `tokenizer` is optional among WhisperKit components | Already guarded with `guard let`; other components are non-optional existentials |
| Continuous transcription drains battery on long recordings | Whisper base on ANE is efficient; monitor in testing |
| `liveText` updates too frequently, causing TextField jank | Debounce updates if needed (e.g., throttle to 200ms) |
| Unconfirmed segments flicker/change | Expected behavior — confirmed segments stabilize, unconfirmed are tentative. Users see final text settle naturally |
| AudioStreamTranscriber manages its own audio session | May conflict with our AVAudioSession setup — test and adjust |
