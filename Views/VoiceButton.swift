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
