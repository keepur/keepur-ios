import SwiftUI
#if os(iOS)
import UIKit
#endif

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
                        .fill(KeepurTheme.Color.danger)
                        .frame(width: 44, height: 44)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(KeepurTheme.Color.fgOnDark)
                } else {
                    Image(systemName: KeepurTheme.Symbol.mic)
                        .font(.title2)
                        .foregroundStyle(speechManager.modelReady ? KeepurTheme.Color.honey500 : KeepurTheme.Color.fgMuted)
                        .frame(width: 44, height: 44)
                }
            }
            .frame(width: 44, height: 44)
            .animation(.easeInOut(duration: 0.2), value: speechManager.isRecording)
        }
        .disabled(!speechManager.modelReady)
        .alert("Microphone Access Needed", isPresented: $speechManager.showMicPermissionAlert) {
            Button("Cancel", role: .cancel) { }
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            #endif
        } message: {
            Text("Keepur needs microphone access to transcribe your voice. Enable it in Settings.")
        }
    }
}
