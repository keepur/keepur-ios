# Replace Apple STT with On-Device WhisperKit

**Status:** Draft
**Date:** 2026-04-11

## Problem

Apple's `SFSpeechRecognizer` (hardcoded to `en-US`) performs poorly with accented English speakers. Transcription errors make voice input unreliable for a significant portion of users.

## Solution

Replace `SFSpeechRecognizer` with [WhisperKit](https://github.com/argmaxinc/WhisperKit) — an on-device, CoreML-optimized Swift package that runs OpenAI's Whisper model on the Apple Neural Engine. Whisper was trained on 680k hours of multilingual audio and handles accents significantly better.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Library | WhisperKit (SPM) | Native Swift, CoreML/ANE optimized, actively maintained |
| Model | `openai_whisper-base` (~150MB) | Best accuracy/size trade-off; big improvement over Apple STT for accents |
| Processing | On-device only | No latency, no network dependency |
| Transcription mode | Full-audio (no partial results) | Whisper processes complete audio for maximum accuracy |
| TTS | Unchanged | `AVSpeechSynthesizer` stays as-is |

## Scope

### In scope
- Replace `SFSpeechRecognizer` with WhisperKit in `SpeechManager`
- Record audio to buffer via `AVAudioEngine`, transcribe on stop
- Add a brief processing indicator in `VoiceButton` (user sees "transcribing" state)
- Model download on first use with progress indicator
- iOS + macOS support

### Out of scope
- Text-to-speech changes (TTS stays with `AVSpeechSynthesizer`)
- Real-time / streaming partial transcription
- Voice selection for STT (Whisper handles all accents automatically)
- Team chat voice input (not yet implemented; same pattern applies later)

## Architecture

### Data Flow (New)

```
USER TAPS MIC
  → SpeechManager.startRecording()
  → AVAudioEngine starts, audio buffers collected into [AVAudioPCMBuffer]
  → isRecording = true

USER TAPS STOP
  → SpeechManager.stopRecording()
  → AVAudioEngine stops, audio session deactivated (iOS)
  → isRecording = false, isTranscribing = true
  → Buffers downmixed to mono, resampled to 16 kHz, normalized to Float [-1.0, 1.0]
  → WhisperKit.transcribe(audioArray:) runs on ANE (off main thread)
  → transcribedText = result
  → isTranscribing = false

VoiceButton.onComplete fires (via onChange of isTranscribing)
  → viewModel.sendVoiceText()  (unchanged)
```

### Files to Modify

#### 1. Xcode SPM — Add WhisperKit dependency

```
https://github.com/argmaxinc/WhisperKit
```

Pin to latest stable release. Verify current version before adding — do not assume version number.

#### 2. `Managers/SpeechManager.swift` — Core replacement

**Remove:**
- `import Speech`
- `SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest`, `SFSpeechRecognitionTask`
- `authorizationStatus: SFSpeechRecognizerAuthorizationStatus` property
- `recognitionTask`, `recognitionRequest`, streaming recognition logic
- `requestPermission()` (replace with mic-only permission)
- Remove `recognitionRequest = nil` and `recognitionTask = nil` from `cleanupRecording()` — those properties no longer exist. The updated `cleanupRecording` retains only: `audioEngine.stop()`, `inputNode.removeTap(onBus: 0)`, `isRecording = false`.

**Retain in `init()`:**
- Keep the `selectedVoiceId` initialization from `UserDefaults` (used by TTS voice selection)
- Remove `speechRecognizer = SFSpeechRecognizer(locale: ...)` and `authorizationStatus` init

**Add:**
- `import WhisperKit`
- `private var whisperKit: WhisperKit?`
- `@Published var isTranscribing = false` — new state between stop and result
- `@Published var modelReady = false` — indicates model is loaded
- `private var audioBuffers: [AVAudioPCMBuffer] = []` — collect audio during recording
- `func loadModel()` — initialize WhisperKit with base model, called on app launch
- `private func convertBuffersToSamples(_:) -> [Float]` — audio format conversion
- Updated `startRecording()` — capture audio to buffer array instead of streaming to Apple STT
- Updated `stopRecording()` — convert buffers, transcribe, handle errors

**Model initialization — must run off main thread:**

`SpeechManager` is `@MainActor`. WhisperKit initialization involves model download + CoreML compilation, which can take 5–15 seconds on first launch. This work must happen off the main thread to avoid freezing the UI.

```swift
func loadModel() async {
    // Heavy work off main thread — model download + CoreML compilation
    // Explicit type annotation avoids double-optional ambiguity from try? inside Task.detached
    let kit: WhisperKit? = await Task.detached {
        try? await WhisperKit(model: "openai_whisper-base")
    }.value

    // Back on @MainActor for published property update.
    // Safe without [weak self] because loadModel() is called via .task{} on the root view —
    // when the view disappears, the parent Task is cancelled, which cancels the await on .value.
    whisperKit = kit
    modelReady = kit != nil
}
```

**Audio format conversion — critical for correct transcription:**

WhisperKit's `transcribe(audioArray:)` expects a `[Float]` array of audio samples at **16 kHz, mono, normalized to [-1.0, 1.0]**. The device microphone captures at native sample rate (typically 44.1 or 48 kHz, potentially stereo). Conversion steps:

```swift
private func convertBuffersToSamples(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
    // 1. Concatenate all buffer float channel data
    // 2. Downmix to mono (average channels if stereo)
    // 3. Resample from device sample rate to 16000 Hz
    //    - Use AVAudioConverter with output format:
    //      AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    //    - Or use vDSP.decimateBy() for simple integer-ratio resampling
    // 4. Return [Float] array normalized to [-1.0, 1.0] (PCM float is already in this range)
}
```

Use `AVAudioConverter` for robust resampling — it handles arbitrary sample rate ratios correctly.

**Recording — collect buffers:**

```swift
func startRecording() {
    // Prevent double-tap: if already recording, stop instead
    if isRecording {
        stopRecording()
        return
    }

    guard modelReady else { return }  // Don't record if model isn't loaded

    audioBuffers = []
    transcribedText = ""

    // Stop TTS if playing
    if isSpeaking { stopSpeaking() }

    #if os(iOS)
    let audioSession = AVAudioSession.sharedInstance()
    do {
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
        cleanupRecording(inputNode: audioEngine.inputNode)
        return
    }
    #endif

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    guard recordingFormat.channelCount > 0 else { return }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
        self?.audioBuffers.append(buffer)
    }

    audioEngine.prepare()
    do {
        try audioEngine.start()
        isRecording = true
    } catch {
        cleanupRecording(inputNode: inputNode)
    }
}
```

**Stop + transcribe — must run transcription off main thread:**

Same reasoning as `loadModel()` — `SpeechManager` is `@MainActor`, and an undecorated `Task {}` inherits the main actor. Whisper inference can take several seconds, so it must run via `Task.detached` to avoid blocking the UI.

```swift
func stopRecording() {
    let inputNode = audioEngine.inputNode
    cleanupRecording(inputNode: inputNode)

    #if os(iOS)
    // Deactivate audio session so TTS playback works immediately after
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif

    // Prepare samples on main thread (fast), then transcribe off main thread (slow)
    let samples = convertBuffersToSamples(audioBuffers)
    audioBuffers = []  // Free memory

    guard !samples.isEmpty else { return }
    guard let whisperKit else { return }

    isTranscribing = true

    Task.detached { [weak self] in
        // NOTE: Verify the exact transcribe() return type against the pinned WhisperKit version.
        // The API has evolved across releases. The intent is:
        //   1. Pass the [Float] audio samples to WhisperKit
        //   2. Extract the first TranscriptionResult's .text property
        //   3. Trim whitespace
        // Use do/catch if the pinned version's transcribe() is throwing, or plain await if not.
        do {
            let results = try await whisperKit.transcribe(audioArray: samples)
            let text = Self.extractText(from: results)
            await MainActor.run {
                self?.transcribedText = text
                self?.isTranscribing = false
            }
        } catch {
            print("Whisper transcription error: \(error)")
            await MainActor.run {
                self?.transcribedText = ""
                self?.isTranscribing = false
            }
        }
    }
}
```

**`extractText` helper — adapts to WhisperKit API version:**

```swift
/// Extract transcription text from WhisperKit results.
/// Handles both [TranscriptionResult] and [[TranscriptionResult]?] return types
/// depending on WhisperKit version. Verify against pinned version at implementation time.
private static func extractText(from results: [TranscriptionResult]) -> String {
    results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
```

If the pinned WhisperKit version returns `[[TranscriptionResult]?]` instead, adjust to:

```swift
private static func extractText(from results: [[TranscriptionResult]?]) -> String {
    results.first??.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
```

**Permissions:** Only microphone access needed. Remove `SFSpeechRecognizer.requestAuthorization`. Use `AVAudioApplication.requestRecordPermission` (iOS 17+) or check `AVAudioSession.sharedInstance().recordPermission`.

#### 3. `Views/VoiceButton.swift` — Add transcribing state

**Remove:**
- `import Speech`
- `isDenied` computed property (based on `SFSpeechRecognizerAuthorizationStatus`)
- `.disabled(isDenied)` modifier

**Add:**
- Third visual state for transcribing
- Disable when model not ready or transcribing
- Replace fixed 0.5s delay with `onChange` observer

```swift
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct VoiceButton: View {
    @ObservedObject var speechManager: SpeechManager
    let onComplete: () -> Void

    var body: some View {
        Button {
            if speechManager.isRecording {
                speechManager.stopRecording()
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
                // onComplete now fires via .onChange(of: isTranscribing) below
            } else {
                speechManager.startRecording()
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                #endif
            }
        } label: {
            ZStack {
                if speechManager.isTranscribing {
                    ProgressView()
                        .frame(width: 44, height: 44)
                } else if speechManager.isRecording {
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
            .animation(.easeInOut(duration: 0.2), value: speechManager.isTranscribing)
        }
        .disabled(!speechManager.modelReady || speechManager.isTranscribing)
        .onChange(of: speechManager.isTranscribing) { _, isTranscribing in
            if !isTranscribing && !speechManager.transcribedText.isEmpty {
                onComplete()
            }
        }
    }
}
```

Note: `onChange` only fires on transitions, so the initial `false` state does not trigger `onComplete`. The `transcribedText` is cleared at the start of each `startRecording()` call, preventing stale text from firing a spurious send.

#### 4. `Views/ChatView.swift` — No changes

The `VoiceButton` and `sendVoiceText()` integration stays the same.

#### 5. `ViewModels/ChatViewModel.swift` — Model initialization

Trigger model loading. `ChatViewModel` currently has no explicit `init` — add one or use `.onAppear` / `.task` in the root view:

```swift
// In ContentView.swift (where @StateObject chatViewModel is declared), add .task:
.task {
    await chatViewModel.speechManager.loadModel()
}
```

This ties model loading to the root view lifecycle. When the view disappears, the `.task` is cancelled, which safely cancels the `loadModel()` await. Do not place this in `KeepurApp.swift` — it has no access to `chatViewModel`.

#### 6. `Views/SettingsView.swift` — No changes needed

`SettingsView` currently only displays TTS voice selection — no speech recognition status is shown. No modifications required.

#### 7. Xcode Target Info — Remove stale permission

Remove `NSSpeechRecognitionUsageDescription` from the target's Info tab in Xcode (this key is managed in Xcode's build settings UI, not directly in the custom `Info.plist` file). Keep `NSMicrophoneUsageDescription`.

### Model Management

WhisperKit downloads CoreML models from HuggingFace on first initialization. The model is cached in the app's container (`Application Support/huggingface/`). No re-download needed after first use.

**First-launch experience:**
- `loadModel()` is called on app start (via `.task` on root view)
- While downloading/compiling: `modelReady = false`, mic button appears grayed out and disabled
- After model is ready: `modelReady = true`, mic button becomes active
- Model download happens once; subsequent launches load from cache (fast)

### Permissions Changes

| Permission | Before | After |
|------------|--------|-------|
| Microphone | Required | Required (unchanged) |
| Speech Recognition | Required (`NSSpeechRecognitionUsageDescription`) | **Removed** — no longer needed |

This is a win — one fewer permission prompt for users.

## Testing

- Verify transcription accuracy with accented speech samples
- Verify model downloads and caches correctly on first launch
- Verify recording → transcribing → result flow on both iOS and macOS
- Verify VoiceButton states: idle (gray when loading, blue when ready) → recording → transcribing → idle
- Verify TTS still works immediately after transcription (audio session deactivated properly)
- Verify app size impact (~150MB model, downloaded on first use — not in IPA)
- Verify behavior when model is still loading (button disabled, taps ignored)
- Verify error path: transcription failure resets `isTranscribing` and doesn't lock the UI
- Verify audio format conversion: mono 16 kHz output from various device sample rates

## Risks

| Risk | Mitigation |
|------|------------|
| 150MB model download on first use | Show loading state on mic button; model cached after first download |
| Transcription takes >2s on older devices | Base model runs well on A14+; could fall back to Tiny for older hardware |
| WhisperKit API changes | Pin to specific stable version in SPM |
| CoreML compilation slow on first launch | Runs off main thread via `Task.detached`; UI stays responsive |
| Audio session conflict with TTS | Explicitly deactivate record session after transcription completes |
