import Foundation
import AVFoundation
import Combine
import WhisperKit
#if os(iOS)
import UIKit
#endif

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

@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
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

        _ = bufferCollector.drain() // Clear any stale buffers
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

        let collector = bufferCollector
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            // AVAudioEngine reuses buffer memory — must copy before storing.
            // Append synchronously under lock (no async dispatch = no lost buffers).
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            collector.append(copy)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
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

        // Drain all buffers under lock — guaranteed complete, no race.
        let samples = convertBuffersToSamples(bufferCollector.drain())

        guard !samples.isEmpty else { return }
        guard let whisperKit else { return }

        isTranscribing = true
        let options = buildDecodingOptions()

        Task.detached { [weak self] in
            do {
                let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
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
    /// Whisper processes audio in 30-second windows — long recordings produce multiple
    /// TranscriptionResult entries. Join them all to avoid truncating the transcription.
    nonisolated private static func extractText(from results: [TranscriptionResult]) -> String {
        results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

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
        // Clamp to 224 tokens — Whisper's prompt token budget.
        let clampedTokens = Array(tokens.prefix(224))
        return DecodingOptions(promptTokens: clampedTokens)
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

        // Step 2: Set up converter from input format -> 16 kHz mono float
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
                let framesToProvide = min(Int(inNumberOfPackets), remaining)
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
                frameOffset += framesToProvide // Only advance by what was actually provided

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
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
}
