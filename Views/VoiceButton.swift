import SwiftUI
import Speech
import UIKit

struct VoiceButton: View {
    @ObservedObject var speechManager: SpeechManager
    let onComplete: () -> Void

    private var isDenied: Bool {
        speechManager.authorizationStatus == .denied || speechManager.authorizationStatus == .restricted
    }

    var body: some View {
        Button {
            if speechManager.isRecording {
                speechManager.stopRecording()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    onComplete()
                }
            } else {
                speechManager.startRecording()
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
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
                        .foregroundStyle(isDenied ? .gray : Color.accentColor)
                        .frame(width: 44, height: 44)
                }
            }
            .frame(width: 44, height: 44)
            .animation(.easeInOut(duration: 0.2), value: speechManager.isRecording)
        }
        .disabled(isDenied)
    }
}
