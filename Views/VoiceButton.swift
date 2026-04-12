import SwiftUI
#if os(iOS)
import UIKit
#endif

struct VoiceButton: View {
    @ObservedObject var speechManager: SpeechManager

    var body: some View {
        Button {
            speechManager.startRecording()
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            #endif
        } label: {
            if speechManager.isModelLoading {
                // Model downloading / compiling — show spinner so user knows it's loading
                ProgressView()
                    .frame(width: 44, height: 44)
            } else if speechManager.isTranscribing {
                // Whisper transcription in progress
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .foregroundStyle(speechManager.modelReady ? Color.accentColor : .gray)
                    .frame(width: 44, height: 44)
            }
        }
        .disabled(!speechManager.modelReady || speechManager.isRecording || speechManager.isTranscribing)
    }
}
