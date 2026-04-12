# WhisperKit STT Implementation Plan

> **For agentic workers:** Use dodi-dev:implement to execute this plan.

**Goal:** Replace Apple's `SFSpeechRecognizer` with on-device WhisperKit for significantly better accent accuracy.

**Architecture:** Swap the speech recognition backend in `SpeechManager` from streaming Apple STT to batch WhisperKit transcription. Audio is still captured via `AVAudioEngine` but collected into buffers instead of streamed. On stop, buffers are resampled to 16 kHz mono and passed to WhisperKit's `transcribe(audioArray:)` running off the main thread. `VoiceButton` gains a third "transcribing" state. TTS is unchanged.

**Tech Stack:** SwiftUI, WhisperKit (SPM), AVFoundation, CoreML

---

### Task 1: Add WhisperKit SPM Dependency

**Files:**
- Modify: `Keepur.xcodeproj/project.pbxproj`

Adding WhisperKit via Xcode SPM requires modifying the pbxproj. The existing MarkdownUI dependency (lines 545–561) shows the exact pattern.

- [ ] **Step 1:** Check the latest WhisperKit release version:

```bash
curl -s https://api.github.com/repos/argmaxinc/WhisperKit/releases/latest | grep tag_name
```

- [ ] **Step 2:** Add the WhisperKit package reference and product dependency to `project.pbxproj`.

Generate unique UUIDs for the new entries, then add three stanzas following the MarkdownUI pattern:

**a) Add `XCRemoteSwiftPackageReference` (in the section starting at line 545):**

```
		AABB11223344556677889900 /* XCRemoteSwiftPackageReference "WhisperKit" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/argmaxinc/WhisperKit";
			requirement = {
				kind = exactVersion;
				version = <VERSION_FROM_STEP_1>;
			};
		};
```

**b) Add `XCSwiftPackageProductDependency` (in the section starting at line 556):**

```
		BBCC22334455667788990011 /* WhisperKit */ = {
			isa = XCSwiftPackageProductDependency;
			package = AABB11223344556677889900 /* XCRemoteSwiftPackageReference "WhisperKit" */;
			productName = WhisperKit;
		};
```

**c) Wire into the main target:**

1. Add `AABB11223344556677889900` to the `packageReferences` array (line 198–200):
```
			packageReferences = (
				C1D2E3F4A5B6C7D8E9F0A1B2 /* XCRemoteSwiftPackageReference "swift-markdown-ui" */,
				AABB11223344556677889900 /* XCRemoteSwiftPackageReference "WhisperKit" */,
			);
```

2. Add `BBCC22334455667788990011` to `packageProductDependencies` (near line 146):
```
				D2E3F4A5B6C7D8E9F0A1B2C3 /* MarkdownUI */,
				BBCC22334455667788990011 /* WhisperKit */,
```

3. Add a `PBXBuildFile` entry for WhisperKit in Frameworks build phase (near line 73):
```
				CCDD33445566778899001122 /* WhisperKit in Frameworks */ = {isa = PBXBuildFile; productRef = BBCC22334455667788990011 /* WhisperKit */; };
```

And add `CCDD33445566778899001122` to the frameworks build phase files array.

**Note:** The UUIDs above are placeholders — generate real 24-character hex UUIDs that don't collide with existing ones in the file. Use `uuidgen | tr -d '-' | cut -c1-24` to generate them.

- [ ] **Step 3:** Verify the dependency resolves:

```bash
cd /Users/mokie/github/keepur-ios && xcodebuild -resolvePackageDependencies -project Keepur.xcodeproj -scheme Keepur 2>&1 | tail -10
```

Expected: Package resolution succeeds without errors.

- [ ] **Step 4:** Commit

```bash
git add Keepur.xcodeproj/project.pbxproj
git commit -m "chore: add WhisperKit SPM dependency"
```

---

### Task 2: Rewrite SpeechManager for WhisperKit

**Files:**
- Modify: `Managers/SpeechManager.swift` (full rewrite of STT logic, TTS untouched)

This is the core change. Remove all `Speech` framework code, add WhisperKit model loading, buffer-based recording, audio format conversion, and off-main-thread transcription.

- [ ] **Step 1:** Replace `Managers/SpeechManager.swift` with the following complete implementation:

```swift
import Foundation
import AVFoundation
import Combine
import WhisperKit

@MainActor
final class SpeechManager: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isSpeaking = false
    @Published var transcribedText = ""
    @Published var modelReady = false
    @Published var selectedVoiceId: String? {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "selectedVoiceId") }
    }

    private var whisperKit: WhisperKit?
    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private var audioBuffers: [AVAudioPCMBuffer] = []

    init() {
        self.selectedVoiceId = UserDefaults.standard.string(forKey: "selectedVoiceId")
    }

    // MARK: - Model Loading

    func loadModel() async {
        // Heavy work off main thread — model download + CoreML compilation
        // Explicit type annotation avoids double-optional ambiguity from try? inside Task.detached
        let kit: WhisperKit? = await Task.detached {
            try? await WhisperKit(model: "openai_whisper-base")
        }.value

        // Back on @MainActor for published property update.
        whisperKit = kit
        modelReady = kit != nil
    }

    // MARK: - Recording

    func startRecording() {
        // Prevent double-tap: if already recording, stop instead
        if isRecording {
            stopRecording()
            return
        }

        guard modelReady else { return }

        // Request mic permission if not yet granted (iOS 17+)
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        guard audioSession.recordPermission == .granted else {
            if audioSession.recordPermission == .undetermined {
                // Request mic permission — use iOS 17+ API with fallback
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
            // If denied, do nothing — button is tappable but mic won't work.
            // User must grant permission in system Settings.
            return
        }
        #endif

        audioBuffers = []
        transcribedText = ""

        // Stop TTS if playing
        if isSpeaking { stopSpeaking() }

        #if os(iOS)
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
            // AVAudioEngine reuses buffer memory — must copy before dispatching
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            Task { @MainActor in
                self?.audioBuffers.append(copy)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            cleanupRecording(inputNode: inputNode)
        }
    }

    func stopRecording() {
        let inputNode = audioEngine.inputNode
        cleanupRecording(inputNode: inputNode)

        #if os(iOS)
        // Deactivate audio session so TTS playback works immediately after
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        // Prepare samples on main thread (fast), then transcribe off main thread (slow)
        let samples = convertBuffersToSamples(audioBuffers)
        audioBuffers = []

        guard !samples.isEmpty else { return }
        guard let whisperKit else { return }

        isTranscribing = true

        Task.detached { [weak self] in
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

    // MARK: - Transcription Helpers

    /// Extract transcription text from WhisperKit results.
    /// Verify the return type against the pinned WhisperKit version at build time.
    /// If the version returns [[TranscriptionResult]?] instead of [TranscriptionResult],
    /// adjust to: results.first??.first?.text
    private static func extractText(from results: [TranscriptionResult]) -> String {
        results.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Audio Format Conversion

    /// Converts recorded audio buffers to 16 kHz mono Float array for WhisperKit.
    /// WhisperKit expects [Float] at 16000 Hz, mono, normalized to [-1.0, 1.0].
    ///
    /// Strategy: Pre-concatenate all small capture buffers into one large input buffer,
    /// then convert in a single pass. This avoids the multi-buffer slicing problem where
    /// AVAudioConverter's input callback could partially consume a buffer and silently
    /// drop frames.
    private func convertBuffersToSamples(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        guard let firstBuffer = buffers.first else { return [] }

        let inputFormat = firstBuffer.format

        // AVAudioEngine's outputFormat(forBus:) typically returns float32 on modern
        // Apple platforms, but some macOS audio interfaces may produce int16/int32.
        // AVAudioConverter handles format conversion, but our concatenation loop uses
        // floatChannelData — guard for float format and bail if unexpected.
        guard inputFormat.commonFormat == .pcmFormatFloat32 else {
            print("Unexpected audio format: \(inputFormat.commonFormat) — expected pcmFormatFloat32")
            return []
        }

        // Step 1: Pre-concatenate all capture buffers into one contiguous input buffer
        let totalInputFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard totalInputFrames > 0 else { return [] }

        guard let combinedBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(totalInputFrames)
        ) else { return [] }

        for buffer in buffers {
            guard let srcData = buffer.floatChannelData,
                  let dstData = combinedBuffer.floatChannelData else { continue }
            let frameCount = Int(buffer.frameLength)
            let offset = Int(combinedBuffer.frameLength)
            for ch in 0..<Int(inputFormat.channelCount) {
                dstData[ch].advanced(by: offset)
                    .update(from: srcData[ch], count: frameCount)
            }
            combinedBuffer.frameLength += buffer.frameLength
        }

        // Step 2: Set up converter from input format → 16 kHz mono float
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { return [] }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return [] }

        // Step 3: Convert in chunks, looping until all input is consumed
        let ratio = 16000.0 / inputFormat.sampleRate
        let estimatedOutputFrames = Int(Double(totalInputFrames) * ratio) + 1024
        let chunkCapacity: AVAudioFrameCount = 4096

        var allSamples: [Float] = []
        allSamples.reserveCapacity(estimatedOutputFrames)

        // Track how many frames of the combined buffer the converter has consumed.
        // The input callback may be called multiple times per convert() call —
        // we provide slices of the combined buffer starting at frameOffset.
        var frameOffset = 0
        var status: AVAudioConverterOutputStatus = .haveData

        while status == .haveData {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: chunkCapacity
            ) else { break }

            status = converter.convert(to: outputBuffer, error: nil) { inNumberOfPackets, outStatus in
                let totalFrames = Int(combinedBuffer.frameLength)
                let remaining = totalFrames - frameOffset
                guard remaining > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                // Provide only as many frames as the converter requests (inNumberOfPackets),
                // or fewer if we don't have that many left. For PCM, packets == frames.
                let framesToProvide = min(Int(inNumberOfPackets.pointee), remaining)
                guard let slice = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: AVAudioFrameCount(framesToProvide)
                ) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                if let src = combinedBuffer.floatChannelData,
                   let dst = slice.floatChannelData {
                    for ch in 0..<Int(inputFormat.channelCount) {
                        dst[ch].update(from: src[ch].advanced(by: frameOffset), count: framesToProvide)
                    }
                }
                slice.frameLength = AVAudioFrameCount(framesToProvide)
                frameOffset += framesToProvide  // Only advance by what was actually provided

                // Tell the converter how many packets we actually provided
                inNumberOfPackets.pointee = AVAudioPacketCount(framesToProvide)
                outStatus.pointee = .haveData
                return slice
            }

            if status == .error { break }

            // Append converted chunk
            if let channelData = outputBuffer.floatChannelData {
                let frameCount = Int(outputBuffer.frameLength)
                allSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
            }
        }

        return allSamples
    }

    // MARK: - TTS (unchanged)

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
        #endif

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.05
        utterance.voice = bestVoice()
        isSpeaking = true
        synthesizer.speak(utterance)
        Task {
            try? await Task.sleep(for: .seconds(Double(text.count) / 15.0))
            self.isSpeaking = false
        }
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func bestVoice() -> AVSpeechSynthesisVoice? {
        if let id = selectedVoiceId,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }
        if let premium = voices.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = voices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - Private

    private func cleanupRecording(inputNode: AVAudioInputNode) {
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        isRecording = false
    }
}
```

- [ ] **Step 2:** Verify the file compiles (will need Task 1 complete first — WhisperKit import)

- [ ] **Step 3:** Commit

```bash
git add Managers/SpeechManager.swift
git commit -m "feat: replace SFSpeechRecognizer with WhisperKit in SpeechManager"
```

---

### Task 3: Update VoiceButton for Transcribing State

**Files:**
- Modify: `Views/VoiceButton.swift` (full rewrite — 52 lines → ~45 lines)

Remove `Speech` framework dependency, add transcribing spinner state, replace 0.5s delay with `onChange` observer, gate on `modelReady`.

- [ ] **Step 1:** Replace `Views/VoiceButton.swift` with:

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
                // onComplete fires via .onChange(of: isTranscribing) below
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
        .onChange(of: speechManager.isTranscribing) {
            if !speechManager.isTranscribing && !speechManager.transcribedText.isEmpty {
                onComplete()
            }
        }
    }
}
```

- [ ] **Step 2:** Commit

```bash
git add Views/VoiceButton.swift
git commit -m "feat: add transcribing state to VoiceButton, remove Speech framework dependency"
```

---

### Task 4: Add Model Loading to ContentView

**Files:**
- Modify: `Views/ContentView.swift:31` (add `.task` modifier)

Trigger WhisperKit model loading when the root view appears. Uses `.task {}` on the `Group` so it's tied to the view lifecycle.

- [ ] **Step 1:** Add `.task(id:)` modifier to the `Group`, chained after the last `.onChange` modifier and **before** the closing `}` of `var body`. Insert between the closing `}` of `.onChange(of: teamViewModel.isAuthenticated)` (line 55) and the closing `}` of `body` (line 56):

```swift
        .task(id: isPaired) {
            guard isPaired else { return }
            await chatViewModel.speechManager.loadModel()
        }
```

This uses `.task(id: isPaired)` so it:
- Skips model download when the app is not yet paired (no 150MB download on first launch before pairing)
- Re-runs when `isPaired` transitions to `true` after pairing completes

The full modifier chain on the `Group` becomes:
```swift
        .onAppear { ... }
        .onChange(of: scenePhase) { ... }
        .onChange(of: chatViewModel.isAuthenticated) { ... }
        .onChange(of: teamViewModel.isAuthenticated) { ... }
        .task(id: isPaired) {
            guard isPaired else { return }
            await chatViewModel.speechManager.loadModel()
        }
```

- [ ] **Step 2:** Commit

```bash
git add Views/ContentView.swift
git commit -m "feat: load WhisperKit model on app launch via .task on ContentView"
```

---

### Task 5: Remove NSSpeechRecognitionUsageDescription

**Files:**
- Modify: `Keepur.xcodeproj/project.pbxproj` (if the key is in build settings)

The `NSSpeechRecognitionUsageDescription` Info.plist key is no longer needed since we removed `SFSpeechRecognizer`. It may be stored in Xcode's target Info tab (embedded in the pbxproj build settings) rather than in the custom `Info.plist` file.

- [ ] **Step 1:** Search for the key in the project file:

```bash
grep -n "NSSpeechRecognition" /Users/mokie/github/keepur-ios/Keepur.xcodeproj/project.pbxproj /Users/mokie/github/keepur-ios/Info.plist
```

- [ ] **Step 2:** If found, remove the `NSSpeechRecognitionUsageDescription` entry. Keep `NSMicrophoneUsageDescription`.

- [ ] **Step 3:** Commit (if changes were made)

```bash
git add Keepur.xcodeproj/project.pbxproj Info.plist
git commit -m "chore: remove NSSpeechRecognitionUsageDescription (no longer using Speech framework)"
```

---

### Task 6: Build Verification

**Files:** None (verification only)

- [ ] **Step 1:** Build the project for both iOS and macOS:

```bash
cd /Users/mokie/github/keepur-ios
xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

```bash
xcodebuild build -project Keepur.xcodeproj -scheme Keepur -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: Both builds succeed with no errors.

- [ ] **Step 2:** Run existing tests to verify no regressions:

```bash
xcodebuild test -project Keepur.xcodeproj -scheme Keepur -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: All existing tests pass (WSMessageAttachmentTests, ContextClearedTests, etc.)

- [ ] **Step 3:** If WhisperKit's `transcribe(audioArray:)` API signature doesn't match what we wrote (return type or throws vs non-throws), adjust `SpeechManager.stopRecording()` and the `extractText` pattern accordingly. The spec documents both `[TranscriptionResult]` and `[[TranscriptionResult]?]` return type variants — use whichever matches the pinned version.
