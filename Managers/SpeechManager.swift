import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechManager: ObservableObject {
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var transcribedText = ""
    @Published var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published var selectedVoiceId: String? {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "selectedVoiceId") }
    }

    private var speechRecognizer: SFSpeechRecognizer?
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    init() {
        self.selectedVoiceId = UserDefaults.standard.string(forKey: "selectedVoiceId")
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                if status == .authorized {
                    self?.startRecording()
                }
            }
        }
    }

    func startRecording() {
        if isRecording {
            stopRecording()
            return
        }

        guard authorizationStatus == .authorized else {
            requestPermission()
            return
        }

        // Stop TTS if playing
        if isSpeaking { stopSpeaking() }

        transcribedText = ""
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.channelCount > 0 else {
            recognitionRequest = nil
            return
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcribedText = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.cleanupRecording(inputNode: inputNode)
                }
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
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
        recognitionRequest?.endAudio()
        audioEngine.stop()
        isRecording = false
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)

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

    private func cleanupRecording(inputNode: AVAudioInputNode) {
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }
}
