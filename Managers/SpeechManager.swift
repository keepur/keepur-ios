import Foundation
import AVFoundation
import Combine
import WhisperKit
#if os(iOS)
import UIKit
#endif

@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isRecording = false
    @Published var isSpeaking = false
    /// Live transcription text — updates continuously while recording.
    @Published var liveText: String = ""
    @Published var modelReady = false
    /// Set to true when the user taps the mic but has previously denied
    /// microphone permission. Views observe this to show a Settings alert.
    @Published var showMicPermissionAlert = false
    /// Whisper prompt text for domain vocabulary conditioning.
    /// Set by TeamViewModel on connect; tokenized lazily before each transcription.
    var whisperPrompt: String = WhisperPromptBuilder.staticPrompt
    @Published var selectedVoiceId: String? {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "selectedVoiceId") }
    }

    private var whisperKit: WhisperKit?
    private let synthesizer = AVSpeechSynthesizer()
    private var streamTranscriber: AudioStreamTranscriber?
    /// Accumulated text from confirmed segments that have already been absorbed
    /// across all transcription cycles. Survives the 30s rolling window slide.
    private var accumulatedConfirmedText: String = ""
    /// Highest `end` timestamp (seconds) of any confirmed segment we've already
    /// appended to `accumulatedConfirmedText`. Used to skip re-emitted segments
    /// that are still inside the current window.
    private var lastConfirmedEnd: Float = 0

    override init() {
        self.selectedVoiceId = UserDefaults.standard.string(forKey: "selectedVoiceId")
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    // MARK: - Model Loading

    func loadModel() async {
        // Heavy work off main thread — model download + CoreML compilation
        // Explicit type annotation avoids double-optional ambiguity from try? inside Task.detached
        let kit: WhisperKit? = await Task.detached {
            do {
                let pipe = try await WhisperKit(model: "openai_whisper-base")
                // Explicitly load models + tokenizer. The init alone does not
                // guarantee tokenizer is populated — without this, transcription
                // bails at `guard let tokenizer = whisperKit.tokenizer`.
                try await pipe.loadModels()
                return pipe
            } catch {
                return nil
            }
        }.value

        // Back on @MainActor for published property update.
        whisperKit = kit
        // Only mark ready if tokenizer actually materialized — otherwise the
        // mic button lights up but startRecording silently bails.
        modelReady = (kit?.tokenizer != nil)
    }

    // MARK: - Recording

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
        accumulatedConfirmedText = ""
        lastConfirmedEnd = 0

        // Retain mic permission pre-check for first-install UX.
        // AudioStreamTranscriber calls requestRecordPermission() internally,
        // but it doesn't retry on grant — without this guard the user would
        // need to tap mic twice on first install.
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        switch audioSession.recordPermission {
        case .granted:
            break
        case .undetermined:
            if #available(iOS 17, *) {
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    Task { @MainActor in
                        if granted { self?.startRecording() }
                        else { self?.showMicPermissionAlert = true }
                    }
                }
            } else {
                audioSession.requestRecordPermission { [weak self] granted in
                    Task { @MainActor in
                        if granted { self?.startRecording() }
                        else { self?.showMicPermissionAlert = true }
                    }
                }
            }
            return
        case .denied:
            showMicPermissionAlert = true
            return
        @unknown default:
            return
        }
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { return }
        #endif

        // Build decoding options with prompt tokens + VAD
        let options = buildDecodingOptions() ?? DecodingOptions(skipSpecialTokens: true, chunkingStrategy: .vad)

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
        ) { [weak self] _, newState in
            Task { @MainActor in
                guard let self else { return }
                let confirmed = newState.confirmedSegments.map { (end: $0.end, text: $0.text) }
                let unconfirmed = newState.unconfirmedSegments.map(\.text).joined(separator: " ")
                self.liveText = self.absorbTranscriptionTick(confirmed: confirmed, unconfirmed: unconfirmed)
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

    // MARK: - Test Hooks

    /// Pure accumulation step, extracted for unit testing. Mutates
    /// `accumulatedConfirmedText` and `lastConfirmedEnd`, returns the combined
    /// `liveText` value that would be published.
    /// - Parameters:
    ///   - confirmed: array of (end, text) pairs from `newState.confirmedSegments`
    ///   - unconfirmed: joined text from `newState.unconfirmedSegments`
    func absorbTranscriptionTick(confirmed: [(end: Float, text: String)], unconfirmed: String) -> String {
        // Epsilon guards against WhisperKit re-emitting a previously confirmed
        // segment with its `end` timestamp refined by a few ms as alignment
        // settles — without it, such a segment would be appended twice.
        let dedupEpsilon: Float = 0.05
        for segment in confirmed where segment.end > lastConfirmedEnd + dedupEpsilon {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                if accumulatedConfirmedText.isEmpty {
                    accumulatedConfirmedText = text
                } else {
                    accumulatedConfirmedText += " " + text
                }
            }
            lastConfirmedEnd = segment.end
        }
        let trimmedUnconfirmed = unconfirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [accumulatedConfirmedText, trimmedUnconfirmed]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return combined
    }

    /// Test hook: reset cumulative buffers as if a new recording were starting.
    func resetAccumulationForTesting() {
        accumulatedConfirmedText = ""
        lastConfirmedEnd = 0
        liveText = ""
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
            skipSpecialTokens: true,
            promptTokens: clampedTokens,
            chunkingStrategy: .vad
        )
    }
}
