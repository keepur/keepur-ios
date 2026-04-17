import Foundation
import AVFoundation
import Speech
import Combine
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
    @Published var selectedVoiceId: String? {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "selectedVoiceId") }
    }
    /// Per-agent voice overrides. Key: agent.id, value: AVSpeechSynthesisVoice.identifier.
    /// Missing key means the agent uses the global default voice.
    @Published var agentVoiceIds: [String: String] {
        didSet { UserDefaults.standard.set(agentVoiceIds, forKey: "agentVoiceIds") }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()

    override init() {
        self.selectedVoiceId = UserDefaults.standard.string(forKey: "selectedVoiceId")
        self.agentVoiceIds = (UserDefaults.standard.dictionary(forKey: "agentVoiceIds") as? [String: String]) ?? [:]
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

    // MARK: - Setup

    func loadModel() async {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            modelReady = speechRecognizer?.isAvailable ?? false
        case .notDetermined:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    Task { @MainActor in
                        self.modelReady = (newStatus == .authorized) && (self.speechRecognizer?.isAvailable ?? false)
                        continuation.resume()
                    }
                }
            }
        default:
            modelReady = false
        }
    }

    // MARK: - Recording

    func startRecording() {
        if isRecording {
            stopRecording()
            return
        }

        guard modelReady, let speechRecognizer, speechRecognizer.isAvailable else { return }

        if isSpeaking { stopSpeaking() }
        liveText = ""

        // Mic permission
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

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cleanupRecording()
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.liveText = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.cleanupRecording()
                }
            }
        }

        isRecording = true
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    func stopRecording() {
        recognitionRequest?.endAudio()
        cleanupRecording()
    }

    private func cleanupRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false

        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - TTS

    /// Speak text. If `agentId` is provided and has a stored per-agent voice override,
    /// that voice is used; otherwise the global default voice is used.
    func speak(_ text: String, agentId: String? = nil) {
        synthesizer.stopSpeaking(at: .immediate)

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
        #endif

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.05
        utterance.voice = voiceForAgent(agentId) ?? bestVoice()
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Speak text in a specific voice — used by voice preview UI.
    func speak(_ text: String, voice: AVSpeechSynthesisVoice) {
        synthesizer.stopSpeaking(at: .immediate)

        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
        #endif

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.05
        utterance.voice = voice
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Voice Resolution

    /// Resolve the per-agent voice override. Returns nil when no override is set
    /// or the stored identifier no longer resolves to an installed voice.
    func voiceForAgent(_ agentId: String?) -> AVSpeechSynthesisVoice? {
        guard let agentId,
              let voiceId = agentVoiceIds[agentId] else { return nil }
        return AVSpeechSynthesisVoice(identifier: voiceId)
    }

    /// Set or clear the voice override for an agent. Pass nil to revert to default.
    func setVoice(_ voiceId: String?, forAgent agentId: String) {
        if let voiceId {
            agentVoiceIds[agentId] = voiceId
        } else {
            agentVoiceIds.removeValue(forKey: agentId)
        }
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
}
