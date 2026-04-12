import SwiftUI
#if os(iOS)
import UIKit
#endif

struct RecordingOverlayView: View {
    @ObservedObject var speechManager: SpeechManager
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Full-screen dark background
            Color.black
                .ignoresSafeArea()

            // Big pulsing stop button
            Button {
                speechManager.stopRecording()
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 120, height: 120)
                        .scaleEffect(isPulsing ? 1.15 : 0.95)

                    Image(systemName: "stop.fill")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .onDisappear {
            isPulsing = false
        }
    }
}
